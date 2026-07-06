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

$profileName = $ssid
$profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$(ConvertTo-WlanXmlText $profileName)</name>
  <SSIDConfig>
    <SSID>
      <name>$(ConvertTo-WlanXmlText $ssid)</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>$(ConvertTo-WlanXmlText $authentication)</authentication>
        <encryption>$(ConvertTo-WlanXmlText $encryption)</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$(ConvertTo-WlanXmlText $wifiPassword)</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@

$profilePath = Join-Path $env:TEMP ("OSIT-WiFi-{0}.xml" -f (Get-SafeName -Value $ssid))
try {
    Set-Content -LiteralPath $profilePath -Value $profileXml -Encoding UTF8 -Force -ErrorAction Stop
    Invoke-ExternalCommand -FilePath netsh.exe -Arguments @('wlan', 'add', 'profile', "filename=$profilePath", 'user=all') -LogName 'msp-wifi-add-profile.log' | Out-Null
    Invoke-ExternalCommand -FilePath netsh.exe -Arguments @('wlan', 'connect', "name=$ssid", "ssid=$ssid") -AllowedExitCodes @(0, 1) -LogName 'msp-wifi-connect.log' | Out-Null
} finally {
    Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
}

if (-not (Wait-WifiConnection -Ssid $ssid -TimeoutSeconds $timeout)) {
    throw "Timed out waiting for WiFi SSID '$ssid' to connect."
}

$result = [ordered]@{
    ssid = $ssid
    status = 'Connected'
    timestamp = (Get-Date).ToString('o')
}
if ($state) {
    $state.msp_wifi_setup = $result
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'MSP WiFi setup completed' -Data $result
Write-Log -Level Success -Message "Connected to MSP WiFi SSID '$ssid'."
