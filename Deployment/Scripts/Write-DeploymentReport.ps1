[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath,
    [switch]$Failure,
    [string]$FailureMessage
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
$paths = Get-DeploymentPaths -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }

$state = Read-DeploymentState -StatePath $StatePath
if (-not $state) { $state = New-DeploymentState -RunId (New-DeploymentRunId) }

$reportRoot = Get-DeploymentReportRoot -UsbRoot $UsbRoot
$runId = $state.deployment_run_id
$jsonReport = Join-Path $reportRoot "deployment-report-$runId.json"
$mdReport = Join-Path $reportRoot "deployment-summary-$runId.md"
$inventoryPath = Join-Path $reportRoot "asset-inventory-$runId.json"

$inventory = & (Join-Path $paths.Scripts 'Get-AssetInventory.ps1') -UsbRoot $UsbRoot -OutputPath $inventoryPath

$report = [ordered]@{
    report_created_at = (Get-Date).ToString('o')
    status = if ($Failure) { 'Failed' } else { 'Ready for customer onboarding' }
    failure_message = $FailureMessage
    dry_run = [bool](Test-DeploymentDryRun)
    deployment_state = $state
    asset_inventory = $inventory
    stop_point = 'Domain join, Entra join, and customer-specific identity onboarding were intentionally not performed.'
}
Write-JsonFile -Path $jsonReport -InputObject $report

$completed = if ($state.completed_steps) { ($state.completed_steps -join ', ') } else { 'None' }
$lastError = if ($state.last_error) { $state.last_error.message } elseif ($FailureMessage) { $FailureMessage } else { 'None' }
$computer = $inventory.computer
$windows = $inventory.windows

$lines = @(
    '# Windows 11 Deployment Summary',
    '',
    "Status: $($report.status)",
    "Report created: $($report.report_created_at)",
    "Run ID: $runId",
    "Dry run: $($report.dry_run)",
    '',
    '## Device',
    "Computer name: $($computer.computer_name)",
    "Serial number: $($computer.serial_number)",
    "UUID: $($computer.uuid)",
    "Manufacturer: $($computer.manufacturer)",
    "Model: $($computer.model)",
    "SKU: $($computer.sku)",
    '',
    '## Windows',
    "Edition: $($windows.caption)",
    "Version/build: $($windows.version) / $($windows.build)",
    '',
    '## Deployment',
    "Completed steps: $completed",
    "Last successful step: $($state.last_successful_step)",
    "Last error: $lastError",
    '',
    '## Stop Point',
    'The device is ready for final customer onboarding. Domain join, Entra join, and customer-specific identity joins have not been performed by this toolkit.'
)

Set-Content -LiteralPath $mdReport -Value $lines -Encoding UTF8 -Force
Write-Log -Level Success -Message "Deployment reports written to $reportRoot"
[ordered]@{
    json_report = $jsonReport
    markdown_report = $mdReport
    inventory_report = $inventoryPath
}
