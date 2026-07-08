<#
    .SYNOPSIS
        Imports every secondary WiFi profile from Deployment\WifiProfiles\ (everything except
        Primary.xml, which Configure-MspWifi.ps1 already handles), verifies each one on a
        best-effort basis, then switches back to and confirms the primary network.

    .DESCRIPTION
        Runs after ModelDrivers and before WingetApps/DattoRmm/LocalApps: Windows Update has
        already finished by this point, and this is the last point before steps that need
        sustained network access for downloads, so briefly hopping between networks here will
        not interrupt an in-progress download.

        Secondary profiles are commonly captured ahead of time for a network that is not
        actually in range on the bench (e.g. a customer's own office/home WiFi, exported via
        `netsh wlan export profile key=clear` before the machine ever leaves that site) -- so
        importing and saving a profile always happens regardless of whether it can be verified,
        and a failed verification connect is expected and logged, never a deployment-stopping
        error. Only failing to get back onto the primary network at the end is treated as fatal,
        because later steps need real connectivity.
#>
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

if (-not [bool]$config.configure_additional_wifi_profiles) {
    Write-Log -Level Info -Message 'Additional WiFi profile import is disabled by config.'
    return
}

$profilesFolder = $paths.WifiProfiles
if (-not (Test-Path -LiteralPath $profilesFolder -PathType Container)) {
    Write-Log -Level Info -Message "No $profilesFolder folder found; skipping additional WiFi profile import."
    return
}

$primaryProfilePath = Join-Path $profilesFolder $script:PrimaryWifiProfileFileName
$secondaryProfiles = @(Get-ChildItem -LiteralPath $profilesFolder -Filter '*.xml' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $primaryProfilePath })

# Same primary-identification rule as Configure-MspWifi.ps1: Primary.xml's own SSID wins over
# msp_wifi_setup.ssid when the file exists.
$mspWifiConfig = if ($config.ContainsKey('msp_wifi_setup') -and $null -ne $config.msp_wifi_setup) { ConvertTo-PlainHashtable $config.msp_wifi_setup } else { @{} }
$primarySsid = [string]$mspWifiConfig.ssid
if ([string]::IsNullOrWhiteSpace($primarySsid)) { $primarySsid = 'OneSolution' }
if (Test-Path -LiteralPath $primaryProfilePath -PathType Leaf) {
    $primarySsid = Get-WlanProfileSsid -ProfileXmlPath $primaryProfilePath
}

if ($secondaryProfiles.Count -eq 0) {
    Write-Log -Level Info -Message "No secondary WiFi profiles found in $profilesFolder (besides $script:PrimaryWifiProfileFileName, if present); nothing to do."
    return
}

$wirelessAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11' })
if ($wirelessAdapters.Count -eq 0) {
    Write-Log -Level Warn -Message "$($secondaryProfiles.Count) secondary WiFi profile(s) found but no wireless network adapter was detected; skipping import."
    return
}

$timeout = [int]$config.additional_wifi_profiles_connect_timeout_seconds
if ($timeout -lt 5) { $timeout = 5 }

if (Test-DeploymentDryRun) {
    foreach ($profileFile in $secondaryProfiles) {
        $profileSsid = $profileFile.BaseName
        try { $profileSsid = Get-WlanProfileSsid -ProfileXmlPath $profileFile.FullName } catch { Write-Verbose "Could not read SSID from $($profileFile.FullName) during dry run: $($_.Exception.Message)" }
        Write-DryRunAction -State $state -Step 'AdditionalWifiProfiles' -Action "would import and best-effort verify secondary WLAN profile '$profileSsid' from $($profileFile.FullName)" -Data ([ordered]@{ ssid = $profileSsid; source = $profileFile.FullName })
    }
    Write-DryRunAction -State $state -Step 'AdditionalWifiProfiles' -Action "would switch back to and confirm primary WiFi SSID '$primarySsid' after importing secondary profiles" -Data ([ordered]@{ ssid = $primarySsid })

    $dryRunResult = [ordered]@{
        profiles_found = $secondaryProfiles.Count
        primary_ssid   = $primarySsid
        status         = 'DryRun'
        timestamp      = (Get-Date).ToString('o')
    }
    if ($state) {
        $state.additional_wifi_profiles = $dryRunResult
        Write-DeploymentState -State $state -StatePath $StatePath
    }
    Write-StructuredLog -Level Info -Message 'Additional WiFi profile import dry run completed' -Data $dryRunResult
    Write-Log -Level Success -Message "Dry run: would import and best-effort verify $($secondaryProfiles.Count) secondary WiFi profile(s), then confirm primary SSID '$primarySsid'. No WLAN profile was added or changed."
    return
}

