#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for Test\Rehearsal\RehearsalMonitoring.ps1 (FABLE_TASKS.md T12 -- guest
    monitoring and artifact collection).

    Only Get-RehearsalTerminalState and Get-RehearsalArtifactFolder are pure functions; every
    other function in that file (Save-RehearsalVmScreenshot, Wait-RehearsalSetupExit,
    Invoke-RehearsalGuestStatusPoll, Watch-RehearsalDeployment, Copy-RehearsalArtifacts,
    Invoke-RehearsalMonitoring) requires a real Windows Hyper-V host, a live VM, WMI access to
    root\virtualization\v2, and/or an actual PowerShell Direct session to a guest -- none of
    which exist on this pwsh 7/Linux sandbox, and mocking them meaningfully would just be
    re-asserting the mock rather than testing real behaviour. Those were verified instead by:
    dot-sourcing RehearsalMonitoring.ps1 alongside RehearsalCommon.ps1 and confirming every
    function loads without error, and manual code review confirming every Hyper-V/WMI/PS-Direct
    call is preceded by Assert-HyperVAvailable (RehearsalCommon.ps1, T09/T11's own convention).
#>

BeforeAll {
    $script:MonitoringScriptPath = Join-Path $PSScriptRoot '..\..\Test\Rehearsal\RehearsalMonitoring.ps1'
    . $script:MonitoringScriptPath
}

Describe 'Get-RehearsalTerminalState (T12 terminal-state classification)' {

    It "maps Get-DeploymentStatus.ps1's 'Completed' to 'Success'" {
        Get-RehearsalTerminalState -OverallStatus 'Completed' | Should -Be 'Success'
    }

    It "maps 'Failed' to 'Failed'" {
        Get-RehearsalTerminalState -OverallStatus 'Failed' | Should -Be 'Failed'
    }

    It "maps 'Running' to 'Running' (not yet terminal)" {
        Get-RehearsalTerminalState -OverallStatus 'Running' | Should -Be 'Running'
    }

    It "maps 'Stalled' to 'Running' (not yet terminal -- the harness's own timeout budget decides Timeout, not this function)" {
        Get-RehearsalTerminalState -OverallStatus 'Stalled' | Should -Be 'Running'
    }

    It "maps 'WaitingForReboot' to 'Running' (not yet terminal)" {
        Get-RehearsalTerminalState -OverallStatus 'WaitingForReboot' | Should -Be 'Running'
    }

    It "maps 'NotStarted' to 'Running' (not yet terminal)" {
        Get-RehearsalTerminalState -OverallStatus 'NotStarted' | Should -Be 'Running'
    }

    It 'adversarial: maps an unrecognised/empty overall_status to Running rather than throwing' {
        Get-RehearsalTerminalState -OverallStatus '' | Should -Be 'Running'
        Get-RehearsalTerminalState -OverallStatus 'SomethingUnexpected' | Should -Be 'Running'
    }
}

Describe 'Get-RehearsalArtifactFolder (T12 artifact path construction)' {

    # Drive-letter-free paths are used deliberately: Join-Path with a literal 'C:\...' path
    # throws DriveNotFoundException on non-Windows pwsh (no C: PSDrive exists), which this test
    # suite must run under. With $ErrorActionPreference = 'Continue' that non-terminating error
    # was silently swallowed and both sides of Should -Be evaluated to $null, so this previously
    # "passed" without actually comparing anything.
    It 'joins the artifact root and timestamp into one path' {
        Get-RehearsalArtifactFolder -ArtifactRoot 'Repo\Test\Rehearsal\Artifacts' -Timestamp '20260706-143000' |
            Should -Be (Join-Path 'Repo\Test\Rehearsal\Artifacts' '20260706-143000')
    }

    It 'adversarial: does not collapse or alter a timestamp that looks path-like' {
        Get-RehearsalArtifactFolder -ArtifactRoot 'Artifacts' -Timestamp '2026-07-06_14-30-00' |
            Should -Be (Join-Path 'Artifacts' '2026-07-06_14-30-00')
    }
}
