[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This script is an interactive technician CLI (USB preparation wizard): colored status output and Read-Host prompts are the intended UX, not library output.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$VolumeLabel = '1S-WIN11',
    [switch]$SkipCopy
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $sourceRoot 'Deployment\Scripts\Common.ps1')
# Shared with Validate-Unattend.ps1 so CI validates the exact code path that writes the USB.
. (Join-Path $sourceRoot 'Deployment\Scripts\UnattendGeneration.ps1')

function Set-DotEnvSecret {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        $found = $false
        for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
            if ($lines[$lineIndex] -match "^\s*$([regex]::Escape($Name))\s*=") {
                $found = $true
                $lines[$lineIndex] = "$Name=$Value"
            }
        }
        if (-not $found) { $lines += "$Name=$Value" }
    } else {
        $lines = @("$Name=$Value")
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -Force -ErrorAction Stop
}

function Resolve-OsitPasswordForInitialisation {
    param(
        [string]$SourceRoot,
        [string]$UsbRoot
    )

    $password = Get-OsitLocalAdminPassword -SearchRoots @($SourceRoot, $UsbRoot)
    if (-not [string]::IsNullOrWhiteSpace($password)) { return $password }

    Write-Host ''
    Write-Host 'OSIT_LOCAL_ADMIN_PASSWORD was not found in the environment or a .env file.' -ForegroundColor Yellow
    Write-Host 'The generated USB Autounattend.xml needs this password for the OSIT auto-logon account.' -ForegroundColor Yellow
    Write-Host 'D) Create or update .env in this toolkit folder'
    Write-Host 'E) Create or update the current user environment variable'
    Write-Host 'Q) Quit without writing Autounattend.xml'

    do {
        $choice = (Read-Host 'Choose D, E, or Q').Trim().ToUpperInvariant()
    } until ($choice -in @('D', 'E', 'Q'))

    if ($choice -eq 'Q') { throw 'OSIT password initialisation cancelled.' }

    $secure = Read-Host 'Enter the OSIT local admin password' -AsSecureString
    $plain = ConvertFrom-SecureStringToPlainText -SecureString $secure
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'OSIT local admin password cannot be empty.' }

    if ($choice -eq 'D') {
        $envPath = Join-Path $SourceRoot '.env'
        Set-DotEnvSecret -Path $envPath -Name 'OSIT_LOCAL_ADMIN_PASSWORD' -Value $plain
        Write-Host ".env updated at $envPath" -ForegroundColor Green
    } else {
        [Environment]::SetEnvironmentVariable('OSIT_LOCAL_ADMIN_PASSWORD', $plain, 'User')
        [Environment]::SetEnvironmentVariable('OSIT_LOCAL_ADMIN_PASSWORD', $plain, 'Process')
        Write-Host 'User environment variable OSIT_LOCAL_ADMIN_PASSWORD has been set.' -ForegroundColor Green
    }

    return $plain
}

function Resolve-OsitWifiPasswordForInitialisation {
    param(
        [string]$SourceRoot,
        [string]$UsbRoot
    )

    $password = Get-OsitWifiPassword -SearchRoots @($SourceRoot, $UsbRoot)
    if (-not [string]::IsNullOrWhiteSpace($password)) { return $password }

    Write-Host ''
    Write-Host 'OSIT_WIFI_PASSWORD was not found in the environment or a .env file.' -ForegroundColor Yellow
    Write-Host 'MSP WiFi setup is enabled and needs this password to connect to OneSolution during deployment.' -ForegroundColor Yellow
    Write-Host 'D) Create or update .env in this toolkit folder'
    Write-Host 'E) Create or update the current user environment variable'
    Write-Host 'Q) Quit without writing the WiFi password'

    do {
        $choice = (Read-Host 'Choose D, E, or Q').Trim().ToUpperInvariant()
    } until ($choice -in @('D', 'E', 'Q'))

    if ($choice -eq 'Q') { throw 'OSIT WiFi password initialisation cancelled.' }

    $secure = Read-Host 'Enter the OneSolution WiFi password' -AsSecureString
    $plain = ConvertFrom-SecureStringToPlainText -SecureString $secure
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'OSIT WiFi password cannot be empty.' }

    if ($choice -eq 'D') {
        $envPath = Join-Path $SourceRoot '.env'
        Set-DotEnvSecret -Path $envPath -Name 'OSIT_WIFI_PASSWORD' -Value $plain
        Write-Host ".env updated at $envPath" -ForegroundColor Green
    } else {
        [Environment]::SetEnvironmentVariable('OSIT_WIFI_PASSWORD', $plain, 'User')
        [Environment]::SetEnvironmentVariable('OSIT_WIFI_PASSWORD', $plain, 'Process')
        Write-Host 'User environment variable OSIT_WIFI_PASSWORD has been set.' -ForegroundColor Green
    }

    return $plain
}

