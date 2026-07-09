<#
    .SYNOPSIS
        Installs/verifies the toolchain this repo's own tooling needs on a fresh Windows
        machine: PowerShell 7, git, the External\unattend-generator submodule content, a .NET
        SDK covering that submodule's TargetFrameworks, and the PSScriptAnalyzer/Pester
        PowerShell modules CLAUDE.md's documented commands assume are already present.

    .DESCRIPTION
        Deliberately written to also run under Windows PowerShell 5.1 (no PS7-only syntax),
        since a bare new machine may not have PowerShell 7 installed yet -- this script is what
        installs it.

        Scope: this is about the REPO'S OWN authoring/build/test tooling on a technician or
        developer workstation, not the target notebooks this toolkit deploys onto -- those only
        ever run Windows PowerShell 5.1, already built into Windows, and nothing here changes
        that (see CLAUDE.md's "Runtime constraint").

        What this always installs/checks (small, fast, needed for the documented CLAUDE.md
        commands and Build-UnattendGeneratorLibrary.ps1 to work at all):
          - winget itself (checked only; cannot be silently installed without it or an
            interactive Microsoft Store sign-in, so this just explains how)
          - PowerShell 7 (winget: Microsoft.PowerShell)
          - git submodule content for External\unattend-generator, if it looks uninitialised
          - a .NET SDK covering every TargetFramework UnattendGenerator.csproj lists, parsed
            from the csproj itself (so this does not need updating if that project's target
            frameworks change) -- this is exactly the gap that produces "No .NET SDKs were
            found" / exit code -2147450725 from Build-UnattendGeneratorLibrary.ps1 on a fresh
            machine
          - the NuGet PackageProvider (with -ForceBootstrap, the same fix already applied to
            Install-WindowsUpdates.ps1/Install-WingetApps.ps1 this session -- otherwise the
            module installs below hit the same interactive "install NuGet provider? [Y/N]"
            prompt on a truly fresh machine) and the PSScriptAnalyzer/Pester (>=5.0) modules

        What this only reports on unless explicitly asked for (heavier, not needed for most
        contributor work):
          - Hyper-V (Test\Rehearsal Tier 1 harness): -IncludeHyperV enables the Windows
            feature, which needs a reboot to take effect and is a bigger system change than
            anything else here, so it is never done silently.
          - Windows ADK (Validate-Unattend.ps1 -RequireSchema-level XSD validation):
            -IncludeAdk installs it via winget (the same two package IDs
            Validate-Unattend.ps1's own -InstallAdkWithWinget switch uses), a multi-GB download.

    .PARAMETER IncludeHyperV
        Also enable the Hyper-V Windows feature if it is not already enabled. Requires a reboot
        to take effect, and only matters for Test\Rehearsal (Tier 1) -- most contributor work
        does not need this.

    .PARAMETER IncludeAdk
        Also install the Windows ADK + WinPE Add-on via winget if not already present. Only
        matters for full unattend.xml XSD schema validation (Validate-Unattend.ps1
        -RequireSchema) -- most contributor work does not need this, and it is a multi-GB
        download.

    .PARAMETER SkipModuleInstall
        Skip installing/updating the PSScriptAnalyzer and Pester PowerShell modules.

    .EXAMPLE
        .\Install-Dependencies.ps1

        Installs PowerShell 7, the .NET SDK Build-UnattendGeneratorLibrary.ps1 needs, the
        PSScriptAnalyzer/Pester modules, and populates the submodule if it is empty. Reports
        (without installing) Hyper-V/ADK status.

    .EXAMPLE
        .\Install-Dependencies.ps1 -IncludeHyperV -IncludeAdk

        Also enables Hyper-V (reboot required afterward) and installs the Windows ADK.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Colored technician-facing setup progress, matching Initialize-UsbDeployment.ps1/Build-UnattendGeneratorLibrary.ps1''s existing convention for this kind of interactive CLI tooling.')]
[CmdletBinding()]
param(
    [switch]$IncludeHyperV,
    [switch]$IncludeAdk,
    [switch]$SkipModuleInstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'This repository''s tooling (and the toolkit it produces) is Windows-only. Run this on a Windows machine.'
}

function Test-IsAdministrator {
    # Same 4-line check as Test-IsAdministrator in Deployment\Scripts\Common.ps1 -- duplicated
    # rather than dot-sourced from there, since that file initialises deployment-runtime state
    # (Get-UsbRoot, dry-run plumbing, etc.) this repo-setup script has no business pulling in.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'This script is not running elevated. winget machine-wide installs and Install-PackageProvider may prompt for elevation or fail.' -ForegroundColor Yellow
    Write-Host 'Re-run from an elevated PowerShell prompt (Run as Administrator) if anything below fails.' -ForegroundColor Yellow
}

function Get-WingetCommand {
    # Same shape as Get-WingetCommand in Deployment\Scripts\Common.ps1 (App Installer can be
    # present but not yet on PATH immediately after a fresh install/first logon) -- duplicated
    # for the same layering reason as Test-IsAdministrator above.
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    return $candidate
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$WingetPath,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    & $WingetPath install --id $PackageId --exact --accept-package-agreements --accept-source-agreements --disable-interactivity
    # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED -- a successful install that just wants a reboot
    # before the installed thing is fully usable (matches this repo's other winget call sites).
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        throw "winget install $PackageId failed with exit code $LASTEXITCODE."
    }
}

Write-Host ''
Write-Host '=== winget ===' -ForegroundColor Cyan
$winget = Get-WingetCommand
if (-not $winget) {
    Write-Host 'winget.exe was not found.' -ForegroundColor Red
    throw 'Install "App Installer" from the Microsoft Store (or download it from https://github.com/microsoft/winget-cli/releases), then rerun this script. winget is required to install everything below.'
}
Write-Host "Found: $winget" -ForegroundColor Green

Write-Host ''
Write-Host '=== PowerShell 7 ===' -ForegroundColor Cyan
if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
    Write-Host 'Already installed.' -ForegroundColor Green
} else {
    Write-Host 'Installing (winget: Microsoft.PowerShell)...' -ForegroundColor Yellow
    Install-WingetPackage -WingetPath $winget -PackageId 'Microsoft.PowerShell'
    Write-Host 'Installed. Rehearsal-tier tooling and Build-UnattendGeneratorLibrary.ps1''s own DLL-loading step need this.' -ForegroundColor Green
}

