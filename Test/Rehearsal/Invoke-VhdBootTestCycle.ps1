<#
    .SYNOPSIS
        End-to-end convenience wrapper for the "refresh the VHD, then boot a fresh test VM from
        it" cycle a technician repeats after every code change: refreshes a bootable "1S-WIN11"
        VHD from this repo's current state (Update-VhdBootMedia.ps1), then (re)creates and starts
        a Hyper-V test VM booting from it as a hard disk (New-VhdBootTestVm.ps1).

    .DESCRIPTION
        Combines two already-independently-usable scripts rather than reimplementing either:
        Update-VhdBootMedia.ps1 (mount + Initialize-UsbDeployment.ps1 + Validate-Unattend.ps1 +
        dismount) and New-VhdBootTestVm.ps1 (create + start a Gen-2 VM booting from that VHD).
        Either can still be run standalone -- this is purely a convenience for running both in
        the order that actually matters (the VHD must be dismounted before a VM can boot it, and
        New-VhdBootTestVm.ps1 already refuses to run against a VHD this host still has mounted).

        -Force additionally removes any pre-existing VM named -VmName first: stops it if running,
        then deletes its OWN working folder (its VM configuration and OS disk) -- never
        -VhdPath itself, which this script is refreshing in place, not recreating. Without
        -Force, an existing VM of the same name is left in place and New-VhdBootTestVm.ps1
        throws exactly the same actionable "already exists" error it always would.

    .PARAMETER VmName
        Passed through to New-VhdBootTestVm.ps1. Defaults to '1S-WIN11-VhdBootTest', matching
        that script's own default.

    .PARAMETER VhdPath
        Passed through to both Update-VhdBootMedia.ps1 and New-VhdBootTestVm.ps1. Defaults to
        Deployment\VHD\1S-WIN11.vhd beside this repository.

    .PARAMETER WorkingDirectory
        Passed through to New-VhdBootTestVm.ps1 (and used to locate a leftover VM folder to
        clean up under -Force). Defaults to Test\Rehearsal\VhdBootVms beside this repository.

    .PARAMETER Force
        Remove a pre-existing VM named -VmName (and its own working folder, including a
        leftover one from an interrupted previous run even if no VM is currently registered)
        before creating the fresh one. Never touches -VhdPath itself.

    .PARAMETER SkipValidation
        Passed through to Update-VhdBootMedia.ps1: skip Validate-Unattend.ps1 against the
        regenerated Autounattend.xml.

    .PARAMETER OsDiskGB
        Passed through to New-VhdBootTestVm.ps1. Default 120.

    .PARAMETER MemoryGB
        Passed through to New-VhdBootTestVm.ps1. Default 8.

    .PARAMETER CpuCount
        Passed through to New-VhdBootTestVm.ps1. Default 4.

    .PARAMETER SwitchName
        Passed through to New-VhdBootTestVm.ps1. Default 'Default Switch'.

    .PARAMETER SecureBootTemplate
        Passed through to New-VhdBootTestVm.ps1. Default 'MicrosoftWindows'.

    .PARAMETER DisableSecureBoot
        Passed through to New-VhdBootTestVm.ps1. See that script's own parameter help for when
        this is required (a VHD built from Rufus's UEFI:NTFS bridge loader).

    .PARAMETER Start
        Passed through to New-VhdBootTestVm.ps1. Default $true.

    .EXAMPLE
        .\Test\Rehearsal\Invoke-VhdBootTestCycle.ps1 -Force -DisableSecureBoot

        Refreshes Deployment\VHD\1S-WIN11.vhd from the current repo, removes any existing
        '1S-WIN11-VhdBootTest' VM, then creates and starts a fresh one from the refreshed VHD.

    .NOTES
        Cannot be executed end-to-end in a Linux sandbox with no Hyper-V -- see
        Update-VhdBootMedia.ps1 and New-VhdBootTestVm.ps1's own .NOTES.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Colored technician-facing progress output, matching Initialize-UsbDeployment.ps1/New-VhdBootTestVm.ps1''s existing convention for this kind of interactive CLI tooling.')]
[CmdletBinding()]
param(
    [string]$VmName = '1S-WIN11-VhdBootTest',
    [string]$VhdPath,
    [string]$WorkingDirectory,
    [switch]$Force,
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

if ([string]::IsNullOrWhiteSpace($VhdPath)) { $VhdPath = Join-Path $repoRoot 'Deployment\VHD\1S-WIN11.vhd' }
if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = Join-Path $repoRoot 'Test\Rehearsal\VhdBootVms' }

Assert-HyperVAvailable

Write-Host ''
Write-Host '=== Step 1: Refresh VHD boot media ===' -ForegroundColor Cyan
$updateArgs = @{ VhdPath = $VhdPath }
if ($SkipValidation) { $updateArgs.SkipValidation = $true }
& (Join-Path $PSScriptRoot 'Update-VhdBootMedia.ps1') @updateArgs | Out-Null

if ($Force) {
    Write-Host ''
    Write-Host '=== Step 2: Remove existing test VM (if any) ===' -ForegroundColor Cyan
    $existingVm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($existingVm) {
        if ($existingVm.State -ne 'Off') {
            Write-Host "Stopping '$VmName'..." -ForegroundColor Yellow
            Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        }
        $existingVmFolder = $existingVm.Path
        Write-Host "Removing VM '$VmName'..." -ForegroundColor Yellow
        Remove-VM -Name $VmName -Force -ErrorAction Stop
        if ($existingVmFolder -and (Test-Path -LiteralPath $existingVmFolder)) {
            # Only this VM's OWN folder (its configuration + OS disk) -- never -VhdPath, which
            # lives outside this folder and was refreshed in Step 1, not recreated.
            Write-Host "Removing leftover VM folder $existingVmFolder..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $existingVmFolder -Recurse -Force -ErrorAction Stop
        }
    } else {
        Write-Host "No existing VM named '$VmName' found." -ForegroundColor Green
        # Even with no registered VM, a leftover folder from an interrupted previous run would
        # make New-VhdBootTestVm.ps1's own "already exists" guard throw -- matching -Force's
        # "clean slate" intent, this clears it too.
        if (Test-Path -LiteralPath $WorkingDirectory) {
            $staleVmFolder = Join-Path (Resolve-Path -LiteralPath $WorkingDirectory).Path $VmName
            if (Test-Path -LiteralPath $staleVmFolder) {
                Write-Host "Removing leftover VM folder $staleVmFolder (files remain from an earlier run)..." -ForegroundColor Yellow
                Remove-Item -LiteralPath $staleVmFolder -Recurse -Force -ErrorAction Stop
            }
        }
    }
}

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
return & (Join-Path $PSScriptRoot 'New-VhdBootTestVm.ps1') @vmArgs
