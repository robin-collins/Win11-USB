<#
    .SYNOPSIS
        Validates Autounattend.xml for the OSIT Windows 11 USB deployment toolkit.

    .DESCRIPTION
        Performs practical validation of the repository Autounattend.xml template or a generated
        USB-root Autounattend.xml file.

        Checks include:
        - XML well-formedness.
        - Optional ADK/AIK schema validation when Microsoft.ComponentStudio.ComponentPlatformInterface.dll is available.
        - Template placeholder handling for __OSIT_LOCAL_ADMIN_PASSWORD__ and __WINDOWS_PE_SETTINGS__.
        - OSIT local account and AutoLogon consistency.
        - BypassNRO specialize command.
        - FirstLogonCommand points back to USB label 1S-WIN11 and Start-Deployment.ps1.
        - Optional destructive disk layout checks when generated XML contains a windowsPE pass.

    .PARAMETER Path
        Path to Autounattend.xml. Defaults to .\Autounattend.xml beside this script.

    .PARAMETER ConfigPath
        Path to deployment_config.json. Used for expectation checks such as wipe_repartition_drive.

    .PARAMETER DllPath
        Optional explicit path to Microsoft.ComponentStudio.ComponentPlatformInterface.dll.

    .PARAMETER RequireSchema
        Fail validation if ADK/AIK schema validation cannot be performed.

    .PARAMETER Generated
        Treat Path as a generated USB-root Autounattend.xml. Generated files should not contain toolkit placeholders.

    .PARAMETER Template
        Treat Path as the repository template. Template files should contain toolkit placeholders. This is the default.

    .EXAMPLE
        .\Validate-Unattend.ps1

    .EXAMPLE
        .\Validate-Unattend.ps1 -Path E:\Autounattend.xml -Generated

    .NOTES
        Schema extraction functions are based on:
        https://gist.github.com/davidwallis3101/48454cb6c17c988de43b5ea17089ea6f
        and the unattend schema notes at:
        http://schneegans.de/computer/unattend-schema/
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'Autounattend.xml'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Deployment\Config\deployment_config.json'),
    [string]$DllPath,
    [switch]$RequireSchema,
    [switch]$Generated,
    [switch]$Template
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $Generated -and -not $Template) { $Template = $true }
if ($Generated -and $Template) { throw 'Use only one of -Generated or -Template.' }

$script:ValidationResults = New-Object 'System.Collections.Generic.List[object]'

function Add-ValidationResult {
    param(
        [ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [string]$Check,
        [string]$Message,
        [object]$Data = $null
    )

    $script:ValidationResults.Add([ordered]@{
            status  = $Status
            check   = $Check
            message = $Message
            data    = $Data
        }) | Out-Null

    $color = switch ($Status) {
        'Pass' { 'Green' }
        'Warn' { 'Yellow' }
        'Fail' { 'Red' }
    }
    Write-Host "[$Status] $Check - $Message" -ForegroundColor $color
}

function Get-Schema {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $assembly = [Reflection.Assembly]::LoadFile($Path)
    $resNames = $assembly.GetManifestResourceNames()
    $resName = ($resNames | Where-Object { $_ -like '*.resources' } | Select-Object -First 1)
    if (-not $resName) { throw "No .resources manifest entry found in $Path" }

    $resourceBaseName = $resName.Replace('.resources', '')
    $resourceManager = New-Object System.Resources.ResourceManager -ArgumentList $resourceBaseName, $assembly

    foreach ($cultureName in @('en-US', 'en-GB', '')) {
        $culture = if ($cultureName) { New-Object System.Globalization.CultureInfo -ArgumentList $cultureName } else { [System.Globalization.CultureInfo]::InvariantCulture }
        $resources = $resourceManager.GetResourceSet($culture, $true, $true)
        if (-not $resources) { continue }

        foreach ($resource in $resources) {
            if ($resource.Name -ne 'Unattend') { continue }
            return [System.Text.Encoding]::ASCII.GetString($resource.Value)
        }
    }

    throw "Unattend schema resource was not found in $Path"
}

function Find-UnattendSchemaDll {
    $candidateNames = @(
        'Microsoft.ComponentStudio.ComponentPlatformInterface.dll',
        'microsoft.componentstudio.componentplatforminterface.dll'
    )
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits",
        "$env:ProgramFiles\Windows Kits",
        "${env:ProgramFiles(x86)}\Windows AIK",
        "$env:ProgramFiles\Windows AIK"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }

    foreach ($root in $roots) {
        foreach ($name in $candidateNames) {
            $match = Get-ChildItem -LiteralPath $root -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($match) { return $match.FullName }
        }
    }

    return $null
}

function Test-XmlSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$XmlPath,
        [Parameter(Mandatory = $true)][string]$SchemaText
    )

    $validationErrors = New-Object 'System.Collections.Generic.List[string]'
    $handler = [System.Xml.Schema.ValidationEventHandler]{
        param($sender, $eventArgs)
        $validationErrors.Add($eventArgs.Exception.Message) | Out-Null
    }

    $schemaReader = New-Object System.IO.StringReader($SchemaText)
    try {
        $schema = [System.Xml.Schema.XmlSchema]::Read($schemaReader, $handler)
        $xml = New-Object System.Xml.XmlDocument
        $xml.Schemas.Add($schema) | Out-Null
        $xml.Load($XmlPath)
        $xml.Validate($handler)
    } finally {
        $schemaReader.Close()
    }

    return @($validationErrors)
}