function Resolve-OsitSmtpPasswordForInitialisation {
    param(
        [string]$SourceRoot,
        [string]$UsbRoot,
        [string]$EnvVarName
    )

    $password = Get-OsitSmtpPassword -SearchRoots @($SourceRoot, $UsbRoot) -EnvVarName $EnvVarName
    if (-not [string]::IsNullOrWhiteSpace($password)) { return $password }

    Write-Host ''
    Write-Host "$EnvVarName was not found in the environment or a .env file." -ForegroundColor Yellow
    Write-Host 'SMTP email notification is enabled and configured with a username, so it needs this password to authenticate.' -ForegroundColor Yellow
    Write-Host 'D) Create or update .env in this toolkit folder'
    Write-Host 'E) Create or update the current user environment variable'
    Write-Host 'Q) Quit without writing the SMTP password'

    do {
        $choice = (Read-Host 'Choose D, E, or Q').Trim().ToUpperInvariant()
    } until ($choice -in @('D', 'E', 'Q'))

    if ($choice -eq 'Q') { throw 'SMTP password initialisation cancelled.' }

    $secure = Read-Host "Enter the SMTP password for $EnvVarName" -AsSecureString
    $plain = ConvertFrom-SecureStringToPlainText -SecureString $secure
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'SMTP password cannot be empty.' }

    if ($choice -eq 'D') {
        $envPath = Join-Path $SourceRoot '.env'
        Set-DotEnvSecret -Path $envPath -Name $EnvVarName -Value $plain
        Write-Host ".env updated at $envPath" -ForegroundColor Green
    } else {
        [Environment]::SetEnvironmentVariable($EnvVarName, $plain, 'User')
        [Environment]::SetEnvironmentVariable($EnvVarName, $plain, 'Process')
        Write-Host "User environment variable $EnvVarName has been set." -ForegroundColor Green
    }

    return $plain
}

function Test-SmtpPasswordRequired {
    param([hashtable]$SmtpConfig)

    if (-not [bool]$SmtpConfig.enabled) { return $false }
    return -not [string]::IsNullOrWhiteSpace([string]$SmtpConfig.username)
}

function Test-MspWifiSetupEnabled {
    param([hashtable]$Config)

    if (-not $Config.ContainsKey('msp_wifi_setup') -or $null -eq $Config.msp_wifi_setup) { return $false }
    $wifiConfig = ConvertTo-PlainHashtable $Config.msp_wifi_setup
    if ($wifiConfig.ContainsKey('enabled')) { return [bool]$wifiConfig.enabled }
    return $true
}

