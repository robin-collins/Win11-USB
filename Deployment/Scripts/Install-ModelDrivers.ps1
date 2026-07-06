[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath
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
$manufacturer = Normalize-Manufacturer -Manufacturer $system.Manufacturer
$model = Normalize-Model -Model $system.Model -Manufacturer $manufacturer
$driverFolder = Join-Path (Join-Path $paths.Drivers $manufacturer) $model

$state.manufacturer = $system.Manufacturer
$state.model = $system.Model
$state.normalized_manufacturer = $manufacturer
$state.normalized_model = $model
Write-DeploymentState -State $state -StatePath $StatePath

Write-Log -Level Info -Message "Detected hardware: manufacturer '$($system.Manufacturer)' as '$manufacturer'; model '$($system.Model)' as '$model'."

function Install-InfDriversFromFolder {
    param([Parameter(Mandatory = $true)][string]$Folder)

    $infFiles = @(Get-ChildItem -LiteralPath $Folder -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    if ($infFiles.Count -eq 0) {
        Write-Log -Level Info -Message "No .inf files found in $Folder."
        return [ordered]@{ installed = $false; count = 0; folder = $Folder }
    }

    $result = Invoke-ExternalCommand -FilePath pnputil.exe -Arguments @('/add-driver', (Join-Path $Folder '*.inf'), '/subdirs', '/install') -AllowedExitCodes @(0, 3010) -LogName 'pnputil-model-drivers.log'
    $summary = [ordered]@{
        installed = $true
        count = $infFiles.Count
        folder = $Folder
        exit_code = $result.exit_code
    }
    Write-Log -Level Success -Message "Processed $($infFiles.Count) driver INF file(s) from $Folder."
    Write-StructuredLog -Level Info -Message 'Model driver installation result' -Data $summary
    return $summary
}

if (Test-Path -LiteralPath $driverFolder -PathType Container) {
    $infFiles = @(Get-ChildItem -LiteralPath $driverFolder -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    if ($infFiles.Count -gt 0) {
        Install-InfDriversFromFolder -Folder $driverFolder | Out-Null
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
Write-Host 'A) Recheck the newly created folder now for drivers to install'
Write-Host 'B) Continue without installing additional offline drivers'

do {
    $choice = (Read-Host 'Choose A or B').Trim().ToUpperInvariant()
} until ($choice -in @('A', 'B'))

if ($choice -eq 'A') {
    Install-InfDriversFromFolder -Folder $driverFolder | Out-Null
} else {
    Write-Log -Level Warn -Message "Continuing without offline drivers for $manufacturer\\$model."
    Add-StateHistory -State $state -Event 'model_drivers_skipped_by_technician' -Data @{ folder = $driverFolder }
    Write-DeploymentState -State $state -StatePath $StatePath
}
