#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the Complete step's dry-run credential-scrub preview in
    Deployment\Scripts\Start-Deployment.ps1 (FABLE_TASKS.md T07c).

    T07c previously had no dedicated test file (unlike its siblings T07a/DryRunEnvironmentSteps
    and T07b/DryRunInstallSteps), and a real bug went undetected as a result: the Complete
    branch's dry-run scrub-preview calls Write-DryRunAction (which only appends to $State in
    memory) but never called Write-DeploymentState to persist that before returning. The
    orchestrator's step loop re-reads state from disk immediately after Invoke-DeploymentStep
    returns (to check reboot_pending), discarding the in-memory object -- so the entire
    scrub-preview audit trail silently vanished from state.dryrun_actions (and therefore from
    the T08 dry-run summary report) even though it still printed to the log.

    Invoke-DeploymentStep is extracted via the same AST-based technique
    Tests\Unit\StartDeploymentDryRun.Tests.ps1 (T06) already established, rather than
    dot-sourcing the whole orchestrator script (which has top-level side-effecting code that
    must never run just because a unit test file was collected). Get-ConfigValue (also defined
    in Start-Deployment.ps1, used internally by the Complete branch) is extracted the same way.

    The Complete branch's two genuinely Windows-only touchpoints (a registry read for Winlogon
    values, and netsh.exe for the WLAN profile check, both via functions this suite mocks) are
    mocked so the rest of the branch -- and specifically the persistence bug above -- can be
    exercised for real on every platform this suite runs on, including ubuntu-latest CI.
#>

BeforeAll {
    $script:CommonScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Common.ps1'
    $script:StartDeploymentPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Start-Deployment.ps1'

    Remove-Item Env:\OSIT_DEPLOYMENT_DRYRUN -ErrorAction SilentlyContinue
    $env:OSIT_DEPLOYMENT_DRYRUN = '1'
    . $script:CommonScriptPath

    function Get-StartDeploymentFunctionScriptBlock {
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

    . (Get-StartDeploymentFunctionScriptBlock -Name 'Get-ConfigValue')
    . (Get-StartDeploymentFunctionScriptBlock -Name 'Invoke-DeploymentStep')

    # The real branch reads Winlogon values via Get-ItemProperty against an HKLM: path (not
    # present on non-Windows platforms) and checks for an existing WLAN profile via
    # Invoke-ExternalCommand/netsh.exe (a real Windows-only binary). Neither capability is what
    # this suite is testing -- the persistence bug is orthogonal to what these two calls find --
    # so both are mocked to a deterministic "nothing found" result on every platform.
    Mock Get-ItemProperty { $null }
    Mock Invoke-ExternalCommand { @{ exit_code = 1; stdout = ''; stderr = '' } }
}

Describe 'Invoke-DeploymentStep -Step Complete, dry-run scrub preview (T07c)' {
    BeforeEach {
        $script:StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        $script:StatePath = Join-Path $script:StateDir 'deployment_state.dryrun.json'

        $script:State = New-DeploymentState
        Write-DeploymentState -State $script:State -StatePath $script:StatePath
        $script:Config = @{}
    }

    It 'regression: persists the scrub-preview dryrun_actions to disk before returning, surviving an immediate re-read' {
        # Mirrors the orchestrator's own step loop exactly: call the step, then immediately
        # re-read state from disk the way Start-Deployment.ps1's main loop does right after
        # Invoke-DeploymentStep returns (to check reboot_pending). Before the fix, this re-read
        # would show zero dryrun_actions for the Complete step even though several
        # Write-DryRunAction calls had just run.
        Invoke-DeploymentStep -Step 'Complete' -UsbRoot $script:StateDir -State $script:State -StatePath $script:StatePath -Config $script:Config
        $reread = Read-DeploymentState -StatePath $script:StatePath

        $completeActions = @($reread.dryrun_actions | Where-Object { $_.step -eq 'Complete' })
        $completeActions.Count | Should -BeGreaterThan 0 -Because 'the Complete step''s scrub-preview must reach disk, not just the log, so the T08 summary report can aggregate it'
    }

    It 'logs a would-scrub/not-present line for every cached unattend file path, every Winlogon value, the local handover .env, and the WLAN profile' {
        Invoke-DeploymentStep -Step 'Complete' -UsbRoot $script:StateDir -State $script:State -StatePath $script:StatePath -Config $script:Config
        $reread = Read-DeploymentState -StatePath $script:StatePath
        $completeActions = @($reread.dryrun_actions | Where-Object { $_.step -eq 'Complete' })

        # 5 unattend cache paths + 3 Winlogon values + 1 handover .env + 1 WLAN profile = 10.
        $completeActions.Count | Should -Be 10
        # @(...) wrap required: each dryrun_actions entry is a Hashtable (Read-DeploymentState's
        # ConvertTo-PlainHashtable), and Hashtable has its own .Count (key count). When exactly
        # one item matches, Where-Object unwraps to that single Hashtable rather than a
        # 1-element array, so an unwrapped .Count here would silently read the matched action's
        # 4 keys (timestamp/step/action/data) instead of "how many actions matched".
        @($completeActions | Where-Object { $_.action -like '*handover*.env*' }).Count | Should -Be 1
        @($completeActions | Where-Object { $_.action -like '*WLAN profile*' }).Count | Should -Be 1
    }

    It 'does not throw and returns before the real (non-dry-run) scrub/removal branch' {
        { Invoke-DeploymentStep -Step 'Complete' -UsbRoot $script:StateDir -State $script:State -StatePath $script:StatePath -Config $script:Config } | Should -Not -Throw
    }
}
