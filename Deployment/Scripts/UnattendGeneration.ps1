<#
    .SYNOPSIS
        Shared Autounattend.xml / OSIT-DiskPart.txt generation logic for the OSIT Windows 11 USB
        deployment toolkit.

    .DESCRIPTION
        This file is dot-sourced by both Initialize-UsbDeployment.ps1 (which writes the generated
        files to a real USB) and Validate-Unattend.ps1 (which, in -Ci mode, generates the same
        files into a temp folder so CI can validate exactly what production would write, including
        the windowsPE wipe/partition block and the 259-character RunSynchronousCommand Path
        constraint).

        Keeping this logic in one place means there is only one code path that turns
        Deployment\Config\deployment_config.json plus the Autounattend.xml template into the
        answer file and diskpart script a machine actually boots from.
#>

[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'The wipe/no-wipe banners here are deliberate, colored technician-facing warnings shown at generation time (both from Initialize-UsbDeployment.ps1''s interactive run and Validate-Unattend.ps1''s console output) about whether the produced media will destructively partition a disk; this is intentional interactive CLI UX, not library output.')]
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$script:DiskPartScriptFileName = 'OSIT-DiskPart.txt'
$script:DiskPartLogFileName = 'OSIT-DiskPart.log'
$script:DiskCheckScriptFileName = 'OSIT-DiskCheck.cmd'
$script:DiskCheckLogFileName = 'OSIT-DiskCheck.log'
$script:DiskCheckOkFileName = 'OSIT-DiskCheck.ok'
$script:DiskDiagScriptFileName = 'OSIT-DiskDiag.vbs'
$script:DiskDiagLogFileName = 'OSIT-DiskDiag.log'
$script:StorageDriversRelativePath = 'Deployment\Drivers\Storage'

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-DiskDiagnosticScript {
    <#
        .SYNOPSIS
            Builds OSIT-DiskDiag.vbs: a WinPE-safe on-failure diagnostic that a technician sees
            immediately (on screen, via a blocking MsgBox) and can also read back later from the
            USB, instead of having to dig through OSIT-DiskCheck.log to work out why the disk
            safety net refused to wipe.

        .DESCRIPTION
            Run only from OSIT-DiskCheck.cmd's own failure branches (fewer than $MinDiskCount
            disks visible, or the configured target disk not strictly larger than every other
            visible disk) -- covers both the original "a storage driver is likely missing"
            scenario and the field-confirmed one where every needed disk is already visible but
            WinPE's enumeration simply put the USB/boot media at the configured disk ID instead
            of the internal disk. Gathers, via WMI: the notebook's own make/model
            (Win32_ComputerSystem) and serial number (Win32_BIOS) so a technician can identify
            the exact machine without reading a label; every disk WinPE can currently see
            (Win32_DiskDrive), each tagged with its actual PHYSICALDRIVE/diskpart disk number
            (Index) rather than an arbitrary list position, so it can be read directly back into
            wipe_repartition_disk_id; and every PnP device with no working driver
            (Win32_PnPEntity where ConfigManagerErrorCode <> 0), whose PNPDeviceID's VEN_/DEV_
            tokens identify exactly which storage controller chipset needs a driver.

            Also flags every visible disk that is Fixed/non-removable and at least as large as
            the configured target disk but is NOT the configured target disk, as a likely-correct
            candidate. This is deliberately diagnostic-only guidance for a technician to act on
            (integrate the storage driver into the media with IntegrateDriversToWindowsInstall.ps1
            so the internal disk enumerates at boot, or update wipe_repartition_disk_id and
            regenerate the USB) rather than something this script or OSIT-DiskCheck.cmd
            auto-switches to: Windows Setup parses ImageInstall/InstallTo/DiskID from the answer
            file into memory before any windowsPE RunSynchronousCommand runs, so nothing running
            at this point can change which disk Setup will actually install to.

            Writes the same report to the given output path (USB root) and shows it as a modal
            MsgBox. MsgBox renders as a real dialog under cscript.exe as much as wscript.exe --
            the cscript/wscript distinction only changes plain WScript.Echo's behaviour, not
            VBScript's own MsgBox -- so this uses cscript.exe, which is guaranteed present in
            WinPE, rather than switching hosts.

        .NOTES
            UNVERIFIED ON REAL WINPE: whether a MsgBox raised by a windowsPE-pass
            RunSynchronousCommand script actually renders on top of Windows Setup's own UI (as
            opposed to being suppressed, or blocking invisibly) cannot be exercised in this
            sandbox. Confirm via a Tier 1 Hyper-V rehearsal with a deliberately-broken storage
            driver scenario before relying on this in the field.
    #>
    param(
        [int]$DiskId,
        [int]$MinDiskCount
    )

    return @(
        'On Error Resume Next',
        'outputPath = WScript.Arguments(0)',
        # Numeric-only assignments (no VBScript string literals on these lines at all) --
        # deliberately kept separate from every message-building line below so that every line
        # with a VBScript string literal can stay a plain single-quoted PowerShell string, with
        # VBScript's own double quotes passing through unescaped. Mixing PowerShell string
        # interpolation with VBScript's double-quote literals on the same line is exactly what
        # produced a mismatched-quote-count parse failure the first time these companion .vbs
        # scripts were written this way -- not repeating that here.
        "minDiskCount = $MinDiskCount",
        "targetDiskId = $DiskId",
        'Set wmi = GetObject("winmgmts:\\.\root\cimv2")',
        '',
        'report = "=== OSIT Disk Diagnostic ===" & vbCrLf',
        'report = report & "Looking for at least " & minDiskCount & " disk(s); target disk " & targetDiskId & " must be strictly larger than every other visible disk." & vbCrLf & vbCrLf',
        '',
        'report = report & "Device make/model:" & vbCrLf',
        'Set sysSet = wmi.ExecQuery("SELECT Manufacturer, Model FROM Win32_ComputerSystem")',
        'For Each sys In sysSet',
        '  report = report & "  " & sys.Manufacturer & " " & sys.Model & vbCrLf',
        'Next',
        'Set biosSet = wmi.ExecQuery("SELECT SerialNumber FROM Win32_BIOS")',
        'For Each b In biosSet',
        '  report = report & "  Serial: " & b.SerialNumber & vbCrLf',
        'Next',
        '',
        # First pass: resolve the configured target disk's size so the main loop below can flag
        # every other disk that is at least as large as a likely-correct candidate.
        'targetSizeGb = -1',
        'Set targetSet = wmi.ExecQuery("SELECT Index, Size FROM Win32_DiskDrive")',
        'For Each t In targetSet',
        '  If t.Index = targetDiskId And IsNumeric(t.Size) Then targetSizeGb = CLng(t.Size / 1024 / 1024 / 1024)',
        'Next',
        '',
        'report = report & vbCrLf & "Disks currently visible to WinPE (Disk N matches diskpart/PHYSICALDRIVE numbering):" & vbCrLf',
        'Set diskSet = wmi.ExecQuery("SELECT Index, Model, InterfaceType, MediaType, Size, PNPDeviceID FROM Win32_DiskDrive")',
        'diskCount = 0',
        'candidates = ""',
        'For Each d In diskSet',
        '  diskCount = diskCount + 1',
        '  sizeText = "unknown size"',
        '  sizeGb = -1',
        '  If IsNumeric(d.Size) Then',
        '    sizeGb = CLng(d.Size / 1024 / 1024 / 1024)',
        '    sizeText = CStr(sizeGb) & " GB"',
        '  End If',
        '  report = report & "  Disk " & d.Index & ": " & d.Model & "  [" & d.InterfaceType & "/" & d.MediaType & ", " & sizeText & "]" & vbCrLf',
        '  report = report & "     " & d.PNPDeviceID & vbCrLf',
        '  If d.MediaType = "Fixed hard disk media" And sizeGb >= targetSizeGb And d.Index <> targetDiskId Then',
        '    candidates = candidates & "  Disk " & d.Index & " (" & sizeText & ")" & vbCrLf',
        '  End If',
        'Next',
        'If diskCount = 0 Then report = report & "  (none detected at all)" & vbCrLf',
        '',
        'If candidates <> "" Then',
        '  report = report & vbCrLf & "Disk " & targetDiskId & " is configured (wipe_repartition_disk_id), but these fixed, non-removable disks are at least as large -- one of them is likely the internal disk:" & vbCrLf & candidates',
        '  report = report & "Integrate this model" & Chr(39) & "s storage controller driver into the installation media with IntegrateDriversToWindowsInstall.ps1 so the internal disk is visible from the moment Setup boots and enumerates ahead of the USB, or update wipe_repartition_disk_id in deployment_config.json and regenerate the USB -- retrying on this same media will hit the same check again." & vbCrLf',
        'End If',
        '',
        'report = report & vbCrLf & "Devices with no working driver (the storage controller is likely one of these):" & vbCrLf',
        'Set pnpSet = wmi.ExecQuery("SELECT Name, Manufacturer, PNPDeviceID, ConfigManagerErrorCode FROM Win32_PnPEntity WHERE ConfigManagerErrorCode <> 0")',
        'problemCount = 0',
        'For Each p In pnpSet',
        '  problemCount = problemCount + 1',
        '  report = report & "  " & problemCount & ". " & p.Name & " (" & p.Manufacturer & ")  [error " & p.ConfigManagerErrorCode & "]" & vbCrLf',
        '  report = report & "     " & p.PNPDeviceID & vbCrLf',
        'Next',
        'If problemCount = 0 Then report = report & "  (none -- every enumerated device already has a driver)" & vbCrLf',
        '',
        'On Error Resume Next',
        'Set fso = CreateObject("Scripting.FileSystemObject")',
        'Set outFile = fso.OpenTextFile(outputPath, 8, True)',
        'outFile.WriteLine report',
        'outFile.Close',
        '',
        'MsgBox report, vbOKOnly + vbExclamation, "OSIT: disk safety check failed -- integrate the storage driver into this media (IntegrateDriversToWindowsInstall.ps1, drivers in Deployment\Drivers\Storage\<Vendor>)"'
    ) -join "`r`n"
}

