<#
    .SYNOPSIS
        One lifecycle script for the manual VHD-boot test cycle a technician runs: refresh the
        bootable "1S-WIN11" VHD from this repo's current state and boot a fresh test VM from it
        (default), stop that VM and mount both of its disks on the host to read the deployment
        logs (-Finalize), then tear everything down again (-Destroy).

    .DESCRIPTION
        Three mutually exclusive phases over the same VM (-Finalize and -Destroy may not be
        combined):

        Default (no switch) -- provision and boot. Removes any leftover VM/folder named -VmName
        first (the behaviour Invoke-VhdBootTestCycle.ps1 gates behind -Force is unconditional
        here: this script owns the whole lifecycle, so a stale VM from its own previous cycle is
        never worth keeping -- and a still-running one holds the 1S-WIN11 VHD open, which would
        make the refresh fail), then refreshes -VhdPath via Update-VhdBootMedia.ps1, then creates
        and starts a fresh Gen-2 VM via New-VhdBootTestVm.ps1. Watch the deployment run via
        Hyper-V Manager or vmconnect.exe.

        -Finalize -- stop the VM (gracefully if the guest cooperates, hard power-off otherwise)
        and mount both its OS VHDX and the 1S-WIN11 media VHD on the host, reporting where the
        deployment/Setup logs live on each. The disks deliberately STAY mounted afterwards so the
        logs can be read at leisure; run -Destroy when done.

        -Destroy -- dismount both disks, remove the VM and its own working folder. The 1S-WIN11
        VHD file itself (-VhdPath) is never deleted, moved, or otherwise touched beyond
        dismounting: it is the reusable boot media the next cycle refreshes in place.

    .PARAMETER VmName
        Name of the Hyper-V test VM this lifecycle manages. Defaults to '1S-WIN11-VhdBootTest',
        matching New-VhdBootTestVm.ps1/Invoke-VhdBootTestCycle.ps1, so the three phases compose
        with those scripts' own defaults.

    .PARAMETER VhdPath
        Path to the bootable "1S-WIN11" VHD (Windows Setup media plus the deployment toolkit).
        Defaults to Deployment\VHD\1S-WIN11.vhd beside this repository. Refreshed in the default
        phase, mounted read-back in -Finalize, dismounted (never deleted) in -Destroy.

    .PARAMETER WorkingDirectory
        Scratch directory the VM's own folder (configuration, OS disk) lives under. Defaults to
        Test\Rehearsal\VhdBootVms beside this repository. All three phases derive the VM folder
        as <WorkingDirectory>\<VmName>, so pass the same value to every phase of one cycle.

    .PARAMETER Finalize
        Stop the VM and mount its OS disk plus the 1S-WIN11 media VHD for log reading. Mutually
        exclusive with -Destroy.

    .PARAMETER Destroy
        Dismount both disks, remove the VM and its working folder. Preserves -VhdPath itself.
        Mutually exclusive with -Finalize.

    .PARAMETER SkipValidation
        Default phase only: passed through to Update-VhdBootMedia.ps1 to skip
        Validate-Unattend.ps1 against the regenerated Autounattend.xml.

    .PARAMETER OsDiskGB
        Default phase only: passed through to New-VhdBootTestVm.ps1. Default 120.

    .PARAMETER MemoryGB
        Default phase only: passed through to New-VhdBootTestVm.ps1. Default 8.

    .PARAMETER CpuCount
        Default phase only: passed through to New-VhdBootTestVm.ps1. Default 4.

    .PARAMETER SwitchName
        Default phase only: passed through to New-VhdBootTestVm.ps1. Default 'Default Switch'.

    .PARAMETER SecureBootTemplate
        Default phase only: passed through to New-VhdBootTestVm.ps1. Default 'MicrosoftWindows'.

    .PARAMETER DisableSecureBoot
        Default phase only: passed through to New-VhdBootTestVm.ps1. See that script's own
        parameter help for when this is required (a VHD built from Rufus's UEFI:NTFS bridge
        loader).

    .PARAMETER Start
        Default phase only: passed through to New-VhdBootTestVm.ps1. Default $true.

    .EXAMPLE
        .\Test\Rehearsal\Invoke-VhdVmDeploymentTest.ps1 -DisableSecureBoot

        Refreshes Deployment\VHD\1S-WIN11.vhd from the current repo, removes any stale
        '1S-WIN11-VhdBootTest' VM, then creates and starts a fresh one booting from the
        refreshed VHD.

    .EXAMPLE
        .\Test\Rehearsal\Invoke-VhdVmDeploymentTest.ps1 -Finalize

        After watching the deployment run to completion: stops the VM and mounts both its OS
        disk and the 1S-WIN11 media VHD on this host, reporting which deployment/Setup log
        locations exist on each. The disks stay mounted for reading.

    .EXAMPLE
        .\Test\Rehearsal\Invoke-VhdVmDeploymentTest.ps1 -Destroy

        Dismounts both disks, removes the VM and its working folder. The 1S-WIN11 VHD file
        itself is preserved for the next cycle.

    .NOTES
        Requires pwsh 7+ on Windows with the Hyper-V feature enabled and an elevated session.
        Cannot be executed in a Linux sandbox with no Hyper-V: every phase depends on
        Mount-VHD/Dismount-VHD and the VM cmdlets against a real Windows host with a pre-built
        "1S-WIN11" VHD.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Colored technician-facing progress output, matching Initialize-UsbDeployment.ps1/New-VhdBootTestVm.ps1''s existing convention for this kind of interactive CLI tooling.')]
