<#
.SYNOPSIS
    Integrates storage controller drivers into Windows installation media so they are present
    before Windows Setup enumerates disks.

.DESCRIPTION
    When a notebook's storage controller driver (e.g. Intel VMD/RST, AMD RAID) is not in
    boot.wim, Windows Setup boots without seeing the internal drive, the USB stick becomes
    disk 0, and the unattended disk layout targets the wrong disk. Loading the driver
    later (drvload / $WinPEDriver$) makes the internal drive appear as disk 1, which
    still breaks the disk-0 assumption.

    This script services the media offline with DISM so the drivers are boot-critical:

      1. Injects every driver under Deployment\Drivers\Storage into ALL indexes of
         <Root>\sources\boot.wim (index 1 = WinPE, index 2 = Windows Setup).
      2. Injects the same drivers into ALL indexes of <Root>\sources\install.wim,
         so the installed OS can boot from the controller on first boot.
         install.esd / install.swm cannot be serviced in place; those are skipped with
         a warning (step 3 still covers the installed OS in that case).
      3. Mirrors the drivers into <Root>\$WinPEDriver$\Storage. The generated
         OSIT-DiskPart setup script injects everything in $WinPEDriver$ into the applied
         image with dism /Add-Driver, so the installed OS gets the drivers even when the
         install image itself could not be serviced.

    The media to service can be given three ways:

      - Omit -UsbRoot and -VhdPath entirely: the real 1S-WIN11 USB is located by volume
        label (never by drive letter).
      - -UsbRoot: a drive letter or folder that already has installation media on it
        (a real USB stick, or an extracted-ISO folder).
      - -VhdPath: one or more .vhd/.vhdx files containing installation media (e.g. a
        Rufus USB imaged to a .vhd for rehearsal, or several golden VHDs kept around
        for different hardware). Each is mounted, the partition containing
        sources\boot.wim is located automatically (no particular volume label is
        required), serviced, and dismounted again -- in turn, so one bad VHD does not
        stop the rest. This is how to patch every golden VHD you keep whenever the
        drivers under Deployment\Drivers\Storage change, without hand-mounting each one
        first. -VhdPath accepts wildcards (e.g. -VhdPath 'Deployment\VHD\*.vhd').

    Images are copied to a local scratch directory for servicing (DISM mounts are slow
    and fragile directly on FAT32 removable media) and copied back on success. Ensure
    the scratch drive has free space of roughly twice the largest image being serviced.

    Requires an elevated (Administrator) PowerShell session on Windows. Works under
    Windows PowerShell 5.1 and PowerShell 7. -VhdPath additionally requires the Hyper-V
    feature (Mount-VHD/Dismount-VHD).

.PARAMETER UsbRoot
    Root of the installation media (e.g. E:\ or an extracted-ISO folder). When omitted
    (and -VhdPath is not used), the USB is located by volume label, never by drive letter.
    Mutually exclusive with -VhdPath.

.PARAMETER VolumeLabel
    Volume label used to locate the deployment USB when neither -UsbRoot nor -VhdPath is
    supplied. Defaults to 1S-WIN11.

.PARAMETER VhdPath
    One or more paths to .vhd/.vhdx files containing Windows installation media. Wildcards
    are supported. Each VHD is mounted, serviced, and dismounted in turn. Mutually
    exclusive with -UsbRoot.

.PARAMETER DriverRoot
    Folder scanned recursively for driver packages (*.inf). Defaults to
    Deployment\Drivers\Storage in this toolkit checkout.

.PARAMETER ScratchRoot
    Local working directory for image copies and DISM mount points. Defaults to a
    timestamped folder under %TEMP%. Each target (USB root, or each VHD) gets its own
    subfolder underneath so a failure on one target cannot block another. Removed on
    success; kept for inspection under a failed target.

.PARAMETER SkipInstallImage
    Only service boot.wim; leave install.wim untouched.

.PARAMETER SkipWinPEDriverFolder
    Do not mirror the drivers into <Root>\$WinPEDriver$\Storage.

