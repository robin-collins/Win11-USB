#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the -DryRun plumbing added to Deployment\Scripts\Start-Deployment.ps1
    (FABLE_TASKS.md T06).

    Start-Deployment.ps1 is an orchestrator script, not a function library: it has top-level
    side-effecting code (Enter-DeploymentRunLock, the full step loop, catch/finally cleanup)
    that runs immediately if the whole file is dot-sourced. That is not something a unit test
    should ever trigger. To test the pieces of *pure* logic T06 added without executing that
    body, this suite parses the script's AST and extracts just the named function definitions
    as standalone script blocks -- the same text the real script uses, dot-sourced in
    isolation -- rather than duplicating or re-implementing the logic under test.

    In scope here:
      - Get-DryRunSummaryLine: pure string formatting for the "DRYRUN RESULT: ..." completion
        line (acceptance criterion: exact format steps=<n> actions=<n> would-reboot=<n>).
      - Initialize-StateForRun's -DryRun bypass: must never prompt and must never resume/match
        against existing (possibly stale) shadow state -- it always returns a fresh state.

    Out of scope, and why (not skipped arbitrarily -- verified unavailable first):
    Invoke-ComputerNameStep, Invoke-CreateLocalAdminStep, New-ConfiguredLocalUserPassword, and
    Add-UserToConfiguredGroups all guard mutating calls to Windows-only cmdlets
    (Rename-Computer, New-LocalUser, Get-LocalUser, Add-LocalGroupMember,
    Get-LocalGroupMember) that do not exist at all on this pwsh 7/Linux sandbox -- Get-Command
    does not find them, so Pester has no real command shape to Mock against, and every branch
    around them is either "call the real Windows cmdlet" (untestable here by definition) or a
    Write-DryRunAction call (already covered generically by Tests\Unit\DryRun.Tests.ps1). These
    were instead verified by manual code trace: every mutating call site in Start-Deployment.ps1
    is wrapped in `if (Test-DeploymentDryRun) { Write-DryRunAction ... } else { <original
    mutating call, byte-for-byte> }`, confirmed via diff review against origin/main.
#>

BeforeAll {
    $script:CommonScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Common.ps1'
    $script:StartDeploymentPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Start-Deployment.ps1'

    # Common.ps1 has no side effects at dot-source time beyond variable/function setup (see
    # Common.Tests.ps1's BeforeAll), so it is safe to dot-source directly here to provide the
    # functions Initialize-StateForRun calls internally (New-DeploymentState,
    # New-DeploymentRunId, Read-DeploymentState, Write-DeploymentState,
    # Test-StateMatchesDevice, ...). Dry-run mode itself is irrelevant to the two functions
    # under test (Get-DryRunSummaryLine takes plain ints; Initialize-StateForRun's -DryRun
    # parameter is passed explicitly per test), so the ambient env var is simply cleared for a
    # clean, deterministic baseline.
    Remove-Item Env:\OSIT_DEPLOYMENT_DRYRUN -ErrorAction SilentlyContinue
    . $script:CommonScriptPath

    function Get-StartDeploymentFunctionScriptBlock {
        <#
            Extracts a single named function definition out of Start-Deployment.ps1 via the
            PowerShell language parser/AST and returns it as a standalone scriptblock. Kept as
            a plain (non dot-sourced) helper function on purpose: dot-sourcing *inside* a
            function only defines things in that function's own scope, not the caller's, so
            the actual ". $scriptBlock" that brings the function into scope has to happen at
            the BeforeAll level itself, not inside a nested helper.
        #>
        param(
            [Parameter(Mandatory = $true)][string]$Name
        )

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:StartDeploymentPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "Start-Deployment.ps1 failed to parse: $($parseErrors[0].Message)"
        }

        $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        if (-not $functionAst) {
            throw "Function '$Name' was not found in Start-Deployment.ps1."
        }

        return [scriptblock]::Create($functionAst.Extent.Text)
    }

    . (Get-StartDeploymentFunctionScriptBlock -Name 'Get-DryRunSummaryLine')
    . (Get-StartDeploymentFunctionScriptBlock -Name 'Initialize-StateForRun')
}

Describe 'Get-DryRunSummaryLine (T06 completion summary line)' {
    It 'formats steps/actions/reboots into the exact "DRYRUN RESULT: ..." line' {
        Get-DryRunSummaryLine -StepCount 17 -ActionCount 5 -RebootCount 1 | Should -Be 'DRYRUN RESULT: steps=17 actions=5 would-reboot=1'
    }

    It 'handles a dry run that logged no actions and no reboots' {
        Get-DryRunSummaryLine -StepCount 17 -ActionCount 0 -RebootCount 0 | Should -Be 'DRYRUN RESULT: steps=17 actions=0 would-reboot=0'
    }

    It 'adversarial: a zero step count still produces a well-formed line (no throw, no blank fields)' {
        Get-DryRunSummaryLine -StepCount 0 -ActionCount 0 -RebootCount 0 | Should -Be 'DRYRUN RESULT: steps=0 actions=0 would-reboot=0'
    }

    It 'adversarial: large counts are not truncated or reformatted (e.g. no thousands separators)' {
        Get-DryRunSummaryLine -StepCount 17 -ActionCount 12345 -RebootCount 9999 | Should -Be 'DRYRUN RESULT: steps=17 actions=12345 would-reboot=9999'
    }
}