function New-DiskCheckScript {
    <#
        .SYNOPSIS
            Builds OSIT-DiskCheck.cmd: a WinPE-safe (cmd.exe only, no PowerShell) pre-wipe safety
            net that runs before OSIT-DiskPart.txt ever touches a disk.

        .DESCRIPTION
            A missing boot-critical storage/RAID/NVMe driver can leave WinPE seeing only one
            fixed disk -- the USB/boot media itself -- which would then become "disk 0" and get
            wiped by the very next RunSynchronous command instead of the client's internal disk.
            This script: (1) loads any .inf drivers under the USB's Deployment\Drivers\Storage\
            <Vendor> folders via drvload, giving a missing storage driver a chance to make the
            real internal disk visible, (2) re-enumerates disks with diskpart, and (3) refuses
            to continue (exit /b 1) unless at least $MinDiskCount disks are visible AND the
            configured target disk is strictly larger than every other visible disk (a client
            notebook's internal disk is always larger than the deployment USB, so a target that
            is not the largest disk means the USB/boot media has taken the configured disk ID),
            and only then writes OSIT-DiskCheck.ok. Order=2's own RunSynchronous command line
            (built in New-WindowsPeArtifacts) requires that file to exist before it will run
            diskpart at all -- confirmed necessary in the field, where a machine failed this
            exact check (correctly: the USB stick had enumerated as the configured disk ID) and
            Windows Setup still ran Order=2's diskpart wipe anyway, destroying the USB's own
            partitions. A non-zero exit from this script is not sufficient on its own to stop
            Windows Setup from continuing to Order=2. Both failure branches run OSIT-DiskDiag.vbs
            (New-DiskDiagnosticScript) first, which both saves and shows on screen the machine's
            make/model/serial and exactly which storage controller has no working driver.

            These two relative checks deliberately replaced the earlier absolute thresholds
            (wipe_minimum_target_disk_gb) and per-property WMI assertions (OSIT-DiskAssert.vbs:
            partition-count/interface-type/media-type/maximum-size): the absolute checks
            false-failed in the field on a machine whose disk 0 genuinely was the internal disk
            (an existing base Windows 11 install meant it already had partitions), while the
            relative size comparison holds on any hardware without per-model tuning.

        .NOTES
            The disk-count/size FOR /F parsing has been reproduced and confirmed against real
            cmd.exe with mock "diskpart list disk" output (including the header's literal
            "Disk ###" row correctly excluded, and MB/GB/TB unit normalisation). The
            drvload/storage-driver-loading branch still cannot be exercised outside a real WinPE
            boot. Confirm end to end via a Tier 1 Hyper-V rehearsal (see TESTING.md) before
            relying on this for a release: check OSIT-DiskCheck.log on the rehearsal media/
            artifacts for the disk count and sizes it actually detected. Also note findstr.exe
            is NOT reliably present in a plain Windows Setup WinPE image -- do not reintroduce a
            dependency on it here. Confirmed on real hardware (not just the VM rehearsal, where
            the target disk happens to be blank) that disk enumeration order is not guaranteed:
            a machine with an existing OEM Windows install can still enumerate the USB boot
            media as disk 0, which is exactly the failure mode this check plus the
            OSIT-DiskCheck.ok gate exist to catch and refuse to wipe.
    #>
    param(
        [int]$DiskId,
        [int]$MinDiskCount
    )

    return @(
        '@echo off',
        'setlocal enabledelayedexpansion',
        '',
        'set OSITDRIVE=%~1',
        'if "%OSITDRIVE%"=="" set OSITDRIVE=%~d0',
        '',
        "set LOGFILE=%OSITDRIVE%\$script:DiskCheckLogFileName",
        "set DIAGSCRIPT=%OSITDRIVE%\$script:DiskDiagScriptFileName",
        "set DIAGLOG=%OSITDRIVE%\$script:DiskDiagLogFileName",
        "set TARGETDISK=$DiskId",
        "set MINDISKS=$MinDiskCount",
        "set OKFILE=%OSITDRIVE%\$script:DiskCheckOkFileName",
        '',
        # A prior run leaving this behind (or Windows Setup somehow re-running Order 1) must never
        # let a fresh failure be masked by a stale pass -- always start from "not OK".
        'del "%OKFILE%" >nul 2>&1',
        '',
        'echo OSIT-DiskCheck starting> "%LOGFILE%"',
        # A trailing numeric variable (0-9) directly touching ">>" is misparsed by cmd.exe as a
        # file-handle redirect (e.g. "2>>" means "redirect handle 2/stderr"), silently swallowing
        # the digit instead of writing it as text -- reproduced and confirmed with %DISKCOUNT%
        # while writing this. Every redirect below that could follow a numeric variable keeps a
        # deliberate trailing space before ">>" to keep the digit and the operator unambiguous.
        'echo Target disk id: %TARGETDISK%  Minimum disks required: %MINDISKS%  Target disk must be strictly larger than every other visible disk. >> "%LOGFILE%"',
        '',
        "set DRIVERROOT=%OSITDRIVE%\$script:StorageDriversRelativePath",
        # Iterates vendor subfolders one at a time (Storage\<Vendor>\*.inf), the same shape as
        # Install-NetworkDrivers.ps1's per-vendor loop for Deployment\Drivers\Network\<Vendor> --
        # deliberately not a single flat "for /r" across the whole Storage tree, so a technician
        # reading OSIT-DiskCheck.log sees exactly which vendor folder was tried and how many INF
        # files it had, instead of one undifferentiated pile of drvload lines. Only vendor
        # subfolders are considered (matching the Network convention); a loose .inf dropped
        # directly under Storage\ with no vendor subfolder is not picked up.
        'if exist "%DRIVERROOT%" (',
        '    echo Loading boot-critical storage drivers from %DRIVERROOT% by vendor folder>> "%LOGFILE%"',
        '    for /d %%V in ("%DRIVERROOT%\*") do (',
        # "for /r %%V %%F in (...)" -- using a metavariable directly as /r's path argument -- is
        # ambiguous to cmd.exe's parser (both the /r path and the loop variable are %-sigils) and
        # was confirmed to silently match nothing rather than error, reproduced against this exact
        # nested for /d + for /r shape before switching to pushd/popd, which sidesteps the
        # ambiguity entirely by giving for /r no path argument (it then defaults to the current
        # directory).
        '        pushd "%%V"',
        '        set VENDORINFCOUNT=0',
        '        for /r %%F in (*.inf) do set /a VENDORINFCOUNT+=1',
        '        if !VENDORINFCOUNT! GTR 0 (',
        '            echo   Vendor %%~nxV: !VENDORINFCOUNT! INF file^(s^) >> "%LOGFILE%"',
        '            for /r %%F in (*.inf) do (',
        '                echo     drvload %%F>> "%LOGFILE%"',
        '                drvload "%%F">> "%LOGFILE%" 2>&1',
        '            )',
        '        ) else (',
        '            echo   Vendor %%~nxV: no INF files; skipping>> "%LOGFILE%"',
        '        )',
        '        popd',
        '    )',
        ') else (',
        '    echo No storage driver folder found at %DRIVERROOT%; skipping driver load.>> "%LOGFILE%"',
        ')',
        '',
        'set DPSCRIPT=%OSITDRIVE%\OSIT-DiskCheck-List.txt',
        'set DPOUT=%OSITDRIVE%\OSIT-DiskCheck-List.log',
        'echo list disk> "%DPSCRIPT%"',
        'diskpart /s "%DPSCRIPT%" > "%DPOUT%" 2>&1',
        'type "%DPOUT%">> "%LOGFILE%"',
        '',
        # findstr.exe is NOT present in the plain Windows Setup WinPE image (confirmed on real
        # hardware: "'findstr' is not recognized as an internal or external command"), so
        # counting/parsing "diskpart list disk" output uses pure batch FOR /F tokenizing instead --
        # no external tool, no regex, and (per the pipe note this replaced) no pipe inside a
        # for /f (''...'') command either, which was separately confirmed to hang cmd.exe. This
        # relies only on diskpart''s header row always being the literal text "Disk ###" (never a
        # real disk number) to tell data rows apart from the header/separator rows. Every disk's
        # size is normalised to GB so the target disk can be compared against the largest OTHER
        # visible disk; a "No Media" status row (e.g. an empty card reader) shifts the size tokens
        # so %%E is never a recognised unit and the row safely counts as 0 GB.
        'set DISKCOUNT=0',
        'set TARGETSIZEGB=0',
        'set MAXOTHERSIZEGB=0',
        'set MAXOTHERDISK=none',
        'for /f "tokens=1-5" %%A in (%DPOUT%) do (',
        '    if /i "%%A"=="Disk" if not "%%B"=="###" (',
        '        set /a DISKCOUNT+=1',
        '        set SIZEGB=0',
        '        if /i "%%E"=="TB" (set /a SIZEGB=%%D*1024) else if /i "%%E"=="GB" (set /a SIZEGB=%%D) else if /i "%%E"=="MB" (set /a SIZEGB=%%D/1024)',
        '        if "%%B"=="%TARGETDISK%" (',
        '            set /a TARGETSIZEGB=SIZEGB',
        '        ) else (',
        '            if !SIZEGB! GTR !MAXOTHERSIZEGB! (',
        '                set /a MAXOTHERSIZEGB=SIZEGB',
        '                set MAXOTHERDISK=%%B',
        '            )',
        '        )',
        '    )',
        ')',
        '',
        'echo Disk count detected: %DISKCOUNT% >> "%LOGFILE%"',
        'echo Target disk %TARGETDISK% size GB: %TARGETSIZEGB% >> "%LOGFILE%"',
        'echo Largest other disk: %MAXOTHERDISK% at %MAXOTHERSIZEGB% GB >> "%LOGFILE%"',
        '',
        'del "%DPSCRIPT%" >nul 2>&1',
        'del "%DPOUT%" >nul 2>&1',
        '',
        'if %DISKCOUNT% LSS %MINDISKS% (',
        '    echo FAIL: only %DISKCOUNT% disk^(s^) visible; expected at least %MINDISKS% ^(this USB itself plus the internal disk^). A boot-critical storage driver is likely missing -- integrate the storage controller driver for this model into this media with IntegrateDriversToWindowsInstall.ps1 ^(drivers go under Deployment\Drivers\Storage\^<Vendor^>^).>> "%LOGFILE%"',
        '    cscript.exe //Nologo "%DIAGSCRIPT%" "%DIAGLOG%">> "%LOGFILE%" 2>&1',
        '    exit /b 1',
        ')',
        '',
        # Strictly-larger, not merely present: a client notebook's internal disk is always larger
        # than the deployment USB, so if the configured target disk is not the single largest
        # visible disk, the USB/boot media (or another removable device) has taken the configured
        # disk ID and wiping it would destroy the wrong disk.
        'if %TARGETSIZEGB% LEQ %MAXOTHERSIZEGB% (',
        '    echo FAIL: disk %TARGETDISK% is %TARGETSIZEGB% GB but disk %MAXOTHERDISK% is %MAXOTHERSIZEGB% GB -- the target disk must be strictly larger than every other visible disk. The USB/boot media has likely enumerated as disk %TARGETDISK% because the storage controller driver loaded late or is missing -- integrate it into this media with IntegrateDriversToWindowsInstall.ps1 so the internal disk is visible from the moment Setup boots.>> "%LOGFILE%"',
        '    cscript.exe //Nologo "%DIAGSCRIPT%" "%DIAGLOG%">> "%LOGFILE%" 2>&1',
        '    exit /b 1',
        ')',
        '',
        'echo PASS: %DISKCOUNT% disk^(s^) visible; disk %TARGETDISK% ^(%TARGETSIZEGB% GB^) is the largest visible disk. Proceeding with wipe.>> "%LOGFILE%"',
        # Order 2's own command line requires this file to exist before it will run diskpart at
        # all -- confirmed necessary in the field: a machine whose disk-check FAILED here (this
        # exact popup/log) still had its USB stick wiped, meaning Windows Setup does not reliably
        # abort the windowsPE pass just because Order 1 exited non-zero. This sentinel makes the
        # gate self-enforced instead of depending on Setup's own error handling.
        'echo OK> "%OKFILE%"',
        'exit /b 0'
    ) -join "`r`n"
}

