[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-DeploymentRoot }
$paths = Get-DeploymentPaths -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }
$config = Get-DeploymentConfig -UsbRoot $UsbRoot
$state = Read-DeploymentState -StatePath $StatePath

function Get-LocalHandoverConfig {
    param([hashtable]$Config)

    $settings = @{
        enabled = $false
        local_path = 'C:\1S-WIN11'
        # Handover is a local USB-to-disk copy that runs as the deployment's very first step,
        # before any network/WiFi work, so it needs no connectivity (matches
        # Get-DefaultDeploymentConfig in Common.ps1).
        require_network = $false
    }

    if ($Config.ContainsKey('local_deployment_handover') -and $null -ne $Config.local_deployment_handover) {
        $override = ConvertTo-PlainHashtable $Config.local_deployment_handover
        foreach ($key in $override.Keys) { $settings[$key] = $override[$key] }
    }
    return $settings
}

$handover = Get-LocalHandoverConfig -Config $config
if (-not [bool]$handover.enabled) {
    Write-Log -Level Info -Message 'Local deployment handover is disabled by config; the deployment continues to run from the current deployment root.'
    return
}

$targetRoot = [string]$handover.local_path
if ([string]::IsNullOrWhiteSpace($targetRoot)) { throw 'local_deployment_handover.local_path must not be empty when enabled.' }

$normalizedTarget = ([System.IO.Path]::GetFullPath($targetRoot)).TrimEnd('\')
$resolvedCurrent = (Resolve-Path -LiteralPath $UsbRoot -ErrorAction Stop).Path.TrimEnd('\')

if ($resolvedCurrent -ieq $normalizedTarget) {
    Write-Log -Level Info -Message "Already running from the local handover path $normalizedTarget; no copy is required."
    # Dry-run invariant (FABLE_TASKS.md T07a): never write state.local_deployment_root in a
    # dry run, even in this "already there" edge case, so Start-Deployment.ps1's post-step
    # switch-over logic (which keys off that field) has nothing to react to.
    if ((Test-DeploymentDryRun)) {
        Write-Log -Level Info -Message 'Dry run: not recording local_deployment_root even though already at the target path, so no deployment-root switch-over is triggered.'
    } elseif ($state -and (-not $state.ContainsKey('local_deployment_root') -or [string]::IsNullOrWhiteSpace([string]$state.local_deployment_root))) {
        $state.local_deployment_root = $normalizedTarget
        Write-DeploymentState -State $state -StatePath $StatePath
    }
    return
}

# Handover runs as the very first step and needs no connectivity, so require_network defaults
# to $false. If a site opts back in (require_network=true), "no network yet" is treated as a
# reason to skip rather than fail, so a device that is offline at this point simply keeps
# running the deployment from the USB; handover is not retried later in the run.
if ([bool]$handover.require_network -and -not (Test-InternetConnectivity)) {
    Write-Log -Level Warn -Message 'Local deployment handover is enabled but no network connection is currently available; continuing to run from the current deployment root without handover.'
    return
}

$sourceDeployment = Join-Path $resolvedCurrent 'Deployment'
$targetDeployment = Join-Path $normalizedTarget 'Deployment'
$sourceEnvPath = Join-Path $resolvedCurrent '.env'

if (Test-DeploymentDryRun) {
    # Detection value kept for real (FABLE_TASKS.md T07a, same "enumeration is the real value"
    # pattern as the driver-folder scan): confirm the *source* tree actually has what a real
    # copy would need, so a broken source tree is still caught even though nothing is copied.
    $requiredBeforeCopy = @(
        (Join-Path $sourceDeployment 'Scripts\Common.ps1'),
        (Join-Path $sourceDeployment 'Scripts\Start-Deployment.ps1'),
        (Join-Path $sourceDeployment 'Config\deployment_config.json')
    )
    foreach ($requiredPath in $requiredBeforeCopy) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Local deployment handover dry run: expected source file missing at $requiredPath"
        }
    }

    # robocopy /L (list-only) genuinely does not copy, delete, timestamp, or create anything;
    # -ReadOnly asserts exactly that to Invoke-ExternalCommand so it executes for real even in
    # dry-run mode instead of being refused like a real mutating command (Common.ps1, T05),
    # letting a technician see what WOULD copy without anything actually copying.
    $listArgs = @($sourceDeployment, $targetDeployment, '/E', '/L', '/R:0', '/W:0', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
    $listResult = Invoke-ExternalCommand -FilePath robocopy.exe -Arguments $listArgs -AllowedExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -LogName 'local-handover-robocopy-dryrun-list.log' -ReadOnly -State $state

    if (Test-Path -LiteralPath $sourceEnvPath -PathType Leaf) {
        Write-DryRunAction -State $state -Step 'LocalHandover' -Action "would copy .env from $sourceEnvPath to $(Join-Path $normalizedTarget '.env')" -Data ([ordered]@{
                source = $sourceEnvPath
                target = (Join-Path $normalizedTarget '.env')
            })
    } else {
        Write-Log -Level Info -Message "No .env file found at $resolvedCurrent; nothing to copy for local handover .env in this dry run."
    }

    Write-StructuredLog -Level Info -Message 'Local deployment handover dry run completed' -Data ([ordered]@{
            source                   = $resolvedCurrent
            target                   = $normalizedTarget
            robocopy_list_exit_code  = $listResult.exit_code
        })
    Write-Log -Level Success -Message "Dry run: local deployment handover would copy $resolvedCurrent to $normalizedTarget. Not creating the target folder, not copying any files, and not switching the running deployment root."
    return
}

Write-Log -Level Info -Message "Copying deployment files from $resolvedCurrent to $normalizedTarget for local handover."
New-Item -ItemType Directory -Path $normalizedTarget -Force -ErrorAction Stop | Out-Null

# robocopy mirrors reliably at scale (drivers, app installers, existing logs/state) and
# retries transient failures far more gracefully than Copy-Item -Recurse for a tree this
# size. Exit codes 0-7 all indicate some degree of success per the robocopy exit code table;
# 8 and above indicate a real failure.
$robocopyArgs = @($sourceDeployment, $targetDeployment, '/E', '/R:3', '/W:5', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
$copyResult = Invoke-ExternalCommand -FilePath robocopy.exe -Arguments $robocopyArgs -AllowedExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -LogName 'local-handover-robocopy.log'

if (Test-Path -LiteralPath $sourceEnvPath -PathType Leaf) {
    Copy-Item -LiteralPath $sourceEnvPath -Destination (Join-Path $normalizedTarget '.env') -Force -ErrorAction Stop
}

$requiredAfterCopy = @(
    (Join-Path $targetDeployment 'Scripts\Common.ps1'),
    (Join-Path $targetDeployment 'Scripts\Start-Deployment.ps1'),
    (Join-Path $targetDeployment 'Config\deployment_config.json')
)
foreach ($requiredPath in $requiredAfterCopy) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Local deployment handover copy verification failed: expected file missing at $requiredPath"
    }
}

$state.local_deployment_root = $normalizedTarget
$state.local_handover_completed_at = (Get-Date).ToString('o')
Write-DeploymentState -State $state -StatePath $StatePath

Write-StructuredLog -Level Info -Message 'Local deployment handover completed' -Data @{ source = $resolvedCurrent; target = $normalizedTarget; robocopy_exit_code = $copyResult.exit_code }
Write-Log -Level Success -Message "Deployment files copied to $normalizedTarget. The remaining deployment steps continue from local disk; the USB can now be safely ejected."
Show-DeploymentToast -Title 'Windows 11 Deployment' -Message "Deployment copied to $normalizedTarget. The USB can now be ejected."
