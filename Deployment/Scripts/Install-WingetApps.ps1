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
$packageConfig = Read-JsonFile -Path $paths.WingetFile -Required
$state = Read-DeploymentState -StatePath $StatePath
if (-not $state) { throw "Deployment state not found at $StatePath" }

# winget exit codes are HRESULTs, not MSI-style codes (signed int32 values of 0x8A15xxxx).
$script:WingetNoApplicationsFound = -1978335212      # 0x8A150014
$script:WingetRebootRequiredToFinish = -1978334964   # 0x8A15010C
$script:WingetRebootRequiredToInstall = -1978334963  # 0x8A15010D

function Initialize-WingetCommand {
    param([bool]$Bootstrap)

    $winget = Get-WingetCommand
    if ($winget) { return $winget }
    if (-not $Bootstrap) { return $null }

    # On a fresh OOBE-bypassed first logon, App Installer is often provisioned but not yet
    # registered for this user, so winget.exe does not resolve until it is re-registered.
    Write-Log -Level Info -Message 'winget is not available yet; attempting bootstrap.'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    } catch {
        Write-Log -Level Warn -Message "App Installer registration attempt failed: $($_.Exception.Message)"
    }
    $winget = Get-WingetCommand
    if ($winget) { return $winget }

    try {
        # -Force alone still shows the interactive "Do you want PowerShellGet to install and
        # import the NuGet provider now? [Y] Yes [N] No" prompt on a fresh Windows install with
        # no NuGet provider yet; -ForceBootstrap is the flag that actually suppresses it.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Confirm:$false -ErrorAction Stop | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
        }
        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Latest -Force -ErrorAction Stop
    } catch {
        Write-Log -Level Warn -Message "winget bootstrap via Microsoft.WinGet.Client failed: $($_.Exception.Message)"
    }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $winget = Get-WingetCommand
        if ($winget) { return $winget }
        Write-Log -Level Info -Message "Waiting for winget to become available (attempt $attempt of 6)."
        Start-Sleep -Seconds 10
    }
    return (Get-WingetCommand)
}

$winget = Initialize-WingetCommand -Bootstrap ([bool]$config.winget_bootstrap)
if (-not $winget) {
    throw 'winget.exe is not available and bootstrap did not succeed. Install App Installer or disable install_winget_apps in deployment_config.json.'
}

if (-not $packageConfig.ContainsKey('packages')) {
    throw "winget package config must contain a top-level 'packages' array: $($paths.WingetFile)"
}

$packages = @($packageConfig.packages)
Write-Log -Level Info -Message "winget app installation started: $($packages.Count) package(s) configured in $($paths.WingetFile); winget resolved at $winget."

$results = @()
$packageIndex = 0
foreach ($package in $packages) {
    $packageIndex++
    $id = [string]$package.id
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'A winget package entry is missing id.' }
    $displayName = if ($package.ContainsKey('display_name') -and -not [string]::IsNullOrWhiteSpace([string]$package.display_name)) { [string]$package.display_name } else { $id }
    $required = if ($package.ContainsKey('required')) { [bool]$package.required } else { $true }
    $installArguments = if ($package.ContainsKey('install_arguments')) { [string]$package.install_arguments } else { '' }

    Write-Log -Level Info -Message "Checking winget package $displayName ($id) [$packageIndex of $($packages.Count)]."
    # 'winget list' exits with NO_APPLICATIONS_FOUND (not 0/1) when the package is absent.
    # -ReadOnly: a detection query, never a mutation, so it runs for real even in dry-run
    # (FABLE_TASKS.md T07b) -- without it, Common.ps1's generic dry-run refusal (T05) would
    # intercept this call too and report every package as installed regardless of truth.
    $list = Invoke-ExternalCommand -FilePath $winget -Arguments @('list', '--id', $id, '--exact', '--accept-source-agreements') -AllowedExitCodes @(0, 1, $script:WingetNoApplicationsFound) -LogName ("winget-list-{0}.log" -f (Get-SafeName -Value $id)) -ReadOnly -State $state
    if ($list.exit_code -eq 0) {
        Write-Log -Level Success -Message "$displayName is already installed."
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = 'AlreadyInstalled'; required = $required })
        continue
    }

    $wingetArgs = @(
        'install',
        '--id', $id,
        '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if (-not [string]::IsNullOrWhiteSpace($installArguments)) {
        $wingetArgs += @('--override', $installArguments)
    }

    if (Test-DeploymentDryRun) {
        $argumentLine = ConvertTo-ProcessArgumentString -Arguments $wingetArgs
        Write-DryRunAction -State $state -Step 'WingetApps' -Action "would winget install $id ($argumentLine)" -Data ([ordered]@{ id = $id; display_name = $displayName; arguments = $wingetArgs; required = $required })
        Write-Log -Level Success -Message "Dry run: $displayName would be installed via winget."
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = 'DryRun'; required = $required })
        continue
    }

    try {
        $install = Invoke-ExternalCommand -FilePath $winget -Arguments $wingetArgs -AllowedExitCodes @(0, 3010, $script:WingetRebootRequiredToFinish, $script:WingetRebootRequiredToInstall) -LogName ("winget-install-{0}.log" -f (Get-SafeName -Value $id))
        $status = if ($install.exit_code -ne 0) { 'InstalledRebootRequired' } else { 'Installed' }
        Write-Log -Level Success -Message "$displayName install result: $status."
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = $status; required = $required; exit_code = $install.exit_code })
    } catch {
        $message = "winget install failed for $displayName ($id): $($_.Exception.Message)"
        Write-Log -Level Error -Message $message
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = 'Failed'; required = $required; error = $_.Exception.Message })
        if ($required -and [bool]$config.fail_on_missing_required_app) { throw $message }
        $continueReason = if ($required) { 'fail_on_missing_required_app is disabled in deployment_config.json' } else { 'the package is not marked required' }
        Write-Log -Level Warn -Message "Continuing after failed install of $displayName because $continueReason. Install it manually or rerun this step after fixing the cause (see winget-install-$(Get-SafeName -Value $id).log)."
    }
}

if (Test-DeploymentDryRun) {
    # Persists the dryrun_actions accumulated above (T05's Write-DryRunAction mutates $state
    # in-memory only) -- this script previously never wrote state at all, so a dry-run-only
    # persist here is added without changing the untouched-outside-dry-run behaviour.
    Write-DeploymentState -State $state -StatePath $StatePath
}

$alreadyInstalledCount = @($results | Where-Object { $_.status -eq 'AlreadyInstalled' }).Count
$installedCount = @($results | Where-Object { $_.status -like 'Installed*' }).Count
$failedCount = @($results | Where-Object { $_.status -eq 'Failed' }).Count
$dryRunCount = @($results | Where-Object { $_.status -eq 'DryRun' }).Count

Write-StructuredLog -Level Info -Message 'winget app installation completed' -Data $results
Write-Log -Level Success -Message "winget app installation completed: $installedCount installed, $alreadyInstalledCount already installed, $failedCount failed$(if ($dryRunCount -gt 0) { ", $dryRunCount dry-run" }) of $($packages.Count) package(s)."