function New-WindowsPeArtifacts {
    param([hashtable]$Config)

    if (-not [bool]$Config.wipe_repartition_drive) {
        Write-Host ''
        Write-Host 'wipe_repartition_drive is FALSE: the generated Autounattend.xml will NOT wipe or partition any disk.' -ForegroundColor Yellow
        Write-Host 'Windows Setup will require technician-led language, disk, and image selection.' -ForegroundColor Yellow
        Write-Host 'To enable automatic wipe/partitioning, set wipe_repartition_drive=true in Deployment\Config\deployment_config.json in this toolkit folder BEFORE running this script, then rerun it.' -ForegroundColor Yellow
        return @{ SettingsBlock = ''; DiskPartScript = $null; DiskCheckScript = $null; DiskDiagScript = $null }
    }

    $diskId = [int]$Config.wipe_repartition_disk_id
    if ($diskId -lt 0) { throw 'wipe_repartition_disk_id must be 0 or greater.' }

    # The disk safety check compares the target disk's size against every other visible disk,
    # which is only meaningful when the USB/boot media itself is also visible -- hence 2, not 1.
    $minDiskCount = [int]$Config.wipe_minimum_disk_count
    if ($minDiskCount -lt 2) { throw 'wipe_minimum_disk_count must be 2 or greater (the USB/boot media plus at least one internal disk).' }

    $efiSize = [int]$Config.efi_partition_size_mb
    $msrSize = [int]$Config.msr_partition_size_mb
    $recoverySize = [int]$Config.recovery_partition_size_mb
    $imageName = [string]$Config.windows_image_name

    if ($efiSize -lt 100) { throw 'efi_partition_size_mb must be at least 100.' }
    if ($msrSize -ne 16) { Write-Warning 'Microsoft standard MSR size is 16 MB. Continuing with configured value.' }
    if ($recoverySize -lt 1024) { throw 'recovery_partition_size_mb must be at least 1024.' }
    if ([string]::IsNullOrWhiteSpace($imageName)) { throw 'windows_image_name must not be empty when wipe_repartition_drive is true.' }

    Write-Host ''
    Write-Host "Destructive partitioning is ENABLED for disk $diskId." -ForegroundColor Yellow
    Write-Host "USB-root $script:DiskCheckScriptFileName will refuse to wipe unless at least $minDiskCount disk(s) are visible and disk $diskId is strictly larger than every other visible disk (loading Deployment\Drivers\Storage\<Vendor> boot-critical drivers first if needed)." -ForegroundColor Yellow
    Write-Host "USB-root $script:DiskPartScriptFileName will then clean disk $diskId and create EFI $efiSize MB, MSR $msrSize MB, Windows, and WinRE $recoverySize MB partitions." -ForegroundColor Yellow

    # Letters S/W with noerr instead of C: WinPE often assigns C: to the USB stick when the
    # target disk is blank, and a failed assign makes diskpart /s abort every later command.
    # ImageInstall targets DiskID/PartitionID, so these letters are diagnostic only.
    $diskPartScript = @(
        "select disk $diskId",
        'clean',
        'convert gpt',
        "create partition efi size=$efiSize",
        'format quick fs=fat32 label=System',
        'assign letter=S noerr',
        "create partition msr size=$msrSize",
        'create partition primary',
        "shrink desired=$recoverySize minimum=$recoverySize",
        'format quick fs=ntfs label=Windows',
        'assign letter=W noerr',
        'create partition primary',
        'format quick fs=ntfs label=WinRE',
        'set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac',
        'gpt attributes=0x8000000000000001',
        'list volume',
        'exit'
    ) -join "`r`n"

    $diskCheckScript = New-DiskCheckScript -DiskId $diskId -MinDiskCount $minDiskCount
    $diskDiagScript = New-DiskDiagnosticScript -DiskId $diskId -MinDiskCount $minDiskCount

    # The unattend schema caps RunSynchronousCommand Path at 259 characters, so both the disk
    # safety check and the diskpart wipe ship as USB-root files, and each of these commands only
    # locates the USB (by the presence of its own marker file) and runs it.
    $diskCheckCommandLine = 'cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\{0} (call %d:\{0} %d:)' -f $script:DiskCheckScriptFileName
    if ($diskCheckCommandLine.Length -gt 259) {
        throw "Generated windowsPE disk-check RunSynchronous command is $($diskCheckCommandLine.Length) characters; the unattend Path limit is 259."
    }

    # Order=2 requires OSIT-DiskCheck.ok (written by Order=1's script only on success) in addition
    # to the diskpart script itself -- confirmed necessary in the field, where Order=2's diskpart
    # wipe still ran against a disk that Order=1 had just failed its safety check on, wiping the
    # USB stick itself. Windows Setup's own windowsPE-pass error handling cannot be trusted alone
    # to stop Order=2 from running after Order=1 exits non-zero.
    $diskPartCommandLine = 'cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\{0} if exist %d:\{1} (diskpart /s %d:\{1} > %d:\{2} 2>&1)' -f $script:DiskCheckOkFileName, $script:DiskPartScriptFileName, $script:DiskPartLogFileName
    if ($diskPartCommandLine.Length -gt 259) {
        throw "Generated windowsPE RunSynchronous command is $($diskPartCommandLine.Length) characters; the unattend Path limit is 259."
    }

    $escapedImageName = ConvertTo-XmlText -Value $imageName

    $settingsBlock = @"
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-AU</InputLocale>
      <SystemLocale>en-AU</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-AU</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Refuse to continue unless at least $minDiskCount disk(s) are visible and disk $diskId is strictly larger than every other visible disk, loading Deployment\Drivers\Storage drivers first if needed</Description>
          <Path><![CDATA[$diskCheckCommandLine]]></Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order>
          <Description>If Order 1 wrote $script:DiskCheckOkFileName, wipe disk $diskId with USB-root $script:DiskPartScriptFileName and create OSIT Windows 11 UEFI partition layout</Description>
          <Path><![CDATA[$diskPartCommandLine]]></Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/NAME</Key>
              <Value>$escapedImageName</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>$diskId</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
      <UserData>
        <ProductKey>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
"@

    return @{ SettingsBlock = $settingsBlock; DiskPartScript = $diskPartScript; DiskCheckScript = $diskCheckScript; DiskDiagScript = $diskDiagScript }
}