$results = @()
foreach ($profileFile in $secondaryProfiles) {
    $profileSsid = $null
    try {
        $profileSsid = Get-WlanProfileSsid -ProfileXmlPath $profileFile.FullName
    } catch {
        Write-Log -Level Warn -Message "Skipping $($profileFile.FullName): $($_.Exception.Message)"
        $results += , ([ordered]@{ file = $profileFile.Name; ssid = $null; status = 'InvalidProfile' })
        continue
    }

    Write-Log -Level Info -Message "Importing secondary WiFi profile '$profileSsid' from $($profileFile.FullName)."
    $connected = Import-WlanProfileFile -ProfileXmlPath $profileFile.FullName -Ssid $profileSsid -Connect -ConnectTimeoutSeconds $timeout
    if ($connected) {
        Write-Log -Level Success -Message "Verified secondary WiFi profile '$profileSsid' connects."
    } else {
        Write-Log -Level Warn -Message "Secondary WiFi profile '$profileSsid' was imported and saved, but could not be verified within $timeout second(s) here (network likely not in range on the bench) -- this is expected for a profile captured for a different site."
    }
    $results += , ([ordered]@{ file = $profileFile.Name; ssid = $profileSsid; status = if ($connected) { 'ImportedAndVerified' } else { 'ImportedNotVerified' } })
}

# Always attempt to end up back on the primary network specifically (not just "whatever this
# machine happened to be on before this step"), since that is the network everything from here
# on should be running on. Only treated as fatal if there is no other connectivity either --
# a bench machine on Ethernet with the primary WiFi network out of range should not fail here.
$reconnectedToPrimary = $false
if ((Get-ConnectedWifiSsid) -eq $primarySsid) {
    Write-Log -Level Success -Message "Already back on primary WiFi SSID '$primarySsid'."
    $reconnectedToPrimary = $true
} else {
    Write-Log -Level Info -Message "Reconnecting to primary WiFi SSID '$primarySsid' after importing secondary WiFi profiles."
    Invoke-ExternalCommand -FilePath netsh.exe -Arguments @('wlan', 'connect', "name=$primarySsid", "ssid=$primarySsid") -AllowedExitCodes @(0, 1) -LogName 'additional-wifi-reconnect-primary.log' | Out-Null
    $reconnectedToPrimary = Wait-WifiConnection -Ssid $primarySsid -TimeoutSeconds $timeout
}

if (-not $reconnectedToPrimary) {
    if (Test-InternetConnectivity) {
        Write-Log -Level Warn -Message "Could not reconnect to primary WiFi SSID '$primarySsid' after importing secondary profiles, but other connectivity (e.g. Ethernet) is available; continuing."
    } else {
        throw "Could not reconnect to primary WiFi SSID '$primarySsid' after importing secondary WiFi profiles, and no other connectivity is available. Later steps need network connectivity -- verify the network manually before continuing."
    }
}

$summary = [ordered]@{
    profiles_found          = $secondaryProfiles.Count
    results                 = $results
    primary_ssid            = $primarySsid
    reconnected_to_primary  = $reconnectedToPrimary
    timestamp               = (Get-Date).ToString('o')
}
if ($state) {
    $state.additional_wifi_profiles = $summary
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'Additional WiFi profile import completed' -Data $summary
Write-Log -Level Success -Message "Additional WiFi profile import completed: $($results.Count) profile(s) processed."
