#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the -DryRun plumbing added to the environment step scripts in
    Deployment\Scripts\ (FABLE_TASKS.md T07a): Install-NetworkDrivers.ps1,
    Configure-MspWifi.ps1, Invoke-PreflightChecks.ps1, Invoke-LocalHandover.ps1,
    Configure-PowerSettings.ps1.

    These are orchestrator step scripts, not function libraries: each has top-level
    side-effecting code (dot-sources Common.ps1, reads live deployment state, touches the
    network/registry/filesystem) that must never run just because a unit test file was
    collected. The one piece of genuinely pure logic these scripts added is
    Invoke-PreflightChecks.ps1's Get-EffectivePreflightStatus, extracted here via the same
    AST-based technique Tests\Unit\StartDeploymentDryRun.Tests.ps1 (T06) already established,
    rather than duplicating or re-implementing the logic under test.

    Everything else in T07a (Install-NetworkDrivers.ps1's reliance on Common.ps1's existing
    Invoke-ExternalCommand dry-run refusal, Configure-MspWifi.ps1's connect-and-wait skip,
    Invoke-LocalHandover.ps1's robocopy /L -ReadOnly list pass and local_deployment_root
    suppression, Configure-PowerSettings.ps1's powercfg logging) depends on Windows-only
    cmdlets/state (real WLAN adapters, robocopy.exe as a real binary with real exit-code
    semantics tied to a real filesystem, powercfg.exe) not meaningfully mockable on this
    pwsh 7/Linux sandbox, and was verified instead by manual code trace (every mutating call
    site guarded by `if (Test-DeploymentDryRun) { Write-DryRunAction ... } else { <original
    call, unchanged> }`, confirmed via diff review).
#>

BeforeAll {
    $script:PreflightScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Invoke-PreflightChecks.ps1'

    function Get-PreflightFunctionScriptBlock {
        param(
            [Parameter(Mandatory = $true)][string]$Name
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:PreflightScriptPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "Invoke-PreflightChecks.ps1 failed to parse: $($parseErrors[0].Message)"
        }

        $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        if (-not $functionAst) {
            throw "Function '$Name' was not found in Invoke-PreflightChecks.ps1."
        }

        return [scriptblock]::Create($functionAst.Extent.Text)
    }

    . (Get-PreflightFunctionScriptBlock -Name 'Get-EffectivePreflightStatus')
}

Describe 'Get-EffectivePreflightStatus (T07a dry-run environment-failure downgrade)' {

    It 'downgrades a Fail to Warn for Administrator in dry-run' {
        Get-EffectivePreflightStatus -Name 'Administrator' -Status 'Fail' -DryRun $true | Should -Be 'Warn'
    }

    It 'downgrades a Fail to Warn for Internet in dry-run' {
        Get-EffectivePreflightStatus -Name 'Internet' -Status 'Fail' -DryRun $true | Should -Be 'Warn'
    }

    It 'downgrades a Fail to Warn for AC Power in dry-run' {
        Get-EffectivePreflightStatus -Name 'AC Power' -Status 'Fail' -DryRun $true | Should -Be 'Warn'
    }

    It 'adversarial: does NOT downgrade a genuine config-defect Fail (unrelated check name) in dry-run' {
        Get-EffectivePreflightStatus -Name 'Deployment Config' -Status 'Fail' -DryRun $true | Should -Be 'Fail'
    }

    It 'adversarial: does NOT downgrade any Fail when dry-run is off, even for an environment-dependent name' {
        Get-EffectivePreflightStatus -Name 'Administrator' -Status 'Fail' -DryRun $false | Should -Be 'Fail'
    }

    It 'adversarial: is a no-op for Pass regardless of dry-run' {
        Get-EffectivePreflightStatus -Name 'Administrator' -Status 'Pass' -DryRun $true | Should -Be 'Pass'
        Get-EffectivePreflightStatus -Name 'Administrator' -Status 'Pass' -DryRun $false | Should -Be 'Pass'
    }

    It 'adversarial: is a no-op for Warn regardless of dry-run' {
        Get-EffectivePreflightStatus -Name 'Internet' -Status 'Warn' -DryRun $true | Should -Be 'Warn'
    }

    It 'matches the check name case-insensitively (PowerShell -contains default behaviour)' {
        Get-EffectivePreflightStatus -Name 'administrator' -Status 'Fail' -DryRun $true | Should -Be 'Warn'
    }

    It 'adversarial: an unrecognised check name entirely is never downgraded' {
        Get-EffectivePreflightStatus -Name 'Some Other Check' -Status 'Fail' -DryRun $true | Should -Be 'Fail'
    }
}
