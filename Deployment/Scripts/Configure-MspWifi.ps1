[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
$paths = Get-DeploymentPaths -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }
$config = Get-DeploymentConfig -UsbRoot $UsbRoot
$state = Read-DeploymentState -StatePath $StatePath

function Get-MspWifiConfig {
    param([hashtable]$Config)

    $settings = @{
        enabled = $true
        ssid = 'OneSolution'
        password_env_var = 'OSIT_WIFI_PASSWORD'
        authentication = 'WPA2PSK'
        encryption = 'AES'
        connect_timeout_seconds = 60
    }

    if ($Config.ContainsKey('msp_wifi_setup') -and $null -ne $Config.msp_wifi_setup) {
        $override = ConvertTo-PlainHashtable $Config.msp_wifi_setup
        foreach ($key in $override.Keys) { $settings[$key] = $override[$key] }
    }
    return $settings
}

function ConvertTo-WlanXmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-ConnectedWifiSsid {
    $interfaces = netsh.exe wlan show interfaces 2>$null
    if (-not $interfaces) { return $null }
    foreach ($line in $interfaces) {
        if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$' -and $line -notmatch '^\s*BSSID\s*:') {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Wait-WifiConnection {
    param(
        [string]$Ssid,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $connected = Get-ConnectedWifiSsid
        if ($connected -eq $Ssid) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

$wifi = Get-MspWifiConfig -Config $config
if (-not [bool]$wifi.enabled) {
    Write-Log -Level Info -Message 'MSP WiFi setup is disabled by config.'
    return
}

$ssid = [string]$wifi.ssid
if ([string]::IsNullOrWhiteSpace($ssid)) { throw 'msp_wifi_setup.ssid must not be empty when MSP WiFi setup is enabled.' }
$passwordEnvVar = [string]$wifi.password_env_var
if ([string]::IsNullOrWhiteSpace($passwordEnvVar)) { $passwordEnvVar = 'OSIT_WIFI_PASSWORD' }
if ($passwordEnvVar -ne 'OSIT_WIFI_PASSWORD') { Write-Log -Level Warn -Message "Custom WiFi password variable '$passwordEnvVar' configured; OSIT_WIFI_PASSWORD remains the documented standard." }

$connectedSsid = Get-ConnectedWifiSsid
if ($connectedSsid -eq $ssid) {
    Write-Log -Level Success -Message "Already connected to WiFi SSID '$ssid'."
    return
}

# A wired (or otherwise connected) machine does not need MSP WiFi; failing here would
# stop deployments on Ethernet-connected desktops and docked notebooks.
if (Test-InternetConnectivity) {
    Write-Log -Level Success -Message 'Internet connectivity is already available; skipping MSP WiFi setup.'
    return
}

$wirelessAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11' })
if ($wirelessAdapters.Count -eq 0) {
    Write-Log -Level Warn -Message 'MSP WiFi setup is enabled but no wireless network adapter was detected; skipping. Preflight will verify internet connectivity.'
    return
}

$wifiPassword = if ($passwordEnvVar -eq 'OSIT_WIFI_PASSWORD') {
    Get-OsitWifiPassword -SearchRoots @($UsbRoot)
} else {
    $value = $null
    foreach ($target in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($passwordEnvVar, $target)
        if (-not [string]::IsNullOrWhiteSpace($value)) { break }
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = Get-DotEnvValue -Path (Join-Path $UsbRoot '.env') -Name $passwordEnvVar
    }
    $value
}

if ([string]::IsNullOrWhiteSpace($wifiPassword)) {
    throw "$passwordEnvVar was not found in environment variables or USB-root .env. Run Initialize-UsbDeployment.ps1 to prepare the USB."
}

$authentication = [string]$wifi.authentication
$encryption = [string]$wifi.encryption
$timeout = [int]$wifi.connect_timeout_seconds
if ($timeout -lt 10) { $timeout = 10 }

# Dry-run invariant (FABLE_TASKS.md T07a): config validity, password presence, existing
# connectivity, and wireless-adapter detection above all ran for real -- that is the genuine
# value of a dry run for this step. But actually adding/connecting a WLAN profile is a real
# machine mutation, and simply letting it fall through to Invoke-ExternalCommand's generic
# dry-run refusal (T05) is not enough on its own here: the polling loop below
# (Wait-WifiConnection) would still spin for up to $timeout seconds waiting for a connection
# that a synthesized "success" never actually establishes, then treat that as a real failure,
# retry the WPA2PSK fallback, spin again, and finally throw -- turning a dry run into a false
# failure. So the whole connect-and-wait sequence is skipped outright and replaced with a
# single logged action, and `netsh wlan add/connect` is never invoked at all in dry-run.
if (Test-DeploymentDryRun) {
    Write-DryRunAction -State $state -Step 'MspWifiSetup' -Action "would create WLAN profile '$ssid' (authentication=$authentication, encryption=$encryption) and connect (timeout ${timeout}s)" -Data ([ordered]@{
            ssid                    = $ssid
            authentication          = $authentication
            encryption              = $encryption
            connect_timeout_seconds = $timeout
        })

    $dryRunResult = [ordered]@{
        ssid           = $ssid
        status         = 'DryRun'
        authentication = $authentication
        timestamp      = (Get-Date).ToString('o')
    }
    if ($state) {
        $state.msp_wifi_setup = $dryRunResult
        Write-DeploymentState -State $state -StatePath $StatePath
    }

    Write-StructuredLog -Level Info -Message 'MSP WiFi setup dry run completed' -Data $dryRunResult
    Write-Log -Level Success -Message "Dry run: would connect to MSP WiFi SSID '$ssid' using $authentication/$encryption. No WLAN profile was added or changed."
    return
}

function Remove-MspWifiProfile {
    param([string]$Ssid)
    # Deletes any existing profile for this SSID first. A stale profile from an earlier run
    # (or one with a mismatched authentication type) makes Windows treat the network as
    # "settings changed" and silently refuse to connect, forcing an interactive re-entry.
    Invoke-ExternalCommand -FilePath netsh.exe -Arguments @('wlan', 'delete', 'profile', "name=$Ssid") -AllowedExitCodes @(0, 1) -LogName 'msp-wifi-delete-profile.log' | Out-Null
}

function Connect-MspWifiProfile {
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The WLAN profile XML format (netsh wlan add profile) requires the pre-shared key as plaintext keyMaterial; there is no SecureString/PSCredential equivalent for this XML.')]
    param(
        [string]$Ssid,
        [string]$Authentication,
        [string]$Encryption,
        [string]$Password,
        [int]$TimeoutSeconds
    )

    $profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$(ConvertTo-WlanXmlText $Ssid)</name>
  <SSIDConfig>
    <SSID>
      <name>$(ConvertTo-WlanXmlText $Ssid)</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>$(ConvertTo-WlanXmlText $Authentication)</authentication>
        <encryption>$(ConvertTo-WlanXmlText $Encryption)</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$(ConvertTo-WlanXmlText $Password)</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@

    $profilePath = Join-Path $env:TEMP ("OSIT-WiFi-{0}.xml" -f (Get-SafeName -Value $Ssid))
    try {
        Remove-MspWifiProfile -Ssid $Ssid
        Set-Content -LiteralPath $profilePath -Value $profileXml -Encoding UTF8 -Force -ErrorAction Stop
        Invoke-ExternalCommand -FilePath netsh.exe -Arguments @('wlan', 'add', 'profile', "filename=$profilePath", 'user=all') -LogName 'msp-wifi-add-profile.log' | Out-Null
        Invoke-ExternalCommand -FilePath netsh.exe -Arguments @('wlan', 'connect', "name=$Ssid", "ssid=$Ssid") -AllowedExitCodes @(0, 1) -LogName 'msp-wifi-connect.log' | Out-Null
    } finally {
        Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    }

    return (Wait-WifiConnection -Ssid $Ssid -TimeoutSeconds $TimeoutSeconds)
}

$connected = Connect-MspWifiProfile -Ssid $ssid -Authentication $authentication -Encryption $encryption -Password $wifiPassword -TimeoutSeconds $timeout
$usedAuthentication = $authentication

# WPA2-Personal is accepted by pure-WPA2 access points and by WPA2/WPA3-transition
# (mixed) access points alike, so it is a safe universal fallback when the configured
# authentication type does not match what the access point actually negotiates.
if (-not $connected -and $authentication -ne 'WPA2PSK') {
    Write-Log -Level Warn -Message "Could not connect to '$ssid' using $authentication/$encryption within $timeout second(s). Retrying with WPA2PSK/AES."
    $connected = Connect-MspWifiProfile -Ssid $ssid -Authentication 'WPA2PSK' -Encryption 'AES' -Password $wifiPassword -TimeoutSeconds $timeout
    if ($connected) {
        $usedAuthentication = 'WPA2PSK'
        Write-Log -Level Warn -Message "Connected using WPA2PSK fallback instead of configured '$authentication'. Update msp_wifi_setup.authentication in deployment_config.json to WPA2PSK to avoid this delay on future deployments."
    }
}

if (-not $connected) {
    # Leaving a mismatched profile behind would make the next manual connection attempt
    # fail with the same "network settings have changed" prompt until it is removed.
    Remove-MspWifiProfile -Ssid $ssid
    throw "Timed out waiting for WiFi SSID '$ssid' to connect using both '$authentication' and the WPA2PSK fallback. Verify the access point's actual security mode and OSIT_WIFI_PASSWORD."
}

$result = [ordered]@{
    ssid = $ssid
    status = 'Connected'
    authentication = $usedAuthentication
    timestamp = (Get-Date).ToString('o')
}
if ($state) {
    $state.msp_wifi_setup = $result
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'MSP WiFi setup completed' -Data $result
Write-Log -Level Success -Message "Connected to MSP WiFi SSID '$ssid' using $usedAuthentication."
