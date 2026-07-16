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

# This step runs before MspWifiSetup and Preflight so a bare Windows image that lacks an
# inbox driver for the installed WiFi (or wired) chip still has a chance to get one before
# any network-dependent step runs. Vendor folders are tried unconditionally and in any
# order: pnputil only binds a driver to hardware whose ID actually matches, so staging an
# unrelated vendor's package is a harmless no-op rather than an error.
if (-not (Test-Path -LiteralPath $paths.NetworkDrivers -PathType Container)) {
    Write-Log -Level Info -Message "No network driver folder found at $($paths.NetworkDrivers); skipping."
    return
}

$vendorFolders = @(Get-ChildItem -LiteralPath $paths.NetworkDrivers -Directory -ErrorAction SilentlyContinue)
if ($vendorFolders.Count -eq 0) {
    Write-Log -Level Info -Message "No vendor subfolders found under $($paths.NetworkDrivers); skipping network driver installation."
    return
}

Write-Log -Level Info -Message "Network driver installation started: $($vendorFolders.Count) vendor folder(s) under $($paths.NetworkDrivers): $(($vendorFolders | ForEach-Object { $_.Name }) -join ', ')."

$results = @()
foreach ($vendorFolder in $vendorFolders) {
    $infCount = @(Get-ChildItem -LiteralPath $vendorFolder.FullName -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($infCount -eq 0) {
        Write-Log -Level Info -Message "No .inf files under $($vendorFolder.FullName); skipping vendor '$($vendorFolder.Name)'."
        continue
    }

    Write-Log -Level Info -Message "Attempting network driver install for vendor '$($vendorFolder.Name)' ($infCount INF file(s))."
    try {
        # No dry-run branch is needed here (FABLE_TASKS.md T07a): the .inf enumeration above
        # is the real value of this step and already runs unconditionally for real, and
        # Install-InfDriversFromFolder's actual mutation -- pnputil /add-driver ... /install --
        # goes through Invoke-ExternalCommand without -ReadOnly, so Common.ps1's existing
        # dry-run refusal (T05) already logs "would run: pnputil.exe ..." with the concrete
        # folder/INF arguments and returns a synthetic success instead of staging anything.
        $summary = Install-InfDriversFromFolder -Folder $vendorFolder.FullName -LogName ("pnputil-network-{0}.log" -f (Get-SafeName -Value $vendorFolder.Name))
        $results += ,([ordered]@{ vendor = $vendorFolder.Name; status = 'Processed'; count = $summary.count; exit_code = $summary.exit_code })
    } catch {
        # A single bad or mismatched vendor package must not block trying the others, or
        # block the rest of the deployment from reaching a network-capable state.
        Write-Log -Level Warn -Message "Network driver install failed for vendor '$($vendorFolder.Name)': $($_.Exception.Message)"
        $results += ,([ordered]@{ vendor = $vendorFolder.Name; status = 'Failed'; error = $_.Exception.Message })
    }
}

if ($state) {
    $state.network_drivers = $results
    Write-DeploymentState -State $state -StatePath $StatePath
}

$processedCount = @($results | Where-Object { $_.status -eq 'Processed' }).Count
$failedCount = @($results | Where-Object { $_.status -eq 'Failed' }).Count
$emptyVendorCount = $vendorFolders.Count - $results.Count

Write-StructuredLog -Level Info -Message 'Network driver installation completed' -Data $results
if ($processedCount -gt 0) {
    Write-Log -Level Success -Message "Network driver installation completed: $processedCount vendor folder(s) processed, $failedCount failed, $emptyVendorCount skipped (no .inf files). Adapter availability is verified by the WiFi setup and preflight steps that follow."
} else {
    Write-Log -Level Info -Message "No network driver packages were installed ($failedCount vendor folder(s) failed, $emptyVendorCount had no .inf files); continuing with inbox drivers."
}
