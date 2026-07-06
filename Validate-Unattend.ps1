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

        In -Ci mode, this script additionally regenerates Autounattend.xml/OSIT-DiskPart.txt into a
        temp folder using the exact same generation logic Initialize-UsbDeployment.ps1 uses (shared
        via Deployment\Scripts\UnattendGeneration.ps1) against Deployment\Config\deployment_config.json,
        then validates that pair too - so CI checks what production would actually write to a USB,
        not just the repository template.

    .PARAMETER Path
        Path to Autounattend.xml. Defaults to .\Autounattend.xml beside this script.

    .PARAMETER ConfigPath
        Path to deployment_config.json. Used for expectation checks such as wipe_repartition_drive,
        and (in -Ci mode) as the config the generated-file check generates from.

    .PARAMETER DllPath
        Optional explicit path to Microsoft.ComponentStudio.ComponentPlatformInterface.dll.

    .PARAMETER RequireSchema
        Fail validation if ADK/AIK schema validation cannot be performed.

    .PARAMETER InstallAdkWithWinget
        If the schema DLL cannot be found, install Microsoft.WindowsADK and
        Microsoft.WindowsADK.WinPEAddon with winget, then search for the schema DLL again.

    .PARAMETER Generated
        Treat Path as a generated USB-root Autounattend.xml. Generated files should not contain toolkit placeholders.

    .PARAMETER Template
        Treat Path as the repository template. Template files should contain toolkit placeholders. This is the default.

    .PARAMETER Ci
        Run in CI mode: never prompts; treats a missing ADK schema DLL as an expected/normal
        condition (logged as Skipped rather than Warn) instead of a warning; and additionally
        generates Autounattend.xml/OSIT-DiskPart.txt from Deployment\Config\deployment_config.json
        (or -ConfigPath, if given) into a temp folder and validates that generated pair in the same
        invocation. Exit code contract is unchanged: any Fail-status finding across either check
        makes the script exit non-zero.

    .EXAMPLE
        .\Validate-Unattend.ps1

    .EXAMPLE
        .\Validate-Unattend.ps1 -Path E:\Autounattend.xml -Generated

    .EXAMPLE
        .\Validate-Unattend.ps1 -Ci

    .NOTES
        Schema extraction functions are based on:
        https://gist.github.com/davidwallis3101/48454cb6c17c988de43b5ea17089ea6f
        and the unattend schema notes at:
        http://schneegans.de/computer/unattend-schema/
#>

