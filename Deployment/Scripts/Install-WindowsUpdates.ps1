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

function Initialize-PSWindowsUpdateModule {
    param([bool]$Bootstrap)

    $module = Get-Module -ListAvailable -Name PSWindowsUpdate | Sort-Object Version -Descending | Select-Object -First 1
    if ($module) {
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        Write-Log -Level Info -Message "PSWindowsUpdate $($module.Version) is available."
        return $true
    }

    if (-not $Bootstrap) { return $false }

    Write-Log -Level Info -Message 'PSWindowsUpdate is missing; attempting bootstrap from PowerShell Gallery.'
    try {
        # Asking for a MISSING provider by name (Get-PackageProvider -Name NuGet) makes
        # PackageManagement itself offer to download it via an interactive "Would you like
        # PackageManagement to automatically download and install 'nuget' now?" prompt --
        # -ErrorAction suppresses errors, not host prompts, so that existence check is what
        # stalled an unattended run in the field before Install-PackageProvider ever ran.
        # -ListAvailable enumerates installed providers without triggering the offer.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $nugetProvider = @(Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'NuGet' })
        if ($nugetProvider.Count -eq 0) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Confirm:$false -ErrorAction Stop | Out-Null
            # The freshly installed provider is not visible to this session until imported
            # explicitly; without this the very next Install-Module can re-prompt.
            Import-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Log -Level Warn -Message "PSWindowsUpdate bootstrap failed: $($_.Exception.Message). Falling back to the Windows Update COM API for this run."
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

function Invoke-PSWindowsUpdateScan {
    <#
        Dry-run counterpart to Invoke-PSWindowsUpdateCycle: performs the same real scan (the
        genuine value of a dry run here) but never calls Install-WindowsUpdate. Enabling the
        Microsoft Update service manager is left running for real even in dry-run: it only
        registers an additional update source (no reboot, no installed changes) and is
        necessary for the scan itself to see Microsoft-sourced updates, matching the scan's own
        accuracy goal rather than being a mutation a technician would consider unsafe.
    #>
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
    [ordered]@{
        installed_count = 0
        reboot_required = (Test-PendingReboot)
        updates = @($available | Select-Object Title, KB, Size)
    }
}

function Invoke-ComWindowsUpdateScan {
    # Dry-run counterpart to Invoke-ComWindowsUpdateCycle: Search() alone is read-only (no
    # EulaAccepted/Download/Install calls), so this never mutates anything.
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")

    $titles = @()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        $titles += $result.Updates.Item($i).Title
    }

    [ordered]@{
        installed_count = 0
        reboot_required = (Test-PendingReboot)
        updates = @($titles | ForEach-Object { [ordered]@{ title = $_ } })
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

if (Test-DeploymentDryRun) {
    # Dry-run invariant (FABLE_TASKS.md T07b): a single real scan is the whole value of this
    # step in dry-run -- it is never repeated across windows_update_max_cycles, since nothing
    # is ever installed to change the outcome of a second scan. Never bootstrap-installs
    # PSWindowsUpdate here, regardless of pswindowsupdate_bootstrap.
    if (-not (Test-InternetConnectivity)) {
        Write-DryRunAction -State $state -Step 'WindowsUpdates' -Action 'skipped: no internet connectivity detected' -Data @{ include_microsoft_update = $includeMicrosoftUpdate }
        Write-Log -Level Info -Message 'Dry run: no internet connectivity detected; skipping the Windows Update scan.'
        return
    }

    $moduleAvailable = [bool](Get-Module -ListAvailable -Name PSWindowsUpdate | Select-Object -First 1)
    if ($moduleAvailable) {
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
        $cycleResult = Invoke-PSWindowsUpdateScan -IncludeMicrosoftUpdate $includeMicrosoftUpdate
        $scanMethod = 'PSWindowsUpdate'
    } else {
        if ([bool]$config.pswindowsupdate_bootstrap) {
            Write-DryRunAction -State $state -Step 'WindowsUpdates' -Action 'would run: Install-Module PSWindowsUpdate -Scope AllUsers -Force -AllowClobber' -Data @{}
        }
        Write-Log -Level Warn -Message 'Dry run: PSWindowsUpdate module unavailable; using the Windows Update COM fallback for the scan (never bootstrap-installs the module in dry-run).'
        $cycleResult = Invoke-ComWindowsUpdateScan
        $scanMethod = 'COM'
    }

    Write-DryRunAction -State $state -Step 'WindowsUpdates' -Action "scan (method=$scanMethod) found $($cycleResult.updates.Count) update(s); would-reboot=$($cycleResult.reboot_required)" -Data $cycleResult
    Write-Log -Level Success -Message "Dry run: Windows Update scan found $($cycleResult.updates.Count) update(s) (nothing installed). Would reboot afterward: $($cycleResult.reboot_required)."
    return
}

$useModule = Initialize-PSWindowsUpdateModule -Bootstrap ([bool]$config.pswindowsupdate_bootstrap)

$startCycle = [int]$state.update_cycle + 1
$updateMethod = if ($useModule) { 'PSWindowsUpdate' } else { 'COM fallback' }
Write-Log -Level Info -Message "Windows Update step started at cycle $startCycle of $maxCycles (method=$updateMethod, include_microsoft_update=$includeMicrosoftUpdate, pswindowsupdate_bootstrap=$([bool]$config.pswindowsupdate_bootstrap))."

for ($cycle = ([int]$state.update_cycle + 1); $cycle -le $maxCycles; $cycle++) {
    $state.update_cycle = $cycle
    Add-StateHistory -State $state -Event 'windows_update_cycle_started' -Data @{ cycle = $cycle; max_cycles = $maxCycles; method = $(if ($useModule) { 'PSWindowsUpdate' } else { 'COM' }) }
    Write-DeploymentState -State $state -StatePath $StatePath

    Write-Log -Level Info -Message "Windows Update cycle $cycle of $maxCycles started."
    if ($useModule) {
        $cycleResult = Invoke-PSWindowsUpdateCycle -IncludeMicrosoftUpdate $includeMicrosoftUpdate
    } else {
        Write-Log -Level Warn -Message 'Using Windows Update COM fallback because PSWindowsUpdate is unavailable (enable pswindowsupdate_bootstrap in deployment_config.json to install it automatically).'
        $cycleResult = Invoke-ComWindowsUpdateCycle
    }

    Add-StateHistory -State $state -Event 'windows_update_cycle_completed' -Data @{ cycle = $cycle; result = $cycleResult }
    Write-DeploymentState -State $state -StatePath $StatePath
    Write-StructuredLog -Level Info -Message "Windows Update cycle $cycle completed" -Data $cycleResult
    Write-Log -Level Info -Message "Windows Update cycle $cycle of $maxCycles completed: $($cycleResult.installed_count) update(s) installed; reboot required: $($cycleResult.reboot_required)."

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
