#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the Phase B (-DryRun) plumbing added to Common.ps1 (FABLE_TASKS.md T05):
      - Test-DeploymentDryRun / $script:DeploymentDryRun toggling via $env:OSIT_DEPLOYMENT_DRYRUN
      - Write-DryRunAction's audit-trail recording
      - Shadow path resolution (Get-DeploymentPaths / Initialize-DeploymentLogging)
      - Invoke-ExternalCommand's dry-run refusal (and -ReadOnly bypass)

    Convention: Common.ps1 is dot-sourced directly (no module manifest), matching how every
    Deployment\Scripts\*.ps1 step script consumes it ( . "$PSScriptRoot\Common.ps1" ). Because
    $script:DeploymentDryRun is only computed once, at dot-source time, tests that need to
    flip the mode re-dot-source Common.ps1 after changing the environment variable rather
    than mutating the script-scoped variable directly.
#>

BeforeAll {
    $script:CommonScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Common.ps1'
    $script:OriginalDryRunEnvValue = $env:OSIT_DEPLOYMENT_DRYRUN

    function Set-DryRunEnv {
        param([string]$Value)
        if ($null -eq $Value) {
            Remove-Item Env:\OSIT_DEPLOYMENT_DRYRUN -ErrorAction SilentlyContinue
        } else {
            $env:OSIT_DEPLOYMENT_DRYRUN = $Value
        }
        # Re-dot-source so $script:DeploymentDryRun is recomputed from the current environment,
        # exactly as happens the first time any script dot-sources Common.ps1.
        . $script:CommonScriptPath
    }

    # Establish the production-default baseline (env var unset) before any test runs.
    . Set-DryRunEnv -Value $null
}

AfterAll {
    . Set-DryRunEnv -Value $script:OriginalDryRunEnvValue
}

Describe 'Test-DeploymentDryRun' {

    AfterEach {
        # Always leave dry-run mode off for tests outside this Describe block.
        . Set-DryRunEnv -Value $null
    }

    It 'is $false when OSIT_DEPLOYMENT_DRYRUN is unset (production default)' {
        . Set-DryRunEnv -Value $null
        Test-DeploymentDryRun | Should -BeFalse
    }

    It 'is $true when OSIT_DEPLOYMENT_DRYRUN=1' {
        . Set-DryRunEnv -Value '1'
        Test-DeploymentDryRun | Should -BeTrue
    }

    It 'is $false when OSIT_DEPLOYMENT_DRYRUN=0' {
        . Set-DryRunEnv -Value '0'
        Test-DeploymentDryRun | Should -BeFalse
    }

    It 'is $false for any value other than the literal string "1"' {
        . Set-DryRunEnv -Value 'true'
        Test-DeploymentDryRun | Should -BeFalse
    }

    It 'toggles back to $false after being $true' {
        . Set-DryRunEnv -Value '1'
        Test-DeploymentDryRun | Should -BeTrue
        . Set-DryRunEnv -Value $null
        Test-DeploymentDryRun | Should -BeFalse
    }
}

