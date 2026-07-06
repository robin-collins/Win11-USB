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
if (-not $state) { throw "Deployment state not found at $StatePath" }

function Ensure-PSWindowsUpdate {
    param([bool]$Bootstrap)

    $module = Get-Module -ListAvailable -Name PSWindowsUpdate | Sort-Object Version -Descending | Select-Object -First 1
    if ($module) {
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        return $true
    }

    if (-not $Bootstrap) { return $false }

    Write-Log -Level Info -Message 'PSWindowsUpdate is missing; attempting bootstrap from PowerShell Gallery.'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Log -Level Warn -Message "PSWindowsUpdate bootstrap failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-PSWindowsUpdateCycle {
    param([bool]$IncludeMicrosoftUpdate)

    if ($IncludeMicrosoftUpdate) {
        try {
            Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            Write-Log -Level Warn -Message "Could not enable Microsoft Update service: $($_.Exception.Message)"
        }
    }

    $scanArgs = @{
        AcceptAll = $true
        IgnoreReboot = $true
        ErrorAction = 'Stop'
    }
    if ($IncludeMicrosoftUpdate) { $scanArgs.MicrosoftUpdate = $true }

    $available = @(Get-WindowsUpdate @scanArgs)
    if ($available.Count -eq 0) {
        return [ordered]@{ installed_count = 0; reboot_required = (Test-PendingReboot); updates = @() }
    }

    Write-Log -Level Info -Message "Installing $($available.Count) Windows update(s)."
    $installArgs = @{
        AcceptAll = $true
        IgnoreReboot = $true
        ErrorAction = 'Stop'
        Verbose = $true
    }
    if ($IncludeMicrosoftUpdate) { $installArgs.MicrosoftUpdate = $true }
    $installed = @(Install-WindowsUpdate @installArgs)
    [ordered]@{
        installed_count = $installed.Count
        reboot_required = (Test-PendingReboot)
        updates = @($installed | Select-Object Title, KB, Size, Result)
    }
}

function Invoke-ComWindowsUpdateCycle {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if ($result.Updates.Count -eq 0) {
        return [ordered]@{ installed_count = 0; reboot_required = (Test-PendingReboot); updates = @() }
    }

    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    $titles = @()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        $update = $result.Updates.Item($i)
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        $updates.Add($update) | Out-Null
        $titles += $update.Title
    }

    Write-Log -Level Info -Message "Downloading $($updates.Count) Windows update(s) with COM fallback."
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    $downloadResult = $downloader.Download()
    if ($downloadResult.ResultCode -gt 3) {
        throw "Windows Update download failed with result code $($downloadResult.ResultCode)."
    }

    Write-Log -Level Info -Message "Installing $($updates.Count) Windows update(s) with COM fallback."
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $updates
    $installResult = $installer.Install()
    if ($installResult.ResultCode -gt 3) {
        throw "Windows Update install failed with result code $($installResult.ResultCode)."
    }

    [ordered]@{
        installed_count = $updates.Count
        reboot_required = ($installResult.RebootRequired -or (Test-PendingReboot))
        updates = @($titles | ForEach-Object { [ordered]@{ title = $_ } })
    }
}

$maxCycles = [int]$config.windows_update_max_cycles
if ($maxCycles -lt 1) { $maxCycles = 1 }
$includeMicrosoftUpdate = [bool]$config.windows_update_include_microsoft_update
$useModule = Ensure-PSWindowsUpdate -Bootstrap ([bool]$config.pswindowsupdate_bootstrap)

for ($cycle = ([int]$state.update_cycle + 1); $cycle -le $maxCycles; $cycle++) {
    $state.update_cycle = $cycle
    Add-StateHistory -State $state -Event 'windows_update_cycle_started' -Data @{ cycle = $cycle; max_cycles = $maxCycles; method = $(if ($useModule) { 'PSWindowsUpdate' } else { 'COM' }) }
    Write-DeploymentState -State $state -StatePath $StatePath

    Write-Log -Level Info -Message "Windows Update cycle $cycle of $maxCycles started."
    if ($useModule) {
        $cycleResult = Invoke-PSWindowsUpdateCycle -IncludeMicrosoftUpdate $includeMicrosoftUpdate
    } else {
        Write-Log -Level Warn -Message 'Using Windows Update COM fallback because PSWindowsUpdate is unavailable.'
        $cycleResult = Invoke-ComWindowsUpdateCycle
    }

    Add-StateHistory -State $state -Event 'windows_update_cycle_completed' -Data @{ cycle = $cycle; result = $cycleResult }
    Write-DeploymentState -State $state -StatePath $StatePath
    Write-StructuredLog -Level Info -Message "Windows Update cycle $cycle completed" -Data $cycleResult

    if ([int]$cycleResult.installed_count -eq 0) {
        Write-Log -Level Success -Message 'No additional Windows updates were found.'
        return
    }

    if ([bool]$cycleResult.reboot_required) {
        Request-DeploymentReboot -UsbRoot $UsbRoot -State $state -StatePath $StatePath -Reason "Windows Update cycle $cycle installed updates that require reboot."
    }
}

if (Test-PendingReboot) {
    Request-DeploymentReboot -UsbRoot $UsbRoot -State $state -StatePath $StatePath -Reason 'Windows Update reached max cycles with a pending reboot.'
}

Write-Log -Level Warn -Message "Windows Update reached the configured maximum of $maxCycles cycle(s). Continuing with current update state."