[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive technician/CI console validator; colored pass/warn/fail output (Add-ValidationResult) is the primary reporting mechanism, alongside the process exit code.')]
[CmdletBinding()]
param(
    [string]$Path,
    [string]$ConfigPath,
    [string]$DllPath,
    [switch]$RequireSchema,
    [switch]$InstallAdkWithWinget,
    [switch]$Generated,
    [switch]$Template,
    [switch]$Ci
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# $PSScriptRoot can be empty during param default evaluation when invoked with powershell -File,
# so the path defaults are resolved here instead of in the param block.
$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $scriptRoot 'Autounattend.xml' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $scriptRoot 'Deployment\Config\deployment_config.json' }

if (-not $Generated -and -not $Template) { $Template = $true }
if ($Generated -and $Template) { throw 'Use only one of -Generated or -Template.' }

# Shared with Initialize-UsbDeployment.ps1 so -Ci validates the exact code path that writes a USB,
# not a re-implementation of it. Dot-sourcing only defines functions/script-scope variables here
# (no side effects), so it is safe to load unconditionally even when -Ci is not used.
. (Join-Path $scriptRoot 'Deployment\Scripts\Common.ps1')
. (Join-Path $scriptRoot 'Deployment\Scripts\UnattendGeneration.ps1')

$script:ValidationResults = New-Object 'System.Collections.Generic.List[object]'

function Add-ValidationResult {
    param(
        [ValidateSet('Pass', 'Warn', 'Fail', 'Skipped')][string]$Status,
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
        'Skipped' { 'Cyan' }
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

function Get-UnattendSchemaDllCandidates {
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

    $preferredArchitecture = if ([Environment]::Is64BitProcess) { 'amd64' } else { 'x86' }
    $candidateMatches = @()
    foreach ($root in $roots) {
        foreach ($name in $candidateNames) {
            $candidateMatches += @(Get-ChildItem -LiteralPath $root -Filter $name -Recurse -File -ErrorAction SilentlyContinue)
        }
    }

    $ordered = @()
    $ordered += @($candidateMatches |
        Where-Object { $_.FullName -match "\\WSIM\\$([regex]::Escape($preferredArchitecture))\\" } |
        Sort-Object FullName -Descending)

    $ordered += @($candidateMatches |
        Where-Object { $_.FullName -notmatch '\\WSIM\\arm64\\' } |
        Sort-Object FullName -Descending)

    $ordered += @($candidateMatches | Sort-Object FullName -Descending)

    return @($ordered | Select-Object -ExpandProperty FullName -Unique)
}

function Find-UnattendSchemaDll {
    return @(Get-UnattendSchemaDllCandidates | Select-Object -First 1)[0]
}

function Get-CompatibleUnattendSchema {
    param([string[]]$CandidatePaths)

    $attempted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidatePath in @($CandidatePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }

        $resolvedCandidate = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
        $attempted.Add($resolvedCandidate) | Out-Null
        try {
            $schemaText = Get-Schema -Path $resolvedCandidate
            return [ordered]@{
                path = $resolvedCandidate
                text = $schemaText
            }
        }
        catch [System.BadImageFormatException] {
            Add-ValidationResult -Status Warn -Check 'ADK schema DLL architecture' -Message "Skipping incompatible schema DLL for this PowerShell process: $resolvedCandidate"
            continue
        }
        catch {
            if ($_.Exception.Message -match 'architecture is not compatible') {
                Add-ValidationResult -Status Warn -Check 'ADK schema DLL architecture' -Message "Skipping incompatible schema DLL for this PowerShell process: $resolvedCandidate"
                continue
            }
            Add-ValidationResult -Status Warn -Check 'ADK schema DLL load' -Message "Skipping schema DLL after load failure: $resolvedCandidate - $($_.Exception.Message)"
            continue
        }
    }

    if ($attempted.Count -gt 0) {
        throw "No compatible ADK schema DLL could be loaded by this PowerShell process. Attempted: $($attempted -join '; ')"
    }

    return $null
}

function Get-WingetCommand {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidate = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending |
    Select-Object -First 1
    if ($candidate) { return $candidate.FullName }

    return $null
}

function Get-ScriptTempPath {
    # $env:TEMP is a Windows-only convention; [System.IO.Path]::GetTempPath() resolves correctly
    # on both Windows PowerShell 5.1 and pwsh 7 on Linux/macOS, which keeps this script usable in
    # CI runners regardless of OS.
    return [System.IO.Path]::GetTempPath()
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0)
    )

    $tempBase = Join-Path (Get-ScriptTempPath) ([guid]::NewGuid().ToString('N'))
    $stdoutPath = "$tempBase.out"
    $stderrPath = "$tempBase.err"

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    $result = [ordered]@{
        exit_code = $process.ExitCode
        stdout    = $stdout
        stderr    = $stderr
    }

    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath $($Arguments -join ' ')`n$stderr"
    }

    return $result
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    # winget list exits with NO_APPLICATIONS_FOUND (0x8A150014 = -1978335212) when absent.
    $result = Invoke-ProcessCapture -FilePath $WingetPath -Arguments @('list', '--id', $PackageId, '--exact', '--accept-source-agreements') -AllowedExitCodes @(0, 1, -1978335212)
    return ($result.exit_code -eq 0)
}

function Install-AdkPackagesWithWinget {
    $winget = Get-WingetCommand
    if (-not $winget) {
        throw 'winget.exe was not found. Install App Installer or install Windows ADK manually.'
    }

    foreach ($packageId in @('Microsoft.WindowsADK', 'Microsoft.WindowsADK.WinPEAddon')) {
        if (Test-WingetPackageInstalled -WingetPath $winget -PackageId $packageId) {
            Add-ValidationResult -Status Pass -Check "winget package $packageId" -Message 'Package already appears to be installed.'
            continue
        }

        Add-ValidationResult -Status Warn -Check "winget package $packageId" -Message 'Package not detected; installing with winget. This can take several minutes.'
        Invoke-ProcessCapture -FilePath $winget -Arguments @(
            'install',
            '--id', $packageId,
            '--exact',
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--disable-interactivity'
        ) -AllowedExitCodes @(0, 3010) | Out-Null
        Add-ValidationResult -Status Pass -Check "winget package $packageId" -Message 'winget install completed.'
    }
}

function Test-XmlSchema {
    [Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'schemaEventSender', Justification = 'System.Xml.Schema.ValidationEventHandler''s delegate signature requires (sender, args); the sender parameter is unused by design.')]
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory = $true)][string]$XmlPath,
        [Parameter(Mandatory = $true)][string]$SchemaText
    )

    $validationErrors = New-Object 'System.Collections.Generic.List[string]'
    $handler = [System.Xml.Schema.ValidationEventHandler] {
        param($schemaEventSender, $schemaValidationEventArgs)
        $validationErrors.Add($schemaValidationEventArgs.Exception.Message) | Out-Null
    }

    $schemaReader = New-Object System.IO.StringReader($SchemaText)
    try {
        $schema = [System.Xml.Schema.XmlSchema]::Read($schemaReader, $handler)
        $xml = New-Object System.Xml.XmlDocument
        $xml.Schemas.Add($schema) | Out-Null
        $xml.Load($XmlPath)
        $xml.Validate($handler)
    }
    finally {
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

function Get-ConfigProperty {
    param(
        [object]$Config,
        [string]$Name,
        [object]$Default
    )

    if ($Config -and $Config.PSObject.Properties[$Name] -and $null -ne $Config.$Name) { return $Config.$Name }
    return $Default
}

function Get-UnattendNamespaceManager {
    param([xml]$Xml)

    $ns = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend') | Out-Null
    Write-Output -InputObject $ns -NoEnumerate
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
    }
    else {
        Add-ValidationResult -Status Fail -Check $Check -Message "Expected '$Expected' but found '$actual'." -Data @{ xpath = $XPath; actual = $actual; expected = $Expected }
    }
}

function Invoke-UnattendValidation {
    <#
        .SYNOPSIS
            Runs the full set of Autounattend.xml checks against one file and appends results to
            $script:ValidationResults. Factored out of top-level script code so -Ci can run it
            twice in a single invocation: once for the template/-Path check, and once more for the
            generated Autounattend.xml/OSIT-DiskPart.txt pair written to a temp folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ValidationPath,
        [string]$ValidationConfigPath,
        [string]$SchemaDllPath,
        [switch]$RequireAdkSchema,
        [switch]$InstallAdkSchemaWithWinget,
        [switch]$IsGenerated,
        [switch]$IsTemplateSwitch,
        [switch]$CiMode
    )

    if (-not $IsGenerated -and -not $IsTemplateSwitch) { $IsTemplateSwitch = $true }
    if ($IsGenerated -and $IsTemplateSwitch) { throw 'Use only one of -IsGenerated or -IsTemplateSwitch.' }

    $resolvedPath = (Resolve-Path -LiteralPath $ValidationPath -ErrorAction Stop).Path
    $content = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop
    $isTemplate = [bool]$IsTemplateSwitch
    $config = Read-JsonHashtable -JsonPath $ValidationConfigPath

    Write-Host "Validating: $resolvedPath"
    Write-Host "Mode: $(if ($isTemplate) { 'Template' } else { 'Generated' })"

    if ($isTemplate) {
        if ($content -match '__OSIT_LOCAL_ADMIN_PASSWORD__') {
            Add-ValidationResult -Status Pass -Check 'Template password placeholder' -Message 'OSIT password placeholder is present.'
        }
        else {
            Add-ValidationResult -Status Fail -Check 'Template password placeholder' -Message 'Template should contain __OSIT_LOCAL_ADMIN_PASSWORD__.'
        }

        if ($content -match '__WINDOWS_PE_SETTINGS__') {
            Add-ValidationResult -Status Pass -Check 'Template windowsPE placeholder' -Message 'windowsPE placeholder is present for config-driven partitioning.'
        }
        else {
            Add-ValidationResult -Status Warn -Check 'Template windowsPE placeholder' -Message 'windowsPE placeholder is absent; generated partitioning block cannot be inserted by Initialize-UsbDeployment.ps1.'
        }
    }
    else {
        if ($content -match '__OSIT_LOCAL_ADMIN_PASSWORD__|__WINDOWS_PE_SETTINGS__') {
            Add-ValidationResult -Status Fail -Check 'Generated placeholders' -Message 'Generated Autounattend.xml must not contain toolkit placeholders.'
        }
        else {
            Add-ValidationResult -Status Pass -Check 'Generated placeholders' -Message 'No toolkit placeholders found.'
        }
    }

    $validationContent = ConvertTo-ValidationXml -Content $content -IsTemplate:$isTemplate
    $tempValidationFile = Join-Path (Get-ScriptTempPath) ("autounattend-validation-{0}.xml" -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $tempValidationFile -Value $validationContent -Encoding UTF8 -Force

    try {
        try {
            [xml]$xml = $validationContent
            Add-ValidationResult -Status Pass -Check 'XML well-formed' -Message 'XML parsed successfully after template placeholder normalization.'
        }
        catch {
            Add-ValidationResult -Status Fail -Check 'XML well-formed' -Message $_.Exception.Message
            throw
        }

        $ns = Get-UnattendNamespaceManager -Xml $xml
        $rootName = $xml.DocumentElement.LocalName
        $rootNs = $xml.DocumentElement.NamespaceURI
        if ($rootName -eq 'unattend' -and $rootNs -eq 'urn:schemas-microsoft-com:unattend') {
            Add-ValidationResult -Status Pass -Check 'Root element' -Message 'Root element is unattend with the expected namespace.'
        }
        else {
            Add-ValidationResult -Status Fail -Check 'Root element' -Message "Unexpected root element '$rootName' namespace '$rootNs'."
        }

        Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'OSIT local account' -XPath '//u:LocalAccount/u:Name' -Expected 'OSIT'
        Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'OSIT AutoLogon' -XPath '//u:AutoLogon/u:Username' -Expected 'OSIT'

        $localPassword = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:LocalAccount/u:Password/u:Value'
        $autologonPassword = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:AutoLogon/u:Password/u:Value'
        if (-not [string]::IsNullOrWhiteSpace($localPassword) -and $localPassword -eq $autologonPassword) {
            Add-ValidationResult -Status Pass -Check 'OSIT password consistency' -Message 'Local account and AutoLogon password values match.'
        }
        else {
            Add-ValidationResult -Status Fail -Check 'OSIT password consistency' -Message 'Local account and AutoLogon password values are missing or do not match.'
        }

        $specializeCommands = @($xml.SelectNodes('//u:settings[@pass="specialize"]//u:RunSynchronousCommand/u:Path', $ns) | ForEach-Object { $_.InnerText })
        if ($specializeCommands -match 'BypassNRO') {
            Add-ValidationResult -Status Pass -Check 'BypassNRO' -Message 'BypassNRO registry command is present.'
        }
        else {
            Add-ValidationResult -Status Fail -Check 'BypassNRO' -Message 'BypassNRO registry command was not found in specialize pass.'
        }

        $firstLogonCommand = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine'
        if ($firstLogonCommand -match '1S-WIN11' -and $firstLogonCommand -match 'Start-Deployment\.ps1') {
            Add-ValidationResult -Status Pass -Check 'FirstLogon deployment command' -Message 'FirstLogon command locates the USB label and starts Start-Deployment.ps1.'
        }
        else {
            Add-ValidationResult -Status Fail -Check 'FirstLogon deployment command' -Message 'FirstLogon command does not contain both USB label 1S-WIN11 and Start-Deployment.ps1.'
        }

        $windowsPeSettings = @($xml.SelectNodes('//u:settings[@pass="windowsPE"]', $ns))
        if ($windowsPeSettings.Count -gt 0) {
            Add-ValidationResult -Status Pass -Check 'windowsPE pass' -Message 'windowsPE pass is present.'
            $expectedDiskId = [string](Get-ConfigProperty -Config $config -Name 'wipe_repartition_disk_id' -Default 0)
            Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'Windows install disk' -XPath '//u:ImageInstall/u:OSImage/u:InstallTo/u:DiskID' -Expected $expectedDiskId
            Test-ExpectedText -Xml $xml -NamespaceManager $ns -Check 'Windows install partition' -XPath '//u:ImageInstall/u:OSImage/u:InstallTo/u:PartitionID' -Expected '3'

            $runSync = Get-NodeText -Xml $xml -NamespaceManager $ns -XPath '//u:settings[@pass="windowsPE"]//u:RunSynchronousCommand/u:Path'
            if ($runSync -and $runSync.Length -le 259) {
                Add-ValidationResult -Status Pass -Check 'windowsPE command length' -Message "RunSynchronous command is $($runSync.Length) characters (limit 259)."
            }
            else {
                $actualLength = if ($runSync) { $runSync.Length } else { 0 }
                Add-ValidationResult -Status Fail -Check 'windowsPE command length' -Message "RunSynchronous command is $actualLength characters; the unattend Path limit is 259 and Windows Setup fails with 0x80004005 - 0x40030 when it is exceeded."
            }

            if ($runSync -match 'OSIT-DiskPart\.txt' -and $runSync -match 'diskpart\s+/s') {
                Add-ValidationResult -Status Pass -Check 'DiskPart script reference' -Message 'RunSynchronous command locates USB-root OSIT-DiskPart.txt and runs diskpart /s against it.'
            }
            else {
                Add-ValidationResult -Status Fail -Check 'DiskPart script reference' -Message 'RunSynchronous command does not reference USB-root OSIT-DiskPart.txt with diskpart /s.'
            }

            $diskPartScriptPath = Join-Path (Split-Path -Parent $resolvedPath) $script:DiskPartScriptFileName
            if (Test-Path -LiteralPath $diskPartScriptPath -PathType Leaf) {
                Add-ValidationResult -Status Pass -Check 'DiskPart script file' -Message "Companion diskpart script found: $diskPartScriptPath"
                $diskPartContent = Get-Content -LiteralPath $diskPartScriptPath -Raw

                $efiSize = [int](Get-ConfigProperty -Config $config -Name 'efi_partition_size_mb' -Default 512)
                $msrSize = [int](Get-ConfigProperty -Config $config -Name 'msr_partition_size_mb' -Default 16)
                $recoverySize = [int](Get-ConfigProperty -Config $config -Name 'recovery_partition_size_mb' -Default 2048)
                foreach ($fragment in @("select disk $expectedDiskId", 'clean', 'convert gpt', "create partition efi size=$efiSize", "create partition msr size=$msrSize", "shrink desired=$recoverySize minimum=$recoverySize", 'set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac', 'gpt attributes=0x8000000000000001')) {
                    if ($diskPartContent -match [regex]::Escape($fragment)) {
                        Add-ValidationResult -Status Pass -Check "Partition command: $fragment" -Message 'Expected partition command fragment found.'
                    }
                    else {
                        Add-ValidationResult -Status Fail -Check "Partition command: $fragment" -Message 'Expected partition command fragment missing from OSIT-DiskPart.txt.'
                    }
                }

                if ($diskPartContent -match '(?im)^\s*assign\s+letter=C\b') {
                    Add-ValidationResult -Status Fail -Check 'DiskPart drive letters' -Message 'Script assigns letter C, which WinPE often gives to the USB stick on a blank disk; a failed assign aborts the rest of the diskpart script.'
                }
                else {
                    Add-ValidationResult -Status Pass -Check 'DiskPart drive letters' -Message 'Script avoids assigning drive letter C during WinPE.'
                }

                if ($diskPartContent -match 'label="' -or $diskPartContent -match 'letter="' -or $diskPartContent -match 'set id="') {
                    Add-ValidationResult -Status Fail -Check 'Partition command quoting' -Message 'DiskPart script contains quoted label, drive letter, or GUID values that diskpart /s does not require.'
                }
                else {
                    Add-ValidationResult -Status Pass -Check 'Partition command quoting' -Message 'DiskPart script avoids unnecessary quoted values.'
                }
            }
            else {
                Add-ValidationResult -Status Fail -Check 'DiskPart script file' -Message "windowsPE pass expects $script:DiskPartScriptFileName beside the answer file, but it was not found: $diskPartScriptPath"
            }
        }
        elseif ($config -and $config.wipe_repartition_drive -eq $true -and -not $isTemplate) {
            Add-ValidationResult -Status Fail -Check 'windowsPE pass' -Message 'Config expects wipe_repartition_drive=true, but generated XML has no windowsPE pass.'
        }
        else {
            Add-ValidationResult -Status Warn -Check 'windowsPE pass' -Message 'windowsPE pass is absent. This is expected for the repository template or technician-led disk selection.'
        }

        $schemaDllCandidates = @()
        if ($SchemaDllPath) {
            $schemaDllCandidates += $SchemaDllPath
        }
        else {
            $schemaDllCandidates += @(Get-UnattendSchemaDllCandidates)
        }

        if ($schemaDllCandidates.Count -eq 0 -and $InstallAdkSchemaWithWinget) {
            try {
                Install-AdkPackagesWithWinget
                $schemaDllCandidates += @(Get-UnattendSchemaDllCandidates)
            }
            catch {
                Add-ValidationResult -Status Fail -Check 'ADK winget install' -Message $_.Exception.Message
            }
        }

        if ($SchemaDllPath) {
            $schemaDllCandidates += @(Get-UnattendSchemaDllCandidates)
            $schemaDllCandidates = @($schemaDllCandidates | Select-Object -Unique)
        }

        if ($schemaDllCandidates.Count -gt 0) {
            try {
                $schema = Get-CompatibleUnattendSchema -CandidatePaths $schemaDllCandidates
                if (-not $schema) { throw 'No compatible ADK schema DLL was found.' }

                $schemaErrors = @(Test-XmlSchema -XmlPath $tempValidationFile -SchemaText $schema.text)
                if ($schemaErrors.Count -eq 0) {
                    Add-ValidationResult -Status Pass -Check 'ADK schema validation' -Message "Schema validation passed using $($schema.path)."
                }
                else {
                    foreach ($schemaError in $schemaErrors) {
                        Add-ValidationResult -Status Fail -Check 'ADK schema validation' -Message $schemaError
                    }
                }
            }
            catch {
                Add-ValidationResult -Status Fail -Check 'ADK schema validation' -Message $_.Exception.Message
            }
        }
        elseif ($RequireAdkSchema) {
            Add-ValidationResult -Status Fail -Check 'ADK schema validation' -Message 'Schema DLL was not found and -RequireSchema was specified.'
        }
        elseif ($CiMode) {
            # No ADK/AIK install is expected on a CI runner, so this is a normal, expected
            # condition rather than something that should show up as a warning wall on every run.
            Add-ValidationResult -Status Skipped -Check 'ADK schema validation' -Message 'Schema DLL not found; skipped in -Ci mode (no ADK is expected on CI runners). This is expected and not a problem.'
        }
        else {
            Add-ValidationResult -Status Warn -Check 'ADK schema validation' -Message 'Schema DLL not found. Install Windows ADK or pass -DllPath for full schema validation.'
        }
    }
    finally {
        Remove-Item -LiteralPath $tempValidationFile -Force -ErrorAction SilentlyContinue
    }
}

function New-CiGeneratedUnattendArtifacts {
    <#
        .SYNOPSIS
            For -Ci mode: generates Autounattend.xml/OSIT-DiskPart.txt into a fresh temp folder
            using the shared UnattendGeneration.ps1 logic and the resolved deployment config, so
            -Ci validates what Initialize-UsbDeployment.ps1 would actually write to a USB.

        .DESCRIPTION
            Never prompts: the OSIT password is resolved only from environment variables or a .env
            file beside this script (Get-OsitLocalAdminPassword), the same non-interactive lookup
            Initialize-UsbDeployment.ps1 tries first. If no password is available, this throws so
            the caller can record it as a Fail finding instead of hanging on a prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$SourceConfigPath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $SourceConfigPath -PathType Leaf)) {
        throw "Config file for generated-file validation was not found: $SourceConfigPath"
    }

    $configOverride = Read-JsonFile -Path $SourceConfigPath -Required
    $resolvedConfig = Merge-Config -Base (Get-DefaultDeploymentConfig) -Override $configOverride

    $ositPassword = Get-OsitLocalAdminPassword -SearchRoots @($scriptRoot)
    if ([string]::IsNullOrWhiteSpace($ositPassword)) {
        throw 'OSIT_LOCAL_ADMIN_PASSWORD was not found in the environment or a .env file beside this script. -Ci never prompts, so set it before running -Ci (a throwaway value is fine for validation).'
    }

    $generated = New-GeneratedUnattendContent -TemplatePath $TemplatePath -Config $resolvedConfig -Password $ositPassword

    New-Item -ItemType Directory -Path $DestinationDirectory -Force -ErrorAction Stop | Out-Null
    $generatedAutounattendPath = Join-Path $DestinationDirectory 'Autounattend.xml'
    Set-Content -LiteralPath $generatedAutounattendPath -Value $generated.AutounattendContent -Encoding UTF8 -Force -ErrorAction Stop

    if ($null -ne $generated.DiskPartScript) {
        $generatedDiskPartPath = Join-Path $DestinationDirectory $script:DiskPartScriptFileName
        # ASCII avoids a UTF-8 BOM, which diskpart /s misreads as part of the first command -
        # matching exactly how Initialize-UsbDeployment.ps1 writes this file.
        Set-Content -LiteralPath $generatedDiskPartPath -Value $generated.DiskPartScript -Encoding ASCII -Force -ErrorAction Stop
    }

    return $generatedAutounattendPath
}

Invoke-UnattendValidation -ValidationPath $Path -ValidationConfigPath $ConfigPath -SchemaDllPath $DllPath `
    -RequireAdkSchema:$RequireSchema -InstallAdkSchemaWithWinget:$InstallAdkWithWinget `
    -IsGenerated:$Generated -IsTemplateSwitch:$Template -CiMode:$Ci

if ($Ci) {
    Write-Host ''
    Write-Host '-Ci: additionally validating the generated Autounattend.xml/OSIT-DiskPart.txt from Deployment\Config\deployment_config.json...' -ForegroundColor Cyan

    $ciTempDir = Join-Path (Get-ScriptTempPath) ("validate-unattend-ci-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        $sourceAutounattendTemplate = Join-Path $scriptRoot 'Autounattend.xml'
        try {
            $generatedAutounattendPath = New-CiGeneratedUnattendArtifacts -TemplatePath $sourceAutounattendTemplate -SourceConfigPath $ConfigPath -DestinationDirectory $ciTempDir

            Invoke-UnattendValidation -ValidationPath $generatedAutounattendPath -ValidationConfigPath $ConfigPath -SchemaDllPath $DllPath `
                -RequireAdkSchema:$RequireSchema -InstallAdkSchemaWithWinget:$InstallAdkWithWinget `
                -IsGenerated -CiMode:$Ci
        }
        catch {
            Add-ValidationResult -Status Fail -Check 'Generated Autounattend.xml (Ci)' -Message "Could not generate or validate the CI answer file: $($_.Exception.Message)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $ciTempDir -PathType Container) {
            Remove-Item -LiteralPath $ciTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$failures = @($script:ValidationResults | Where-Object { $_.status -eq 'Fail' })
Write-Host ''
Write-Host ("Validation complete: {0} pass, {1} warning, {2} skipped, {3} failure" -f `
    @($script:ValidationResults | Where-Object { $_.status -eq 'Pass' }).Count, `
    @($script:ValidationResults | Where-Object { $_.status -eq 'Warn' }).Count, `
    @($script:ValidationResults | Where-Object { $_.status -eq 'Skipped' }).Count, `
        $failures.Count)

if ($failures.Count -gt 0) {
    exit 1
}

exit 0