function Copy-DeploymentFiles {
    param(
        [string]$SourceDeployment,
        [string]$TargetDeployment
    )

    $resolvedSource = (Resolve-Path -LiteralPath $SourceDeployment -ErrorAction Stop).Path.TrimEnd('\')
    $resolvedTarget = $null
    if (Test-Path -LiteralPath $TargetDeployment) {
        $resolvedTarget = (Resolve-Path -LiteralPath $TargetDeployment -ErrorAction Stop).Path.TrimEnd('\')
    }

    if ($resolvedTarget -and ($resolvedSource -ieq $resolvedTarget)) {
        Write-Host 'Source and target Deployment paths are the same; no file copy required.' -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Path $TargetDeployment -Force | Out-Null

    $sourcePrefix = $resolvedSource + '\'
    $copiedCount = 0
    $skippedExcludedCount = 0

    function Test-ExcludedDeploymentPath {
        param([string]$RelativePath)

        $topLevel = ($RelativePath -split '[\\/]', 2)[0]
        # Logs/Reports/State are per-run runtime output, never toolkit input. VHD holds large
        # local-only Hyper-V rehearsal test media (Test\Rehearsal\Media\ is the intended home;
        # VHD is excluded here too as a backstop) -- never copy it onto real deployment media.
        return $topLevel -in @('Logs', 'Reports', 'State', 'VHD')
    }

    Get-ChildItem -LiteralPath $SourceDeployment -Recurse -Force -Directory -ErrorAction Stop | ForEach-Object {
        $relativePath = $_.FullName.Substring($sourcePrefix.Length)
        if (Test-ExcludedDeploymentPath -RelativePath $relativePath) {
            $skippedExcludedCount++
        } else {
            New-Item -ItemType Directory -Path (Join-Path $TargetDeployment $relativePath) -Force | Out-Null
        }
    }

    Get-ChildItem -LiteralPath $SourceDeployment -Recurse -Force -File -ErrorAction Stop | ForEach-Object {
        $relativePath = $_.FullName.Substring($sourcePrefix.Length)
        if (Test-ExcludedDeploymentPath -RelativePath $relativePath) {
            $skippedExcludedCount++
        } else {
            $targetFile = Join-Path $TargetDeployment $relativePath
            $targetFolder = Split-Path -Parent $targetFile
            if (-not (Test-Path -LiteralPath $targetFolder -PathType Container)) {
                New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
            }

            if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
                Set-ItemProperty -LiteralPath $targetFile -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            }

            Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force -ErrorAction Stop
            $copiedCount++
        }
    }

    Write-Host "Deployment files refreshed at $TargetDeployment ($copiedCount files overwritten or copied; $skippedExcludedCount runtime/VHD items skipped)." -ForegroundColor Green
}

function Clear-DeploymentState {
    param([string]$TargetDeployment)

    $targetState = Join-Path $TargetDeployment 'State'
    New-Item -ItemType Directory -Path $targetState -Force | Out-Null

    $resolvedDeployment = (Resolve-Path -LiteralPath $TargetDeployment -ErrorAction Stop).Path.TrimEnd('\')
    $resolvedState = (Resolve-Path -LiteralPath $targetState -ErrorAction Stop).Path.TrimEnd('\')
    $expectedState = (Join-Path $resolvedDeployment 'State').TrimEnd('\')
    if ($resolvedState -ine $expectedState) {
        throw "Refusing to clear deployment state because the resolved path is unexpected: $resolvedState"
    }

    $stateItems = @(Get-ChildItem -LiteralPath $resolvedState -Force -ErrorAction Stop)
    if ($stateItems.Count -eq 0) {
        Write-Host "Deployment state is already clear at $resolvedState" -ForegroundColor Green
        return
    }

    foreach ($item in $stateItems) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }

    Write-Host "Deployment state scrubbed at $resolvedState ($($stateItems.Count) items removed)." -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
    $UsbRoot = Get-UsbRoot -VolumeLabel $VolumeLabel
}

$paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
Write-Host "Deployment folder structure ensured under $UsbRoot" -ForegroundColor Green
$deploymentConfig = Get-DeploymentConfig -UsbRoot $sourceRoot
$ositPassword = Resolve-OsitPasswordForInitialisation -SourceRoot $sourceRoot -UsbRoot $UsbRoot
$wifiPassword = $null
$sourcePrimaryWifiProfile = Join-Path (Join-Path $sourceRoot 'Deployment\WifiProfiles') $script:PrimaryWifiProfileFileName
if (Test-Path -LiteralPath $sourcePrimaryWifiProfile -PathType Leaf) {
    Write-Host "Deployment\WifiProfiles\$script:PrimaryWifiProfileFileName found; the primary WLAN profile it contains already carries its own key, so OSIT_WIFI_PASSWORD is not needed." -ForegroundColor Green
} elseif (Test-MspWifiSetupEnabled -Config $deploymentConfig) {
    $wifiPassword = Resolve-OsitWifiPasswordForInitialisation -SourceRoot $sourceRoot -UsbRoot $UsbRoot
}
$smtpConfig = Get-SmtpConfig -UsbRoot $sourceRoot
$smtpPasswordEnvVar = [string]$smtpConfig.password_env_var
if ([string]::IsNullOrWhiteSpace($smtpPasswordEnvVar)) { $smtpPasswordEnvVar = 'OSIT_SMTP_PASSWORD' }
$smtpPassword = $null
if (Test-SmtpPasswordRequired -SmtpConfig $smtpConfig) {
    $smtpPassword = Resolve-OsitSmtpPasswordForInitialisation -SourceRoot $sourceRoot -UsbRoot $UsbRoot -EnvVarName $smtpPasswordEnvVar
}

if (-not $SkipCopy) {
    $sourceDeployment = Join-Path $sourceRoot 'Deployment'
    $targetDeployment = Join-Path $UsbRoot 'Deployment'
    Copy-DeploymentFiles -SourceDeployment $sourceDeployment -TargetDeployment $targetDeployment
    Clear-DeploymentState -TargetDeployment $targetDeployment

    $windowsPe = New-WindowsPeArtifacts -Config $deploymentConfig
    $sourceAutounattend = Join-Path $sourceRoot 'Autounattend.xml'
    $targetAutounattend = Join-Path $UsbRoot 'Autounattend.xml'
    if (Test-Path -LiteralPath $sourceAutounattend -PathType Leaf) {
        Write-PreparedAutounattend -SourcePath $sourceAutounattend -TargetPath $targetAutounattend -Password $ositPassword -WindowsPeSettingsBlock $windowsPe.SettingsBlock
        Write-Host "Autounattend.xml prepared for OSIT and written to $targetAutounattend" -ForegroundColor Green
    }

    $targetDiskPartScript = Join-Path $UsbRoot $script:DiskPartScriptFileName
    $targetDiskPartLog = Join-Path $UsbRoot $script:DiskPartLogFileName
    if ($null -ne $windowsPe.DiskPartScript) {
        # ASCII avoids a UTF-8 BOM, which diskpart /s misreads as part of the first command.
        Set-Content -LiteralPath $targetDiskPartScript -Value $windowsPe.DiskPartScript -Encoding ASCII -Force -ErrorAction Stop
        Write-Host "DiskPart wipe script written to $targetDiskPartScript" -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $targetDiskPartScript -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskPartScript -Force -ErrorAction Stop
        Write-Host "Removed stale $targetDiskPartScript because wipe_repartition_drive is disabled." -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $targetDiskPartLog -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskPartLog -Force -ErrorAction SilentlyContinue
    }

    $targetDiskCheckScript = Join-Path $UsbRoot $script:DiskCheckScriptFileName
    $targetDiskCheckLog = Join-Path $UsbRoot $script:DiskCheckLogFileName
    if ($null -ne $windowsPe.DiskCheckScript) {
        # ASCII avoids a UTF-8 BOM, which cmd.exe misreads as part of the first command.
        Set-Content -LiteralPath $targetDiskCheckScript -Value $windowsPe.DiskCheckScript -Encoding ASCII -Force -ErrorAction Stop
        Write-Host "Pre-wipe disk safety check written to $targetDiskCheckScript" -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $targetDiskCheckScript -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskCheckScript -Force -ErrorAction Stop
        Write-Host "Removed stale $targetDiskCheckScript because wipe_repartition_drive is disabled." -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $targetDiskCheckLog -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskCheckLog -Force -ErrorAction SilentlyContinue
    }

    $targetDiskAssertScript = Join-Path $UsbRoot $script:DiskAssertScriptFileName
    if ($null -ne $windowsPe.DiskAssertScript) {
        # ASCII avoids a UTF-8 BOM, which cscript.exe misreads as part of the first command.
        Set-Content -LiteralPath $targetDiskAssertScript -Value $windowsPe.DiskAssertScript -Encoding ASCII -Force -ErrorAction Stop
        Write-Host "WMI disk assertion script written to $targetDiskAssertScript" -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $targetDiskAssertScript -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskAssertScript -Force -ErrorAction Stop
        Write-Host "Removed stale $targetDiskAssertScript because wipe_repartition_drive is disabled." -ForegroundColor Yellow
    }

    $targetDiskDiagScript = Join-Path $UsbRoot $script:DiskDiagScriptFileName
    if ($null -ne $windowsPe.DiskDiagScript) {
        # ASCII avoids a UTF-8 BOM, which cscript.exe misreads as part of the first command.
        Set-Content -LiteralPath $targetDiskDiagScript -Value $windowsPe.DiskDiagScript -Encoding ASCII -Force -ErrorAction Stop
        Write-Host "On-failure disk diagnostic script written to $targetDiskDiagScript" -ForegroundColor Green
    } elseif (Test-Path -LiteralPath $targetDiskDiagScript -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskDiagScript -Force -ErrorAction Stop
        Write-Host "Removed stale $targetDiskDiagScript because wipe_repartition_drive is disabled." -ForegroundColor Yellow
    }
    $targetDiskDiagLog = Join-Path $UsbRoot $script:DiskDiagLogFileName
    if (Test-Path -LiteralPath $targetDiskDiagLog -PathType Leaf) {
        Remove-Item -LiteralPath $targetDiskDiagLog -Force -ErrorAction SilentlyContinue
    }

    # Validate what actually landed on the USB against the same config used to generate it,
    # so a config/answer-file mismatch fails here instead of at boot on a customer machine.
    $validator = Join-Path $sourceRoot 'Validate-Unattend.ps1'
    if ((Test-Path -LiteralPath $validator -PathType Leaf) -and (Test-Path -LiteralPath $targetAutounattend -PathType Leaf)) {
        Write-Host ''
        Write-Host 'Validating the generated USB Autounattend.xml...' -ForegroundColor Cyan
        & $validator -Path $targetAutounattend -Generated -ConfigPath (Join-Path $sourceRoot 'Deployment\Config\deployment_config.json')
        if ($LASTEXITCODE -ne 0) {
            throw 'Generated USB Autounattend.xml failed validation. Fix Deployment\Config\deployment_config.json or the template, then rerun Initialize-UsbDeployment.ps1.'
        }
    }

    if ($null -ne $windowsPe.DiskPartScript) {
        Write-Host ''
        Write-Host "REMINDER: this USB will WIPE disk $([int]$deploymentConfig.wipe_repartition_disk_id) automatically when a machine boots from it." -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host 'This USB performs technician-led disk setup (no automatic wipe).' -ForegroundColor Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($wifiPassword)) {
        $targetEnvPath = Join-Path $UsbRoot '.env'
        Set-DotEnvSecret -Path $targetEnvPath -Name 'OSIT_WIFI_PASSWORD' -Value $wifiPassword
        Write-Host "OSIT_WIFI_PASSWORD written to USB-root .env for MSP WiFi setup: $targetEnvPath" -ForegroundColor Green
    }

    if (-not [string]::IsNullOrWhiteSpace($smtpPassword)) {
        $targetEnvPath = Join-Path $UsbRoot '.env'
        Set-DotEnvSecret -Path $targetEnvPath -Name $smtpPasswordEnvVar -Value $smtpPassword
        Write-Host "$smtpPasswordEnvVar written to USB-root .env for SMTP email notification: $targetEnvPath" -ForegroundColor Green
    }
} else {
    Write-Host 'SkipCopy was specified; deployment files and Autounattend.xml were not copied.' -ForegroundColor Yellow
}

foreach ($vendor in @('Dell', 'HP', 'Lenovo', 'Generic')) {
    $vendorPath = Join-Path $paths.Drivers $vendor
    if (-not (Test-Path -LiteralPath $vendorPath -PathType Container)) {
        New-Item -ItemType Directory -Path $vendorPath -Force | Out-Null
    }
}

Write-Host 'USB deployment toolkit initialisation complete.' -ForegroundColor Green
