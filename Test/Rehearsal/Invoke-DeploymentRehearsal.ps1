<#
    .SYNOPSIS
        Entry point for the Tier 1 Hyper-V rehearsal harness: boots a Gen-2 VM (vTPM + Secure
        Boot) from a Windows 11 ISO plus generated USB-equivalent media and runs the full
        unattended deployment flow end-to-end.

    .DESCRIPTION
        Host-side tooling only. Run this on a technician's Windows 10/11 Pro/Enterprise/
        Education bench machine with Hyper-V enabled -- never on a client notebook, and this
        folder is never copied onto a production deployment USB.

        Built up in stages (RehearsalCommon.ps1, RehearsalMonitoring.ps1, RehearsalAssertions.ps1
        each add their own layer, all dot-sourced by this entry point):
          - T09 provided the parameter surface and prerequisite gate.
          - T10 New-RehearsalMedia       : build the "USB" VHDX (label 1S-WIN11) and run the
                                            real Initialize-UsbDeployment.ps1 against it.
          - T11 New-RehearsalVm /
                Remove-RehearsalVm /
                Checkpoint-Rehearsal      : Gen-2 VM lifecycle, vTPM + Secure Boot, checkpoints.
          - T12 Invoke-RehearsalMonitoring: guest monitoring (WinPE heartbeat, PowerShell Direct
                                            polling of deployment_state.json) + artifact harvest.
          - T13 Test-RehearsalResult      : post-run assertion suite (completion, credential
                                            scrub, identity, config effects, disk layout); the
                                            exit code below reflects its Passed verdict unless
                                            -SkipAssertions was given, in which case the exit
                                            code reflects only T12's own terminal-state result.

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
        Skip the T13 post-run assertion suite (Test-RehearsalResult is never called); still
        builds media, runs the VM, and harvests artifacts. The exit code then reflects only
        T12's own terminal-state classification instead of a full assertion pass.

    .NOTES
        Requires pwsh 7+ on Windows with Hyper-V. Will not run a real rehearsal on this
        toolkit's Linux CI/dev sandbox; Test-RehearsalPrerequisites is designed to fail
        cleanly there instead of throwing (see RehearsalCommon.ps1).
#>

