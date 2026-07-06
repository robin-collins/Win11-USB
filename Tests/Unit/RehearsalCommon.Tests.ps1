#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the T11 VM lifecycle additions to Test\Rehearsal\RehearsalCommon.ps1
    (FABLE_TASKS.md T11): New-RehearsalVm, Checkpoint-Rehearsal, Remove-RehearsalVm, and their
    helpers Assert-HyperVAvailable / Get-RehearsalVmPaths / Get-RehearsalHgsGuardian.

    Scope, deliberately narrow: almost everything T11 adds calls real Hyper-V cmdlets
    (New-VM, Add-VMHardDiskDrive, Set-VMKeyProtector, Checkpoint-VM, ...) that simply do not
    exist outside a Windows host with the Hyper-V feature enabled -- there is no meaningful way
    to unit test VM creation, vTPM/Secure Boot configuration, or checkpoint/teardown behaviour
    on this toolkit's Linux dev/CI sandbox without mocking essentially the entire Hyper-V
    cmdlet surface, which would test the mocks rather than the code. That exercise belongs on a
    real Windows/Hyper-V bench host (see FABLE_TASKS.md T11's acceptance criteria), not here.

    Two things ARE meaningfully testable without Hyper-V, and are covered below:
      - Get-RehearsalVmPaths is pure path/string logic (see its own comment-based help) with no
        Hyper-V dependency at all.
      - Assert-HyperVAvailable's fail-fast behaviour is exercised for real (not mocked): this
        sandbox genuinely lacks every Hyper-V cmdlet, so calling it -- directly, or indirectly
        via New-RehearsalVm / Checkpoint-Rehearsal / Remove-RehearsalVm -- throws for real here,
        which doubles as a regression check that each public function still calls the guard
        first, before doing anything else.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\Test\Rehearsal\RehearsalCommon.ps1')
}

Describe 'Get-RehearsalVmPaths' {
    # Deliberately platform-neutral working directories (no hard-coded drive letter): this
    # suite runs on pwsh 7/Linux (see Tests\README.md), where Join-Path treats a Windows-style
    # 'C:\...' root as a PSDrive lookup that does not exist here, not as a literal path segment.
    # RehearsalCommon.ps1 only ever runs on Windows in production, but Get-RehearsalVmPaths
    # itself is pure Join-Path composition and behaves identically given any valid root -- so a
    # '/tmp/...'-style root exercises the exact same code path as a real 'C:\...' one would.

    It 'derives VmFolder as WorkingDirectory\VmName' {
        $paths = Get-RehearsalVmPaths -VmName 'Rehearsal-Standard-20260706-120000' -WorkingDirectory '/tmp/DeploymentRehearsal'
        $paths.VmFolder | Should -Be (Join-Path '/tmp/DeploymentRehearsal' 'Rehearsal-Standard-20260706-120000')
    }

    It 'derives OsDiskPath as VmFolder plus "VmName-OS.vhdx"' {
        $paths = Get-RehearsalVmPaths -VmName 'Rehearsal-Standard-20260706-120000' -WorkingDirectory '/tmp/DeploymentRehearsal'
        $expected = Join-Path (Join-Path '/tmp/DeploymentRehearsal' 'Rehearsal-Standard-20260706-120000') 'Rehearsal-Standard-20260706-120000-OS.vhdx'
        $paths.OsDiskPath | Should -Be $expected
    }

    It 'is a pure function of its two inputs: calling it twice with the same arguments returns identical paths' {
        $first = Get-RehearsalVmPaths -VmName 'Rehearsal-ResumeKill-1' -WorkingDirectory '/tmp/DeploymentRehearsal'
        $second = Get-RehearsalVmPaths -VmName 'Rehearsal-ResumeKill-1' -WorkingDirectory '/tmp/DeploymentRehearsal'
        $first.VmFolder | Should -Be $second.VmFolder
        $first.OsDiskPath | Should -Be $second.OsDiskPath
    }

    It 'produces different VmFolder values for different VM names under the same working directory' {
        $a = Get-RehearsalVmPaths -VmName 'Rehearsal-Standard-1' -WorkingDirectory '/tmp/DeploymentRehearsal'
        $b = Get-RehearsalVmPaths -VmName 'Rehearsal-Standard-2' -WorkingDirectory '/tmp/DeploymentRehearsal'
        $a.VmFolder | Should -Not -Be $b.VmFolder
    }

    It 'throws when -VmName is not supplied (adversarial: missing mandatory parameter)' {
        { Get-RehearsalVmPaths -WorkingDirectory '/tmp/DeploymentRehearsal' } | Should -Throw
    }

    It 'throws when -WorkingDirectory is not supplied (adversarial: missing mandatory parameter)' {
        { Get-RehearsalVmPaths -VmName 'Rehearsal-Standard-1' } | Should -Throw
    }
}

Describe 'Assert-HyperVAvailable' {
    # This suite runs on pwsh 7/Linux (see Tests\README.md), which has none of the Hyper-V
    # module's cmdlets under any circumstance -- so these are real assertions about real
    # behaviour on this platform, not a simulation of a Windows host missing the feature.

    It 'throws when the Hyper-V module is not present' {
        { Assert-HyperVAvailable } | Should -Throw
    }

    It 'names at least one missing cmdlet and points at Test-RehearsalPrerequisites in the error' {
        { Assert-HyperVAvailable } | Should -Throw -ExpectedMessage '*Hyper-V*Test-RehearsalPrerequisites*'
    }
}

Describe 'New-RehearsalVm, Checkpoint-Rehearsal, and Remove-RehearsalVm fail fast without Hyper-V' {
    # Regression guard, not a behavioural test of VM lifecycle logic: proves each public T11
    # function still calls Assert-HyperVAvailable before touching any Hyper-V cmdlet, rather
    # than getting partway through (e.g. creating a folder, or throwing PowerShell's generic
    # "term not recognized" error) before failing.

    It 'New-RehearsalVm throws the Hyper-V-unavailable error, not a generic "command not found" error' {
        { New-RehearsalVm -VmName 'Rehearsal-Test' -IsoPath '/nonexistent.iso' -MediaVhdxPath '/nonexistent.vhdx' -WorkingDirectory '/tmp' } |
            Should -Throw -ExpectedMessage '*Hyper-V*'
    }

    It 'Checkpoint-Rehearsal throws the Hyper-V-unavailable error' {
        { Checkpoint-Rehearsal -VmName 'Rehearsal-Test' -CheckpointName 'pre-boot' } | Should -Throw -ExpectedMessage '*Hyper-V*'
    }

    It 'Remove-RehearsalVm throws the Hyper-V-unavailable error' {
        { Remove-RehearsalVm -VmName 'Rehearsal-Test' } | Should -Throw -ExpectedMessage '*Hyper-V*'
    }

    It 'Remove-RehearsalVm -KeepVm short-circuits before the Hyper-V guard and does not throw' {
        # -KeepVm is a complete no-op by design (see the function's .DESCRIPTION) -- it must
        # return cleanly even on a platform with no Hyper-V support at all, since a caller
        # requesting -KeepVm is explicitly asking for nothing to happen.
        { Remove-RehearsalVm -VmName 'Rehearsal-Test' -KeepVm } | Should -Not -Throw
    }
}