[CmdletBinding()]
param(
    [string]$VmName = '1S-WIN11-VhdBootTest',
    [string]$VhdPath,
    [string]$WorkingDirectory,
    [switch]$Finalize,
    [switch]$Destroy,
    [switch]$SkipValidation,
    [ValidateRange(1, [int]::MaxValue)][int]$OsDiskGB = 120,
    [ValidateRange(1, [int]::MaxValue)][int]$MemoryGB = 8,
    [ValidateRange(1, [int]::MaxValue)][int]$CpuCount = 4,
    [string]$SwitchName = 'Default Switch',
    [ValidateSet('MicrosoftWindows', 'MicrosoftUEFICertificateAuthority')]
    [string]$SecureBootTemplate = 'MicrosoftWindows',
    [switch]$DisableSecureBoot,
    [bool]$Start = $true
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'RehearsalCommon.ps1')
# Common.ps1 supplies $script:DeploymentVolumeLabel, the same label Get-UsbRoot looks for in
# production -- so the media-VHD partition search below can never drift from the real one.
. (Join-Path $repoRoot 'Deployment\Scripts\Common.ps1')

if ($Finalize -and $Destroy) {
    throw 'Invoke-VhdVmDeploymentTest: -Finalize and -Destroy are mutually exclusive phases. Run -Finalize first to stop the VM and mount its disks for log reading, then rerun with -Destroy (alone) to tear everything down.'
}

if ([string]::IsNullOrWhiteSpace($VhdPath)) { $VhdPath = Join-Path $repoRoot 'Deployment\VHD\1S-WIN11.vhd' }
if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = Join-Path $repoRoot 'Test\Rehearsal\VhdBootVms' }

Assert-HyperVAvailable

# Assert-HyperVAvailable covers the VM cmdlets only, not the disk-mounting ones every phase of
# this script also needs -- same guard, same reasoning as Update-VhdBootMedia.ps1: one clear,
# actionable failure up front instead of a cryptic "term not recognized" partway through.
foreach ($cmdletName in @('Mount-VHD', 'Dismount-VHD', 'Get-Partition', 'Add-PartitionAccessPath', 'Get-Volume')) {
    if (-not (Test-RehearsalCommandAvailable -Name $cmdletName)) {
        throw "$cmdletName is not available on this platform. Invoke-VhdVmDeploymentTest.ps1 requires Windows 10/11 Pro, Enterprise, or Education with the Hyper-V feature enabled."
    }
}

