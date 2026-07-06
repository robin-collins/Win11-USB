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

$script:DiskPartScriptFileName = 'OSIT-DiskPart.txt'
$script:DiskPartLogFileName = 'OSIT-DiskPart.log'

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
        $lines = @($lines | ForEach-Object {
                if ($_ -match "^\s*$([regex]::Escape($Name))\s*=") {
                    $found = $true
                    "$Name=$Value"
                } else {
                    $_
                }
            })
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

function Test-MspWifiSetupEnabled {
    param([hashtable]$Config)

    if (-not $Config.ContainsKey('msp_wifi_setup') -or $null -eq $Config.msp_wifi_setup) { return $false }
    $wifiConfig = ConvertTo-PlainHashtable $Config.msp_wifi_setup
    if ($wifiConfig.ContainsKey('enabled')) { return [bool]$wifiConfig.enabled }
    return $true
}

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-WindowsPeArtifacts {
    param([hashtable]$Config)

    if (-not [bool]$Config.wipe_repartition_drive) {
        return @{ SettingsBlock = ''; DiskPartScript = $null }
    }

    $diskId = [int]$Config.wipe_repartition_disk_id
    if ($diskId -lt 0) { throw 'wipe_repartition_disk_id must be 0 or greater.' }

    $efiSize = [int]$Config.efi_partition_size_mb
    $msrSize = [int]$Config.msr_partition_size_mb
    $recoverySize = [int]$Config.recovery_partition_size_mb
    $imageName = [string]$Config.windows_image_name

    if ($efiSize -lt 100) { throw 'efi_partition_size_mb must be at least 100.' }
    if ($msrSize -ne 16) { Write-Warning 'Microsoft standard MSR size is 16 MB. Continuing with configured value.' }
    if ($recoverySize -lt 1024) { throw 'recovery_partition_size_mb must be at least 1024.' }
    if ([string]::IsNullOrWhiteSpace($imageName)) { throw 'windows_image_name must not be empty when wipe_repartition_drive is true.' }

    Write-Host ''
    Write-Host "Destructive partitioning is ENABLED for disk $diskId." -ForegroundColor Yellow
    Write-Host "USB-root $script:DiskPartScriptFileName will clean disk $diskId and create EFI $efiSize MB, MSR $msrSize MB, Windows, and WinRE $recoverySize MB partitions." -ForegroundColor Yellow

    # Letters S/W with noerr instead of C: WinPE often assigns C: to the USB stick when the
    # target disk is blank, and a failed assign makes diskpart /s abort every later command.
    # ImageInstall targets DiskID/PartitionID, so these letters are diagnostic only.
    $diskPartScript = @(
        "select disk $diskId",
        'clean',
        'convert gpt',
        "create partition efi size=$efiSize",
        'format quick fs=fat32 label=System',
        'assign letter=S noerr',
        "create partition msr size=$msrSize",
        'create partition primary',
        "shrink desired=$recoverySize minimum=$recoverySize",
        'format quick fs=ntfs label=Windows',
        'assign letter=W noerr',
        'create partition primary',
        'format quick fs=ntfs label=WinRE',
        'set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac',
        'gpt attributes=0x8000000000000001',
        'list volume',
        'exit'
    ) -join "`r`n"

    # The unattend schema caps RunSynchronousCommand Path at 259 characters, so the diskpart
    # script ships as a USB-root file and this command only locates the USB (by the presence
    # of that file) and runs it, logging diskpart output back to the USB for diagnostics.
    $commandLine = 'cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\{0} (diskpart /s %d:\{0} > %d:\{1} 2>&1)' -f $script:DiskPartScriptFileName, $script:DiskPartLogFileName
    if ($commandLine.Length -gt 259) {
        throw "Generated windowsPE RunSynchronous command is $($commandLine.Length) characters; the unattend Path limit is 259."
    }

    $escapedImageName = ConvertTo-XmlText -Value $imageName

    $settingsBlock = @"
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-AU</InputLocale>
      <SystemLocale>en-AU</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-AU</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Wipe disk $diskId with USB-root $script:DiskPartScriptFileName and create OSIT Windows 11 UEFI partition layout</Description>
          <Path><![CDATA[$commandLine]]></Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/NAME</Key>
              <Value>$escapedImageName</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>$diskId</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
"@

    return @{ SettingsBlock = $settingsBlock; DiskPartScript = $diskPartScript }
}

function Write-PreparedAutounattend {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Password,
        [AllowEmptyString()][string]$WindowsPeSettingsBlock
    )

    $content = Get-Content -LiteralPath $SourcePath -Raw -ErrorAction Stop
    if ($content -notmatch '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        throw "Autounattend template does not contain the __OSIT_LOCAL_ADMIN_PASSWORD__ placeholder: $SourcePath"
    }

    $escapedPassword = [System.Security.SecurityElement]::Escape($Password)
    $content = $content.Replace('__OSIT_LOCAL_ADMIN_PASSWORD__', $escapedPassword)
    $content = $content.Replace('  __WINDOWS_PE_SETTINGS__', $WindowsPeSettingsBlock.TrimEnd())

    $xmlValidation = [xml]$content
    if (-not $xmlValidation.unattend) { throw 'Generated Autounattend.xml did not validate as an unattend document.' }
    Set-Content -LiteralPath $TargetPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop
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
    $skippedRuntimeCount = 0

    function Test-RuntimeDeploymentPath {
        param([string]$RelativePath)

        $topLevel = ($RelativePath -split '[\\/]', 2)[0]
        return $topLevel -in @('Logs', 'Reports', 'State')
    }

    Get-ChildItem -LiteralPath $SourceDeployment -Recurse -Force -Directory -ErrorAction Stop | ForEach-Object {
        $relativePath = $_.FullName.Substring($sourcePrefix.Length)
        if (Test-RuntimeDeploymentPath -RelativePath $relativePath) {
            $skippedRuntimeCount++
        } else {
            New-Item -ItemType Directory -Path (Join-Path $TargetDeployment $relativePath) -Force | Out-Null
        }
    }

    Get-ChildItem -LiteralPath $SourceDeployment -Recurse -Force -File -ErrorAction Stop | ForEach-Object {
        $relativePath = $_.FullName.Substring($sourcePrefix.Length)
        if (Test-RuntimeDeploymentPath -RelativePath $relativePath) {
            $skippedRuntimeCount++
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

    Write-Host "Deployment files refreshed at $TargetDeployment ($copiedCount files overwritten or copied; $skippedRuntimeCount runtime items skipped)." -ForegroundColor Green
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
if (Test-MspWifiSetupEnabled -Config $deploymentConfig) {
    $wifiPassword = Resolve-OsitWifiPasswordForInitialisation -SourceRoot $sourceRoot -UsbRoot $UsbRoot
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

    if (-not [string]::IsNullOrWhiteSpace($wifiPassword)) {
        $targetEnvPath = Join-Path $UsbRoot '.env'
        Set-DotEnvSecret -Path $targetEnvPath -Name 'OSIT_WIFI_PASSWORD' -Value $wifiPassword
        Write-Host "OSIT_WIFI_PASSWORD written to USB-root .env for MSP WiFi setup: $targetEnvPath" -ForegroundColor Green
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
