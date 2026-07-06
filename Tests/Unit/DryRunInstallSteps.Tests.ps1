#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the -DryRun plumbing added to the install step scripts in
    Deployment\Scripts\ (FABLE_TASKS.md T07b): Install-WindowsUpdates.ps1,
    Install-WingetApps.ps1, Install-LocalApps.ps1, Install-DattoRmm.ps1.

    Same convention as Tests\Unit\StartDeploymentDryRun.Tests.ps1 (T06) and
    Tests\Unit\DryRunEnvironmentSteps.Tests.ps1 (T07a): these are orchestrator step scripts
    with side-effecting top-level code, so the one piece of genuinely pure logic added --
    Install-LocalApps.ps1's Get-LocalInstallerDryRunAction, which builds the "would run: ..."
    description string for each installer_type without invoking anything -- is extracted via
    the PowerShell AST rather than dot-sourcing the whole script.

    Everything else in T07b (the real Get-WindowsUpdate/COM scan, the real `winget list`
    detection now marked -ReadOnly, the Datto RMM UUID/already-installed checks) depends on
    Windows-only cmdlets and live network state not meaningfully mockable on this pwsh
    7/Linux sandbox, and was verified instead by manual code trace (every mutating call site
    guarded by `if (Test-DeploymentDryRun) { Write-DryRunAction ... } else { <original call,
    unchanged> }`, or already routed through Invoke-ExternalCommand without -ReadOnly, which
    T05 already makes dry-run-safe).
#>

BeforeAll {
    $script:CommonScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Common.ps1'
    $script:LocalAppsScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Install-LocalApps.ps1'

    # Common.ps1 has no side effects at dot-source time beyond variable/function setup (see
    # Common.Tests.ps1's BeforeAll), and Get-LocalInstallerDryRunAction below calls two of its
    # pure helpers (ConvertTo-ProcessArgumentString, Split-CommandLineArguments) directly.
    Remove-Item Env:\OSIT_DEPLOYMENT_DRYRUN -ErrorAction SilentlyContinue
    . $script:CommonScriptPath

    function Get-LocalAppsFunctionScriptBlock {
        param(
            [Parameter(Mandatory = $true)][string]$Name
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:LocalAppsScriptPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "Install-LocalApps.ps1 failed to parse: $($parseErrors[0].Message)"
        }

        $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        if (-not $functionAst) {
            throw "Function '$Name' was not found in Install-LocalApps.ps1."
        }

        return [scriptblock]::Create($functionAst.Extent.Text)
    }

    . (Get-LocalAppsFunctionScriptBlock -Name 'Get-LocalInstallerDryRunAction')
}

Describe 'Get-LocalInstallerDryRunAction (T07b dry-run install-command description)' {

    It 'describes an msi install with default silent arguments' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Foo.msi' -InstallerType 'msi' -SilentArguments '' |
            Should -Be 'would run: msiexec.exe /i C:\Apps\Foo.msi /qn /norestart'
    }

    It 'describes an msi install with custom silent arguments, overriding the defaults' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Foo.msi' -InstallerType 'msi' -SilentArguments '/quiet /norestart ALLUSERS=1' |
            Should -Be 'would run: msiexec.exe /i C:\Apps\Foo.msi /quiet /norestart ALLUSERS=1'
    }

    It 'describes an exe install with no arguments' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Setup.exe' -InstallerType 'exe' -SilentArguments '' |
            Should -Be 'would run: C:\Apps\Setup.exe'
    }

    It 'describes an exe install and preserves a quoted argument containing a space' {
        # The silent_arguments string must itself quote an embedded-space token (matching how
        # Split-CommandLineArguments tokenizes on unquoted whitespace); ConvertTo-ProcessArgumentString
        # then re-quotes that one token when rebuilding the command line.
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Setup.exe' -InstallerType 'exe' -SilentArguments '/S "/D=C:\Program Files\Foo"' |
            Should -Be 'would run: C:\Apps\Setup.exe /S "/D=C:\Program Files\Foo"'
    }

    It 'describes an msix install via Add-AppxPackage' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Foo.msix' -InstallerType 'msix' -SilentArguments '' |
            Should -Be 'would run: Add-AppxPackage -Path C:\Apps\Foo.msix'
    }

    It 'describes an appx install via Add-AppxPackage (same handling as msix)' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Foo.appx' -InstallerType 'appx' -SilentArguments '' |
            Should -Be 'would run: Add-AppxPackage -Path C:\Apps\Foo.appx'
    }

    It 'describes a script install with arguments appended' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\install.ps1' -InstallerType 'script' -SilentArguments '-Silent' |
            Should -Be 'would run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Apps\install.ps1 -Silent'
    }

    It 'is case-insensitive on installer_type' {
        Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Foo.MSI' -InstallerType 'MSI' -SilentArguments '' |
            Should -Be 'would run: msiexec.exe /i C:\Apps\Foo.MSI /qn /norestart'
    }

    It 'adversarial: throws for an unsupported installer_type, matching Invoke-LocalInstaller''s own behaviour' {
        { Get-LocalInstallerDryRunAction -InstallerPath 'C:\Apps\Foo.bin' -InstallerType 'zip' -SilentArguments '' } |
            Should -Throw "*Unsupported installer_type 'zip'*"
    }
}
