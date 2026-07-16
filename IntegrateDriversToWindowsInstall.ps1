<#
.SYNOPSIS
    Integrates storage controller drivers into the Windows installation media on the
    1S-WIN11 deployment USB so they are present before Windows Setup enumerates disks.

.DESCRIPTION
    When a notebook's storage controller driver (e.g. Intel VMD/RST, AMD RAID) is not in
    boot.wim, Windows Setup boots without seeing the internal drive, the USB stick becomes
    disk 0, and the unattended disk layout targets the wrong disk. Loading the driver
    later (drvload / $WinPEDriver$) makes the internal drive appear as disk 1, which
    still breaks the disk-0 assumption.

    This script services the media offline with DISM so the drivers are boot-critical:

      1. Injects every driver under Deployment\Drivers\Storage into ALL indexes of
         <UsbRoot>\sources\boot.wim (index 1 = WinPE, index 2 = Windows Setup).
      2. Injects the same drivers into ALL indexes of <UsbRoot>\sources\install.wim,
         so the installed OS can boot from the controller on first boot.
         install.esd / install.swm cannot be serviced in place; those are skipped with
         a warning (step 3 still covers the installed OS in that case).
      3. Mirrors the drivers into <UsbRoot>\$WinPEDriver$\Storage. The generated
         OSIT-DiskPart setup script injects everything in $WinPEDriver$ into the applied
         image with dism /Add-Driver, so the installed OS gets the drivers even when the
         install image itself could not be serviced.

    Images are copied to a local scratch directory for servicing (DISM mounts are slow
    and fragile directly on FAT32 removable media) and copied back on success. Ensure
    the scratch drive has free space of roughly twice the largest image being serviced.

    Requires an elevated (Administrator) PowerShell session on Windows. Works under
    Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER UsbRoot
    Root of the installation media (e.g. E:\ or an extracted-ISO folder). When omitted,
    the USB is located by volume label, never by drive letter.

.PARAMETER VolumeLabel
    Volume label used to locate the deployment USB when -UsbRoot is not supplied.
    Defaults to 1S-WIN11.

.PARAMETER DriverRoot
    Folder scanned recursively for driver packages (*.inf). Defaults to
    Deployment\Drivers\Storage in this toolkit checkout.

.PARAMETER ScratchRoot
    Local working directory for image copies and DISM mount points. Defaults to a
    timestamped folder under %TEMP%. Removed on success.

.PARAMETER SkipInstallImage
    Only service boot.wim; leave install.wim untouched.

.PARAMETER SkipWinPEDriverFolder
    Do not mirror the drivers into <UsbRoot>\$WinPEDriver$\Storage.

.PARAMETER ForceUnsigned
    Pass /ForceUnsigned to DISM for unsigned driver packages. Avoid unless a vendor
    package is unsigned and you have verified its provenance.

.EXAMPLE
    .\IntegrateDriversToWindowsInstall.ps1
    Locates the 1S-WIN11 USB and integrates Deployment\Drivers\Storage into its media.

.EXAMPLE
    .\IntegrateDriversToWindowsInstall.ps1 -UsbRoot E:\ -SkipInstallImage
    Services only E:\sources\boot.wim and refreshes E:\$WinPEDriver$\Storage.
