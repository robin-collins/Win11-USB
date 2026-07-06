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
        require_network = $true
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
    if ($state -and (-not $state.ContainsKey('local_deployment_root') -or [string]::IsNullOrWhiteSpace([string]$state.local_deployment_root))) {
        $state.local_deployment_root = $normalizedTarget
        Write-DeploymentState -State $state -StatePath $StatePath
    }
    return
}

# A wired or already-connected machine has network the moment NetworkDrivers/MspWifiSetup
# finish, same signal Preflight uses; treat "no network yet" as a reason to skip rather than
# fail, so a device that is genuinely offline simply keeps running deployment from the USB.
if ([bool]$handover.require_network -and -not (Test-InternetConnectivity)) {
    Write-Log -Level Warn -Message 'Local deployment handover is enabled but no network connection is currently available; continuing to run from the current deployment root without handover.'
    return
}

Write-Log -Level Info -Message "Copying deployment files from $resolvedCurrent to $normalizedTarget for local handover."
New-Item -ItemType Directory -Path $normalizedTarget -Force -ErrorAction Stop | Out-Null

$sourceDeployment = Join-Path $resolvedCurrent 'Deployment'
$targetDeployment = Join-Path $normalizedTarget 'Deployment'

# robocopy mirrors reliably at scale (drivers, app installers, existing logs/state) and
# retries transient failures far more gracefully than Copy-Item -Recurse for a tree this
# size. Exit codes 0-7 all indicate some degree of success per the robocopy exit code table;
# 8 and above indicate a real failure.
$robocopyArgs = @($sourceDeployment, $targetDeployment, '/E', '/R:3', '/W:5', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
$copyResult = Invoke-ExternalCommand -FilePath robocopy.exe -Arguments $robocopyArgs -AllowedExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -LogName 'local-handover-robocopy.log'

$sourceEnvPath = Join-Path $resolvedCurrent '.env'
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