# All three phases derive the VM's folder and OS disk from -VmName + -WorkingDirectory alone
# (same shape as New-VhdBootTestVm.ps1 / Get-RehearsalVmPaths) -- never from $vm.Path, which
# Hyper-V may report as a nested subfolder under the -Path given to New-VM. Trusting $vm.Path
# for cleanup can leave the OS VHDX behind one level up, which then trips New-VhdBootTestVm's
# "already exists" folder guard on the next cycle.
$vmFolder = Join-Path $WorkingDirectory $VmName
$osDiskPath = Join-Path $vmFolder "$VmName-OS.vhdx"

# The default phase and -Destroy both delete $vmFolder recursively, so a -VhdPath inside it
# would be deleted along with the folder -- silently breaking the "the 1S-WIN11 VHD is never
# deleted" contract every phase documents. Refuse up front instead of at teardown.
$normalizedVmFolderPrefix = [System.IO.Path]::GetFullPath($vmFolder).TrimEnd('\') + '\'
if ([System.IO.Path]::GetFullPath($VhdPath).StartsWith($normalizedVmFolderPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Invoke-VhdVmDeploymentTest: -VhdPath ($VhdPath) is inside the VM's own working folder ($vmFolder), which this script deletes on teardown. Keep the 1S-WIN11 boot media outside <WorkingDirectory>\<VmName>."
}

function Stop-TestVmHard {
    <#
        .SYNOPSIS
            Forces a test VM to the Off state, tolerating the Saved state, where Stop-VM (even
            -TurnOff) fails with "not in a running state" -- a saved VM can only be brought Off
            by discarding its saved state (Remove-VMSavedState), Hyper-V's equivalent of
            Hyper-V Manager's "Delete Saved State".
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    $vmToStop = Get-VM -Name $Name -ErrorAction Stop
    if ($vmToStop.State -eq 'Off') { return }
    if ($vmToStop.State -eq 'Saved') {
        Remove-VMSavedState -VMName $Name -ErrorAction Stop
        return
    }
    Stop-VM -Name $Name -TurnOff -Force -ErrorAction Stop
}

if ($Finalize) {
    # ---------------------------------------------------------------- Phase B: -Finalize
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "Invoke-VhdVmDeploymentTest: no VM named '$VmName' exists on this host, so there is nothing to finalize. Run this script with no phase switch first to provision and boot the test VM, or pass the -VmName an earlier run actually used."
    }

    Write-Host ''
    Write-Host '=== Finalize step 1: Stop the test VM ===' -ForegroundColor Cyan
    # A running VM holds both VHD files locked, so it must be fully Off before anything mounts.
    if ($vm.State -ne 'Off') {
        $gracefulStopSucceeded = $false
        # A guest shutdown can only ever succeed from Running; Saved/Paused go straight to the
        # hard path (which Stop-TestVmHard resolves per-state) instead of burning the timeout.
        if ($vm.State -eq 'Running') {
            Write-Host "Requesting guest shutdown of '$VmName'..." -ForegroundColor Cyan
            $stopJob = $null
            try {
                # -Force here only suppresses the confirmation prompt; it is still a guest
                # shutdown, not a power-off. -AsJob bounds the wait: a guest wedged in WinPE or
                # mid-Setup never completes a graceful shutdown and would hang this phase forever.
                $stopJob = Stop-VM -Name $VmName -Force -AsJob -ErrorAction Stop
                $finishedJob = Wait-Job -Job $stopJob -Timeout 180
                if ($finishedJob -and $stopJob.State -eq 'Completed') {
                    $gracefulStopSucceeded = $true
                }
            } catch {
                $gracefulStopSucceeded = $false
            } finally {
                if ($stopJob) {
                    Stop-Job -Job $stopJob -ErrorAction SilentlyContinue
                    Remove-Job -Job $stopJob -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if (-not $gracefulStopSucceeded) {
            Write-Host "'$VmName' did not shut down gracefully (state: $($vm.State)); forcing it off..." -ForegroundColor Yellow
            Stop-TestVmHard -Name $VmName
        }
    } else {
        Write-Host "'$VmName' is already Off." -ForegroundColor Green
    }

    if (-not (Test-Path -LiteralPath $osDiskPath -PathType Leaf)) {
        throw "Invoke-VhdVmDeploymentTest: the VM's OS disk was not found at $osDiskPath. Was the VM created by this script (or New-VhdBootTestVm.ps1) with the same -VmName and -WorkingDirectory?"
    }
    if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) {
        throw "Invoke-VhdVmDeploymentTest: the 1S-WIN11 media VHD was not found at $VhdPath."
    }
    $resolvedOsDiskPath = (Resolve-Path -LiteralPath $osDiskPath).Path
    $resolvedVhdPath = (Resolve-Path -LiteralPath $VhdPath).Path

    # Tracks what THIS phase has mounted so a partway failure can undo exactly that before
    # rethrowing. Deliberately try/catch, not finally: on success the disks must STAY mounted
    # for log reading -- that is the whole point of -Finalize.
    $mountedThisPhase = @()
    try {
        Write-Host ''
        Write-Host '=== Finalize step 2: Mount the OS disk ===' -ForegroundColor Cyan
        $existingOsVhd = Get-VHD -Path $resolvedOsDiskPath -ErrorAction SilentlyContinue
        if ($existingOsVhd -and $existingOsVhd.Attached) {
            Write-Host "Dismounting $resolvedOsDiskPath (already attached from a previous run)..." -ForegroundColor Yellow
            Dismount-VHD -Path $resolvedOsDiskPath -ErrorAction Stop
        }
        Write-Host "Mounting $resolvedOsDiskPath..." -ForegroundColor Cyan
        $mountedOsDisk = Mount-VHD -Path $resolvedOsDiskPath -Passthru -ErrorAction Stop
        $mountedThisPhase += $resolvedOsDiskPath
        $osDiskNumber = $mountedOsDisk.DiskNumber

        # The deployed layout is EFI/MSR/Windows/WinRE, so the largest NTFS partition on the OS
        # disk is always the Windows volume -- no label to search for here, unlike the media VHD.
        # -ErrorAction SilentlyContinue: on a blank/RAW disk (deployment never partitioned it),
        # Get-Partition emits an ObjectNotFound *error* rather than an empty result, and Stop
        # would terminate here with that raw CIM error instead of the actionable throw below.
        $windowsPartition = Get-Partition -DiskNumber $osDiskNumber -ErrorAction SilentlyContinue | Where-Object {
            $volume = $_ | Get-Volume -ErrorAction SilentlyContinue
            $volume -and $volume.FileSystem -eq 'NTFS'
        } | Sort-Object -Property Size -Descending | Select-Object -First 1
        if (-not $windowsPartition) {
            throw "No NTFS partition was found on the mounted OS disk (disk $osDiskNumber). The deployment may never have applied the Windows image to it -- check the VM's console/Setup output instead."
        }
        if (-not $windowsPartition.DriveLetter) {
            Write-Host 'Assigning a drive letter to the Windows partition...' -ForegroundColor Cyan
            $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
            # The original partition object's DriveLetter is stale after Add-PartitionAccessPath;
            # re-fetch by DiskNumber+PartitionNumber -- same workaround as Update-VhdBootMedia.ps1.
            $windowsPartition = Get-Partition -DiskNumber $osDiskNumber -PartitionNumber $windowsPartition.PartitionNumber -ErrorAction Stop
        }
        $osDriveLetter = $windowsPartition.DriveLetter
        Write-Host "OS disk Windows volume mounted at ${osDriveLetter}:\" -ForegroundColor Green

        Write-Host ''
        Write-Host '=== Finalize step 3: Mount the 1S-WIN11 media VHD ===' -ForegroundColor Cyan
        $existingMediaVhd = Get-VHD -Path $resolvedVhdPath -ErrorAction SilentlyContinue
        if ($existingMediaVhd -and $existingMediaVhd.Attached) {
            Write-Host "Dismounting $resolvedVhdPath (already attached from a previous run)..." -ForegroundColor Yellow
            Dismount-VHD -Path $resolvedVhdPath -ErrorAction Stop
        }
        Write-Host "Mounting $resolvedVhdPath..." -ForegroundColor Cyan
        $mountedMediaVhd = Mount-VHD -Path $resolvedVhdPath -Passthru -ErrorAction Stop
        $mountedThisPhase += $resolvedVhdPath
        $mediaDiskNumber = $mountedMediaVhd.DiskNumber

        # SilentlyContinue for the same blank-disk reason as the OS-disk search above: the
        # actionable "is this really a prepared 1S-WIN11 image?" throw below must be reachable.
        $mediaPartition = Get-Partition -DiskNumber $mediaDiskNumber -ErrorAction SilentlyContinue | Where-Object {
            $volume = $_ | Get-Volume -ErrorAction SilentlyContinue
            $volume -and $volume.FileSystemLabel -eq $script:DeploymentVolumeLabel
        } | Select-Object -First 1
        if (-not $mediaPartition) {
            throw "No partition labelled '$script:DeploymentVolumeLabel' was found on the mounted media VHD (disk $mediaDiskNumber). Is $resolvedVhdPath really a prepared 1S-WIN11 USB image?"
        }
        if (-not $mediaPartition.DriveLetter) {
            Write-Host 'Assigning a drive letter to the 1S-WIN11 partition...' -ForegroundColor Cyan
            $mediaPartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
            # Same stale-DriveLetter workaround as above / Update-VhdBootMedia.ps1.
            $mediaPartition = Get-Partition -DiskNumber $mediaDiskNumber -PartitionNumber $mediaPartition.PartitionNumber -ErrorAction Stop
        }
        $mediaDriveLetter = $mediaPartition.DriveLetter
        Write-Host "Media VHD 1S-WIN11 volume mounted at ${mediaDriveLetter}:\" -ForegroundColor Green

        Write-Host ''
        Write-Host '=== Finalize step 4: Where to read the logs ===' -ForegroundColor Cyan
        Write-Host "OS disk (Windows volume): ${osDriveLetter}:\" -ForegroundColor Green
        $osDiskLogChecks = @(
            @{ Path = "${osDriveLetter}:\1S-WIN11\Deployment\Logs"; Hint = 'LocalHandover is off by default; without it, deployment logs live on the media VHD instead.' }
            @{ Path = "${osDriveLetter}:\1S-WIN11\Deployment\State\deployment_state.json"; Hint = 'no local step-state file; the run either never handed over locally or state lives on the media VHD.' }
            @{ Path = "${osDriveLetter}:\1S-WIN11\Deployment\Reports"; Hint = 'no local reports; the FinalReport step may not have run, or reports live on the media VHD.' }
            @{ Path = "${osDriveLetter}:\Windows\Panther\setupact.log"; Hint = 'Windows Setup may never have reached the specialize pass on this disk.' }
            @{ Path = "${osDriveLetter}:\Windows\Panther\UnattendGC\setupact.log"; Hint = 'the oobeSystem unattend pass may never have run on this disk.' }
        )
        foreach ($check in $osDiskLogChecks) {
            if (Test-Path -LiteralPath $check.Path) {
                Write-Host "  [exists ] $($check.Path)" -ForegroundColor Green
            } else {
                Write-Host "  [missing] $($check.Path) -- $($check.Hint)" -ForegroundColor Yellow
            }
        }
        Write-Host "Media VHD (1S-WIN11 volume): ${mediaDriveLetter}:\" -ForegroundColor Green
        $mediaLogChecks = @(
            @{ Path = "${mediaDriveLetter}:\OSIT-DiskCheck.log"; Hint = 'Windows Setup may never have launched OSIT-DiskCheck.cmd from this media.' }
            @{ Path = "${mediaDriveLetter}:\OSIT-DiskPart.log"; Hint = 'diskpart may never have run -- it is gated on the disk check succeeding first.' }
            @{ Path = "${mediaDriveLetter}:\OSIT-DiskDiag.log"; Hint = 'no disk diagnostics were captured; these are only written when the disk check needs them.' }
            @{ Path = "${mediaDriveLetter}:\Deployment\Logs"; Hint = 'no deployment logs on the media; the orchestrator may never have started, or LocalHandover moved logging to C:\1S-WIN11.' }
        )
        foreach ($check in $mediaLogChecks) {
            if (Test-Path -LiteralPath $check.Path) {
                Write-Host "  [exists ] $($check.Path)" -ForegroundColor Green
            } else {
                Write-Host "  [missing] $($check.Path) -- $($check.Hint)" -ForegroundColor Yellow
            }
        }

        Write-Host ''
        Write-Host 'Both disks remain mounted for log reading. When finished, rerun this script with -Destroy to dismount everything and remove the VM.' -ForegroundColor Cyan
    } catch {
        foreach ($mountedPath in $mountedThisPhase) {
            Write-Host "Dismounting $mountedPath after failure..." -ForegroundColor Yellow
            Dismount-VHD -Path $mountedPath -ErrorAction SilentlyContinue
        }
        throw
    }
    return
}

if ($Destroy) {
    # ---------------------------------------------------------------- Phase C: -Destroy
    Write-Host ''
    Write-Host '=== Destroy step 1: Stop the test VM (if any) ===' -ForegroundColor Cyan
    # The VM must be off BEFORE the dismount step: Get-VHD reports a running VM's disks as
    # Attached, but Dismount-VHD cannot detach a file the VM worker process holds open -- it
    # would fail there with a raw storage error instead of ever reaching this power-off.
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($vm) {
        if ($vm.State -ne 'Off') {
            Write-Host "'$VmName' is not off (state: $($vm.State)); forcing it off..." -ForegroundColor Yellow
            Stop-TestVmHard -Name $VmName
        } else {
            Write-Host "'$VmName' is already Off." -ForegroundColor Green
        }
    } else {
        Write-Host "No VM named '$VmName' is registered." -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== Destroy step 2: Dismount disks ===' -ForegroundColor Cyan
    foreach ($diskPath in @($osDiskPath, $VhdPath)) {
        # Get-VHD returns $null for a missing or never-attached file; the -and guard keeps this
        # tolerant of already-dismounted (or already-deleted) disks under StrictMode 2.0.
        $vhd = Get-VHD -Path $diskPath -ErrorAction SilentlyContinue
        if ($vhd -and $vhd.Attached) {
            Write-Host "Dismounting $diskPath..." -ForegroundColor Cyan
            Dismount-VHD -Path $diskPath -ErrorAction Stop
        } else {
            Write-Host "$diskPath is not mounted." -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host '=== Destroy step 3: Remove the test VM ===' -ForegroundColor Cyan
    # Deliberately NOT Remove-RehearsalVm (RehearsalCommon.ps1): that function deletes every
    # disk Get-VMHardDiskDrive discovers on the VM, which here includes the shared 1S-WIN11
    # VHD (-VhdPath) attached at SCSI 0/LUN 1 -- the reusable boot media the next cycle
    # refreshes in place. This phase must dismount that VHD but never delete it, so the VM and
    # only the VM's OWN folder are removed explicitly instead.
    if ($vm) {
        Write-Host "Removing VM '$VmName'..." -ForegroundColor Cyan
        Remove-VM -Name $VmName -Force -ErrorAction Stop
    }

    Write-Host ''
    Write-Host '=== Destroy step 4: Remove the VM folder ===' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $vmFolder) {
        Write-Host "Removing $vmFolder..." -ForegroundColor Cyan
        Remove-Item -LiteralPath $vmFolder -Recurse -Force -ErrorAction Stop
    } else {
        Write-Host "No VM folder at $vmFolder." -ForegroundColor Green
    }

    Write-Host ''
    Write-Host "Teardown complete. The 1S-WIN11 VHD was preserved at $VhdPath -- rerun this script with no phase switch to start the next cycle from it." -ForegroundColor Green
    return
}

# -------------------------------------------------------------------- Phase A: provision + boot
# Removal comes BEFORE the media refresh: a still-running VM from the previous cycle holds the
# 1S-WIN11 VHD open, and Update-VhdBootMedia.ps1 cannot dismount/mount a VHD out from under a VM.
Write-Host ''
Write-Host '=== Step 1: Remove existing test VM (if any) ===' -ForegroundColor Cyan
$existingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existingVm) {
    if ($existingVm.State -ne 'Off') {
        Write-Host "Stopping '$VmName'..." -ForegroundColor Yellow
        Stop-TestVmHard -Name $VmName
    }
    Write-Host "Removing VM '$VmName'..." -ForegroundColor Yellow
    Remove-VM -Name $VmName -Force -ErrorAction Stop
}
# A -Finalize that was never followed by -Destroy leaves the OS disk host-mounted, which would
# make the recursive folder delete below fail with a file-in-use error -- dismount it first.
$leftoverOsVhd = Get-VHD -Path $osDiskPath -ErrorAction SilentlyContinue
if ($leftoverOsVhd -and $leftoverOsVhd.Attached) {
    Write-Host "Dismounting $osDiskPath (left mounted by an earlier -Finalize)..." -ForegroundColor Yellow
    Dismount-VHD -Path $osDiskPath -ErrorAction Stop
}
# Only this VM's OWN derived folder -- never -VhdPath, which the guard near the top proved
# lives outside it. Deleted whether or not a VM was registered: a leftover folder from an
# interrupted previous run would trip New-VhdBootTestVm.ps1's "already exists" guard.
if (Test-Path -LiteralPath $vmFolder) {
    Write-Host "Removing leftover VM folder $vmFolder..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $vmFolder -Recurse -Force -ErrorAction Stop
}
if (-not $existingVm) {
    Write-Host "No existing VM named '$VmName' found." -ForegroundColor Green
}

Write-Host ''
Write-Host '=== Step 2: Refresh VHD boot media ===' -ForegroundColor Cyan
$updateArgs = @{ VhdPath = $VhdPath }
if ($SkipValidation) { $updateArgs.SkipValidation = $true }
# Out-Null is load-bearing: Update-VhdBootMedia.ps1's success stream is polluted by the child
# scripts it runs (Initialize-UsbDeployment.ps1/Validate-Unattend.ps1), not just its own return.
& (Join-Path $PSScriptRoot 'Update-VhdBootMedia.ps1') @updateArgs | Out-Null

Write-Host ''
Write-Host '=== Step 3: Create and start the test VM ===' -ForegroundColor Cyan
$vmArgs = @{
    VmName             = $VmName
    VhdPath            = $VhdPath
    WorkingDirectory   = $WorkingDirectory
    OsDiskGB           = $OsDiskGB
    MemoryGB           = $MemoryGB
    CpuCount           = $CpuCount
    SwitchName         = $SwitchName
    SecureBootTemplate = $SecureBootTemplate
    Start              = $Start
}
if ($DisableSecureBoot) { $vmArgs.DisableSecureBoot = $true }
$vm = & (Join-Path $PSScriptRoot 'New-VhdBootTestVm.ps1') @vmArgs

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host "  1. Watch the deployment run to completion: vmconnect.exe localhost `"$VmName`""
Write-Host "  2. Then gather the logs: .\Test\Rehearsal\Invoke-VhdVmDeploymentTest.ps1 -Finalize -VmName '$VmName'"
Write-Host "  3. Then tear down:       .\Test\Rehearsal\Invoke-VhdVmDeploymentTest.ps1 -Destroy -VmName '$VmName'"

return $vm