Describe 'Write-DryRunAction' {

    BeforeEach {
        . Set-DryRunEnv -Value $null
    }

    It 'logs a message with a DRYRUN prefix via Write-Log' {
        Mock -CommandName Write-Log -Verifiable
        Write-DryRunAction -State @{} -Step 'TestStep' -Action 'would do a thing'
        Should -Invoke -CommandName Write-Log -Times 1 -ParameterFilter {
            $Level -eq 'Info' -and $Message -like 'DRYRUN*' -and $Message -like '*TestStep*' -and $Message -like '*would do a thing*'
        }
    }

    It 'appends a self-describing record to $State.dryrun_actions' {
        $state = @{ dryrun_actions = @() }
        Write-DryRunAction -State $state -Step 'NetworkDrivers' -Action 'would run pnputil /add-driver' -Data @{ folder = 'X:\Drivers' }

        $state.dryrun_actions.Count | Should -Be 1
        $record = $state.dryrun_actions[0]
        $record.step | Should -Be 'NetworkDrivers'
        $record.action | Should -Be 'would run pnputil /add-driver'
        $record.data.folder | Should -Be 'X:\Drivers'
        $record.timestamp | Should -Not -BeNullOrEmpty
        { [datetime]::Parse($record.timestamp) } | Should -Not -Throw
    }

    It 'initialises dryrun_actions when the key does not already exist on State' {
        $state = @{}
        Write-DryRunAction -State $state -Step 'Step1' -Action 'first action'
        $state.ContainsKey('dryrun_actions') | Should -BeTrue
        $state.dryrun_actions.Count | Should -Be 1
    }

    It 'accumulates multiple actions in call order without overwriting earlier ones' {
        $state = @{}
        Write-DryRunAction -State $state -Step 'A' -Action 'first'
        Write-DryRunAction -State $state -Step 'B' -Action 'second'
        Write-DryRunAction -State $state -Step 'C' -Action 'third'

        $state.dryrun_actions.Count | Should -Be 3
        $state.dryrun_actions[0].step | Should -Be 'A'
        $state.dryrun_actions[1].step | Should -Be 'B'
        $state.dryrun_actions[2].step | Should -Be 'C'
    }

    It 'tolerates a $null State without throwing (log-only call sites)' {
        { Write-DryRunAction -State $null -Step 'NoState' -Action 'noop' } | Should -Not -Throw
    }

    It 'does not leak a return value onto the caller''s output stream' {
        # Regression guard: Write-DryRunAction must behave like Add-StateHistory (mutate
        # $State, return nothing) - an earlier draft returned the record, which silently
        # merged into the output of any function calling it as a bare statement.
        $state = @{}
        $output = Write-DryRunAction -State $state -Step 'X' -Action 'y'
        $output | Should -BeNullOrEmpty
    }
}

Describe 'Get-DeploymentPaths shadow state file (state isolation invariant)' {

    BeforeAll {
        $script:PathsTestRoot = Join-Path $TestDrive 'usbroot'
        New-Item -ItemType Directory -Path $script:PathsTestRoot -Force | Out-Null
    }

    AfterEach {
        . Set-DryRunEnv -Value $null
    }

    It 'resolves the real state file name when dry-run is off' {
        . Set-DryRunEnv -Value $null
        $paths = Get-DeploymentPaths -UsbRoot $script:PathsTestRoot
        $paths.StateFile | Should -Match 'deployment_state\.json$'
        $paths.StateFile | Should -Not -Match 'dryrun'
    }

    It 'resolves a shadow deployment_state.dryrun.json when dry-run is on' {
        . Set-DryRunEnv -Value '1'
        $paths = Get-DeploymentPaths -UsbRoot $script:PathsTestRoot
        $paths.StateFile | Should -Match 'deployment_state\.dryrun\.json$'
    }

    It 'leaves every other path key identical between the two modes' {
        . Set-DryRunEnv -Value $null
        $realPaths = Get-DeploymentPaths -UsbRoot $script:PathsTestRoot
        . Set-DryRunEnv -Value '1'
        $dryRunPaths = Get-DeploymentPaths -UsbRoot $script:PathsTestRoot

        foreach ($key in @('UsbRoot', 'Deployment', 'Config', 'Scripts', 'State', 'Logs', 'Reports', 'ConfigFile', 'WingetFile', 'LocalFile', 'SmtpFile')) {
            $dryRunPaths[$key] | Should -Be $realPaths[$key] -Because "key '$key' is not part of the state-isolation shadow and must not change"
        }
    }
}

