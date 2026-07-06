#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for Write-DryRunSummaryReport (Deployment\Scripts\Common.ps1, FABLE_TASKS.md T08):
    aggregates $State.dryrun_actions (Write-DryRunAction's audit trail, T05) into a single
    Markdown report grouped by step.

    Convention: same as Tests\Unit\DryRun.Tests.ps1 -- Common.ps1 is dot-sourced directly, and
    since $script:DeploymentDryRun is only computed once at dot-source time, the environment
    variable is set and Common.ps1 re-dot-sourced (via Set-DryRunEnv) whenever the mode needs to
    flip. Get-DeviceIdentity is Windows-only (Get-CimInstance) and is mocked so
    Get-DeploymentReportRoot -- which Write-DryRunSummaryReport calls internally to resolve
    where the report lands -- can run under $TestDrive without touching real hardware.

    Write-DryRunSummaryReport is only ever called from Start-Deployment.ps1 while dry-run mode
    is already on, so every test below runs with OSIT_DEPLOYMENT_DRYRUN=1, matching that real
    call context and exercising Get-DeploymentReportRoot's dry-run shadow-folder behaviour.
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

    . Set-DryRunEnv -Value '1'
}

AfterAll {
    . Set-DryRunEnv -Value $script:OriginalDryRunEnvValue
}