Describe 'Initialize-StateForRun -DryRun bypass (T06 acceptance: never prompt, never resume stale shadow state)' {
    BeforeEach {
        # Get-DeviceIdentity is Windows-only (Get-CimInstance); mocked the same way
        # Common.Tests.ps1 and DryRun.Tests.ps1 already do, to isolate the pure state-selection
        # logic under test from that dependency.
        Mock Get-DeviceIdentity {
            @{
                serial_number   = 'TEST-SERIAL-DRYRUN'
                uuid            = '22222222-2222-2222-2222-222222222222'
                computer_name   = 'DRYRUNPC'
                manufacturer    = 'Dell'
                model           = 'Latitude'
                windows_caption = 'Windows 11 Pro'
                windows_version = '10.0.22621'
                windows_build   = '22621'
            }
        }

        $script:StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        $script:ShadowStatePath = Join-Path $script:StateDir 'deployment_state.dryrun.json'
    }

    It 'returns a brand-new state when no shadow state file exists yet' {
        $result = Initialize-StateForRun -StatePath $script:ShadowStatePath -Reset:$false -NonInteractive:$false -DryRun:$true
        $result | Should -Not -BeNullOrEmpty
        $result.completed_steps.Count | Should -Be 0
        $result.device_serial_number | Should -Be 'TEST-SERIAL-DRYRUN'
    }

    It 'ignores an existing shadow state file that matches this device and starts fresh anyway (does not resume)' {
        $matching = New-DeploymentState -RunId 'stale-matching-run'
        $matching.completed_steps = @('NetworkDrivers', 'MspWifiSetup')
        Write-DeploymentState -State $matching -StatePath $script:ShadowStatePath

        $result = Initialize-StateForRun -StatePath $script:ShadowStatePath -Reset:$false -NonInteractive:$false -DryRun:$true
        $result.deployment_run_id | Should -Not -Be 'stale-matching-run'
        $result.completed_steps.Count | Should -Be 0
    }

    It 'ignores an existing shadow state file that does NOT match this device, without throwing or prompting' {
        $mismatched = New-DeploymentState -RunId 'stale-mismatched-run'
        $mismatched.device_serial_number = 'SOME-OTHER-DEVICE'
        $mismatched.device_uuid = '99999999-9999-9999-9999-999999999999'
        Write-DeploymentState -State $mismatched -StatePath $script:ShadowStatePath

        # Outside dry-run, a mismatched device under -NonInteractive throws here (see the
        # control test below); the -DryRun bypass must return cleanly and quietly instead.
        { Initialize-StateForRun -StatePath $script:ShadowStatePath -Reset:$false -NonInteractive:$false -DryRun:$true } | Should -Not -Throw
        $result = Initialize-StateForRun -StatePath $script:ShadowStatePath -Reset:$false -NonInteractive:$false -DryRun:$true
        $result.deployment_run_id | Should -Not -Be 'stale-mismatched-run'
    }

    It 'ignores -Reset entirely (the -DryRun bypass wins and needs no archive copy)' {
        $existing = New-DeploymentState -RunId 'stale-run'
        Write-DeploymentState -State $existing -StatePath $script:ShadowStatePath

        Initialize-StateForRun -StatePath $script:ShadowStatePath -Reset:$true -NonInteractive:$false -DryRun:$true | Out-Null

        # The real -Reset path copies the previous state to "<path>.archive-*.json"; the
        # -DryRun bypass returns before any of that archival logic runs.
        $archives = @(Get-ChildItem -Path $script:StateDir -Filter '*.archive-*.json' -ErrorAction SilentlyContinue)
        $archives.Count | Should -Be 0
    }

    It 'control case: confirms the non-dry-run mismatched-device path really would throw under -NonInteractive (proves the bypass is load-bearing)' {
        $mismatched = New-DeploymentState -RunId 'stale-mismatched-run-2'
        $mismatched.device_serial_number = 'SOME-OTHER-DEVICE-2'
        $mismatched.device_uuid = '88888888-8888-8888-8888-888888888888'
        Write-DeploymentState -State $mismatched -StatePath $script:ShadowStatePath

        { Initialize-StateForRun -StatePath $script:ShadowStatePath -Reset:$false -NonInteractive:$true -DryRun:$false } | Should -Throw
    }
}
