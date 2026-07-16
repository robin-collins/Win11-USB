<#
    .SYNOPSIS
        Captures everything needed to reproduce a known-good company WiFi connection in
        Deployment\Config\deployment_config.json's msp_wifi_setup block, by running on a
        notebook that is ALREADY connected to that WiFi.

    .DESCRIPTION
        Configure-MspWifi.ps1 connects deployment notebooks to WiFi by building a pre-shared-key
        WLAN profile XML from msp_wifi_setup's ssid/authentication/encryption, then falling back
        to WPA2PSK/AES once if that fails. If a fresh deployment always fails at the WiFi step
        even though the wireless NIC itself is up and working, the most common causes are:

          1. msp_wifi_setup.authentication/.encryption in deployment_config.json do not match
             what the access point actually negotiates (for example the AP is WPA3-Personal or a
             WPA2/WPA3-transition network, but the config still says WPA2PSK/AES).
          2. The access point is WPA2-Enterprise or WPA3-Enterprise (802.1X) -- Configure-MspWifi.ps1
             cannot connect to this at all today: its WLAN profile XML is hardcoded
             <useOneX>false</useOneX> and only ever carries a static pre-shared key, never 802.1X
             credentials/certificates. This script detects and flags that case explicitly rather
             than producing a config that would never have worked.

        Run this on any notebook that is CURRENTLY connected to the company WiFi -- it does not
        need the deployment USB, Deployment\Config, or any toolkit files present; it is a
        standalone diagnostic. It captures the live negotiated authentication/cipher, the saved
        WLAN profile (including the pre-shared key in cleartext, if there is one), what the
        access point itself broadcasts, and the installed WLAN driver's capabilities -- then
        prints the exact msp_wifi_setup JSON block to paste into deployment_config.json.

    .PARAMETER Ssid
        SSID to capture. Defaults to whatever SSID this machine is currently connected to.

    .PARAMETER OutputPath
        Full diagnostic report path. Defaults to a timestamped file on the current user's Desktop.

    .EXAMPLE
        .\Deployment\Scripts\Capture-WifiConnection.ps1

        Captures the currently-connected SSID's settings and prints the recommended
        msp_wifi_setup config block.
#>