Write-Host ''
Write-Host '=== External\unattend-generator submodule ===' -ForegroundColor Cyan
$repoRoot = $PSScriptRoot
$submoduleCsproj = Join-Path $repoRoot 'External\unattend-generator\UnattendGenerator.csproj'
if (Test-Path -LiteralPath $submoduleCsproj -PathType Leaf) {
    Write-Host 'Already populated.' -ForegroundColor Green
} else {
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Write-Host "$submoduleCsproj is missing, and git.exe was not found to fetch it." -ForegroundColor Red
        throw 'Install Git for Windows (winget: Git.Git), then run: git submodule update --init --recursive'
    }
    Write-Host 'Looks uninitialised (cloned without --recurse-submodules?); running git submodule update --init --recursive...' -ForegroundColor Yellow
    Push-Location $repoRoot
    try {
        git submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
    if (Test-Path -LiteralPath $submoduleCsproj -PathType Leaf) {
        Write-Host 'Submodule populated.' -ForegroundColor Green
    } else {
        Write-Host "Still missing after git submodule update: $submoduleCsproj. Continuing with a fallback .NET SDK version guess." -ForegroundColor Yellow
    }
}

function Get-RequiredDotNetMajorVersions {
    <#
        .SYNOPSIS
            Parses UnattendGenerator.csproj's own <TargetFrameworks> instead of hardcoding
            version numbers, so this script does not silently go stale if that project's
            target frameworks change later.
    #>
    param([string]$CsprojPath)

    if (-not (Test-Path -LiteralPath $CsprojPath -PathType Leaf)) {
        return @(10)
    }
    $content = Get-Content -LiteralPath $CsprojPath -Raw
    $tfmBlock = [regex]::Match($content, '<TargetFrameworks>([^<]+)</TargetFrameworks>')
    if (-not $tfmBlock.Success) { return @(10) }

    $majors = New-Object 'System.Collections.Generic.List[int]'
    foreach ($tfm in ($tfmBlock.Groups[1].Value -split ';')) {
        $tfmMatch = [regex]::Match($tfm.Trim(), '^net(\d+)\.')
        if ($tfmMatch.Success) { $majors.Add([int]$tfmMatch.Groups[1].Value) }
    }
    if ($majors.Count -eq 0) { return @(10) }
    return @($majors | Sort-Object -Unique)
}

