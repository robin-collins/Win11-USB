<#
    .SYNOPSIS
        Entry point for the Tier 1 Hyper-V rehearsal harness: boots a Gen-2 VM (vTPM + Secure
        Boot) from a Windows 11 ISO plus generated USB-equivalent media and runs the full
        unattended deployment flow end-to-end.

    .DESCRIPTION
        Host-side tooling only. Run this on a technician's Windows 10/11 Pro/Enterprise/
        Education bench machine with Hyper-V enabled -- never on a client notebook, and this
        folder is never copied onto a production deployment USB.

        This script (T09) provides the parameter surface and prerequisite gate only. Later
        tasks fill in the rehearsal body in RehearsalCommon.ps1 and wire it in here:
          - T10 New-RehearsalMedia       : build the "USB" VHDX (label 1S-WIN11) and run the
                                            real Initialize-UsbDeployment.ps1 against it.
          - T11 New-RehearsalVm /
                Remove-RehearsalVm /
                Checkpoint-Rehearsal      : Gen-2 VM lifecycle, vTPM + Secure Boot, checkpoints.
          - T12                          : guest monitoring (WinPE heartbeat, PowerShell Direct
                                            polling of deployment_state.json) + artifact harvest.
          - T13 Test-RehearsalResult      : post-run assertion suite, honours -SkipAssertions.
        Until those land, a passing prerequisite check simply prints the resolved rehearsal
        plan and exits 0; no VM is created and no media is built.

    .PARAMETER IsoPath
        Path to the Windows 11 ISO Windows Setup boots from (attached as a virtual DVD drive).

    .PARAMETER WorkingDirectory
        Scratch directory for build artifacts (VHDX staging, rehearsal .env, logs) for this
        run. Defaults to "$env:TEMP\DeploymentRehearsal" (or the platform temp directory if
        $env:TEMP is unset) so multi-gigabyte VHDX files never land inside the git working
        tree. Use a fixed path if you want to inspect or reuse artifacts between runs.

    .PARAMETER Scenario
        Named config overlay under Test\Rehearsal\Scenarios\<name> (defined starting T14).
        Defaults to 'Standard' (wipe on, serial computer naming, one winget app).

    .PARAMETER VmName
        Name of the Hyper-V VM to create. Defaults to "Rehearsal-<Scenario>-<timestamp>" so
        repeated runs never collide with a previous rehearsal's VM.

    .PARAMETER MemoryGB
        Fixed VM memory in GB (dynamic memory is disabled per the T11 design). Default 8.

    .PARAMETER CpuCount
        Virtual CPU count for the VM. Default 4.

    .PARAMETER OsDiskGB
        Size of the dynamic OS VHDX in GB. Default 80. Also used to size the free-disk-space
        prerequisite check (see Test-RehearsalDiskSpace in RehearsalCommon.ps1).

    .PARAMETER TimeoutMinutes
        Overall wall-clock budget for the rehearsal (WinPE + guest deployment + terminal
        detection) before the harness gives up and treats the run as a timeout failure.
        Default 180.

    .PARAMETER KeepVm
        Skip teardown of the VM and its disks after the run (for post-mortem inspection).

    .PARAMETER SkipAssertions
        Skip the T13 post-run assertion suite; still builds media, runs the VM, and harvests
        artifacts.

    .NOTES
        Requires pwsh 7+ on Windows with Hyper-V. Will not run a real rehearsal on this
        toolkit's Linux CI/dev sandbox; Test-RehearsalPrerequisites is designed to fail
        cleanly there instead of throwing (see RehearsalCommon.ps1).
#>

[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive bench-technician CLI harness entry point; the colored console progress/plan output is the primary UX for the person driving a rehearsal run, alongside the structured artifacts written under Test\Rehearsal\Artifacts.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [string]$WorkingDirectory = $(if ($env:TEMP) { Join-Path $env:TEMP 'DeploymentRehearsal' } else { Join-Path ([System.IO.Path]::GetTempPath()) 'DeploymentRehearsal' }),

    [string]$Scenario = 'Standard',

    [string]$VmName = $(if ($Scenario) { 'Rehearsal-{0}-{1}' -f $Scenario, (Get-Date -Format 'yyyyMMdd-HHmmss') } else { 'Rehearsal-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss') }),

    [int]$MemoryGB = 8,

    [int]$CpuCount = 4,

    [int]$OsDiskGB = 80,

    [int]$TimeoutMinutes = 180,

    [switch]$KeepVm,

    [switch]$SkipAssertions
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $scriptRoot 'RehearsalCommon.ps1')

