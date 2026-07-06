[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive technician diagnostic CLI; the colored console summary is the primary deliverable alongside the written report file.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $OutputPath = Join-Path $desktop ("OSIT-WiFi-Diagnostics-{0}.txt" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
}

$sections = New-Object System.Collections.Generic.List[string]
function Add-Section {
    param([string]$Title, [string]$Content)
    $sections.Add("===== $Title =====`r`n$Content`r`n") | Out-Null
}

$config = $null
try {
    if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
    $config = Get-DeploymentConfig -UsbRoot $UsbRoot
} catch {
    Add-Section -Title 'Config lookup' -Content "Could not resolve the deployment USB or config: $($_.Exception.Message)"
}

$configuredSsid = if ($config -and $config.ContainsKey('msp_wifi_setup')) { [string](ConvertTo-PlainHashtable $config.msp_wifi_setup).ssid } else { 'OneSolution' }
if ([string]::IsNullOrWhiteSpace($configuredSsid)) { $configuredSsid = 'OneSolution' }

# 1. Driver capabilities: does the installed WLAN driver actually support the configured
# authentication/encryption and 802.11w (PMF), which some WPA2/WPA3-transition APs require.
Add-Section -Title 'WLAN driver capabilities (netsh wlan show drivers)' -Content ((netsh wlan show drivers) -join "`r`n")

# 2. Current interface state: connected SSID/BSSID, negotiated auth/cipher, signal, channel.
Add-Section -Title 'Current WLAN interface state (netsh wlan show interfaces)' -Content ((netsh wlan show interfaces) -join "`r`n")

# 3. What the access point(s) actually broadcast for this SSID, per BSSID: this is ground
# truth for what authentication/encryption the AP itself supports, independent of any
# profile configured on this machine.
Add-Section -Title "Access point scan results for SSID '$configuredSsid' (netsh wlan show networks mode=bssid)" -Content ((netsh wlan show networks mode=bssid) -join "`r`n")

# 4. Saved profile: what security type Windows currently has stored for this SSID, and the
# actual stored key. A stale profile from an earlier failed attempt is a common cause of
# "network settings have changed" prompts even after the config is fixed.
Add-Section -Title "Saved WLAN profile for '$configuredSsid' (netsh wlan show profile name key=clear)" -Content ((netsh wlan show profile name="$configuredSsid" key=clear 2>&1) -join "`r`n")
Add-Section -Title 'All saved WLAN profiles (netsh wlan show profiles)' -Content ((netsh wlan show profiles) -join "`r`n")

# 5. Adapter and driver health: confirms the WLAN NIC driver is actually bound and enabled,
# and flags any other networking device in a real problem state (excluding phantom/ghost
# devices for previously-connected-but-absent hardware, which are normal noise).
$wirelessAdapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11' }
Add-Section -Title 'Wireless adapter(s) (Get-NetAdapter)' -Content ($wirelessAdapters | Format-List Name, InterfaceDescription, Status, MacAddress, LinkSpeed, DriverVersion | Out-String)
$problemDevices = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' -and $_.Problem -ne 'CM_PROB_PHANTOM' }
$problemDevicesContent = if ($problemDevices) { $problemDevices | Format-Table FriendlyName, Status, Problem -AutoSize | Out-String } else { 'None found.' }
Add-Section -Title 'Network devices with a real problem code (excludes phantom/ghost devices)' -Content $problemDevicesContent

# 6. WLAN-AutoConfig operational log: the authoritative source for exactly why a connection
# attempt failed (association reject, 4-way handshake timeout, wrong password, etc.), with
# a specific reason in the event message rather than just "did not connect".
try {
    $wlanEvents = Get-WinEvent -LogName 'Microsoft-Windows-WLAN-AutoConfig/Operational' -MaxEvents 60 -ErrorAction Stop |
        Select-Object TimeCreated, Id, LevelDisplayName, Message
    Add-Section -Title 'WLAN-AutoConfig operational log (most recent 60 events)' -Content ($wlanEvents | Format-List | Out-String)
} catch {
    Add-Section -Title 'WLAN-AutoConfig operational log' -Content "Could not read this event log: $($_.Exception.Message)"
}

# 7. This toolkit's own MspWifiSetup step logs from the most recent deployment run, if the
# USB is present: exact netsh exit codes and the toolkit's own recorded outcome.
if ($config) {
    try {
        $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
        $state = Read-DeploymentState -StatePath $paths.StateFile
        if ($state) {
            $mspWifiContent = if ($state.ContainsKey('msp_wifi_setup')) { $state.msp_wifi_setup | ConvertTo-Json -Depth 6 } else { 'Not present in state (step has not completed).' }
            Add-Section -Title 'Deployment state: msp_wifi_setup field' -Content $mspWifiContent

            $identity = Get-DeviceIdentity
            $safeDevice = Get-DeviceFolderName -Identity $identity
            $logDir = Join-Path (Join-Path $paths.Logs $safeDevice) $state.deployment_run_id
            if (Test-Path -LiteralPath $logDir -PathType Container) {
                $wifiLogs = @(Get-ChildItem -LiteralPath $logDir -Filter 'msp-wifi-*.log' -ErrorAction SilentlyContinue)
                foreach ($logFile in $wifiLogs) {
                    Add-Section -Title "Toolkit log: $($logFile.Name)" -Content (Get-Content -LiteralPath $logFile.FullName -Raw)
                }
                $eventsPath = Join-Path $logDir 'events.jsonl'
                if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
                    $wifiEventLines = Get-Content -LiteralPath $eventsPath | Where-Object { $_ -match 'wifi|MspWifi' }
                    Add-Section -Title 'Toolkit structured log lines mentioning WiFi' -Content ($wifiEventLines -join "`r`n")
                }
            } else {
                Add-Section -Title 'Toolkit deployment logs' -Content "No log directory found for the most recent run: $logDir"
            }
        } else {
            Add-Section -Title 'Deployment state' -Content 'No deployment_state.json found on the USB.'
        }
    } catch {
        Add-Section -Title 'Toolkit deployment logs' -Content "Could not read toolkit state/logs: $($_.Exception.Message)"
    }
}

$report = $sections -join "`r`n"
Set-Content -LiteralPath $OutputPath -Value $report -Encoding UTF8 -Force

Write-Host ''
Write-Host "Full diagnostic report written to: $OutputPath" -ForegroundColor Green
Write-Host 'Send this file back for review. Key summary below.' -ForegroundColor Green
Write-Host ''

$currentInterface = (netsh wlan show interfaces) -join "`r`n"
Write-Host '--- Current connection state ---' -ForegroundColor Cyan
Write-Host $currentInterface
Write-Host ''
Write-Host "--- Saved profile auth/cipher for '$configuredSsid' ---" -ForegroundColor Cyan
(netsh wlan show profile name="$configuredSsid" 2>&1) | Select-String -Pattern 'Authentication|Cipher|Security key'
Write-Host ''
Write-Host "--- What the access point is broadcasting for '$configuredSsid' ---" -ForegroundColor Cyan
netsh wlan show networks mode=bssid | Select-String -Pattern "SSID.*:\s*$([regex]::Escape($configuredSsid))\s*$" -Context 0,6