#>
[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This script is an interactive technician CLI (media servicing tool): colored status output is the intended UX, not library output.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$VolumeLabel = '1S-WIN11',
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
        Write-Host "  Servicing $imageName index $index of $($indexes.Count)..." -ForegroundColor Cyan

        Invoke-Dism -Arguments @('/Mount-Image', "/ImageFile:$ImagePath", "/Index:$index", "/MountDir:$MountDir") -Activity "mount $imageName index $index"
        try {
            $addArguments = @("/Image:$MountDir", '/Add-Driver', "/Driver:$DriverRoot", '/Recurse')
            if ($ForceUnsigned) { $addArguments += '/ForceUnsigned' }
            $addOutput = Invoke-Dism -Arguments $addArguments -Activity "add drivers to $imageName index $index"

            foreach ($line in $addOutput) {
                if ($line -match 'driver package\(s\)|The driver package was successfully installed') {
                    Write-Host "    $($line.Trim())" -ForegroundColor Gray
                }
            }

            Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$MountDir", '/Commit') -Activity "commit $imageName index $index"
        } catch {
            Write-Host "  Servicing failed; discarding the mounted image..." -ForegroundColor Yellow
            try {
                Invoke-Dism -Arguments @('/Unmount-Image', "/MountDir:$MountDir", '/Discard') -Activity "discard $imageName index $index"
            } catch {
                try {
                    Invoke-Dism -Arguments @('/Cleanup-Mountpoints') -Activity 'clean up orphaned DISM mount points'
                } catch {
                    Write-Host "  DISM mount point cleanup also failed; run 'dism /Cleanup-Mountpoints' manually." -ForegroundColor Yellow
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

    Write-Host "  Copying $imageName to scratch ($([math]::Round((Get-Item -LiteralPath $MediaImagePath).Length / 1MB)) MB)..." -ForegroundColor Gray
    Copy-Item -LiteralPath $MediaImagePath -Destination $workingCopy -Force
    (Get-Item -LiteralPath $workingCopy).IsReadOnly = $false

    Add-DriverToWindowsImage -ImagePath $workingCopy -DriverRoot $DriverRoot -MountDir $MountDir -ForceUnsigned:$ForceUnsigned

    $newLength = (Get-Item -LiteralPath $workingCopy).Length
    if ($MediaFileSystem -eq 'FAT32' -and $newLength -ge 4GB) {
        throw "$imageName is now $([math]::Round($newLength / 1GB, 2)) GB, which exceeds the FAT32 4 GB file limit of the media. Split it into .swm files or rebuild the USB with a filesystem that supports large files."
    }

    Write-Host "  Copying serviced $imageName back to the media..." -ForegroundColor Gray
    $destination = Get-Item -LiteralPath $MediaImagePath
    if ($destination.IsReadOnly) { $destination.IsReadOnly = $false }
    Copy-Item -LiteralPath $workingCopy -Destination $MediaImagePath -Force
    Remove-Item -LiteralPath $workingCopy -Force -ErrorAction SilentlyContinue
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

if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
    $UsbRoot = Get-UsbRoot -VolumeLabel $VolumeLabel
}
if (-not (Test-Path -LiteralPath $UsbRoot -PathType Container)) {
    throw "Media root not found: $UsbRoot"
}
$UsbRoot = (Resolve-Path -LiteralPath $UsbRoot).Path

$bootWim = Join-Path $UsbRoot 'sources\boot.wim'
if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
    throw "boot.wim not found at $bootWim. Point -UsbRoot at the root of Windows installation media (the folder containing 'sources')."
}

if ([string]::IsNullOrWhiteSpace($ScratchRoot)) {
    $ScratchRoot = Join-Path $env:TEMP ("Win11USB-DriverIntegration-{0}" -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
}
$mountDir = Join-Path $ScratchRoot 'Mount'
if (Test-Path -LiteralPath $mountDir) {
    if (@(Get-ChildItem -LiteralPath $mountDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        throw "Mount directory $mountDir is not empty. A previous run may have left an image mounted; run 'dism /Cleanup-Mountpoints' and remove the folder, then retry."
    }
} else {
    New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
}

$mediaFileSystem = Get-MediaVolumeFileSystem -Root $UsbRoot

Write-Host ''
Write-Host '=== Storage driver integration ===' -ForegroundColor White
Write-Host "Media root   : $UsbRoot ($(if ($mediaFileSystem) { $mediaFileSystem } else { 'unknown filesystem' }))"
Write-Host "Driver source: $DriverRoot ($($driverInfs.Count) driver package(s))"
foreach ($inf in $driverInfs) {
    Write-Host "  - $($inf.FullName.Substring($DriverRoot.Length).TrimStart('\'))" -ForegroundColor Gray
}
Write-Host "Scratch      : $ScratchRoot"
Write-Host ''

$succeeded = $false
try {
    # --- boot.wim: this is the fix for the disk-numbering problem. With the storage
    # driver boot-critical in both indexes, the internal disk is visible the moment
    # WinPE/Setup starts, so the USB no longer enumerates as disk 0.
    Write-Host '[1/3] Integrating drivers into boot.wim (WinPE + Windows Setup)...' -ForegroundColor White
    Update-MediaImageWithDrivers -MediaImagePath $bootWim -DriverRoot $DriverRoot -ScratchRoot $ScratchRoot -MountDir $mountDir -MediaFileSystem $mediaFileSystem -ForceUnsigned:$ForceUnsigned
    Write-Host '      boot.wim done.' -ForegroundColor Green

    # --- install image: ensures the deployed OS has the controller driver for its
    # own first boot. ESD/SWM cannot be serviced in place; $WinPEDriver$ (step 3)
    # covers the installed OS there because the generated OSIT-DiskPart script runs
    # dism /Add-Driver against the applied image.
    Write-Host '[2/3] Integrating drivers into the install image...' -ForegroundColor White
    $installWim = Join-Path $UsbRoot 'sources\install.wim'
    $installEsd = Join-Path $UsbRoot 'sources\install.esd'
    $installSwm = Join-Path $UsbRoot 'sources\install.swm'
    if ($SkipInstallImage) {
        Write-Host '      Skipped (-SkipInstallImage).' -ForegroundColor Yellow
    } elseif (Test-Path -LiteralPath $installWim -PathType Leaf) {
        Update-MediaImageWithDrivers -MediaImagePath $installWim -DriverRoot $DriverRoot -ScratchRoot $ScratchRoot -MountDir $mountDir -MediaFileSystem $mediaFileSystem -ForceUnsigned:$ForceUnsigned
        Write-Host '      install.wim done.' -ForegroundColor Green
    } elseif ((Test-Path -LiteralPath $installEsd -PathType Leaf) -or (Test-Path -LiteralPath $installSwm -PathType Leaf)) {
        Write-Host '      install.esd/.swm cannot be serviced in place; skipping. The $WinPEDriver$ folder (next step) still gets these drivers into the installed OS.' -ForegroundColor Yellow
    } else {
        Write-Host '      No install.wim/.esd/.swm found under sources; skipping.' -ForegroundColor Yellow
    }

    # --- $WinPEDriver$: consumed by the generated OSIT-DiskPart setup script, which
    # drvloads these in PE (harmless now) and injects them into the applied image.
    Write-Host '[3/3] Mirroring drivers into $WinPEDriver$\Storage...' -ForegroundColor White
    if ($SkipWinPEDriverFolder) {
        Write-Host '      Skipped (-SkipWinPEDriverFolder).' -ForegroundColor Yellow
    } else {
        $peDriverStorage = Join-Path (Join-Path $UsbRoot '$WinPEDriver$') 'Storage'
        if (Test-Path -LiteralPath $peDriverStorage) {
            Remove-Item -LiteralPath $peDriverStorage -Recurse -Force
        }
        New-Item -Path $peDriverStorage -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $DriverRoot '*') -Destination $peDriverStorage -Recurse -Force
        Write-Host "      Copied to $peDriverStorage." -ForegroundColor Green
    }

    $succeeded = $true
} finally {
    if ($succeeded) {
        Remove-Item -LiteralPath $ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host ''
        Write-Host "Scratch directory kept for inspection: $ScratchRoot" -ForegroundColor Yellow
        Write-Host "If an image is still mounted, run: dism /Unmount-Image /MountDir:`"$mountDir`" /Discard" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Driver integration complete.' -ForegroundColor Green
Write-Host 'The storage drivers are now boot-critical in boot.wim: the internal disk should enumerate as disk 0 with the USB after it, so the unattended disk layout targets the correct disk.'
Write-Host 'Re-run this script whenever driver packages under Deployment\Drivers\Storage change. It is independent of Initialize-UsbDeployment.ps1 and can run before or after it.'