# Kept as its own Describe (rather than a 4th It above): Pester 5 appears to reuse block-level
# scope state across sibling It blocks in a way that collides once Common.ps1 (which itself
# calls Set-StrictMode -Version 2.0) has already been re-dot-sourced by an earlier sibling It
# in the same Describe - a subsequent Mock + re-dot-source in a later sibling It intermittently
# raised "The variable '$runid' cannot be retrieved because it has not been set" from inside
# Initialize-DeploymentLogging, even though $runId is assigned unconditionally on the line
# before its only use. Isolating this test in its own Describe avoids that collision entirely
# (verified: reproduced and fixed in isolation before applying here).
Describe 'Initialize-DeploymentLogging dry-run folder (state isolation invariant)' {

    BeforeAll {
        $script:LoggingTestRoot = Join-Path $TestDrive 'usbroot-logging'
        New-Item -ItemType Directory -Path $script:LoggingTestRoot -Force | Out-Null
    }

    AfterEach {
        . Set-DryRunEnv -Value $null
    }

    It 'writes into a dryrun-prefixed run-id folder when dry-run is on, and the plain run-id folder when off' {
        # Get-DeviceIdentity is Windows-only (CIM); mocked here the same way T02's
        # Common.Tests.ps1 isolates state-round-trip tests from that platform dependency.
        # Re-mocked after every ". Set-DryRunEnv" call below because that re-dot-sources
        # Common.ps1, which redefines (and so clobbers) any earlier Pester mock of it.
        $identityMock = {
            @{
                serial_number = 'TEST-SERIAL-002'
                uuid          = '22222222-2222-2222-2222-222222222222'
                computer_name = 'TESTPC2'
            }
        }

        . Set-DryRunEnv -Value $null
        Mock Get-DeviceIdentity $identityMock
        $state = @{ deployment_run_id = 'runid-real' }
        $ctx = Initialize-DeploymentLogging -UsbRoot $script:LoggingTestRoot -State $state
        try { Stop-DeploymentLogging } catch {
            # Stop-DeploymentLogging is not the focus of this test (it only verifies the
            # dry-run-prefixed log folder naming); tolerate it being a no-op/unavailable here.
            Write-Verbose "Stop-DeploymentLogging: $_"
        }
        Split-Path -Leaf $ctx.LogDir | Should -Be 'runid-real'

        . Set-DryRunEnv -Value '1'
        Mock Get-DeviceIdentity $identityMock
        $dryState = @{ deployment_run_id = 'runid-dry' }
        $dryCtx = Initialize-DeploymentLogging -UsbRoot $script:LoggingTestRoot -State $dryState
        try { Stop-DeploymentLogging } catch {
            # Stop-DeploymentLogging is not the focus of this test (it only verifies the
            # dry-run-prefixed log folder naming); tolerate it being a no-op/unavailable here.
            Write-Verbose "Stop-DeploymentLogging: $_"
        }
        Split-Path -Leaf $dryCtx.LogDir | Should -Be 'dryrun-runid-dry'
    }
}


# Kept as its own Describe for the same reason as "Initialize-DeploymentLogging dry-run
# folder" above: avoids the sibling-It Pester scope collision documented there.
Describe 'Get-DeploymentReportRoot shadow folder (state isolation invariant, FABLE_TASKS.md T07c)' {

    BeforeAll {
        $script:ReportTestRoot = Join-Path $TestDrive 'usbroot-reports'
        New-Item -ItemType Directory -Path $script:ReportTestRoot -Force | Out-Null
    }

    AfterEach {
        . Set-DryRunEnv -Value $null
    }

    It 'resolves the real per-device report folder when dry-run is off, and a nested dryrun folder when on' {
        $identityMock = {
            @{
                serial_number = 'TEST-SERIAL-003'
                uuid          = '33333333-3333-3333-3333-333333333333'
                computer_name = 'TESTPC3'
            }
        }

        . Set-DryRunEnv -Value $null
        Mock Get-DeviceIdentity $identityMock
        $realRoot = Get-DeploymentReportRoot -UsbRoot $script:ReportTestRoot
        # Get-SafeName (used by Get-DeviceFolderName) collapses hyphens to underscores.
        Split-Path -Leaf $realRoot | Should -Be 'TEST_SERIAL_003'
        Test-Path -LiteralPath $realRoot -PathType Container | Should -BeTrue

        . Set-DryRunEnv -Value '1'
        Mock Get-DeviceIdentity $identityMock
        $dryRoot = Get-DeploymentReportRoot -UsbRoot $script:ReportTestRoot
        $dryRoot | Should -Be (Join-Path $realRoot 'dryrun')
        Test-Path -LiteralPath $dryRoot -PathType Container | Should -BeTrue
    }
}

