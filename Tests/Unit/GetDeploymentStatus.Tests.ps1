#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the pure verdict-derivation helpers in
    Deployment\Scripts\Get-DeploymentStatus.ps1:

      - Format-DeploymentAgeText   (seconds -> short human-readable age)
      - Get-DeploymentFailureHistory (state.history -> flat step_failed list)
      - Get-DeploymentVerdict      (snapshot -> one-line technician verdict)

    All three are pure (no CIM, no scheduled tasks, no filesystem), so they run for real on
    every platform, including ubuntu-latest CI.

    The functions are extracted via the same AST-based technique
    Tests\Unit\StartDeploymentDryRun.Tests.ps1 established, rather than dot-sourcing
    Get-DeploymentStatus.ps1 (whose top-level code dot-sources Common.ps1 and immediately
    takes a live status snapshot -- side effects that must never run just because a unit
    test file was collected).

    Contract pinned here on purpose: Get-DeploymentVerdict must never introduce or depend on
    a new overall_status value. Test\Rehearsal\RehearsalMonitoring.ps1 maps
    Completed->Success, Failed->Failed, anything-else->Running to decide rehearsal terminal
    state (pinned by Tests\Unit\RehearsalMonitoring.Tests.ps1); the verdict is purely
    additive report text derived from the existing five statuses plus NotStarted.
#>

BeforeAll {
    $script:StatusScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Get-DeploymentStatus.ps1'

    function Get-StatusFunctionScriptBlock {
        param(
            [Parameter(Mandatory = $true)][string]$Name
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:StatusScriptPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "Get-DeploymentStatus.ps1 failed to parse: $($parseErrors[0].Message)"
        }

        $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        if (-not $functionAst) {
            throw "Function '$Name' was not found in Get-DeploymentStatus.ps1."
        }

        return [scriptblock]::Create($functionAst.Extent.Text)
    }

    . (Get-StatusFunctionScriptBlock -Name 'Format-DeploymentAgeText')
    . (Get-StatusFunctionScriptBlock -Name 'Get-DeploymentFailureHistory')
    . (Get-StatusFunctionScriptBlock -Name 'Get-DeploymentVerdict')
}

Describe 'Format-DeploymentAgeText' {
    It 'renders $null (age unknown) as ''unknown''' {
        Format-DeploymentAgeText -Seconds $null | Should -Be 'unknown'
    }

    It 'renders sub-minute ages as seconds' {
        Format-DeploymentAgeText -Seconds 0 | Should -Be '0s'
        Format-DeploymentAgeText -Seconds 45 | Should -Be '45s'
    }

    It 'renders sub-hour ages as minutes and seconds' {
        Format-DeploymentAgeText -Seconds 723 | Should -Be '12m 3s'
    }

    It 'renders hour-plus ages as hours and minutes' {
        Format-DeploymentAgeText -Seconds 7500 | Should -Be '2h 5m'
    }

    It 'clamps negative ages (clock skew) to 0s instead of printing nonsense' {
        Format-DeploymentAgeText -Seconds -30 | Should -Be '0s'
    }
}

Describe 'Get-DeploymentFailureHistory' {
    It 'returns an empty array for a null state' {
        @(Get-DeploymentFailureHistory -State $null).Count | Should -Be 0
    }

    It 'returns an empty array when state has no history key (older state files)' {
        @(Get-DeploymentFailureHistory -State @{ current_step = 'Preflight' }).Count | Should -Be 0
    }

    It 'extracts only step_failed events, flattened to timestamp/step/message' {
        $state = @{
            history = @(
                @{ timestamp = 't1'; event = 'step_started'; data = @{ step = 'Preflight' } },
                @{ timestamp = 't2'; event = 'step_failed'; data = @{ timestamp = 't2'; step = 'Preflight'; message = 'no AC power' } },
                @{ timestamp = 't3'; event = 'step_completed'; data = @{ step = 'Preflight' } },
                @{ timestamp = 't4'; event = 'step_failed'; data = @{ timestamp = 't4'; step = 'WindowsUpdates'; message = '0x80240438' } }
            )
        }

        $failures = @(Get-DeploymentFailureHistory -State $state)

        $failures.Count | Should -Be 2
        $failures[0].timestamp | Should -Be 't2'
        $failures[0].step | Should -Be 'Preflight'
        $failures[0].message | Should -Be 'no AC power'
        $failures[1].step | Should -Be 'WindowsUpdates'
        $failures[1].message | Should -Be '0x80240438'
    }

    It 'tolerates malformed history entries (missing data, wrong types) without throwing' {
        $state = @{
            history = @(
                'not-a-dictionary',
                @{ event = 'step_failed' },
                @{ timestamp = 't9'; event = 'step_failed'; data = 'not-a-dictionary-either' }
            )
        }

        $failures = @(Get-DeploymentFailureHistory -State $state)

        # The two dictionary-shaped step_failed entries survive with empty step/message;
        # the non-dictionary entry is skipped.
        $failures.Count | Should -Be 2
        $failures[0].step | Should -Be ''
        $failures[1].timestamp | Should -Be 't9'
        $failures[1].message | Should -Be ''
    }

    It 'yields exactly one entry (not a key count) for a single failure when @()-wrapped' {
        $state = @{
            history = @(
                @{ timestamp = 't1'; event = 'step_failed'; data = @{ step = 'DattoRmm'; message = 'installer exit 1603' } }
            )
        }

        @(Get-DeploymentFailureHistory -State $state).Count | Should -Be 1
    }
}