Describe 'Write-DryRunSummaryReport' {

    BeforeEach {
        . Set-DryRunEnv -Value '1'
        # Mocked the same way Tests\Unit\DryRun.Tests.ps1 isolates Get-DeploymentReportRoot's
        # own tests from this Windows-only (Get-CimInstance) dependency.
        Mock Get-DeviceIdentity {
            @{
                serial_number = 'TEST-SUMMARY-001'
                uuid          = '11111111-1111-1111-1111-111111111111'
                computer_name = 'SUMMARYPC'
            }
        }
        $script:UsbRootTest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:UsbRootTest -Force | Out-Null
    }

    It 'writes a Markdown file under the dry-run report folder and returns its path' {
        $state = @{ deployment_run_id = 'run-001'; dryrun_actions = @() }
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=0 would-reboot=0'

        $path | Should -Match 'dryrun-summary-run-001\.md$'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        # Get-DeploymentReportRoot's own dry-run shadow behaviour is already covered by
        # Tests\Unit\DryRun.Tests.ps1; re-asserted here because this function's whole purpose
        # depends on actually landing there, not merely on that other function being correct.
        $path | Should -Match '[\\/]dryrun[\\/]'
    }

    It 'includes the exact SummaryLine text verbatim near the top, without recomputing it' {
        $state = @{ deployment_run_id = 'run-002'; dryrun_actions = @() }
        $summaryLine = 'DRYRUN RESULT: steps=17 actions=42 would-reboot=3'
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine $summaryLine

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match ([regex]::Escape($summaryLine))
    }

    It 'groups actions under a heading per step, in Get-DeploymentSteps canonical order' {
        $state = @{
            deployment_run_id = 'run-003'
            dryrun_actions    = @(
                [ordered]@{ timestamp = '2026-01-01T00:00:03Z'; step = 'CreateLocalAdmin'; action = 'would create local user OSIT'; data = @{ username = 'OSIT' } },
                [ordered]@{ timestamp = '2026-01-01T00:00:01Z'; step = 'NetworkDrivers'; action = 'would run pnputil'; data = @{ folder = 'X:\Drivers\Intel' } },
                [ordered]@{ timestamp = '2026-01-01T00:00:02Z'; step = 'NetworkDrivers'; action = 'would run pnputil again'; data = @{ folder = 'X:\Drivers\Realtek' } }
            )
        }
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=3 would-reboot=0'
        $lines = Get-Content -LiteralPath $path

        $networkHeadingIndex = ($lines | Select-String -Pattern '^## NetworkDrivers$').LineNumber
        $adminHeadingIndex = ($lines | Select-String -Pattern '^## CreateLocalAdmin$').LineNumber
        $networkHeadingIndex | Should -Not -BeNullOrEmpty
        $adminHeadingIndex | Should -Not -BeNullOrEmpty
        # NetworkDrivers precedes CreateLocalAdmin in Get-DeploymentSteps, even though the
        # actions above were listed in a different order (CreateLocalAdmin first).
        $networkHeadingIndex | Should -BeLessThan $adminHeadingIndex

        $joined = $lines -join "`n"
        $joined | Should -Match 'would run pnputil'
        $joined | Should -Match 'would run pnputil again'
        $joined | Should -Match 'would create local user OSIT'
    }

    It 'renders each action''s .data as a compact one-line JSON blob so nothing is dropped' {
        $state = @{
            deployment_run_id = 'run-004'
            dryrun_actions    = @(
                [ordered]@{ timestamp = '2026-01-01T00:00:00Z'; step = 'PowerSettings'; action = 'would run: powercfg.exe /change monitor-timeout-dc 60'; data = [ordered]@{ file_path = 'powercfg.exe'; arguments = @('/change', 'monitor-timeout-dc', '60') } }
            )
        }
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=1 would-reboot=0'
        $content = Get-Content -LiteralPath $path -Raw

        $content | Should -Match ([regex]::Escape('"file_path":"powercfg.exe"'))
        $content | Should -Match ([regex]::Escape('"monitor-timeout-dc"'))
    }

    It 'renders "(none)" for an action with no .data instead of dropping the line' {
        $state = @{
            deployment_run_id = 'run-005'
            dryrun_actions    = @(
                [ordered]@{ timestamp = '2026-01-01T00:00:00Z'; step = 'Complete'; action = 'not present: some path'; data = $null }
            )
        }
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=1 would-reboot=0'
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'not present: some path'
        $content | Should -Match '\(none\)'
    }

    It 'still renders a non-canonical fallback step name, appended after the canonical steps' {
        $state = @{
            deployment_run_id = 'run-006'
            dryrun_actions    = @(
                [ordered]@{ timestamp = '2026-01-01T00:00:00Z'; step = 'NetworkDrivers'; action = 'would run pnputil'; data = $null },
                [ordered]@{ timestamp = '2026-01-01T00:00:01Z'; step = 'ExternalCommand'; action = 'would run: robocopy.exe /L C:\Source C:\Dest'; data = $null }
            )
        }
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=2 would-reboot=0'
        $lines = Get-Content -LiteralPath $path

        $networkIndex = ($lines | Select-String -Pattern '^## NetworkDrivers$').LineNumber
        $fallbackIndex = ($lines | Select-String -Pattern '^## ExternalCommand$').LineNumber
        $networkIndex | Should -Not -BeNullOrEmpty
        $fallbackIndex | Should -Not -BeNullOrEmpty
        $networkIndex | Should -BeLessThan $fallbackIndex
    }

    It 'writes a well-formed report even with an empty dryrun_actions collection (adversarial: nothing to summarise)' {
        $state = @{ deployment_run_id = 'run-007'; dryrun_actions = @() }
        $path = Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=0 would-reboot=0'
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'No dry-run actions were recorded for this run\.'
    }

    It 'adversarial: tolerates a State with no dryrun_actions key at all (never recorded any action)' {
        $state = @{ deployment_run_id = 'run-008' }
        { Write-DryRunSummaryReport -State $state -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=0 would-reboot=0' } | Should -Not -Throw
    }

    It 'produces a distinct report file per run ID so two runs for the same device do not collide' {
        $stateA = @{ deployment_run_id = 'run-A'; dryrun_actions = @() }
        $stateB = @{ deployment_run_id = 'run-B'; dryrun_actions = @() }
        $pathA = Write-DryRunSummaryReport -State $stateA -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=0 would-reboot=0'
        $pathB = Write-DryRunSummaryReport -State $stateB -UsbRoot $script:UsbRootTest -SummaryLine 'DRYRUN RESULT: steps=17 actions=0 would-reboot=0'

        $pathA | Should -Not -Be $pathB
        Test-Path -LiteralPath $pathA -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $pathB -PathType Leaf | Should -BeTrue
    }
}