.PARAMETER ForceUnsigned
    Pass /ForceUnsigned to DISM for unsigned driver packages. Avoid unless a vendor
    package is unsigned and you have verified its provenance.

.EXAMPLE
    .\IntegrateDriversToWindowsInstall.ps1
    Locates the 1S-WIN11 USB and integrates Deployment\Drivers\Storage into its media.

.EXAMPLE
    .\IntegrateDriversToWindowsInstall.ps1 -UsbRoot E:\ -SkipInstallImage
    Services only E:\sources\boot.wim and refreshes E:\$WinPEDriver$\Storage.

.EXAMPLE
    .\IntegrateDriversToWindowsInstall.ps1 -VhdPath Deployment\VHD\1S-WIN11.vhd
    Mounts the VHD, services its media, and dismounts it again.

.EXAMPLE
    .\IntegrateDriversToWindowsInstall.ps1 -VhdPath 'Deployment\VHD\*.vhd', 'D:\GoldenImages\*.vhdx'
    Patches every matching VHD in turn -- for refreshing several golden images at once after
    adding a new driver package.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This script is an interactive technician CLI (media servicing tool): colored status output is the intended UX, not library output.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$VolumeLabel = '1S-WIN11',
    [string[]]$VhdPath,
    [string]$DriverRoot,
    [string]$ScratchRoot,
    [switch]$SkipInstallImage,
    [switch]$SkipWinPEDriverFolder,
    [switch]$ForceUnsigned
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $sourceRoot 'Deployment\Scripts\Common.ps1')

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Dism {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Activity
    )

    [string[]]$output = @(& dism.exe @Arguments /English 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        $tail = ($output | Select-Object -Last 15) -join [Environment]::NewLine
        $dismLog = Join-Path $env:WINDIR 'Logs\DISM\dism.log'
        throw "DISM failed during '$Activity' (exit code $LASTEXITCODE).`n$tail`nFull log: $dismLog"
    }
    return $output
}

function Get-WimImageIndexList {
    [CmdletBinding()]
    [OutputType([int[]])]
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $output = Invoke-Dism -Arguments @('/Get-ImageInfo', "/ImageFile:$ImagePath") -Activity "read image info from $ImagePath"
    $indexes = @()
    foreach ($line in $output) {
        if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') {
            $indexes += [int]$Matches[1]
        }
    }
    if ($indexes.Count -eq 0) {
        throw "No image indexes found in $ImagePath. Is this a valid WIM file?"
    }
    return $indexes
}

function Add-DriverToWindowsImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$DriverRoot,
        [Parameter(Mandatory = $true)][string]$MountDir,
        [switch]$ForceUnsigned
    )

    $indexes = Get-WimImageIndexList -ImagePath $ImagePath
    $imageName = Split-Path -Leaf $ImagePath

    foreach ($index in $indexes) {
        Write-Host "    Servicing $imageName index $index of $($indexes.Count)..." -ForegroundColor Cyan

        Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$ImagePath", "/Index:$index", "/MountDir:$MountDir") -Activity "mount $imageName index $index"
        try {
            $addArguments = @("/Image:$MountDir", '/Add-Driver', "/Driver:$DriverRoot", '/Recurse')
            if ($ForceUnsigned) { $addArguments += '/ForceUnsigned' }
            $addOutput = Invoke-Dism -Arguments $addArguments -Activity "add drivers to $imageName index $index"

            foreach ($line in $addOutput) {
                if ($line -match 'driver package\(s\)|The driver package was successfully installed') {
                    Write-Host "      $($line.Trim())" -ForegroundColor Gray
                }
            }

            Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$MountDir", '/Commit') -Activity "commit $imageName index $index"
        } catch {
            Write-Host "    Servicing failed; discarding the mounted image..." -ForegroundColor Yellow
            try {
                Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$MountDir", '/Discard') -Activity "discard $imageName index $index"
            } catch {
                try {
                    Invoke-Dism -Arguments @('/Cleanup-Mountpoints') -Activity 'clean up orphaned DISM mount points'
                } catch {
                    Write-Host "    DISM mount point cleanup also failed; run 'dism /Cleanup-Mountpoints' manually." -ForegroundColor Yellow
                }
            }
            throw
        }
    }
}

