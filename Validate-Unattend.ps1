<#
    .SYNOPSIS
        Test-Unattend.ps1

    .DESCRIPTION
        Test-Unattend.ps1

    .NOTES
        For additonal information please contact david.wallis@transunion.co.uk

    .LINK
        https://gist.github.com/davidwallis3101/48454cb6c17c988de43b5ea17089ea6f
#>

Function Get-Schema {
    <#
        .SYNOPSIS
            Get-Schema

        .DESCRIPTION
            Get-Schema

        .PARAMETER Path
            The path to the DLL to extract the schema from

        .EXAMPLE
            PS C:\> Get-Schema -Path "C:\binaries\microsoft.componentstudio.componentplatforminterface.dll"

        .NOTES
            Based on infomation found via the link below
            For additonal information please contact david.wallis@transunion.co.uk

        .LINK
            http://schneegans.de/computer/unattend-schema/
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $assembly = [Reflection.Assembly]::LoadFile($Path)

    $resNames = $assembly.GetManifestResourceNames()
    $resname = $resNames[0].Replace(".resources", "")

    $resMan = New-Object -TypeName System.Resources.ResourceManager -ArgumentList $resname, $assembly

    $language = New-Object System.Globalization.CultureInfo -ArgumentList "en-GB"
    $resources = $resMan.GetResourceSet($language, $true, $true)

    foreach ($obj in $resources) {
        if ($obj.Name -NotLike "Unattend") { continue }
        [System.Text.Encoding]::ASCII.GetString($obj.Value)
    }
}

Function Test-Xml {
    <#
        .SYNOPSIS
            Test-Xml

        .DESCRIPTION
            Validates an xml file against an xml schema file.

        .PARAMETER SchemaFile
            The schema file to use for validation

        .PARAMETER Schema
            The schema to use for validation when stored as a string

        .PARAMETER XmlFile
            The xml file to validate

        .PARAMETER ValidationEventHandler
            Scriptblock to be executed when a validation error occurs

        .EXAMPLE
            PS C:\> dir *.xml | Test-XmlFile -SchemaFile schema.xsd

        .EXAMPLE
            PS C:\> dir *.xml | Test-XmlFile -Schema $schema

        .NOTES
            Based on answer from stackoverflow linked below
            For additonal information please contact david.wallis@transunion.co.uk

        .LINK
            https://stackoverflow.com/questions/822907/how-do-i-use-powershell-to-validate-xml-files-against-an-xsd/21283694
    #>

    [CmdletBinding(DefaultParameterSetName = 'File')]
    Param (
        [Parameter(Mandatory = $True, ParameterSetName = 'File' )]
        [ValidateScript({
            if(-Not ($_ | Test-Path) ){
                throw "File does not exist"
            }
            if(-Not ($_ | Test-Path -PathType Leaf) ){
                throw "The Path argument must be a file. Folder paths are not allowed."
            }
            return $true
        })]
        [System.IO.FileInfo] $SchemaFile,

        [Parameter(Mandatory = $True, ParameterSetName = 'String')]
        [string] $Schema,

        [Parameter(ValueFromPipeline=$true, Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [alias('Fullname')]
        [ValidateScript({
            if(-Not ($_ | Test-Path) ){
                throw "File does not exist"
            }
            if(-Not ($_ | Test-Path -PathType Leaf) ){
                throw "The Path argument must be a file. Folder paths are not allowed."
            }
            return $true
        })]
        [System.IO.FileInfo] $XmlFile,

        [scriptblock] $ValidationEventHandler = { Write-Error $args[1].Exception }
    )

    Begin {
        If ($PSCmdlet.ParameterSetName -eq "File") {
            $schemaFromFile = Get-Content $SchemaFile -Raw
            $schemaReader = New-Object System.IO.StringReader($schemaFromFile)
        } else {
            $schemaReader = New-Object System.IO.StringReader($Schema)
        }

        [System.Xml.Schema.XmlSchema]$schema = ([System.Xml.Schema.XmlSchema]::Read($schemaReader, $ValidationEventHandler))
    }

    Process {
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Schemas.Add($schema) | Out-Null
            $xml.Load($XmlFile.FullName)
            write-verbose "Validating XML Schema for file $($XmlFile)"
            $xml.Validate($ValidationEventHandler)

        } catch {
            Write-Error $_
        }
    }

    End {
        $schemaReader.Close()
    }
}

Function Test-Unattend {
    <#
        .SYNOPSIS
            Test-Unattend

        .DESCRIPTION
            Validates unattend.xml or autounattend.xml against the schema contained within the AIK dll

        .PARAMETER Path
            The path to the xml file

        .EXAMPLE
            PS C:\> Get-ChildItem -Path "C:\answer_files\" -Filter "*.xml" -Recurse |
                        Test-Unattend -DllPath "C:\binaries\microsoft.componentstudio.componentplatforminterface.dll"

        .NOTES
            For additonal information please contact david.wallis@transunion.co.uk
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeline = $true)]
        [Alias("Path")]
        [ValidateScript({
            if(-Not ($_ | Test-Path) ){
                throw "File does not exist"
            }
            if(-Not ($_ | Test-Path -PathType Leaf) ){
                throw "The Path argument must be a file. Folder paths are not allowed."
            }
            return $true
        })]
        [System.IO.FileInfo[]]$Files,

        [Parameter(Mandatory=$true)]
        [string]$DllPath
    )

    begin {
        write-verbose ("Extracting schema from {0} Version: {1}" -f (Split-Path $dllpath -Leaf), ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($dllpath).FileVersion))
        $schemaString = Get-Schema -Path $dllPath
    }
    process {
        Foreach ($xmlFile in $Files) {
            Test-Xml `
                -Schema $schemaString `
                -XmlFile $xmlFile.FullName `
                -ValidationEventHandler { Write-error "Unable to validate schema for $($xmlFile) $($args[1].Exception.Message)" }
        }
    }
}

Get-ChildItem -Path "C:\answer_files\" -Filter "*.xml" -Recurse |
    Test-Unattend -DllPath "C:\binaries\microsoft.componentstudio.componentplatforminterface.dll" -Verbose
