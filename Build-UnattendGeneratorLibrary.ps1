<#
    .SYNOPSIS
        Builds Schneegans' UnattendGenerator.dll (External\unattend-generator, a git submodule)
        so PowerShell 7+ generation-time tooling in this repo can load it.

    .DESCRIPTION
        External\unattend-generator is a .NET 8/9/10 class library, not something Windows
        PowerShell 5.1 can load (its own Example.ps1 says so directly). Everything under
        Deployment\Scripts\ must stay runnable on Windows PowerShell 5.1 per CLAUDE.md -- that
        constraint is about what a target notebook runs during deployment, not this repo's own
        generation-time tooling (Initialize-UsbDeployment.ps1, Validate-Unattend.ps1), so a
        PowerShell 7+-only build/consume step here does not violate it.

        `dotnet publish` (not `build`) is required: UnattendGenerator.csproj references
        Newtonsoft.Json, and only `publish` copies that dependency next to the library's own DLL.
        Without it, loading the DLL works until the first code path that touches JSON, which then
        throws a FileNotFoundException for Newtonsoft.Json.dll.

        Output lands in External\unattend-generator\publish\<TargetFramework>\ (gitignored --
        a local, reproducible build artifact, not something to commit). Consume it from
        PowerShell 7+ the same way External\unattend-generator\Example.ps1 does:

            using namespace Schneegans.Unattend;
            Import-Module -Name "External\unattend-generator\publish\net8.0\UnattendGenerator.dll";
            $generator = [UnattendGenerator]::new();

    .PARAMETER TargetFramework
        Which of the csproj's TargetFrameworks (net8.0, net9.0, net10.0) to publish. Defaults to
        net8.0, the lowest common denominator most likely to already be installed.

    .EXAMPLE
        .\Build-UnattendGeneratorLibrary.ps1

        Publishes net8.0 to External\unattend-generator\publish\net8.0\UnattendGenerator.dll.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Colored technician-facing progress banners at generation time, matching Initialize-UsbDeployment.ps1 and UnattendGeneration.ps1''s existing convention for this kind of interactive CLI tooling.')]
[CmdletBinding()]
param(
    [ValidateSet('net8.0', 'net9.0', 'net10.0')]
    [string]$TargetFramework = 'net8.0'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$projectPath = Join-Path $repoRoot 'External\unattend-generator\UnattendGenerator.csproj'
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "UnattendGenerator.csproj not found at $projectPath. Did you clone this repo with --recurse-submodules, or run 'git submodule update --init'?"
}

if (-not (Get-Command -Name dotnet -ErrorAction SilentlyContinue)) {
    throw 'dotnet CLI not found on PATH. Install a .NET SDK (8.0 or later) from https://dotnet.microsoft.com/download, matching one of UnattendGenerator.csproj''s TargetFrameworks.'
}

$outputDir = Join-Path $repoRoot "External\unattend-generator\publish\$TargetFramework"

Write-Host "Publishing UnattendGenerator ($TargetFramework) to $outputDir..." -ForegroundColor Cyan
dotnet publish $projectPath -c Release -f $TargetFramework -o $outputDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$dllPath = Join-Path $outputDir 'UnattendGenerator.dll'
if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
    throw "dotnet publish reported success but $dllPath does not exist."
}

Write-Host "Built: $dllPath" -ForegroundColor Green
return $dllPath
