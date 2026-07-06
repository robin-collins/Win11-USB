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
$appConfig = Read-JsonFile -Path $paths.LocalFile -Required

if (-not $appConfig.ContainsKey('apps')) {
    throw "Local app config must contain a top-level 'apps' array: $($paths.LocalFile)"
}

function Test-LocalAppDetected {
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingInvokeExpression', '', Justification = 'The detection command string comes from this toolkit''s own local_apps.json, authored by the deploying technician/MSP (not external/untrusted input); arbitrary expression evaluation is the intended extensibility point for custom detection logic per app entry.')]
    param([object]$Detection)

    if (-not $Detection) { return $false }
    $type = if ($Detection.ContainsKey('type')) { [string]$Detection.type } else { '' }
    switch ($type.ToLowerInvariant()) {
        'registry' {
            if (-not $Detection.ContainsKey('display_name_pattern')) { throw 'Registry detection requires display_name_pattern.' }
            return (Test-ProgramInstalled -Pattern ([string]$Detection.display_name_pattern))
        }
        'command' {
            if (-not $Detection.ContainsKey('command')) { throw 'Command detection requires command.' }
            try {
                $result = Invoke-Expression ([string]$Detection.command)
                return [bool]$result
            } catch {
                Write-Log -Level Warn -Message "Detection command failed: $($_.Exception.Message)"
                return $false
            }
        }
        'path' {
            if (-not $Detection.ContainsKey('path')) { throw 'Path detection requires path.' }
            return (Test-Path -LiteralPath ([string]$Detection.path))
        }
        default {
            throw "Unsupported local app detection type '$type'."
        }
    }
}

function Invoke-LocalInstaller {
    param(
        [string]$InstallerPath,
        [string]$InstallerType,
        [string]$SilentArguments,
        [string]$LogName
    )

    switch ($InstallerType.ToLowerInvariant()) {
        'msi' {
            $installerArgs = @('/i', $InstallerPath)
            if ([string]::IsNullOrWhiteSpace($SilentArguments)) { $installerArgs += @('/qn', '/norestart') } else { $installerArgs += (Split-CommandLineArguments -ArgumentString $SilentArguments) }
            return Invoke-ExternalCommand -FilePath msiexec.exe -Arguments $installerArgs -AllowedExitCodes @(0, 3010, 1641) -LogName $LogName
        }
        'exe' {
            $installerArgs = @()
            if (-not [string]::IsNullOrWhiteSpace($SilentArguments)) { $installerArgs = Split-CommandLineArguments -ArgumentString $SilentArguments }
            return Invoke-ExternalCommand -FilePath $InstallerPath -Arguments $installerArgs -AllowedExitCodes @(0, 3010, 1641) -LogName $LogName
        }
        'msix' {
            Add-AppxPackage -Path $InstallerPath -ErrorAction Stop
            return [ordered]@{ exit_code = 0; stdout = 'Add-AppxPackage completed.'; stderr = '' }
        }
        'appx' {
            Add-AppxPackage -Path $InstallerPath -ErrorAction Stop
            return [ordered]@{ exit_code = 0; stdout = 'Add-AppxPackage completed.'; stderr = '' }
        }
        'script' {
            $installerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $InstallerPath)
            if (-not [string]::IsNullOrWhiteSpace($SilentArguments)) { $installerArgs += (Split-CommandLineArguments -ArgumentString $SilentArguments) }
            return Invoke-ExternalCommand -FilePath powershell.exe -Arguments $installerArgs -AllowedExitCodes @(0, 3010) -LogName $LogName
        }
        default {
            throw "Unsupported installer_type '$InstallerType' for $InstallerPath."
        }
    }
}

$results = @()
foreach ($app in @($appConfig.apps)) {
    $name = [string]$app.name
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'A local app entry is missing name.' }
    $required = if ($app.ContainsKey('required')) { [bool]$app.required } else { $false }
    $relativePath = [string]$app.relative_path
    $installerType = [string]$app.installer_type
    $silentArguments = if ($app.ContainsKey('silent_arguments')) { [string]$app.silent_arguments } else { '' }
    $installerPath = Join-Path $paths.LocalApps $relativePath
    $logName = "local-install-{0}.log" -f (Get-SafeName -Value $name)

    if ($app.ContainsKey('detection') -and (Test-LocalAppDetected -Detection $app.detection)) {
        Write-Log -Level Success -Message "$name is already installed."
        $results += ,([ordered]@{ name = $name; status = 'AlreadyInstalled'; required = $required })
        continue
    }

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        $message = "Configured local installer is missing for $name`: $installerPath"
        Write-Log -Level Error -Message $message
        $results += ,([ordered]@{ name = $name; status = 'MissingInstaller'; required = $required; path = $installerPath })
        if ($required) { throw $message }
        continue
    }

    try {
        Write-Log -Level Info -Message "Installing local app $name from $installerPath."
        $install = Invoke-LocalInstaller -InstallerPath $installerPath -InstallerType $installerType -SilentArguments $silentArguments -LogName $logName
        $status = if ($install.exit_code -in @(3010, 1641)) { 'InstalledRebootRequired' } else { 'Installed' }
        $results += ,([ordered]@{ name = $name; status = $status; required = $required; exit_code = $install.exit_code; path = $installerPath })
        Write-Log -Level Success -Message "$name install result: $status."
    } catch {
        $message = "Local app install failed for $name`: $($_.Exception.Message)"
        Write-Log -Level Error -Message $message
        $results += ,([ordered]@{ name = $name; status = 'Failed'; required = $required; error = $_.Exception.Message; path = $installerPath })
        if ($required -and [bool]$config.fail_on_missing_required_app) { throw $message }
    }
}

Write-StructuredLog -Level Info -Message 'Local app installation completed' -Data $results
