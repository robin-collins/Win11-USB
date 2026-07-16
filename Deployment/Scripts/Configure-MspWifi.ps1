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

$wifi = Get-MspWifiConfig -Config $config
if (-not [bool]$wifi.enabled) {
    Write-Log -Level Info -Message 'MSP WiFi setup is disabled by config (msp_wifi_setup.enabled=false); skipping. Preflight will still verify internet connectivity.'
    return
}

$configuredSsid = [string]$wifi.ssid
if ([string]::IsNullOrWhiteSpace($configuredSsid)) { throw 'msp_wifi_setup.ssid must not be empty when MSP WiFi setup is enabled.' }

# Deployment\WifiProfiles\Primary.xml (e.g. exported via `netsh wlan export profile key=clear`)
# takes priority over msp_wifi_setup's discrete ssid/password_env_var/authentication/encryption
# fields when present: it already carries a real, working profile including its plaintext key,
# so there is nothing left to build or look up a password for. msp_wifi_setup.ssid still names
# which network is primary (and is cross-checked against the file below); it just is not the
# thing actually imported when the file exists.
$primaryProfilePath = Join-Path $paths.WifiProfiles $script:PrimaryWifiProfileFileName
$usePrimaryProfileFile = Test-Path -LiteralPath $primaryProfilePath -PathType Leaf

$ssid = $configuredSsid
if ($usePrimaryProfileFile) {
    $ssid = Get-WlanProfileSsid -ProfileXmlPath $primaryProfilePath
    if ($ssid -ne $configuredSsid) {
        Write-Log -Level Warn -Message "Primary WiFi profile '$primaryProfilePath' is for SSID '$ssid', which does not match configured msp_wifi_setup.ssid '$configuredSsid'. Using '$ssid' from the profile file -- update msp_wifi_setup.ssid to match, or replace the profile file, to remove this warning."
    }
}

$passwordEnvVar = [string]$wifi.password_env_var
if ([string]::IsNullOrWhiteSpace($passwordEnvVar)) { $passwordEnvVar = 'OSIT_WIFI_PASSWORD' }
if (-not $usePrimaryProfileFile -and $passwordEnvVar -ne 'OSIT_WIFI_PASSWORD') { Write-Log -Level Warn -Message "Custom WiFi password variable '$passwordEnvVar' configured; OSIT_WIFI_PASSWORD remains the documented standard." }

$profileSource = if ($usePrimaryProfileFile) { "primary profile file $primaryProfilePath" } else { 'msp_wifi_setup config' }
Write-Log -Level Info -Message "MSP WiFi setup started: target SSID '$ssid' (source: $profileSource)."

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

$wifiPassword = $null
if (-not $usePrimaryProfileFile) {
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
    $dryRunActionText = if ($usePrimaryProfileFile) {
        "would import primary WLAN profile '$ssid' from $primaryProfilePath and connect (timeout ${timeout}s)"
    } else {
        "would create WLAN profile '$ssid' (authentication=$authentication, encryption=$encryption) and connect (timeout ${timeout}s)"
    }
    Write-DryRunAction -State $state -Step 'MspWifiSetup' -Action $dryRunActionText -Data ([ordered]@{
            ssid                    = $ssid
            source                  = if ($usePrimaryProfileFile) { $primaryProfilePath } else { 'msp_wifi_setup config' }
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
    Write-Log -Level Success -Message "Dry run: would connect to primary WiFi SSID '$ssid'. No WLAN profile was added or changed."
    return
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
        Set-Content -LiteralPath $profilePath -Value $profileXml -Encoding UTF8 -Force -ErrorAction Stop
        return (Import-WlanProfileFile -ProfileXmlPath $profilePath -Ssid $Ssid -Connect -ConnectTimeoutSeconds $TimeoutSeconds)
    } finally {
        Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    }
}

if ($usePrimaryProfileFile) {
    # The imported profile already carries whatever authentication/encryption combination was
    # working when it was exported, so there is no discrete "wrong auth type" configuration
    # mistake to retry around the way there can be for the config-built profile below -- if this
    # fails, the network itself is the problem (out of range, key rotated since export, etc.).
    Write-Log -Level Info -Message "Importing primary WLAN profile for '$ssid' from $primaryProfilePath and connecting (timeout ${timeout}s)."
    $connected = Import-WlanProfileFile -ProfileXmlPath $primaryProfilePath -Ssid $ssid -Connect -ConnectTimeoutSeconds $timeout
    $usedAuthentication = 'FromProfileFile'
    if (-not $connected) {
        Remove-WlanProfile -Ssid $ssid
        throw "Timed out waiting for primary WiFi SSID '$ssid' (imported from $primaryProfilePath) to connect within $timeout second(s). Verify the network is in range and the profile's saved key is still correct."
    }
} else {
    Write-Log -Level Info -Message "Creating WLAN profile for '$ssid' ($authentication/$encryption) and connecting (timeout ${timeout}s)."
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
        Remove-WlanProfile -Ssid $ssid
        throw "Timed out waiting for WiFi SSID '$ssid' to connect using both '$authentication' and the WPA2PSK fallback. Verify the access point's actual security mode and OSIT_WIFI_PASSWORD."
    }
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