function Get-MediaVolumeFileSystem {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Root)

    $qualifier = $null
    try {
        $qualifier = (Split-Path -Qualifier $Root -ErrorAction Stop)
    } catch {
        return $null
    }
    if (-not $qualifier) { return $null }

    try {
        $volume = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$qualifier'" -ErrorAction Stop |
            Select-Object -First 1
        if ($volume -and $volume.FileSystem) { return [string]$volume.FileSystem }
    } catch {
        # Best effort only: an extracted-ISO folder or unusual volume simply skips the FAT32 size guard.
        Write-Verbose "Could not determine the filesystem of $qualifier`: $($_.Exception.Message)"
    }
    return $null
}

function Update-MediaImageWithDrivers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$MediaImagePath,
        [Parameter(Mandatory = $true)][string]$DriverRoot,
        [Parameter(Mandatory = $true)][string]$ScratchRoot,
        [Parameter(Mandatory = $true)][string]$MountDir,
        [string]$MediaFileSystem,
        [switch]$ForceUnsigned
    )

    $imageName = Split-Path -Leaf $MediaImagePath
    $workingCopy = Join-Path $ScratchRoot $imageName

    Write-Host "    Copying $imageName to scratch ($([math]::Round((Get-Item -LiteralPath $MediaImagePath).Length / 1MB)) MB)..." -ForegroundColor Gray
    Copy-Item -LiteralPath $MediaImagePath -Destination $workingCopy -Force
    (Get-Item -LiteralPath $workingCopy).IsReadOnly = $false

    Add-DriverToWindowsImage -ImagePath $workingCopy -DriverRoot $DriverRoot -MountDir $MountDir -ForceUnsigned:$ForceUnsigned

    $newLength = (Get-Item -LiteralPath $workingCopy).Length
    if ($MediaFileSystem -eq 'FAT32' -and $newLength -ge 4GB) {
        throw "$imageName is now $([math]::Round($newLength / 1GB, 2)) GB, which exceeds the FAT32 4 GB file limit of the media. Split it into .swm files or rebuild the USB with a filesystem that supports large files."
    }

    Write-Host "    Copying serviced $imageName back to the media..." -ForegroundColor Gray
    $destination = Get-Item -LiteralPath $MediaImagePath
    if ($destination.IsReadOnly) { $destination.IsReadOnly = $false }
    Copy-Item -LiteralPath $workingCopy -Destination $MediaImagePath -Force
    Remove-Item -LiteralPath $workingCopy -Force -ErrorAction SilentlyContinue
}

function Find-WindowsInstallMediaRoot {
    <#
        Given a mounted VHD's disk number, finds the partition containing sources\boot.wim (i.e.
        actual Windows Setup media) and assigns it a drive letter if it does not already have
        one. Deliberately does not filter by volume label: -UsbRoot already accepts any folder
        with sources\boot.wim under it regardless of label, so a -VhdPath target is held to the
        exact same definition of "valid media" instead of requiring the 1S-WIN11 label
        specifically (that stricter, label-based lookup belongs to Update-VhdBootMedia.ps1, which
        only ever targets this toolkit's own deployment VHD).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][int]$DiskNumber)

    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    foreach ($partition in $partitions) {
        if (-not $partition.DriveLetter) {
            try {
                $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
                $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction Stop
            } catch {
                # Reserved/system partitions (EFI, MSR) routinely refuse a drive letter; they
                # never contain sources\boot.wim anyway, so skip rather than fail the whole scan.
                continue
            }
        }
        if (-not $partition.DriveLetter) { continue }

        $candidateRoot = "$($partition.DriveLetter):\"

        # Get-Partition can report a drive letter slightly before the OS has actually finished
        # wiring it up -- observed in practice on a remounted VHD, where Test-Path/Get-ChildItem
        # throw "Cannot find drive" for a letter Get-Partition already reports, even though
        # nothing else assigned that letter to another volume. Poll with [IO.Directory]::Exists
        # (plain .NET, independent of PowerShell's own FileSystem provider) instead of trusting
        # the first read; real hardware/VHD mounts settle in well under this budget.
        $driveIsLive = $false
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            if ([System.IO.Directory]::Exists($candidateRoot)) { $driveIsLive = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $driveIsLive) { continue }

        if (Test-Path -LiteralPath (Join-Path $candidateRoot 'sources\boot.wim') -PathType Leaf) {
            return $candidateRoot
        }
    }
    return $null
}

