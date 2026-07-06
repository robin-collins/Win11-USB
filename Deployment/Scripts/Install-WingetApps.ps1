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
$winget = Get-WingetCommand
if (-not $winget) {
    throw 'winget.exe is not available. Install App Installer or disable install_winget_apps in deployment_config.json.'
}

if (-not $packageConfig.ContainsKey('packages')) {
    throw "winget package config must contain a top-level 'packages' array: $($paths.WingetFile)"
}

$results = @()
foreach ($package in @($packageConfig.packages)) {
    $id = [string]$package.id
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'A winget package entry is missing id.' }
    $displayName = if ($package.ContainsKey('display_name') -and -not [string]::IsNullOrWhiteSpace([string]$package.display_name)) { [string]$package.display_name } else { $id }
    $required = if ($package.ContainsKey('required')) { [bool]$package.required } else { $true }
    $installArguments = if ($package.ContainsKey('install_arguments')) { [string]$package.install_arguments } else { '' }

    Write-Log -Level Info -Message "Checking winget package $displayName ($id)."
    $list = Invoke-ExternalCommand -FilePath $winget -Arguments @('list', '--id', $id, '--exact', '--accept-source-agreements') -AllowedExitCodes @(0, 1) -LogName ("winget-list-{0}.log" -f (Get-SafeName -Value $id))
    if ($list.exit_code -eq 0 -and $list.stdout -match [regex]::Escape($id)) {
        Write-Log -Level Success -Message "$displayName is already installed."
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = 'AlreadyInstalled'; required = $required })
        continue
    }

    $args = @(
        'install',
        '--id', $id,
        '--exact',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if (-not [string]::IsNullOrWhiteSpace($installArguments)) {
        $args += @('--override', $installArguments)
    }

    try {
        $install = Invoke-ExternalCommand -FilePath $winget -Arguments $args -AllowedExitCodes @(0, 3010) -LogName ("winget-install-{0}.log" -f (Get-SafeName -Value $id))
        $status = if ($install.exit_code -eq 3010) { 'InstalledRebootRequired' } else { 'Installed' }
        Write-Log -Level Success -Message "$displayName install result: $status."
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = $status; required = $required; exit_code = $install.exit_code })
    } catch {
        $message = "winget install failed for $displayName ($id): $($_.Exception.Message)"
        Write-Log -Level Error -Message $message
        $results += ,([ordered]@{ id = $id; display_name = $displayName; status = 'Failed'; required = $required; error = $_.Exception.Message })
        if ($required -and [bool]$config.fail_on_missing_required_app) { throw $message }
    }
}

Write-StructuredLog -Level Info -Message 'winget app installation completed' -Data $results