function Merge-AutounattendTemplate {
    # Applies the toolkit placeholder substitution shared by Write-PreparedAutounattend (writes
    # straight to a target file) and New-GeneratedUnattendContent (returns content in memory, e.g.
    # for Validate-Unattend.ps1 -Ci to write into a temp folder). Kept as one function so both
    # callers apply exactly the same substitution and validation.
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The password is escaped directly into Autounattend.xml as plaintext (the unattend schema''s own AutoLogon/LocalAccount format requires plaintext or a documented "obfuscated" base64+padding that is not actually secure). There is no SecureString path into an XML text node.')]
    param(
        [Parameter(Mandatory = $true)][string]$TemplateContent,
        [Parameter(Mandatory = $true)][string]$Password,
        [AllowEmptyString()][string]$WindowsPeSettingsBlock
    )

    $escapedPassword = [System.Security.SecurityElement]::Escape($Password)
    $content = $TemplateContent.Replace('__OSIT_LOCAL_ADMIN_PASSWORD__', $escapedPassword)
    $content = $content.Replace('  __WINDOWS_PE_SETTINGS__', $WindowsPeSettingsBlock.TrimEnd())

    $xmlValidation = [xml]$content
    if (-not $xmlValidation.unattend) { throw 'Generated Autounattend.xml did not validate as an unattend document.' }

    return $content
}

