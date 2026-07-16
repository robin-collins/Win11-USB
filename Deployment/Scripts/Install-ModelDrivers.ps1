[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Interactive technician prompt (A/B choice) for handling a missing model driver folder; colored console output is the intended UX for the person at the keyboard during deployment.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
$paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }
$state = Read-DeploymentState -StatePath $StatePath
if (-not $state) { throw "Deployment state not found at $StatePath" }

$system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$manufacturer = ConvertTo-NormalizedManufacturer -Manufacturer $system.Manufacturer
$model = ConvertTo-NormalizedModel -Model $system.Model -Manufacturer $manufacturer
$driverFolder = Join-Path (Join-Path $paths.Drivers $manufacturer) $model

$state.manufacturer = $system.Manufacturer
$state.model = $system.Model
$state.normalized_manufacturer = $manufacturer
$state.normalized_model = $model
Write-DeploymentState -State $state -StatePath $StatePath

Write-Log -Level Info -Message "Detected hardware: manufacturer '$($system.Manufacturer)' as '$manufacturer'; model '$($system.Model)' as '$model'."

if (Test-Path -LiteralPath $driverFolder -PathType Container) {
    $infFiles = @(Get-ChildItem -LiteralPath $driverFolder -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    if ($infFiles.Count -gt 0) {
        Write-Log -Level Info -Message "Model driver folder found: $driverFolder ($($infFiles.Count) INF file(s)); installing."
        Install-InfDriversFromFolder -Folder $driverFolder -LogName 'pnputil-model-drivers.log' | Out-Null
    } else {
        Write-Log -Level Success -Message "Model driver folder exists and is empty. Treating as intentional: $driverFolder"
        Add-StateHistory -State $state -Event 'model_driver_folder_empty' -Data @{ folder = $driverFolder }
        Write-DeploymentState -State $state -StatePath $StatePath
    }
    return
}

New-Item -ItemType Directory -Path $driverFolder -Force -ErrorAction Stop | Out-Null
Write-Log -Level Warn -Message 'No model-specific driver folder existed, so it has been created.'
Write-Host ''
Write-Host 'Model driver folder created:' -ForegroundColor Yellow
Write-Host "  Manufacturer: $($system.Manufacturer)"
Write-Host "  Raw model:    $($system.Model)"
Write-Host "  Folder name:  $manufacturer\\$model"
Write-Host "  Full path:    $driverFolder"
Write-Host ''

if ($NonInteractive) {
    # A Read-Host here would hang an unattended resume forever; the folder path is logged
    # so drivers can be added and the deployment rerun later if needed.
    Write-Log -Level Warn -Message "Non-interactive session: continuing without offline drivers for $manufacturer\\$model. Copy drivers to $driverFolder and rerun to install them."
    Add-StateHistory -State $state -Event 'model_drivers_skipped_noninteractive' -Data @{ folder = $driverFolder }
    Write-DeploymentState -State $state -StatePath $StatePath
    return
}

Show-DeploymentToast -Title 'Windows 11 Deployment - Action Needed' -Message "Model driver folder created for $manufacturer\$model. Copy drivers or choose to continue."
Write-Host 'A) Recheck the newly created folder now for drivers to install'
Write-Host 'B) Continue without installing additional offline drivers'

do {
    $choice = (Read-Host 'Choose A or B').Trim().ToUpperInvariant()
} until ($choice -in @('A', 'B'))

if ($choice -eq 'A') {
    Write-Log -Level Info -Message "Technician chose to recheck $driverFolder for model drivers."
    Install-InfDriversFromFolder -Folder $driverFolder -LogName 'pnputil-model-drivers.log' | Out-Null
} else {
    Write-Log -Level Warn -Message "Continuing without offline drivers for $manufacturer\\$model."
    Add-StateHistory -State $state -Event 'model_drivers_skipped_by_technician' -Data @{ folder = $driverFolder }
    Write-DeploymentState -State $state -StatePath $StatePath
}