Write-Host ''
Write-Host '=== .NET SDK ===' -ForegroundColor Cyan
$requiredMajors = @(Get-RequiredDotNetMajorVersions -CsprojPath $submoduleCsproj)
$highestRequired = ($requiredMajors | Sort-Object -Descending | Select-Object -First 1)
Write-Host "UnattendGenerator.csproj targets .NET major version(s): $($requiredMajors -join ', ')" -ForegroundColor Cyan

$installedMajors = @()
if (Get-Command dotnet.exe -ErrorAction SilentlyContinue) {
    $installedMajors = @(dotnet --list-sdks 2>$null | ForEach-Object {
            $sdkMatch = [regex]::Match($_, '^(\d+)\.')
            if ($sdkMatch.Success) { [int]$sdkMatch.Groups[1].Value }
        })
}

# dotnet restore evaluates every <TargetFrameworks> entry regardless of which one is actually
# built (Build-UnattendGeneratorLibrary.ps1 defaults to net8.0 alone), and errors out if the
# installed SDK does not recognise the newest one listed -- this is the literal cause of "No
# .NET SDKs were found" / exit code -2147450725 with zero SDKs installed, and would recur with
# only an older SDK installed even once one is present. A newer SDK can still build output for
# an older TargetFramework, so installing just the highest major version required is
# sufficient; it does not need to match every individual entry.
if (@($installedMajors | Where-Object { $_ -ge $highestRequired }).Count -gt 0) {
    Write-Host ".NET SDK already covers major version $highestRequired (installed: $($installedMajors -join ', '))." -ForegroundColor Green
} else {
    Write-Host "Installing .NET $highestRequired SDK (winget: Microsoft.DotNet.SDK.$highestRequired)..." -ForegroundColor Yellow
    Install-WingetPackage -WingetPath $winget -PackageId "Microsoft.DotNet.SDK.$highestRequired"
    Write-Host "Installed. Run .\Build-UnattendGeneratorLibrary.ps1 to build the submodule now that a .NET SDK is present." -ForegroundColor Green
}

if (-not $SkipModuleInstall) {
    Write-Host ''
    Write-Host '=== PowerShell modules (PSScriptAnalyzer, Pester) ===' -ForegroundColor Cyan

    # Fixes the exact "Do you want PowerShellGet to install and import the NuGet provider now?
    # [Y] Yes [N] No" prompt this session already found and fixed in
    # Install-WindowsUpdates.ps1/Install-WingetApps.ps1 -- -Force alone does not suppress it on
    # a fresh machine with no NuGet provider yet; -ForceBootstrap is the flag that does.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Host 'Bootstrapping the NuGet package provider...' -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ForceBootstrap -Confirm:$false -ErrorAction Stop | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Write-Host 'PSScriptAnalyzer already installed.' -ForegroundColor Green
    } else {
        Write-Host 'Installing PSScriptAnalyzer (CurrentUser scope)...' -ForegroundColor Yellow
        Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
    }

    $pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0' } | Select-Object -First 1
    if ($pester) {
        Write-Host "Pester already installed ($($pester.Version))." -ForegroundColor Green
    } else {
        Write-Host 'Installing Pester (>=5.0, CurrentUser scope)...' -ForegroundColor Yellow
        Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
    }
}

