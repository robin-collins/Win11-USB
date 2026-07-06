<#
    .SYNOPSIS
        Shared Autounattend.xml / OSIT-DiskPart.txt generation logic for the OSIT Windows 11 USB
        deployment toolkit.

    .DESCRIPTION
        This file is dot-sourced by both Initialize-UsbDeployment.ps1 (which writes the generated
        files to a real USB) and Validate-Unattend.ps1 (which, in -Ci mode, generates the same
        files into a temp folder so CI can validate exactly what production would write, including
        the windowsPE wipe/partition block and the 259-character RunSynchronousCommand Path
        constraint).

        Keeping this logic in one place means there is only one code path that turns
        Deployment\Config\deployment_config.json plus the Autounattend.xml template into the
        answer file and diskpart script a machine actually boots from.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$script:DiskPartScriptFileName = 'OSIT-DiskPart.txt'
$script:DiskPartLogFileName = 'OSIT-DiskPart.log'

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-WindowsPeArtifacts {
    param([hashtable]$Config)

    if (-not [bool]$Config.wipe_repartition_drive) {
        Write-Host ''
        Write-Host 'wipe_repartition_drive is FALSE: the generated Autounattend.xml will NOT wipe or partition any disk.' -ForegroundColor Yellow
        Write-Host 'Windows Setup will require technician-led language, disk, and image selection.' -ForegroundColor Yellow
        Write-Host 'To enable automatic wipe/partitioning, set wipe_repartition_drive=true in Deployment\Config\deployment_config.json in this toolkit folder BEFORE running this script, then rerun it.' -ForegroundColor Yellow
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

function Merge-AutounattendTemplate {
    # Applies the toolkit placeholder substitution shared by Write-PreparedAutounattend (writes
    # straight to a target file) and New-GeneratedUnattendContent (returns content in memory, e.g.
    # for Validate-Unattend.ps1 -Ci to write into a temp folder). Kept as one function so both
    # callers apply exactly the same substitution and validation.
    param(
        [Parameter(Mandatory = $true)][string]$TemplateContent,
        [Parameter(Mandatory = $true)][string]$Password,
        [AllowEmptyString()][string]$WindowsPeSettingsBlock
    )

    $escapedPassword = [System.Security.SecurityElement]::Escape($Password)
    $content = $TemplateContent.Replace('__OSIT_LOCAL_ADMIN_PASSWORD__', $escapedPassword)
    $content = $content.Replace('  __WINDOWS_PE_SETTINGS__', $WindowsPeSettingsBlock.TrimEnd())

    $xmlValidation = [xml]$content
    if (-not $xmlValidation.unattend) { throw 'Generated Autounattend.xml did not validate as an unattend document.' }

    return $content
}

function Write-PreparedAutounattend {
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The password is escaped directly into Autounattend.xml as plaintext (the unattend schema''s own AutoLogon/LocalAccount format requires plaintext or a documented "obfuscated" base64+padding that is not actually secure). There is no SecureString path into an XML text node.')]
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

    $prepared = Merge-AutounattendTemplate -TemplateContent $content -Password $Password -WindowsPeSettingsBlock $WindowsPeSettingsBlock
    Set-Content -LiteralPath $TargetPath -Value $prepared -Encoding UTF8 -Force -ErrorAction Stop
}

function New-GeneratedUnattendContent {
    <#
        .SYNOPSIS
            Generates the Autounattend.xml content and OSIT-DiskPart.txt script text that
            Initialize-UsbDeployment.ps1 would write to a USB, from the repository template and a
            resolved deployment config hashtable (as returned by Get-DeploymentConfig in
            Common.ps1). Returns content only; callers decide where (if anywhere) to write it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Password
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "Autounattend template not found: $TemplatePath"
    }

    $templateContent = Get-Content -LiteralPath $TemplatePath -Raw -ErrorAction Stop
    if ($templateContent -notmatch '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        throw "Autounattend template does not contain the __OSIT_LOCAL_ADMIN_PASSWORD__ placeholder: $TemplatePath"
    }

    $windowsPe = New-WindowsPeArtifacts -Config $Config
    $autounattendContent = Merge-AutounattendTemplate -TemplateContent $templateContent -Password $Password -WindowsPeSettingsBlock $windowsPe.SettingsBlock

    return [ordered]@{
        AutounattendContent = $autounattendContent
        DiskPartScript      = $windowsPe.DiskPartScript
    }
}