# --- Preconditions ------------------------------------------------------------

if (-not (Get-Command dism.exe -ErrorAction SilentlyContinue)) {
    throw 'dism.exe was not found. This script must run on Windows.'
}
if (-not (Test-IsAdministrator)) {
    throw 'DISM image servicing requires elevation. Re-run this script from an Administrator PowerShell session.'
}

if ([string]::IsNullOrWhiteSpace($DriverRoot)) {
    $DriverRoot = Join-Path $sourceRoot 'Deployment\Drivers\Storage'
}
if (-not (Test-Path -LiteralPath $DriverRoot -PathType Container)) {
    throw "Driver folder not found: $DriverRoot"
}
$DriverRoot = (Resolve-Path -LiteralPath $DriverRoot).Path

$driverInfs = @(Get-ChildItem -LiteralPath $DriverRoot -Filter '*.inf' -Recurse -File)
if ($driverInfs.Count -eq 0) {
    throw "No driver packages (*.inf) were found under $DriverRoot. Place extracted storage controller driver packages in Deployment\Drivers\Storage\<Vendor>\ (e.g. Intel VMD/RST, AMD RAID) and re-run. Packages must be extracted INF/SYS/CAT sets, not .exe installers."
}

if (-not [string]::IsNullOrWhiteSpace($UsbRoot) -and $VhdPath) {
    throw 'Specify either -UsbRoot or -VhdPath, not both.'
}

# --- Resolve targets -----------------------------------------------------------

$targets = @()
if ($VhdPath) {
    foreach ($cmdletName in @('Mount-VHD', 'Dismount-VHD', 'Get-Partition', 'Add-PartitionAccessPath', 'Get-Volume')) {
        if (-not (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
            throw "$cmdletName is not available on this platform. -VhdPath requires Windows 10/11 Pro, Enterprise, or Education with the Hyper-V feature enabled."
        }
    }

    $resolvedVhdPaths = @()
    foreach ($rawPath in $VhdPath) {
        $matchingPaths = @(Resolve-Path -Path $rawPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path)
        if ($matchingPaths.Count -eq 0) {
            throw "VHD not found: $rawPath"
        }
        $resolvedVhdPaths += $matchingPaths
    }
    $resolvedVhdPaths = @($resolvedVhdPaths | Select-Object -Unique)

    foreach ($resolvedVhdPath in $resolvedVhdPaths) {
        $extension = [IO.Path]::GetExtension($resolvedVhdPath)
        if ($extension -notin '.vhd', '.vhdx') {
            throw "$resolvedVhdPath does not look like a .vhd/.vhdx file (extension '$extension')."
        }
        $targets += [ordered]@{ Description = $resolvedVhdPath; VhdPath = $resolvedVhdPath; Root = $null }
    }
} else {
    if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
        $UsbRoot = Get-UsbRoot -VolumeLabel $VolumeLabel
    }
    if (-not (Test-Path -LiteralPath $UsbRoot -PathType Container)) {
        throw "Media root not found: $UsbRoot"
    }
    $UsbRoot = (Resolve-Path -LiteralPath $UsbRoot).Path
    $targets += [ordered]@{ Description = $UsbRoot; VhdPath = $null; Root = $UsbRoot }
}