[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive bench-technician CLI harness entry point; the colored console progress/plan output is the primary UX for the person driving a rehearsal run, alongside the structured artifacts written under Test\Rehearsal\Artifacts.')]
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Building the PSCredential passed to Invoke-RehearsalMonitoring for PowerShell Direct: media.OsitPassword is a fresh, harness-generated rehearsal-only password (New-RehearsalMedia), never technician/user-typed input, so ConvertTo-SecureString is the required bridge into New-Object PSCredential, not a security downgrade.')]
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
. (Join-Path $scriptRoot 'RehearsalMonitoring.ps1')
. (Join-Path $scriptRoot 'RehearsalAssertions.ps1')

# New-RehearsalMedia (RehearsalCommon.ps1) dot-sources Deployment\Scripts\Common.ps1 lazily,
# but it does so *inside its own function scope*, which is torn down when that function
# returns -- so ConvertTo-PlainHashtable (used below) is not reliably available here just
# because New-RehearsalMedia happened to load it internally. Loaded explicitly at this
# script's own top level instead, the same lazy-if-not-already-loaded way RehearsalCommon.ps1
# itself does it.
if (-not (Test-RehearsalCommandAvailable -Name 'ConvertTo-PlainHashtable')) {
    . (Join-Path $script:RehearsalRepoRoot 'Deployment\Scripts\Common.ps1')
}

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

Write-Host 'Building rehearsal media (T10)...' -ForegroundColor Cyan
$media = New-RehearsalMedia -WorkingDirectory $WorkingDirectory -Scenario $Scenario
Write-Host "Rehearsal media built: $($media.VhdxPath)" -ForegroundColor Green

Write-Host 'Creating rehearsal VM (T11)...' -ForegroundColor Cyan
$vm = New-RehearsalVm -VmName $VmName -IsoPath $IsoPath -MediaVhdxPath $media.VhdxPath -WorkingDirectory $WorkingDirectory -MemoryGB $MemoryGB -CpuCount $CpuCount -OsDiskGB $OsDiskGB
Write-Host "Rehearsal VM created: $($vm.VmName)" -ForegroundColor Green

$exitCode = 1
try {
    Write-Host "Taking 'pre-boot' checkpoint..." -ForegroundColor Cyan
    Checkpoint-Rehearsal -VmName $VmName -CheckpointName 'pre-boot'

    Write-Host 'Starting the VM...' -ForegroundColor Cyan
    Start-VM -Name $VmName

    # OSIT credential for PowerShell Direct (T12): the throwaway per-run password
    # New-RehearsalMedia (T10) generated and wrote into the media's own .env, returned here so
    # the harness never needs to re-mount the (now dismounted) media VHDX just to read it back.
    $ositSecurePassword = ConvertTo-SecureString -String $media.OsitPassword -AsPlainText -Force
    $ositCredential = New-Object System.Management.Automation.PSCredential('OSIT', $ositSecurePassword)

    $isHandoverScenario = $false
    if ($media.MergedConfig -and $media.MergedConfig.ContainsKey('local_deployment_handover') -and $media.MergedConfig.local_deployment_handover) {
        $handoverConfig = ConvertTo-PlainHashtable $media.MergedConfig.local_deployment_handover
        $isHandoverScenario = [bool]($handoverConfig.ContainsKey('enabled') -and $handoverConfig.enabled)
    }

    # T14: a scenario may declare a failure-injection descriptor (ResumeKill, Handover) in its
    # own Test\Rehearsal\Scenarios\<name>\scenario.json; $null (Standard, NoWipe,
    # AdditionalUsers) means Watch-RehearsalDeployment injects nothing.
    $failureInjection = Get-RehearsalScenarioFailureInjection -Scenario $Scenario
    if ($failureInjection) {
        Write-Host "Scenario '$Scenario' declares a failure injection: $($failureInjection.Action) on '$($failureInjection.TriggerStep)' $($failureInjection.TriggerWhen)." -ForegroundColor Yellow
    }

    Write-Host 'Monitoring the rehearsal (T12: Setup/WinPE, then guest deployment progress)...' -ForegroundColor Cyan
    $artifactRoot = Join-Path $scriptRoot 'Artifacts'
    $monitorResult = Invoke-RehearsalMonitoring -VmName $VmName -Credential $ositCredential -ArtifactRoot $artifactRoot -TimeoutMinutes $TimeoutMinutes -IsHandoverScenario $isHandoverScenario -FailureInjection $failureInjection -MediaVhdxPath $media.VhdxPath

    Write-Host ''
    Write-Host "Rehearsal monitoring result: $($monitorResult.Result) (phase: $($monitorResult.Phase))" -ForegroundColor $(if ($monitorResult.Result -eq 'Success') { 'Green' } else { 'Red' })
    Write-Host "Artifacts harvested to: $($monitorResult.ArtifactFolder)"

    if ($SkipAssertions) {
        # -SkipAssertions: keep the pre-T13 behaviour exactly -- exit code reflects only T12's
        # own terminal-state classification, and Test-RehearsalResult is never called.
        Write-Host 'SkipAssertions was specified: skipping the T13 post-run assertion suite.' -ForegroundColor Yellow
        $exitCode = if ($monitorResult.Result -eq 'Success') { 0 } else { 1 }
    } else {
        Write-Host ''
        Write-Host 'Running post-run assertion suite (T13)...' -ForegroundColor Cyan
        $assertionResult = Test-RehearsalResult -VmName $VmName -Credential $ositCredential -ArtifactFolder $monitorResult.ArtifactFolder -MergedConfig $media.MergedConfig -DiskNumber ([int]$media.MergedConfig.wipe_repartition_disk_id) -Scenario $Scenario

        Write-Host ''
        foreach ($assertion in $assertionResult.Results) {
            $assertionColor = if ($assertion.Status -eq 'Pass') { 'Green' } else { 'Red' }
            Write-Host "[$($assertion.Status)] $($assertion.Name) - $($assertion.Message)" -ForegroundColor $assertionColor
        }
        Write-Host ''
        Write-Host "Assertion report written to: $($assertionResult.ReportPath)"
        Write-Host "Assertions: $($assertionResult.Summary.Passed)/$($assertionResult.Summary.Total) passed" -ForegroundColor $(if ($assertionResult.Passed) { 'Green' } else { 'Red' })

        # Exit contract (FABLE_TASKS.md T13): exit 0 only when every assertion passed. On any
        # failure, the failed-assertion summary goes to stderr (via [Console]::Error, not
        # Write-Error -- $ErrorActionPreference is 'Stop' at the top of this script, and
        # Write-Error would be promoted to a terminating error and abort before `exit $exitCode`
        # below ever runs) so a CI/scheduled-task caller can capture it without parsing stdout.
        if ($assertionResult.Passed) {
            $exitCode = 0
        } else {
            $exitCode = 1
            $failedAssertions = @($assertionResult.Results | Where-Object { $_.Status -ne 'Pass' })
            [Console]::Error.WriteLine('Rehearsal FAILED: one or more post-run assertions did not pass.')
            foreach ($failure in $failedAssertions) {
                [Console]::Error.WriteLine(" - $($failure.Name): $($failure.Message)")
            }
        }
    }
} finally {
    if ($KeepVm) {
        Write-Host 'KeepVm was specified: leaving the VM and its disks in place for inspection.' -ForegroundColor Yellow
    } else {
        Write-Host 'Tearing down the rehearsal VM...' -ForegroundColor Cyan
        try {
            Remove-RehearsalVm -VmName $VmName -VmFolder $vm.VmFolder -MediaVhdxPath $media.VhdxPath -KeepVm:$KeepVm
        } catch {
            Write-Warning "Remove-RehearsalVm failed (VM/disks may need manual cleanup): $($_.Exception.Message)"
        }
    }
}

exit $exitCode