Describe 'Invoke-ExternalCommand dry-run refusal' {

    BeforeEach {
        . Set-DryRunEnv -Value '1'
    }

    AfterEach {
        . Set-DryRunEnv -Value $null
    }

    It 'does not call Start-Process and returns a synthetic success result' {
        Mock -CommandName Start-Process -MockWith {
            throw 'Start-Process must not be called for a mutating command in dry-run mode.'
        }

        $state = @{}
        $result = Invoke-ExternalCommand -FilePath 'this-binary-definitely-does-not-exist-xyz123' `
            -Arguments @('/mutate', 'value with spaces') -State $state

        Should -Invoke -CommandName Start-Process -Times 0

        $result.file_path | Should -Be 'this-binary-definitely-does-not-exist-xyz123'
        $result.arguments | Should -Be @('/mutate', 'value with spaces')
        $result.exit_code | Should -Be 0
        $result.stdout | Should -Be ''
        $result.stderr | Should -Be ''
    }

    It 'never throws "Executable not found" in the refusal path even for a bogus FilePath' {
        Mock -CommandName Start-Process -MockWith { throw 'should not be called' }
        { Invoke-ExternalCommand -FilePath 'still-not-a-real-binary-987' -Arguments @() } | Should -Not -Throw
    }

    It 'records the exact FilePath and argument string via Write-DryRunAction' {
        Mock -CommandName Start-Process -MockWith { throw 'should not be called' }
        $state = @{}
        Invoke-ExternalCommand -FilePath 'robocopy.exe' -Arguments @('C:\Source', 'C:\Dest with spaces', '/MIR') -State $state | Out-Null

        $state.dryrun_actions.Count | Should -Be 1
        $action = $state.dryrun_actions[0]
        $action.data.file_path | Should -Be 'robocopy.exe'
        $action.action | Should -Match ([regex]::Escape('robocopy.exe'))
        $action.action | Should -Match ([regex]::Escape('"C:\Dest with spaces"'))
    }

    It 'still executes for real when -ReadOnly is passed, even in dry-run mode' {
        Mock -CommandName Start-Process -MockWith {
            [pscustomobject]@{ ExitCode = 0 }
        }

        # Use the current pwsh executable so the pre-flight "executable exists" check passes
        # without needing a mock of its own.
        $realExecutable = (Get-Process -Id $PID).Path
        $state = @{}
        $result = Invoke-ExternalCommand -FilePath $realExecutable -Arguments @('-NoLogo') -ReadOnly -State $state

        Should -Invoke -CommandName Start-Process -Times 1
        $state.ContainsKey('dryrun_actions') | Should -BeFalse
        $result.exit_code | Should -Be 0
    }

    It 'behaves identically to the non-dry-run path when -ReadOnly is passed (no dry-run branching leaks in)' {
        Mock -CommandName Start-Process -MockWith {
            [pscustomobject]@{ ExitCode = 0 }
        }
        $realExecutable = (Get-Process -Id $PID).Path
        $result = Invoke-ExternalCommand -FilePath $realExecutable -Arguments @('-NoLogo') -ReadOnly
        $result.file_path | Should -Be $realExecutable
        $result.exit_code | Should -Be 0
    }
}

Describe 'Invoke-ExternalCommand behaviour is unchanged when dry-run is off' {

    BeforeEach {
        . Set-DryRunEnv -Value $null
    }

    It 'still throws "Executable not found" for a bogus FilePath (T02 tripwire)' {
        { Invoke-ExternalCommand -FilePath 'this-binary-definitely-does-not-exist-xyz123' -Arguments @() } |
            Should -Throw '*Executable not found*'
    }

    It 'calls Start-Process for a real command exactly as before' {
        Mock -CommandName Start-Process -MockWith {
            [pscustomobject]@{ ExitCode = 0 }
        }
        $realExecutable = (Get-Process -Id $PID).Path
        $result = Invoke-ExternalCommand -FilePath $realExecutable -Arguments @('-NoLogo')
        Should -Invoke -CommandName Start-Process -Times 1
        $result.exit_code | Should -Be 0
    }
}