if ([string]::IsNullOrWhiteSpace($ScratchRoot)) {
    $ScratchRoot = Join-Path $env:TEMP ("Win11USB-DriverIntegration-{0}" -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
}

Write-Host ''
Write-Host '=== Storage driver integration ===' -ForegroundColor White
Write-Host "Driver source: $DriverRoot ($($driverInfs.Count) driver package(s))"
foreach ($inf in $driverInfs) {
    Write-Host "  - $($inf.FullName.Substring($DriverRoot.Length).TrimStart('\'))" -ForegroundColor Gray
}
Write-Host "Target(s)    : $($targets.Count)"
foreach ($target in $targets) {
    Write-Host "  - $($target.Description)" -ForegroundColor Gray
}
Write-Host ''

# --- Service each target, best-effort: one bad VHD must not block the rest ----

$results = @()
for ($targetIndex = 0; $targetIndex -lt $targets.Count; $targetIndex++) {
    $target = $targets[$targetIndex]
    $targetScratchRoot = Join-Path $ScratchRoot ("target-{0}" -f ($targetIndex + 1))
    $mountDir = Join-Path $targetScratchRoot 'Mount'

    Write-Host "--- Target $($targetIndex + 1) of $($targets.Count): $($target.Description) ---" -ForegroundColor White

    $mountedVhd = $null
    try {
        if ($target.VhdPath) {
            $existingVhd = Get-VHD -Path $target.VhdPath -ErrorAction SilentlyContinue
            if ($existingVhd -and $existingVhd.Attached) {
                Write-Host "  Dismounting $($target.VhdPath) (already attached from a previous run)..." -ForegroundColor Yellow
                Dismount-VHD -Path $target.VhdPath -ErrorAction Stop
            }
            Write-Host "  Mounting $($target.VhdPath)..." -ForegroundColor Cyan
            $mountedVhd = Mount-VHD -Path $target.VhdPath -Passthru -ErrorAction Stop

            $root = Find-WindowsInstallMediaRoot -DiskNumber $mountedVhd.DiskNumber
            if (-not $root) {
                throw "No partition with sources\boot.wim was found on $($target.VhdPath). Is this really Windows installation media?"
            }
            Write-Host "  Mounted at $root" -ForegroundColor Green
        } else {
            $root = $target.Root
        }

        $bootWim = Join-Path $root 'sources\boot.wim'
        if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
            throw "boot.wim not found at $bootWim. Point -UsbRoot/-VhdPath at Windows installation media (the folder/partition containing 'sources')."
        }

        if (Test-Path -LiteralPath $mountDir) {
            if (@(Get-ChildItem -LiteralPath $mountDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                throw "Mount directory $mountDir is not empty. A previous run may have left an image mounted; run 'dism /Cleanup-Mountpoints' and remove the folder, then retry."
            }
        } else {
            New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
        }

        $mediaFileSystem = Get-MediaVolumeFileSystem -Root $root
        Write-Host "  Media root: $root ($(if ($mediaFileSystem) { $mediaFileSystem } else { 'unknown filesystem' }))" -ForegroundColor Gray
        Write-Host "  Scratch   : $targetScratchRoot" -ForegroundColor Gray

        # boot.wim: this is the fix for the disk-numbering problem. With the storage driver
        # boot-critical in both indexes, the internal disk is visible the moment WinPE/Setup
        # starts, so the USB no longer enumerates as disk 0.
        Write-Host '  [1/3] Integrating drivers into boot.wim (WinPE + Windows Setup)...' -ForegroundColor White
        Update-MediaImageWithDrivers -MediaImagePath $bootWim -DriverRoot $DriverRoot -ScratchRoot $targetScratchRoot -MountDir $mountDir -MediaFileSystem $mediaFileSystem -ForceUnsigned:$ForceUnsigned
        Write-Host '        boot.wim done.' -ForegroundColor Green

        # install image: ensures the deployed OS has the controller driver for its own first
        # boot. ESD/SWM cannot be serviced in place; $WinPEDriver$ (step 3) covers the installed
        # OS there because the generated OSIT-DiskPart script runs dism /Add-Driver against the
        # applied image.
        Write-Host '  [2/3] Integrating drivers into the install image...' -ForegroundColor White
        $installWim = Join-Path $root 'sources\install.wim'
        $installEsd = Join-Path $root 'sources\install.esd'
        $installSwm = Join-Path $root 'sources\install.swm'
        if ($SkipInstallImage) {
            Write-Host '        Skipped (-SkipInstallImage).' -ForegroundColor Yellow
        } elseif (Test-Path -LiteralPath $installWim -PathType Leaf) {
            Update-MediaImageWithDrivers -MediaImagePath $installWim -DriverRoot $DriverRoot -ScratchRoot $targetScratchRoot -MountDir $mountDir -MediaFileSystem $mediaFileSystem -ForceUnsigned:$ForceUnsigned
            Write-Host '        install.wim done.' -ForegroundColor Green
        } elseif ((Test-Path -LiteralPath $installEsd -PathType Leaf) -or (Test-Path -LiteralPath $installSwm -PathType Leaf)) {
            Write-Host '        install.esd/.swm cannot be serviced in place; skipping. The $WinPEDriver$ folder (next step) still gets these drivers into the installed OS.' -ForegroundColor Yellow
        } else {
            Write-Host '        No install.wim/.esd/.swm found under sources; skipping.' -ForegroundColor Yellow
        }

        # $WinPEDriver$: consumed by the generated OSIT-DiskPart setup script, which drvloads
        # these in PE (harmless now) and injects them into the applied image.
        Write-Host '  [3/3] Mirroring drivers into $WinPEDriver$\Storage...' -ForegroundColor White
        if ($SkipWinPEDriverFolder) {
            Write-Host '        Skipped (-SkipWinPEDriverFolder).' -ForegroundColor Yellow
        } else {
            $peDriverStorage = Join-Path (Join-Path $root '$WinPEDriver$') 'Storage'
            if (Test-Path -LiteralPath $peDriverStorage) {
                Remove-Item -LiteralPath $peDriverStorage -Recurse -Force
            }
            New-Item -Path $peDriverStorage -ItemType Directory -Force | Out-Null
            Copy-Item -Path (Join-Path $DriverRoot '*') -Destination $peDriverStorage -Recurse -Force
            Write-Host "        Copied to $peDriverStorage." -ForegroundColor Green
        }

        Remove-Item -LiteralPath $targetScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
        $results += [ordered]@{ Target = $target.Description; Succeeded = $true; Error = $null }
    } catch {
        Write-Host "  Target failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Scratch directory kept for inspection: $targetScratchRoot" -ForegroundColor Yellow
        Write-Host "  If an image is still mounted, run: dism /Unmount-Image /MountDir:`"$mountDir`" /Discard" -ForegroundColor Yellow
        $results += [ordered]@{ Target = $target.Description; Succeeded = $false; Error = $_.Exception.Message }
    } finally {
        if ($mountedVhd) {
            Write-Host "  Dismounting $($target.VhdPath)..." -ForegroundColor Cyan
            Dismount-VHD -Path $target.VhdPath -ErrorAction SilentlyContinue
        }
    }
    Write-Host ''
}

Write-Host '=== Summary ===' -ForegroundColor White
foreach ($result in $results) {
    if ($result.Succeeded) {
        Write-Host "  [OK]   $($result.Target)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $($result.Target): $($result.Error)" -ForegroundColor Red
    }
}
Write-Host ''

$failedTargets = @($results | Where-Object { -not $_.Succeeded })
if ($failedTargets.Count -gt 0) {
    throw "$($failedTargets.Count) of $($targets.Count) target(s) failed driver integration. See the summary above."
}

Write-Host 'Driver integration complete.' -ForegroundColor Green
Write-Host 'The storage drivers are now boot-critical in boot.wim: the internal disk should enumerate as disk 0 with the USB after it, so the unattended disk layout targets the correct disk.'
Write-Host 'Re-run this script whenever driver packages under Deployment\Drivers\Storage change. It is independent of Initialize-UsbDeployment.ps1 and can run before or after it.'
