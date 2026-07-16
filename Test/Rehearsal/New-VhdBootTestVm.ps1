<#
    .SYNOPSIS
        Creates a Gen-2 Hyper-V VM that boots directly from a pre-built "1S-WIN11" VHD (Windows
        Setup media plus the deployment toolkit, as written by Initialize-UsbDeployment.ps1)
        attached as a hard disk, instead of mounting a Windows ISO as a virtual DVD drive.

    .DESCRIPTION
        This is a lightweight, manual alternative to Test\Rehearsal\Invoke-DeploymentRehearsal.ps1
        for technicians who already have a bootable "1S-WIN11" VHD (for example, one produced by
        imaging a real Rufus USB stick to a .vhd file and then running
        Initialize-UsbDeployment.ps1 -UsbRoot against it while mounted) and want to watch a real
        deployment run in a VM without building rehearsal media from an ISO.

        Booting a Gen-2 VM's virtual DVD drive from a Windows Setup ISO shows a "Press any key to
        boot from CD or DVD..." prompt (Windows Setup's own El Torito/cdboot.efi loader waiting
        for input) -- Invoke-DeploymentRehearsal.ps1 handles this with Send-RehearsalKeystroke
        polling. Attaching the same Windows Setup media as a VHD *hard disk* instead of a virtual
        DVD skips that prompt entirely: UEFI just boots the disk's own EFI Boot Manager, exactly
        like a real notebook booting from a physical USB stick.

        Disk placement: -VhdPath is attached at SCSI 0/LUN 1, and a new blank OS disk is attached
        at SCSI 0/LUN 0. Boot order is set to the -VhdPath disk first, so it boots Windows Setup
        -- but WinPE's own disk enumeration (what OSIT-DiskCheck.cmd and OSIT-DiskPart.txt see as
        "disk 0") is controlled by SCSI position, not boot order, so the blank OS disk at LUN 0
        still resolves as disk 0, matching deployment_config.json's wipe_repartition_disk_id
        default of 0 -- the same disk-placement convention New-RehearsalVm (RehearsalCommon.ps1)
        uses for its ISO+media-VHDX model.

        -VhdPath must not already be mounted on this host (Mount-VHD/Mount-DiskImage) when this
        runs -- a VM cannot boot a VHD that the host itself has open. This script dismounts it
        automatically if found attached.

        This script does not build media, drive guest monitoring, inject failures, or run the
        Test-RehearsalResult assertion suite the way Invoke-DeploymentRehearsal.ps1 does. It only
        creates the VM and (by default) starts it; watch and interact with it via Hyper-V Manager
        or `vmconnect.exe`.

    .PARAMETER VmName
        Name of the Hyper-V VM to create. Must not already exist.

    .PARAMETER VhdPath
        Path to the bootable "1S-WIN11" VHD (Windows Setup media plus the deployment toolkit).
        Defaults to Deployment\VHD\1S-WIN11.vhd beside this repository.

    .PARAMETER WorkingDirectory
        Scratch directory the VM's own folder (configuration, OS disk) is created under.
        Defaults to Test\Rehearsal\VhdBootVms beside this repository (gitignored, matching
        Test\Rehearsal\Artifacts\'s convention of never being committed).

    .PARAMETER OsDiskGB
        Size of the new dynamic target OS VHDX, in GB. Default 120 -- comfortably above both
        Windows 11's own minimum and the size of the attached 1S-WIN11 boot VHD, so
        OSIT-DiskCheck.cmd's relative-size safety check (target disk strictly larger than every
        other visible disk) passes without needing a config override.

    .PARAMETER MemoryGB
        Fixed VM memory in GB (dynamic memory is disabled, matching New-RehearsalVm's convention
        that a real client notebook has no memory ballooning).

    .PARAMETER CpuCount
        Virtual CPU count.

    .PARAMETER SwitchName
        Hyper-V virtual switch to attach the VM's network adapter to.

    .PARAMETER SecureBootTemplate
        Defaults to 'MicrosoftWindows', matching New-RehearsalVm and real Windows 11 hardware.
        A VHD built by imaging a USB Rufus wrote in "GPT for UEFI" / persistent-NTFS mode boots
        through Rufus's own UEFI:NTFS bridge loader (needed because UEFI firmware cannot read
        NTFS directly) instead of booting bootmgfw.efi straight from a FAT32 ESP -- confirmed by
        reproducing "The signed image's hash is not allowed (DB)" at the UEFI boot menu with the
        'MicrosoftWindows' template against exactly this kind of VHD. Pass
        'MicrosoftUEFICertificateAuthority' for that case, which additionally allows
        Microsoft-3rd-party-CA-signed loaders such as Rufus's -- confirmed this gets past the
        bridge loader itself, but see -DisableSecureBoot for what was needed to get past it
        entirely against this VHD. Cannot be changed on an existing VM once its vTPM has been
        initialized -- recreate the VM instead of trying to switch this after the fact.

    .PARAMETER DisableSecureBoot
        Turns Secure Boot off instead of using -SecureBootTemplate (vTPM stays enabled either
        way -- Windows 11 Setup was observed to proceed with Secure Boot off as long as a TPM is
        present). Confirmed necessary against a VHD built from Rufus's UEFI:NTFS bridge loader:
        even 'MicrosoftUEFICertificateAuthority' let the bridge loader itself start, but its
        chainload of the real bootmgfw.efi off the NTFS volume still failed Secure Boot
        validation ("Load failure: [26] Security Violation"). Real client notebooks booting
        production media (a standard FAT32 ESP, no NTFS bridge) are not expected to need this.

    .PARAMETER Start
        Starts the VM once created. Default $true; pass -Start:$false to only create it.

    .EXAMPLE
        .\Test\Rehearsal\New-VhdBootTestVm.ps1 -DisableSecureBoot

        Creates and starts a VM named "1S-WIN11-VhdBootTest" from the repo's own
        Deployment\VHD\1S-WIN11.vhd. -DisableSecureBoot is typically required for a VHD built via
        Rufus's UEFI:NTFS bridge loader -- see -DisableSecureBoot above.

    .NOTES
        UNRESOLVED, OBSERVED WHILE BUILDING THIS SCRIPT: even with Secure Boot handled, Windows
        Setup booted straight to the interactive "Product key" page instead of silently applying
        Autounattend.xml -- Windows Setup's automatic unattend-file discovery is understood to
        expect removable media, and a VHD attached to a VM's SCSI controller presents as a fixed
        disk, not removable, so the auto-scan may simply not consider it. Not investigated further
        here (out of scope for this task); a real physical USB stick and Invoke-DeploymentRehearsal.ps1's
        ISO-based flow are both unaffected. If pursuing this further, look at whether Windows Setup
        accepts an explicit `setup.exe /unattend:<path>` invocation from within the booted WinPE
        environment as a workaround.