function Write-PreparedAutounattend {
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The password is escaped directly into Autounattend.xml as plaintext (the unattend schema''s own AutoLogon/LocalAccount format requires plaintext or a documented "obfuscated" base64+padding that is not actually secure). There is no SecureString path into an XML text node.')]
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Password,
        [AllowEmptyString()][string]$WindowsPeSettingsBlock
    )

    $content = Get-Content -LiteralPath $SourcePath -Raw -ErrorAction Stop
    if ($content -notmatch '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        throw "Autounattend template does not contain the __OSIT_LOCAL_ADMIN_PASSWORD__ placeholder: $SourcePath"
    }

    $prepared = Merge-AutounattendTemplate -TemplateContent $content -Password $Password -WindowsPeSettingsBlock $WindowsPeSettingsBlock
    Set-Content -LiteralPath $TargetPath -Value $prepared -Encoding UTF8 -Force -ErrorAction Stop
}

function New-GeneratedUnattendContent {
    <#
        .SYNOPSIS
            Generates the Autounattend.xml content and OSIT-DiskPart.txt script text that
            Initialize-UsbDeployment.ps1 would write to a USB, from the repository template and a
            resolved deployment config hashtable (as returned by Get-DeploymentConfig in
            Common.ps1). Returns content only; callers decide where (if anywhere) to write it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The password is escaped directly into Autounattend.xml as plaintext (the unattend schema''s own AutoLogon/LocalAccount format requires plaintext or a documented "obfuscated" base64+padding that is not actually secure). There is no SecureString path into an XML text node.')]
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Password
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "Autounattend template not found: $TemplatePath"
    }

    $templateContent = Get-Content -LiteralPath $TemplatePath -Raw -ErrorAction Stop
    if ($templateContent -notmatch '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        throw "Autounattend template does not contain the __OSIT_LOCAL_ADMIN_PASSWORD__ placeholder: $TemplatePath"
    }

    $windowsPe = New-WindowsPeArtifacts -Config $Config
    $autounattendContent = Merge-AutounattendTemplate -TemplateContent $templateContent -Password $Password -WindowsPeSettingsBlock $windowsPe.SettingsBlock

    return [ordered]@{
        AutounattendContent = $autounattendContent
        DiskPartScript      = $windowsPe.DiskPartScript
        DiskCheckScript     = $windowsPe.DiskCheckScript
        DiskDiagScript      = $windowsPe.DiskDiagScript
    }
}
