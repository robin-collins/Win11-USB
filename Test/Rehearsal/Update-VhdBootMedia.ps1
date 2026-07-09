<#
    .SYNOPSIS
        Mounts a bootable "1S-WIN11" VHD, refreshes its deployment toolkit content and generated
        Autounattend.xml/OSIT-*.{cmd,vbs,txt} from this repo's current state via the real
        Initialize-UsbDeployment.ps1, validates the result, then dismounts -- so
        New-VhdBootTestVm.ps1 (or a real physical USB re-imaged from this same VHD) boots the
        latest code instead of whatever was on it when it was first built.

    .DESCRIPTION
        -VhdPath is expected to already be a bootable Windows Setup + toolkit VHD -- e.g. one
        produced by imaging a real Rufus USB stick to a .vhd file, as New-VhdBootTestVm.ps1's own
        header describes -- with its data partition labelled "1S-WIN11", exactly the label
        Deployment\Scripts\Common.ps1's Get-UsbRoot looks for in production. This finds that
        partition by its label on the specific disk this VHD mounts as (not by drive letter, and
        not via Get-UsbRoot's own system-wide search, which could find an unrelated device with
        the same label if a real USB stick happens to be plugged in at the same time), then runs
        the REAL Initialize-UsbDeployment.ps1 against it -- the exact same copy + generation +
        validation path a real USB gets -- and Validate-Unattend.ps1 against the result, before
        dismounting.

        This does not create a VHD or partition one: unlike RehearsalCommon.ps1's
        New-RehearsalMedia (which builds a blank rehearsal VHDX from scratch for the ISO+media
        model), -VhdPath here must already have Windows Setup media and an existing
        "1S-WIN11"-labelled partition on it, matching how a real USB stick already looks before
        Initialize-UsbDeployment.ps1 ever touches it for the first time.

    .PARAMETER VhdPath
        Path to the bootable "1S-WIN11" VHD. Defaults to Deployment\VHD\1S-WIN11.vhd beside this
        repository, matching New-VhdBootTestVm.ps1's own default.

    .PARAMETER SkipValidation
        Skip running Validate-Unattend.ps1 against the regenerated Autounattend.xml after
        Initialize-UsbDeployment.ps1 runs.

    .EXAMPLE
        .\Test\Rehearsal\Update-VhdBootMedia.ps1

        Mounts Deployment\VHD\1S-WIN11.vhd, refreshes it from the current repo state, validates
        the result, then dismounts.

    .NOTES
        Cannot be executed end-to-end in a Linux sandbox with no Hyper-V: Mount-VHD/Dismount-VHD
        and running Initialize-UsbDeployment.ps1 against a real mounted NTFS volume both require
        an actual Windows host with a pre-built "1S-WIN11" VHD to test against.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Colored technician-facing progress output, matching Initialize-UsbDeployment.ps1/New-VhdBootTestVm.ps1''s existing convention for this kind of interactive CLI tooling.')]
[CmdletBinding()]
param(
    [string]$VhdPath,
    [switch]$SkipValidation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'RehearsalCommon.ps1')
. (Join-Path $repoRoot 'Deployment\Scripts\Common.ps1')

if ([string]::IsNullOrWhiteSpace($VhdPath)) { $VhdPath = Join-Path $repoRoot 'Deployment\VHD\1S-WIN11.vhd' }
if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) {
    throw "Update-VhdBootMedia: VHD file was not found: $VhdPath"
}
$resolvedVhdPath = (Resolve-Path -LiteralPath $VhdPath).Path

# Matches New-RehearsalMedia's own up-front guard convention (RehearsalCommon.ps1): one clear,
# actionable failure before any work starts, instead of a cryptic "term not recognized" partway
# through mounting. Mount-VHD/Dismount-VHD ship with Hyper-V; Get-Partition/Add-PartitionAccessPath
# ship with Windows itself but are listed here too so every dependency is checked in one place.
foreach ($cmdletName in @('Mount-VHD', 'Dismount-VHD', 'Get-Partition', 'Add-PartitionAccessPath', 'Get-Volume')) {
    if (-not (Test-RehearsalCommandAvailable -Name $cmdletName)) {
        throw "$cmdletName is not available on this platform. Update-VhdBootMedia.ps1 requires Windows 10/11 Pro, Enterprise, or Education with the Hyper-V feature enabled."
    }
}

$existingVhd = Get-VHD -Path $resolvedVhdPath -ErrorAction SilentlyContinue
if ($existingVhd -and $existingVhd.Attached) {
    Write-Host "Dismounting $resolvedVhdPath (already attached from a previous run)..." -ForegroundColor Yellow
    Dismount-VHD -Path $resolvedVhdPath -ErrorAction Stop
}

$mountedVhd = $null
try {
    Write-Host "Mounting $resolvedVhdPath..." -ForegroundColor Cyan
    $mountedVhd = Mount-VHD -Path $resolvedVhdPath -Passthru -ErrorAction Stop
    $diskNumber = $mountedVhd.DiskNumber

    $partition = Get-Partition -DiskNumber $diskNumber -ErrorAction Stop | Where-Object {
        $volume = $_ | Get-Volume -ErrorAction SilentlyContinue
        $volume -and $volume.FileSystemLabel -eq $script:DeploymentVolumeLabel
    } | Select-Object -First 1

    if (-not $partition) {
        throw "No partition labelled '$script:DeploymentVolumeLabel' was found on the mounted VHD (disk $diskNumber). Is $resolvedVhdPath really a prepared 1S-WIN11 USB image? Rufus's own volume-label field must be set to $script:DeploymentVolumeLabel when the USB/VHD was first created."
    }

    if (-not $partition.DriveLetter) {
        Write-Host 'Assigning a drive letter to the 1S-WIN11 partition...' -ForegroundColor Cyan
        $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction Stop
    }

    $usbRoot = "$($partition.DriveLetter):\"
    Write-Host "Mounted at $usbRoot" -ForegroundColor Green

    Write-Host "Refreshing deployment toolkit content (Initialize-UsbDeployment.ps1 -UsbRoot $usbRoot)..." -ForegroundColor Cyan
    & (Join-Path $repoRoot 'Initialize-UsbDeployment.ps1') -UsbRoot $usbRoot

    if (-not $SkipValidation) {
        Write-Host 'Validating the refreshed media...' -ForegroundColor Cyan
        $generatedAutounattendPath = Join-Path $usbRoot 'Autounattend.xml'
        $generatedConfigPath = Join-Path $usbRoot 'Deployment\Config\deployment_config.json'
        & (Join-Path $repoRoot 'Validate-Unattend.ps1') -Path $generatedAutounattendPath -Generated -ConfigPath $generatedConfigPath
        if ($LASTEXITCODE -ne 0) {
            throw 'Validate-Unattend.ps1 reported a failure against the refreshed media. Fix the issue before booting a VM from it.'
        }
    }

    Write-Host "$resolvedVhdPath refreshed successfully." -ForegroundColor Green
} finally {
    if ($mountedVhd) {
        Write-Host "Dismounting $resolvedVhdPath..." -ForegroundColor Cyan
        Dismount-VHD -Path $resolvedVhdPath -ErrorAction SilentlyContinue
    }
}

return $resolvedVhdPath