[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive technician diagnostic CLI; the colored console summary and recommended config block are the primary deliverable alongside the written report file.')]
[CmdletBinding()]
param(
    [string]$Ssid,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $OutputPath = Join-Path $desktop ("OSIT-WiFi-Capture-{0}.txt" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
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

if ([string]::IsNullOrWhiteSpace($Ssid)) {
    $Ssid = Get-ConnectedWifiSsid
    if ([string]::IsNullOrWhiteSpace($Ssid)) {
        Write-Host 'Not currently connected to any WiFi network, and -Ssid was not supplied.' -ForegroundColor Red
        Write-Host 'Connect to the company WiFi first, then rerun this script (or pass -Ssid explicitly to inspect a saved-but-not-connected profile).' -ForegroundColor Red
        exit 1
    }
}

Write-Host "Capturing WiFi settings for SSID '$Ssid'; full report will be written to: $OutputPath" -ForegroundColor Cyan

$sections = New-Object System.Collections.Generic.List[string]
function Add-Section {
    param([string]$Title, [string]$Content)
    $sections.Add("===== $Title =====`r`n$Content`r`n") | Out-Null
}

Add-Section -Title 'WLAN driver capabilities (netsh wlan show drivers)' -Content ((netsh wlan show drivers) -join "`r`n")

$interfaceText = (netsh wlan show interfaces) -join "`r`n"
Add-Section -Title 'Current WLAN interface state (netsh wlan show interfaces)' -Content $interfaceText

$profileClearText = (netsh wlan show profile name="$Ssid" key=clear 2>&1) -join "`r`n"
Add-Section -Title "Saved WLAN profile for '$Ssid' (netsh wlan show profile name key=clear)" -Content $profileClearText

Add-Section -Title "Access point scan results for SSID '$Ssid' (netsh wlan show networks mode=bssid)" -Content ((netsh wlan show networks mode=bssid) -join "`r`n")

# Best-effort mapping from netsh's human-readable "show profile" Authentication/Cipher display
# strings to the WLAN profile XML enum values Configure-MspWifi.ps1 (Deployment\Scripts) actually
# needs in msp_wifi_setup.authentication/.encryption. Only the FIRST Authentication/Cipher pair in
# the profile output is used -- matching what Connect-MspWifiProfile actually negotiates -- since
# netsh sometimes lists a second, fallback cipher entry.
$authenticationMap = [ordered]@{
    'Open'                                       = 'open'
    'WEP'                                        = 'shared'
    'WPA-Personal'                               = 'WPAPSK'
    'WPA2-Personal'                               = 'WPA2PSK'
    'WPA3-Personal'                               = 'WPA3SAE'
    'WPA2-Personal/WPA3-Personal Transition Mode' = 'WPA2WPA3TRANSITION'
}
$encryptionMap = [ordered]@{
    'None'     = 'none'
    'WEP'      = 'WEP'
    'TKIP'     = 'TKIP'
    'CCMP'     = 'AES'
    'CCMP-128' = 'AES'
    'AES'      = 'AES'
    'GCMP'     = 'GCMP256'
    'GCMP-256' = 'GCMP256'
    'GCMP256'  = 'GCMP256'
}

$displayAuthentication = $null
$displayCipher = $null
$isEnterprise = $false
$hasClearKey = $false
foreach ($line in ($profileClearText -split "`r`n")) {
    if ($line -match '^\s*Authentication\s*:\s*(.+?)\s*$') {
        if (-not $displayAuthentication) { $displayAuthentication = $Matches[1].Trim() }
        if ($Matches[1] -match 'Enterprise') { $isEnterprise = $true }
    }
    if ($line -match '^\s*Cipher\s*:\s*(.+?)\s*$' -and -not $displayCipher) {
        $displayCipher = $Matches[1].Trim()
    }
    if ($line -match '^\s*Key Content\s*:\s*(.+?)\s*$') {
        $hasClearKey = $true
    }
}

$recommendedAuthentication = if ($displayAuthentication -and $authenticationMap.Contains($displayAuthentication)) { $authenticationMap[$displayAuthentication] } else { $null }
$recommendedEncryption = if ($displayCipher -and $encryptionMap.Contains($displayCipher)) { $encryptionMap[$displayCipher] } else { $null }

$reportContent = $sections -join "`r`n"
Set-Content -LiteralPath $OutputPath -Value $reportContent -Encoding UTF8 -Force

Write-Host ''
Write-Host "Full diagnostic report written to: $OutputPath" -ForegroundColor Green
Write-Host ''
Write-Host "--- Detected for SSID '$Ssid' ---" -ForegroundColor Cyan
Write-Host "Authentication (as shown by Windows): $displayAuthentication"
Write-Host "Cipher (as shown by Windows):         $displayCipher"
Write-Host ''

if ($isEnterprise) {
    Write-Host '*** This SSID uses Enterprise (802.1X) authentication. ***' -ForegroundColor Red
    Write-Host 'Configure-MspWifi.ps1 (Deployment\Scripts) cannot connect to this today: its WLAN' -ForegroundColor Red
    Write-Host 'profile XML is hardcoded <useOneX>false</useOneX> and only ever carries a static' -ForegroundColor Red
    Write-Host 'pre-shared key, never 802.1X username/password or certificate credentials. This is' -ForegroundColor Red
    Write-Host 'almost certainly why deployments keep failing to connect. Options: add 802.1X' -ForegroundColor Red
    Write-Host 'profile support to Configure-MspWifi.ps1, or provision deployments through a' -ForegroundColor Red
    Write-Host 'separate pre-shared-key SSID instead of this one.' -ForegroundColor Red
    Write-Host ''
} elseif (-not $recommendedAuthentication -or -not $recommendedEncryption) {
    Write-Host "Could not confidently map '$displayAuthentication' / '$displayCipher' to a known msp_wifi_setup value." -ForegroundColor Yellow
    Write-Host 'Check the full report above (or netsh documentation) and set msp_wifi_setup.authentication/.encryption manually.' -ForegroundColor Yellow
    Write-Host ''
} else {
    Write-Host 'Recommended deployment_config.json msp_wifi_setup block:' -ForegroundColor Green
    Write-Host ('  "msp_wifi_setup": {') -ForegroundColor Green
    Write-Host ('    "enabled": true,') -ForegroundColor Green
    Write-Host ('    "ssid": "{0}",' -f $Ssid) -ForegroundColor Green
    Write-Host ('    "password_env_var": "OSIT_WIFI_PASSWORD",') -ForegroundColor Green
    Write-Host ('    "authentication": "{0}",' -f $recommendedAuthentication) -ForegroundColor Green
    Write-Host ('    "encryption": "{0}",' -f $recommendedEncryption) -ForegroundColor Green
    Write-Host ('    "connect_timeout_seconds": 60') -ForegroundColor Green
    Write-Host ('  }') -ForegroundColor Green
    Write-Host ''
    if ($hasClearKey) {
        Write-Host 'The pre-shared key is in the full report above (Key Content). Set it as OSIT_WIFI_PASSWORD' -ForegroundColor Cyan
        Write-Host '(environment variable or toolkit-root .env) before running Initialize-UsbDeployment.ps1 -- never in deployment_config.json.' -ForegroundColor Cyan
    } else {
        Write-Host 'No cleartext key was found in the saved profile (this machine may not store one, or none is required).' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Send the full report file back for review if the connection still fails after updating the config.' -ForegroundColor Green