function ConvertTo-ValidationXml {
    param(
        [string]$Content,
        [bool]$IsTemplate
    )

    $converted = $Content
    if ($IsTemplate) {
        $converted = $converted.Replace('__OSIT_LOCAL_ADMIN_PASSWORD__', 'ValidationOnly!123')
        $converted = $converted.Replace('  __WINDOWS_PE_SETTINGS__', '')
        $converted = $converted.Replace('__WINDOWS_PE_SETTINGS__', '')
    }
    return $converted
}

function Read-JsonHashtable {
    param([string]$JsonPath)

    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { return $null }
    $raw = Get-Content -LiteralPath $JsonPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Get-UnattendNamespaceManager {
    param([xml]$Xml)

    $ns = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend') | Out-Null
    Write-Output -NoEnumerate $ns
}

function Get-NodeText {
    param(
        [xml]$Xml,
        [System.Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$XPath
    )

    $node = $Xml.SelectSingleNode($XPath, $NamespaceManager)
    if ($node) { return $node.InnerText }
    return $null
}

function Test-ExpectedText {
    param(
        [xml]$Xml,
        [System.Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$Check,
        [string]$XPath,
        [string]$Expected
    )

    $actual = Get-NodeText -Xml $Xml -NamespaceManager $NamespaceManager -XPath $XPath
    if ($actual -eq $Expected) {
        Add-ValidationResult -Status Pass -Check $Check -Message "Expected value '$Expected' found."
    } else {
        Add-ValidationResult -Status Fail -Check $Check -Message "Expected '$Expected' but found '$actual'." -Data @{ xpath = $XPath; actual = $actual; expected = $Expected }
    }
}

$resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$content = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop
$isTemplate = [bool]$Template
$config = Read-JsonHashtable -JsonPath $ConfigPath

Write-Host "Validating: $resolvedPath"
Write-Host "Mode: $(if ($isTemplate) { 'Template' } else { 'Generated' })"

if ($isTemplate) {
    if ($content -match '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        Add-ValidationResult -Status Pass -Check 'Template password placeholder' -Message 'OSIT password placeholder is present.'
    } else {
        Add-ValidationResult -Status Fail -Check 'Template password placeholder' -Message 'Template should contain __OSIT_LOCAL_ADMIN_PASSWORD__.'
    }

    if ($content -match '__WINDOWS_PE_SETTINGS__') {
        Add-ValidationResult -Status Pass -Check 'Template windowsPE placeholder' -Message 'windowsPE placeholder is present for config-driven partitioning.'
    } else {
        Add-ValidationResult -Status Warn -Check 'Template windowsPE placeholder' -Message 'windowsPE placeholder is absent; generated partitioning block cannot be inserted by Initialize-UsbDeployment.ps1.'
    }
} else {
    if ($content -match '__OSIT_LOCAL_ADMIN_PASSWORD__|__WINDOWS_PE_SETTINGS__') {
        Add-ValidationResult -Status Fail -Check 'Generated placeholders' -Message 'Generated Autounattend.xml must not contain toolkit placeholders.'
    } else {
        Add-ValidationResult -Status Pass -Check 'Generated placeholders' -Message 'No toolkit placeholders found.'
    }
}

$validationContent = ConvertTo-ValidationXml -Content $content -IsTemplate:$isTemplate
$tempValidationFile = Join-Path $env:TEMP ("autounattend-validation-{0}.xml" -f [guid]::NewGuid().ToString('N'))
Set-Content -LiteralPath $tempValidationFile -Value $validationContent -Encoding UTF8 -Force

try {
    try {
        [xml]$xml = $validationContent
        Add-ValidationResult -Status Pass -Check 'XML well-formed' -Message 'XML parsed successfully after template placeholder normalization.'
    } catch {
        Add-ValidationResult -Status Fail -Check 'XML well-formed' -Message $_.Exception.Message
        throw
    }

    $ns = Get-UnattendNamespaceManager -Xml $xml
    $rootName = $xml.DocumentElement.LocalName
    $rootNs = $xml.DocumentElement.NamespaceURI
    if ($rootName -eq 'unattend' -and $rootNs -eq 'urn:schemas-microsoft-com:unattend') {
        Add-ValidationResult -Status Pass -Check 'Root element' -Message 'Root element is unattend with the expected namespace.'
    } else {
        Add-ValidationResult -Status Fail -Check 'Root element' -Message "Unexpected root element '$rootName' namespace '$rootNs'."
    }

    Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'OSIT local account' -XPath '//u:LocalAccount/u:Name' -Expected 'OSIT'
    Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'OSIT AutoLogon' -XPath '//u:AutoLogon/u:Username' -Expected 'OSIT'

    $localPassword = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:LocalAccount/u:Password/u:Value'
    $autologonPassword = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:AutoLogon/u:Password/u:Value'
    if (-not [string]::IsNullOrWhiteSpace($localPassword) -and $localPassword -eq $autologonPassword) {
        Add-ValidationResult -Status Pass -Check 'OSIT password consistency' -Message 'Local account and AutoLogon password values match.'
    } else {
        Add-ValidationResult -Status Fail -Check 'OSIT password consistency' -Message 'Local account and AutoLogon password values are missing or do not match.'
    }

    $specializeCommands = @($xml.SelectNodes('//u:settings[@pass="specialize"]//u:RunSynchronousCommand/u:Path', $ns) | ForEach-Object { $_.InnerText })
    if ($specializeCommands -match 'BypassNRO') {
        Add-ValidationResult -Status Pass -Check 'BypassNRO' -Message 'BypassNRO registry command is present.'
    } else {
        Add-ValidationResult -Status Fail -Check 'BypassNRO' -Message 'BypassNRO registry command was not found in specialize pass.'
    }

    $firstLogonCommand = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine'
    if ($firstLogonCommand -match '1S-WIN11' -and $firstLogonCommand -match 'Start-Deployment\.ps1') {
        Add-ValidationResult -Status Pass -Check 'FirstLogon deployment command' -Message 'FirstLogon command locates the USB label and starts Start-Deployment.ps1.'
    } else {
        Add-ValidationResult -Status Fail -Check 'FirstLogon deployment command' -Message 'FirstLogon command does not contain both USB label 1S-WIN11 and Start-Deployment.ps1.'
    }

    $windowsPeSettings = @($xml.SelectNodes('//u:settings[@pass="windowsPE"]', $ns))
    if ($windowsPeSettings.Count -gt 0) {
        Add-ValidationResult -Status Pass -Check 'windowsPE pass' -Message 'windowsPE pass is present.'
        Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'Windows install disk' -XPath '//u:ImageInstall/u:OSImage/u:InstallTo/u:DiskID' -Expected '0'
        Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'Windows install partition' -XPath '//u:ImageInstall/u:OSImage/u:InstallTo/u:PartitionID' -Expected '3'

        $runSync = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:settings[@pass="windowsPE"]//u:RunSynchronousCommand/u:Path'
        foreach ($fragment in @('clean', 'convert gpt', 'create partition efi size=512', 'create partition msr size=16', 'shrink desired=2048 minimum=2048', 'set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"', 'gpt attributes=0x8000000000000001')) {
            if ($runSync -match [regex]::Escape($fragment)) {
                Add-ValidationResult -Status Pass -Check "Partition command: $fragment" -Message 'Expected partition command fragment found.'
            } else {
                Add-ValidationResult -Status Fail -Check "Partition command: $fragment" -Message 'Expected partition command fragment missing.'
            }
        }
    } elseif ($config -and $config.wipe_repartition_drive -eq $true -and -not $isTemplate) {
        Add-ValidationResult -Status Fail -Check 'windowsPE pass' -Message 'Config expects wipe_repartition_drive=true, but generated XML has no windowsPE pass.'
    } else {
        Add-ValidationResult -Status Warn -Check 'windowsPE pass' -Message 'windowsPE pass is absent. This is expected for the repository template or technician-led disk selection.'
    }

    if (-not $DllPath) { $DllPath = Find-UnattendSchemaDll }
    if ($DllPath -and (Test-Path -LiteralPath $DllPath -PathType Leaf)) {
        try {
            $schemaText = Get-Schema -Path (Resolve-Path -LiteralPath $DllPath).Path
            $schemaErrors = @(Test-XmlSchema -XmlPath $tempValidationFile -SchemaText $schemaText)
            if ($schemaErrors.Count -eq 0) {
                Add-ValidationResult -Status Pass -Check 'ADK schema validation' -Message "Schema validation passed using $DllPath."
            } else {
                foreach ($schemaError in $schemaErrors) {
                    Add-ValidationResult -Status Fail -Check 'ADK schema validation' -Message $schemaError
                }
            }
        } catch {
            Add-ValidationResult -Status Fail -Check 'ADK schema validation' -Message $_.Exception.Message
        }
    } elseif ($RequireSchema) {
        Add-ValidationResult -Status Fail -Check 'ADK schema validation' -Message 'Schema DLL was not found and -RequireSchema was specified.'
    } else {
        Add-ValidationResult -Status Warn -Check 'ADK schema validation' -Message 'Schema DLL not found. Install Windows ADK or pass -DllPath for full schema validation.'
    }
} finally {
    Remove-Item -LiteralPath $tempValidationFile -Force -ErrorAction SilentlyContinue
}

$failures = @($script:ValidationResults | Where-Object { $_.status -eq 'Fail' })
Write-Host ''
Write-Host ("Validation complete: {0} pass, {1} warning, {2} failure" -f `
        @($script:ValidationResults | Where-Object { $_.status -eq 'Pass' }).Count, `
        @($script:ValidationResults | Where-Object { $_.status -eq 'Warn' }).Count, `
        $failures.Count)

if ($failures.Count -gt 0) {
    exit 1
}

exit 0