Write-Host ''
Write-Host '=== OSIT Windows 11 Deployment Rehearsal ===' -ForegroundColor Cyan
Write-Host "Scenario:          $Scenario"
Write-Host "VM name:           $VmName"
Write-Host "ISO path:          $IsoPath"
Write-Host "Working directory: $WorkingDirectory"
Write-Host "Memory / CPU:      ${MemoryGB} GB / $CpuCount vCPU"
Write-Host "OS disk:           ${OsDiskGB} GB"
Write-Host "Timeout:           $TimeoutMinutes minutes"
Write-Host "KeepVm:            $($KeepVm.IsPresent)"
Write-Host "SkipAssertions:    $($SkipAssertions.IsPresent)"
Write-Host ''

Write-Host 'Checking prerequisites...' -ForegroundColor Cyan
$prereqResults = Test-RehearsalPrerequisites -IsoPath $IsoPath -WorkingDirectory $WorkingDirectory -VmName $VmName -OsDiskGB $OsDiskGB

foreach ($result in $prereqResults) {
    $color = if ($result.Status -eq 'Pass') { 'Green' } else { 'Red' }
    Write-Host "[$($result.Status)] $($result.Check) - $($result.Message)" -ForegroundColor $color
}

$failedChecks = @($prereqResults | Where-Object { $_.Status -eq 'Fail' })
if ($failedChecks.Count -gt 0) {
    Write-Host ''
    Write-Host "Rehearsal cannot proceed: $($failedChecks.Count) of $($prereqResults.Count) prerequisite check(s) failed." -ForegroundColor Red
    foreach ($failure in $failedChecks) {
        Write-Host " - $($failure.Check): $($failure.Message)" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host 'Fix the items above and re-run this script. No VM or media has been created.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host 'All prerequisites passed.' -ForegroundColor Green
Write-Host ''
Write-Host 'Resolved rehearsal plan:' -ForegroundColor Cyan
[ordered]@{
    Scenario         = $Scenario
    VmName           = $VmName
    IsoPath          = (Resolve-Path -LiteralPath $IsoPath).Path
    WorkingDirectory = $WorkingDirectory
    MemoryGB         = $MemoryGB
    CpuCount         = $CpuCount
    OsDiskGB         = $OsDiskGB
    TimeoutMinutes   = $TimeoutMinutes
    KeepVm           = $KeepVm.IsPresent
    SkipAssertions   = $SkipAssertions.IsPresent
} | Format-Table -AutoSize | Out-String | Write-Host

# TODO(T10): New-RehearsalMedia -WorkingDirectory $WorkingDirectory -Scenario $Scenario
#            -> builds the 16 GB "1S-WIN11" VHDX and runs the real Initialize-UsbDeployment.ps1
#            against it, applying the scenario's config overlay.

# TODO(T11): New-RehearsalVm -VmName $VmName -IsoPath $IsoPath -MediaVhdxPath <from T10>
#            -MemoryGB $MemoryGB -CpuCount $CpuCount -OsDiskGB $OsDiskGB
#            -> Gen-2 VM, vTPM + Secure Boot, SCSI 0/LUN 0 OS disk + LUN 1 media disk,
#            attaches to the 'Default Switch', takes the 'pre-boot' checkpoint.

# TODO(T12): guest monitoring loop (WinPE heartbeat -> PowerShell Direct polling of
#            deployment_state.json) driven by -TimeoutMinutes, plus artifact harvest into
#            Test\Rehearsal\Artifacts\<timestamp>\ on any terminal state.

# TODO(T13): unless -SkipAssertions, Test-RehearsalResult against the harvested artifacts and
#            in-guest state; exit non-zero with the failed-assertion summary on stderr if any
#            assertion fails.

# TODO(T11): Remove-RehearsalVm -VmName $VmName unless -KeepVm.

Write-Host 'T09 scaffold complete: prerequisites passed and the rehearsal plan above is resolved.' -ForegroundColor Green
Write-Host 'Media build, VM lifecycle, guest monitoring, and assertions are implemented by T10-T13; this scaffold stops here.' -ForegroundColor Yellow
exit 0
