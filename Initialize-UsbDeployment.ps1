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

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-WindowsPeSettingsBlock {
    param([hashtable]$Config)

    if (-not [bool]$Config.wipe_repartition_drive) {
        return ''
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
    Write-Host "Generated Autounattend.xml will clean disk $diskId and create EFI $efiSize MB, MSR $msrSize MB, Windows, and WinRE $recoverySize MB partitions." -ForegroundColor Yellow

    $diskPartCommand = @(
        "select disk $diskId",
        'clean',
        'convert gpt',
        "create partition efi size=$efiSize",
        'format quick fs=fat32 label="System"',
        'assign letter="S"',
        "create partition msr size=$msrSize",
        'create partition primary',
        "shrink desired=$recoverySize minimum=$recoverySize",
        'format quick fs=ntfs label="Windows"',
        'assign letter="C"',
        'create partition primary',
        'format quick fs=ntfs label="Windows RE tools"',
        'set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"',
        'gpt attributes=0x8000000000000001',
        'list volume'
    )

    $echoLines = ($diskPartCommand | ForEach-Object { 'echo ' + $_ }) -join '&'
    $commandLine = 'cmd.exe /c "({0}) > X:\OSIT-DiskPart.txt & diskpart /s X:\OSIT-DiskPart.txt"' -f $echoLines
    $escapedImageName = ConvertTo-XmlText -Value $imageName

    return @"
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
          <Description>Wipe disk $diskId and create OSIT Windows 11 UEFI partition layout</Description>
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
}

function Write-PreparedAutounattend {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Password,
        [hashtable]$Config
    )

    $content = Get-Content -LiteralPath $SourcePath -Raw -ErrorAction Stop
    if ($content -notmatch '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        throw "Autounattend template does not contain the __OSIT_LOCAL_ADMIN_PASSWORD__ placeholder: $SourcePath"
    }

    $escapedPassword = [System.Security.SecurityElement]::Escape($Password)
    $content = $content.Replace('__OSIT_LOCAL_ADMIN_PASSWORD__', $escapedPassword)
    $content = $content.Replace('  __WINDOWS_PE_SETTINGS__', (New-WindowsPeSettingsBlock -Config $Config).TrimEnd())
    Set-Content -LiteralPath $TargetPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop

    $xmlValidation = [xml]$content
    if (-not $xmlValidation.unattend) { throw 'Generated Autounattend.xml did not validate as an unattend document.' }
}

if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
    $UsbRoot = Get-UsbRoot -VolumeLabel $VolumeLabel
}

$paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
Write-Host "Deployment folder structure ensured under $UsbRoot" -ForegroundColor Green
$deploymentConfig = Get-DeploymentConfig -UsbRoot $sourceRoot
$ositPassword = Resolve-OsitPasswordForInitialisation -SourceRoot $sourceRoot -UsbRoot $UsbRoot

if (-not $SkipCopy) {
    $sourceDeployment = Join-Path $sourceRoot 'Deployment'
    $targetDeployment = Join-Path $UsbRoot 'Deployment'
    if ((Resolve-Path -LiteralPath $sourceDeployment).Path -ne (Resolve-Path -LiteralPath $targetDeployment -ErrorAction SilentlyContinue).Path) {
        Copy-Item -Path (Join-Path $sourceDeployment '*') -Destination $targetDeployment -Recurse -Force -ErrorAction Stop
        Write-Host "Deployment files copied to $targetDeployment" -ForegroundColor Green
    }

    $sourceAutounattend = Join-Path $sourceRoot 'Autounattend.xml'
    $targetAutounattend = Join-Path $UsbRoot 'Autounattend.xml'
    if (Test-Path -LiteralPath $sourceAutounattend -PathType Leaf) {
        Write-PreparedAutounattend -SourcePath $sourceAutounattend -TargetPath $targetAutounattend -Password $ositPassword -Config $deploymentConfig
        Write-Host "Autounattend.xml prepared for OSIT and written to $targetAutounattend" -ForegroundColor Green
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