#>

[CmdletBinding()]
param(
    [string]$VmName = '1S-WIN11-VhdBootTest',
    [string]$VhdPath,
    [string]$WorkingDirectory,
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

if (-not (Test-Path -LiteralPath $VhdPath -PathType Leaf)) {
    throw "New-VhdBootTestVm: VHD file was not found: $VhdPath"
}
if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "New-VhdBootTestVm: a VM named '$VmName' already exists. Remove it first (Remove-VM -Name $VmName -Force, after Stop-VM if running) or choose a different -VmName."
}

$resolvedVhdPath = (Resolve-Path -LiteralPath $VhdPath).Path
$existingVhd = Get-VHD -Path $resolvedVhdPath -ErrorAction SilentlyContinue
if ($existingVhd -and $existingVhd.Attached) {
    Write-Host "Dismounting $resolvedVhdPath from this host so the VM can boot it..." -ForegroundColor Yellow
    Dismount-VHD -Path $resolvedVhdPath -ErrorAction Stop
}

if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
}
$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$vmFolder = Join-Path $resolvedWorkingDirectory $VmName
if (Test-Path -LiteralPath $vmFolder) {
    throw "New-VhdBootTestVm: '$vmFolder' already exists from a previous run. Remove it before retrying."
}
New-Item -ItemType Directory -Path $vmFolder -Force | Out-Null

$osDiskPath = Join-Path $vmFolder "$VmName-OS.vhdx"
Write-Host "Creating dynamic OS disk (${OsDiskGB} GB) at $osDiskPath..." -ForegroundColor Cyan
New-VHD -Path $osDiskPath -Dynamic -SizeBytes ([int64]$OsDiskGB * 1GB) | Out-Null

Write-Host "Creating Gen-2 VM '$VmName' (Memory=${MemoryGB}GB, CPU=$CpuCount, Switch='$SwitchName')..." -ForegroundColor Cyan
New-VM -Name $VmName -Generation 2 -Path $vmFolder -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -NoVHD -SwitchName $SwitchName | Out-Null
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGB * 1GB)
Set-VMProcessor -VMName $VmName -Count $CpuCount

# OS disk at SCSI 0/LUN 0, the bootable 1S-WIN11 VHD at SCSI 0/LUN 1 -- see this script's
# .DESCRIPTION for why disk placement (not boot order) is what keeps disk 0 matching
# wipe_repartition_disk_id, matching New-RehearsalVm's convention for the same reason.
$osDiskDrive = Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $osDiskPath -Passthru
$bootVhdDrive = Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 -Path $resolvedVhdPath -Passthru

# Boot from the 1S-WIN11 VHD (Windows Setup) first; a later reboot out of WinPE/Setup then
# continues from the OS disk. No DVD drive is added at all, so there is no "press any key"
# prompt and no possibility of an accidental network/PXE boot.
Set-VMFirmware -VMName $VmName -BootOrder $bootVhdDrive, $osDiskDrive

Get-RehearsalHgsGuardian | Out-Null
Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
Enable-VMTPM -VMName $VmName
if ($DisableSecureBoot) {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
} else {
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate $SecureBootTemplate
}

Write-Host ''
Write-Host "VM '$VmName' created." -ForegroundColor Green
Write-Host "  OS disk (SCSI 0:0, disk 0 in WinPE): $osDiskPath"
Write-Host "  Boot VHD (SCSI 0:1, boots first):    $resolvedVhdPath"

if ($Start) {
    Write-Host "Starting '$VmName'..." -ForegroundColor Cyan
    Start-VM -Name $VmName
    Write-Host "Connect with: vmconnect.exe localhost `"$VmName`"" -ForegroundColor Green
} else {
    Write-Host "VM created but not started (-Start:`$false). Start it with: Start-VM -Name '$VmName'" -ForegroundColor Yellow
}

return [ordered]@{
    VmName     = $VmName
    VmFolder   = $vmFolder
    OsDiskPath = $osDiskPath
    VhdPath    = $resolvedVhdPath
}