Write-Host ''
Write-Host '=== Optional: Hyper-V (Test\Rehearsal Tier 1 harness) ===' -ForegroundColor Cyan
# Get-WindowsOptionalFeature -Online throws "Class not registered" (a DISM/COM interop issue)
# under PowerShell 7 on Windows even when Hyper-V is genuinely enabled and fully functional --
# confirmed while building Test\Rehearsal\RehearsalCommon.ps1's own Test-RehearsalHyperVFeature,
# which this mirrors: DISM first, then fall back to a functional Get-VMHost probe rather than
# trusting a DISM failure (or a slow, possibly-wrong non-Enabled state) as "not enabled".
$hyperVEnabled = $false
try {
    if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
        $hyperVEnabled = [bool]($feature -and $feature.State -eq 'Enabled')
    }
} catch {
    Write-Verbose "Get-WindowsOptionalFeature failed (falling back to a functional check): $($_.Exception.Message)"
}

if (-not $hyperVEnabled) {
    # Explicit import, not reliance on module auto-loading: a machine with VMware PowerCLI
    # installed alongside Hyper-V (both ship a Get-VMHost cmdlet, for ESXi hosts vs. Hyper-V
    # respectively) can have auto-loading resolve the wrong one -- reproduced on exactly this
    # kind of host while building Test\Rehearsal\RehearsalCommon.ps1, which explicitly imports
    # the Hyper-V module for the same reason.
    Import-Module -Name 'Hyper-V' -ErrorAction SilentlyContinue
    if (Get-Command -Module 'Hyper-V' -Name 'Get-VMHost' -ErrorAction SilentlyContinue) {
        try {
            # Module-qualified (Hyper-V\Get-VMHost), not the bare cmdlet name: guarantees the
            # Hyper-V module's own cmdlet runs even if another loaded module (e.g. VMware
            # PowerCLI, which also defines Get-VMHost) would otherwise win command resolution.
            & (Get-Command -Module 'Hyper-V' -Name 'Get-VMHost') -ErrorAction Stop | Out-Null
            $hyperVEnabled = $true
        } catch {
            Write-Verbose "Get-VMHost functional probe failed (non-fatal): $($_.Exception.Message)"
        }
    }
}

if ($hyperVEnabled) {
    Write-Host 'Hyper-V Windows feature is already enabled.' -ForegroundColor Green
} elseif ($IncludeHyperV) {
    Write-Host 'Enabling the Hyper-V Windows feature (Microsoft-Hyper-V-All)...' -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -All -NoRestart | Out-Null
    Write-Host 'Enabled. A REBOOT is required before Hyper-V actually works -- reboot, then run Test-RehearsalPrerequisites (Test\Rehearsal\RehearsalCommon.ps1) to confirm.' -ForegroundColor Yellow
} else {
    Write-Host 'Not enabled. Only needed for Test\Rehearsal (Tier 1) -- rerun with -IncludeHyperV to enable it (requires a reboot afterward), or see TESTING.md.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== Optional: Windows ADK (full unattend.xml schema validation) ===' -ForegroundColor Cyan
if ($IncludeAdk) {
    foreach ($packageId in @('Microsoft.WindowsADK', 'Microsoft.WindowsADK.WinPEAddon')) {
        Write-Host "Installing $packageId via winget (this can take several minutes)..." -ForegroundColor Yellow
        Install-WingetPackage -WingetPath $winget -PackageId $packageId
    }
    Write-Host 'Installed. Run .\Validate-Unattend.ps1 -RequireSchema to confirm the schema DLL is now found.' -ForegroundColor Green
} else {
    Write-Host 'Not installed. Only needed for Validate-Unattend.ps1 -RequireSchema-level XSD validation -- rerun with -IncludeAdk to install it (a multi-GB download), or run .\Validate-Unattend.ps1 -InstallAdkWithWinget -RequireSchema directly.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Dependency setup complete.' -ForegroundColor Green
Write-Host 'Next: .\Build-UnattendGeneratorLibrary.ps1, then Invoke-Pester -Path Tests\Unit, then Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1.' -ForegroundColor Cyan