Describe 'Get-DeploymentVerdict' {
    It 'Completed: one-liner with step total and finish timestamp' {
        $snapshot = @{
            overall_status       = 'Completed'
            completed_step_count = 19
            total_step_count     = 19
            state_last_updated   = '2026-07-16T10:00:00'
        }

        Get-DeploymentVerdict -Snapshot $snapshot | Should -Be 'COMPLETE - all 19 steps finished at 2026-07-16T10:00:00.'
    }

    It 'Running: current step, progress, and last-activity age (from the log heartbeat)' {
        $snapshot = @{
            overall_status       = 'Running'
            current_step         = 'WindowsUpdates'
            completed_step_count = 6
            total_step_count     = 19
            state_age_seconds    = 900
            log_heartbeat        = @{ seconds_since_activity = 45 }
        }

        Get-DeploymentVerdict -Snapshot $snapshot | Should -Be "IN PROGRESS - step 'WindowsUpdates' (6 of 19 complete), last activity 45s ago."
    }

    It 'Running: falls back to state age when there is no log heartbeat' {
        $snapshot = @{
            overall_status       = 'Running'
            current_step         = 'WingetApps'
            completed_step_count = 11
            total_step_count     = 19
            state_age_seconds    = 723
        }

        Get-DeploymentVerdict -Snapshot $snapshot | Should -Be "IN PROGRESS - step 'WingetApps' (11 of 19 complete), last activity 12m 3s ago."
    }

    It 'Failed with the resume task armed: promises the automatic retry and both manual retry paths' {
        $snapshot = @{
            overall_status = 'Failed'
            current_step   = 'WindowsUpdates'
            last_error     = @{ step = 'WindowsUpdates'; message = '0x80240438' }
            retry          = @{ armed = $true; next_attempt = '2026-07-16 10:05:00' }
        }

        $verdict = Get-DeploymentVerdict -Snapshot $snapshot

        $verdict | Should -BeLike "FAILED at step 'WindowsUpdates': 0x80240438 - will retry automatically (next attempt 2026-07-16 10:05:00);*"
        $verdict | Should -BeLike '*Resume-Deployment.ps1*'
        $verdict | Should -BeLike "*'Resume 1S-WIN11 Deployment'*"
    }

    It 'Failed with the resume task armed but no next_run_time: omits the (next attempt ...) clause' {
        $snapshot = @{
            overall_status = 'Failed'
            last_error     = @{ step = 'DattoRmm'; message = 'installer exit 1603' }
            retry          = @{ armed = $true; next_attempt = $null }
        }

        $verdict = Get-DeploymentVerdict -Snapshot $snapshot

        $verdict | Should -BeLike "FAILED at step 'DattoRmm': installer exit 1603 - will retry automatically;*"
        $verdict | Should -Not -BeLike '*next attempt*'
    }

    It 'Failed without a resume task: points straight at Resume-Deployment.ps1' {
        $snapshot = @{
            overall_status = 'Failed'
            last_error     = @{ step = 'Preflight'; message = 'no AC power' }
            retry          = @{ armed = $false; next_attempt = $null }
        }

        Get-DeploymentVerdict -Snapshot $snapshot |
            Should -Be "FAILED at step 'Preflight': no AC power - run Resume-Deployment.ps1 to retry from this step."
    }

    It 'WaitingForReboot with the resume task armed: says a restart is all that is needed' {
        $snapshot = @{
            overall_status = 'WaitingForReboot'
            current_step   = 'WindowsUpdates'
            retry          = @{ armed = $true; next_attempt = $null }
        }

        $verdict = Get-DeploymentVerdict -Snapshot $snapshot

        $verdict | Should -BeLike "WAITING FOR REBOOT - deployment will resume at step 'WindowsUpdates'*restart the device to continue."
    }

    It 'WaitingForReboot without a resume task: restart plus manual Resume-Deployment.ps1' {
        $snapshot = @{
            overall_status = 'WaitingForReboot'
            current_step   = 'WindowsUpdates'
            retry          = @{ armed = $false; next_attempt = $null }
        }

        $verdict = Get-DeploymentVerdict -Snapshot $snapshot

        $verdict | Should -BeLike 'WAITING FOR REBOOT - a reboot is pending but no resume task is registered;*Resume-Deployment.ps1*'
    }

    It 'Stalled: actionable next move (check log, then Resume-Deployment.ps1), anchored to the last successful step when current_step is empty' {
        $snapshot = @{
            overall_status       = 'Stalled'
            current_step         = ''
            last_successful_step = 'PowerSettings'
            completed_step_count = 6
            total_step_count     = 19
            state_age_seconds    = 7500
        }

        $verdict = Get-DeploymentVerdict -Snapshot $snapshot

        $verdict | Should -BeLike 'STALLED - *6 of 19 complete, last activity 2h 5m ago*'
        $verdict | Should -BeLike "*Resume-Deployment.ps1 to continue from step 'PowerSettings'."
    }

    It 'NotStarted: points at Start-Deployment.ps1' {
        Get-DeploymentVerdict -Snapshot @{ overall_status = 'NotStarted' } |
            Should -Be 'NOT STARTED - no deployment state found on this device; run Start-Deployment.ps1 to begin.'
    }

    It 'unknown status: falls back to the snapshot message rather than inventing a verdict' {
        Get-DeploymentVerdict -Snapshot @{ overall_status = 'SomethingNew'; message = 'fallback text' } |
            Should -Be 'fallback text'
    }

    It 'guarded reads: a minimal snapshot with only overall_status does not throw under StrictMode' {
        Set-StrictMode -Version 2.0
        try {
            { Get-DeploymentVerdict -Snapshot @{ overall_status = 'Failed' } } | Should -Not -Throw
            { Get-DeploymentVerdict -Snapshot @{ overall_status = 'Running' } } | Should -Not -Throw
            { Get-DeploymentVerdict -Snapshot @{ overall_status = 'Stalled' } } | Should -Not -Throw
        } finally {
            Set-StrictMode -Off
        }
    }
}
