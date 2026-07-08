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
$script:DiskAssertScriptFileName = 'OSIT-DiskAssert.vbs'
$script:DiskDiagScriptFileName = 'OSIT-DiskDiag.vbs'
$script:DiskDiagLogFileName = 'OSIT-DiskDiag.log'
$script:StorageDriversRelativePath = 'Deployment\Drivers\Storage'

function ConvertTo-XmlText {
    param([AllowEmptyString()][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

function New-DiskAssertScript {
    <#
        .SYNOPSIS
            Builds OSIT-DiskAssert.vbs: a WinPE-safe WMI-based companion to OSIT-DiskCheck.cmd
            that inspects the target disk itself rather than diskpart's text output.

        .DESCRIPTION
            OSIT-DiskCheck.cmd's disk-count/size checks come from parsing "diskpart list disk"
            text, which has no columns for interface type, media type, or partition count. This
            script queries Win32_DiskDrive for the configured target disk directly (the same WMI
            approach used by cschneegans/unattend-generator's disk-assertion feature, adapted here
            to a known disk ID instead of parsing it out of a diskpart script) and fails with
            exit code 1 -- caught by OSIT-DiskCheck.cmd and propagated as its own failure -- if
            any enabled assertion does not hold. Every assertion is optional and off by default
            except AssertNoExistingPartitions: interface-type/media-type checks are skipped by
            default because real-world storage controllers (RAID/NVMe) can report unexpected
            values and a false positive here would abort a legitimate production deployment.
    #>
    param(
        [int]$DiskId,
        [int]$MaxTargetDiskGb,
        [bool]$AssertNoExistingPartitions,
        [bool]$AssertFixedInterfaceType,
        [bool]$AssertFixedMediaType
    )

    # Built via [char] + string concatenation, not inline "" / '' escaping: VBScript's own
    # quoting rules mean these lines need both a literal " (VBScript string delimiter) and,
    # in a few lines, a literal ' (wrapping a runtime value in the failure message) -- mixing
    # both inside PowerShell's own '' / "" escaping is what caused this to be misparsed
    # (mismatched quote counts) the first time this was written.
    $dq = [char]34
    $sq = [char]39

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
        'Function Fail(message)',
        '  WScript.Echo message',
        '  WScript.Quit 1',
        'End Function',
        '',
        'On Error Resume Next',
        'Set wmi = GetObject("winmgmts:\\.\root\cimv2")',
        ('Set drive = wmi.Get(' + $dq + 'Win32_DiskDrive.DeviceID=' + $sq + '\\.\PHYSICALDRIVE' + $DiskId + $sq + $dq + ')'),
        'If Err.Number <> 0 Then',
        ('  Fail ' + $dq + 'Could not locate disk ' + $DiskId + ' (' + $dq + ' & Err.Description & ' + $dq + ').' + $dq),
        'End If'
    ))

    if ($AssertFixedInterfaceType) {
        $lines.AddRange([string[]]@(
            '',
            'actual = drive.InterfaceType',
            'If actual <> "IDE" And actual <> "SCSI" Then',
            ('  Fail ' + $dq + 'InterfaceType ' + $sq + $dq + ' & actual & ' + $dq + $sq + ' of disk ' + $DiskId + ' is unexpected -- this looks like removable/USB media, not the internal disk.' + $dq),
            'End If'
        ))
    }

    if ($AssertFixedMediaType) {
        $lines.AddRange([string[]]@(
            '',
            'actual = drive.MediaType',
            'If actual <> "Fixed hard disk media" Then',
            ('  Fail ' + $dq + 'MediaType ' + $sq + $dq + ' & actual & ' + $dq + $sq + ' of disk ' + $DiskId + ' is unexpected -- this looks like removable media, not the internal disk.' + $dq),
            'End If'
        ))
    }

    if ($MaxTargetDiskGb -gt 0) {
        $lines.AddRange([string[]]@(
            '',
            'actual = CInt( drive.Size / 1024 / 1024 / 1024 )',
            ('expected = ' + $MaxTargetDiskGb),
            'If actual > expected Then',
            ('  Fail ' + $dq + 'Size of disk ' + $DiskId + ' is expected to be at most ' + $dq + ' & expected & ' + $dq + ' GiB, but actually is ' + $dq + ' & actual & ' + $dq + ' GiB. Refusing to wipe -- this looks larger than expected for the internal disk.' + $dq),
            'End If'
        ))
    }

    if ($AssertNoExistingPartitions) {
        $lines.AddRange([string[]]@(
            '',
            'actual = drive.Partitions',
            'If actual > 0 Then',
            ('  Fail ' + $dq + 'There are already ' + $dq + ' & actual & ' + $dq + ' partition(s) on disk ' + $DiskId + '. Refusing to wipe a disk that already has partitions -- if this is expected, disable wipe_assert_no_existing_partitions.' + $dq),
            'End If'
        ))
    }

    $lines.AddRange([string[]]@(
        '',
        'WScript.Echo "Disk assertions were satisfied."',
        'WScript.Quit 0'
    ))

    return ($lines -join "`r`n")
}

function New-DiskDiagnosticScript {
    <#
        .SYNOPSIS
            Builds OSIT-DiskDiag.vbs: a WinPE-safe on-failure diagnostic that a technician sees
            immediately (on screen, via a blocking MsgBox) and can also read back later from the
            USB, instead of having to dig through OSIT-DiskCheck.log to work out why the disk
            safety net refused to wipe.

        .DESCRIPTION
            Run only from OSIT-DiskCheck.cmd's own failure branches (disk count too low, target
            disk too small, or an OSIT-DiskAssert.vbs assertion failing) -- the same "a storage
            driver is likely missing" scenario those checks already exist to catch. Gathers, via
            WMI: the notebook's own make/model (Win32_ComputerSystem) and serial number
            (Win32_BIOS) so a technician can identify the exact machine without reading a label;
            every disk WinPE can currently see (Win32_DiskDrive) -- normally just the USB stick in
            this failure scenario; and every PnP device with no working driver
            (Win32_PnPEntity where ConfigManagerErrorCode <> 0), whose PNPDeviceID's VEN_/DEV_
            tokens identify exactly which storage controller chipset needs a driver.

            Writes the same report to the given output path (USB root) and shows it as a modal
            MsgBox. MsgBox renders as a real dialog under cscript.exe as much as wscript.exe --
            the cscript/wscript distinction only changes plain WScript.Echo's behaviour, not
            VBScript's own MsgBox -- so this uses cscript.exe for consistency with
            OSIT-DiskAssert.vbs rather than switching hosts.

        .NOTES
            UNVERIFIED ON REAL WINPE: whether a MsgBox raised by a windowsPE-pass
            RunSynchronousCommand script actually renders on top of Windows Setup's own UI (as
            opposed to being suppressed, or blocking invisibly) cannot be exercised in this
            sandbox. Confirm via a Tier 1 Hyper-V rehearsal with a deliberately-broken storage
            driver scenario before relying on this in the field.
    #>
    param(
        [int]$DiskId,
        [int]$MinDiskCount,
        [int]$MinTargetDiskGb
    )

    return @(
        'On Error Resume Next',
        'outputPath = WScript.Arguments(0)',
        # Numeric-only assignments (no VBScript string literals on these lines at all) --
        # deliberately kept separate from every message-building line below so that every line
        # with a VBScript string literal can stay a plain single-quoted PowerShell string, with
        # VBScript's own double quotes passing through unescaped. Mixing PowerShell string
        # interpolation with VBScript's double-quote literals on the same line is exactly what
        # produced a mismatched-quote-count parse failure the first time OSIT-DiskAssert.vbs was
        # written this way -- not repeating that here.
        "minDiskCount = $MinDiskCount",
        "targetDiskId = $DiskId",
        "minTargetDiskGb = $MinTargetDiskGb",
        'Set wmi = GetObject("winmgmts:\\.\root\cimv2")',
        '',
        'report = "=== OSIT Disk Diagnostic ===" & vbCrLf',
        'report = report & "Looking for at least " & minDiskCount & " disk(s); target disk " & targetDiskId & " must be at least " & minTargetDiskGb & " GB." & vbCrLf & vbCrLf',
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
        'report = report & vbCrLf & "Disks currently visible to WinPE:" & vbCrLf',
        'Set diskSet = wmi.ExecQuery("SELECT Model, InterfaceType, MediaType, Size, PNPDeviceID FROM Win32_DiskDrive")',
        'diskCount = 0',
        'For Each d In diskSet',
        '  diskCount = diskCount + 1',
        '  sizeText = "unknown size"',
        '  If IsNumeric(d.Size) Then sizeText = CStr(CLng(d.Size / 1024 / 1024 / 1024)) & " GB"',
        '  report = report & "  " & diskCount & ". " & d.Model & "  [" & d.InterfaceType & "/" & d.MediaType & ", " & sizeText & "]" & vbCrLf',
        '  report = report & "     " & d.PNPDeviceID & vbCrLf',
        'Next',
        'If diskCount = 0 Then report = report & "  (none detected at all)" & vbCrLf',
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
        'MsgBox report, vbOKOnly + vbExclamation, "OSIT: storage driver missing -- see Deployment\Drivers\Storage\<Vendor> on this media"'
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
            configured target disk is at least $MinTargetDiskGb. A non-zero exit here makes
            Windows Setup itself abort the windowsPE pass with an error, before Order=2's
            OSIT-DiskPart.txt can run -- the same fail-stop behaviour the rest of this toolkit
            uses for critical prerequisite failures. Every failure branch (this script's own
            checks and OSIT-DiskAssert.vbs's) runs OSIT-DiskDiag.vbs (New-DiskDiagnosticScript)
            first, which both saves and shows on screen the machine's make/model/serial and
            exactly which storage controller has no working driver.

        .NOTES
            UNVERIFIED ON REAL WINPE: cmd.exe FOR/IF parsing (nested parentheses, ^-escaping,
            diskpart output token parsing) cannot be executed in this sandbox. Confirm end to
            end via a Tier 1 Hyper-V rehearsal (see TESTING.md) before relying on this for a
            release: check OSIT-DiskCheck.log on the rehearsal media/artifacts for the disk
            count and target size it actually detected.
    #>
    param(
        [int]$DiskId,
        [int]$MinDiskCount,
        [int]$MinTargetDiskGb
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
        "set MINGB=$MinTargetDiskGb",
        '',
        'echo OSIT-DiskCheck starting> "%LOGFILE%"',
        # A trailing numeric variable (0-9) directly touching ">>" is misparsed by cmd.exe as a
        # file-handle redirect (e.g. "2>>" means "redirect handle 2/stderr"), silently swallowing
        # the digit instead of writing it as text -- reproduced and confirmed with %DISKCOUNT%
        # while writing this. Every redirect below that could follow a numeric variable keeps a
        # deliberate trailing space before ">>" to keep the digit and the operator unambiguous.
        'echo Target disk id: %TARGETDISK%  Minimum disks required: %MINDISKS%  Minimum target disk size GB: %MINGB% >> "%LOGFILE%"',
        '',
        "set DRIVERROOT=%OSITDRIVE%\$script:StorageDriversRelativePath",
        'if exist "%DRIVERROOT%" (',
        '    echo Loading boot-critical storage drivers from %DRIVERROOT%>> "%LOGFILE%"',
        '    for /r "%DRIVERROOT%" %%F in (*.inf) do (',
        '        echo   drvload %%F>> "%LOGFILE%"',
        '        drvload "%%F">> "%LOGFILE%" 2>&1',
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
        # Deliberately not "findstr ... | find /c /v """ piped through a single for /f capture:
        # a pipe inside a for /f (''...'') command -- even ^-escaped -- was found to hang cmd.exe
        # indefinitely under real testing (reproduced and confirmed before this was written this
        # way). Counting matched lines by iterating the for /f loop itself avoids any pipe.
        'set DISKCOUNT=0',
        'for /f %%N in (''findstr /r /c:"^  Disk [0-9]" "%DPOUT%"'') do set /a DISKCOUNT+=1',
        '',
        'set TARGETSIZEGB=0',
        'for /f "tokens=2,4,5" %%A in (''findstr /r /c:"^  Disk %TARGETDISK%[^0-9]" "%DPOUT%"'') do (',
        '    if /i "%%C"=="TB" (set /a TARGETSIZEGB=%%B*1024) else if /i "%%C"=="MB" (set /a TARGETSIZEGB=%%B/1024) else (set /a TARGETSIZEGB=%%B)',
        ')',
        '',
        'echo Disk count detected: %DISKCOUNT% >> "%LOGFILE%"',
        'echo Target disk %TARGETDISK% size GB: %TARGETSIZEGB% >> "%LOGFILE%"',
        '',
        'del "%DPSCRIPT%" >nul 2>&1',
        'del "%DPOUT%" >nul 2>&1',
        '',
        'if %DISKCOUNT% LSS %MINDISKS% (',
        '    echo FAIL: only %DISKCOUNT% disk^(s^) visible; expected at least %MINDISKS%. A storage driver is likely missing -- see Deployment\Drivers\Storage\^<Vendor^> on this media.>> "%LOGFILE%"',
        '    cscript.exe //Nologo "%DIAGSCRIPT%" "%DIAGLOG%">> "%LOGFILE%" 2>&1',
        '    exit /b 1',
        ')',
        '',
        'if %TARGETSIZEGB% LSS %MINGB% (',
        '    echo FAIL: disk %TARGETDISK% is only %TARGETSIZEGB% GB; expected at least %MINGB% GB. Refusing to wipe -- this looks like the boot/USB media, not the internal disk.>> "%LOGFILE%"',
        '    cscript.exe //Nologo "%DIAGSCRIPT%" "%DIAGLOG%">> "%LOGFILE%" 2>&1',
        '    exit /b 1',
        ')',
        '',
        # OSIT-DiskAssert.vbs (New-DiskAssertScript) checks properties "list disk" text has no
        # columns for -- interface type, media type, exact partition count -- via WMI on the
        # already-known target disk. cscript.exe ships with WinPE, same as the toolkit's other
        # WinPE-safe tooling.
        "cscript.exe //E:vbscript //Nologo ""%OSITDRIVE%\$script:DiskAssertScriptFileName"">> ""%LOGFILE%"" 2>&1",
        'if errorlevel 1 (',
        '    echo FAIL: WMI disk assertions failed for disk %TARGETDISK% -- see OSIT-DiskAssert output above in this log.>> "%LOGFILE%"',
        '    cscript.exe //Nologo "%DIAGSCRIPT%" "%DIAGLOG%">> "%LOGFILE%" 2>&1',
        '    exit /b 1',
        ')',
        '',
        'echo PASS: %DISKCOUNT% disk^(s^) visible; disk %TARGETDISK% is %TARGETSIZEGB% GB. Proceeding with wipe.>> "%LOGFILE%"',
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
        return @{ SettingsBlock = ''; DiskPartScript = $null; DiskCheckScript = $null; DiskAssertScript = $null; DiskDiagScript = $null }
    }

    $diskId = [int]$Config.wipe_repartition_disk_id
    if ($diskId -lt 0) { throw 'wipe_repartition_disk_id must be 0 or greater.' }

    $minDiskCount = [int]$Config.wipe_minimum_disk_count
    $minTargetDiskGb = [int]$Config.wipe_minimum_target_disk_gb
    if ($minDiskCount -lt 1) { throw 'wipe_minimum_disk_count must be 1 or greater.' }
    if ($minTargetDiskGb -lt 0) { throw 'wipe_minimum_target_disk_gb must be 0 or greater.' }

    $maxTargetDiskGb = [int]$Config.wipe_maximum_target_disk_gb
    $assertNoExistingPartitions = [bool]$Config.wipe_assert_no_existing_partitions
    $assertFixedInterfaceType = [bool]$Config.wipe_assert_fixed_interface_type
    $assertFixedMediaType = [bool]$Config.wipe_assert_fixed_media_type
    if ($maxTargetDiskGb -lt 0) { throw 'wipe_maximum_target_disk_gb must be 0 or greater (0 disables the check).' }
    if ($maxTargetDiskGb -gt 0 -and $maxTargetDiskGb -le $minTargetDiskGb) {
        throw "wipe_maximum_target_disk_gb ($maxTargetDiskGb) must be greater than wipe_minimum_target_disk_gb ($minTargetDiskGb)."
    }

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
    Write-Host "USB-root $script:DiskCheckScriptFileName will refuse to wipe unless at least $minDiskCount disk(s) are visible and disk $diskId is at least $minTargetDiskGb GB (loading Deployment\Drivers\Storage\<Vendor> boot-critical drivers first if needed)." -ForegroundColor Yellow
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

    $diskCheckScript = New-DiskCheckScript -DiskId $diskId -MinDiskCount $minDiskCount -MinTargetDiskGb $minTargetDiskGb
    $diskAssertScript = New-DiskAssertScript -DiskId $diskId -MaxTargetDiskGb $maxTargetDiskGb -AssertNoExistingPartitions $assertNoExistingPartitions -AssertFixedInterfaceType $assertFixedInterfaceType -AssertFixedMediaType $assertFixedMediaType
    $diskDiagScript = New-DiskDiagnosticScript -DiskId $diskId -MinDiskCount $minDiskCount -MinTargetDiskGb $minTargetDiskGb

    # The unattend schema caps RunSynchronousCommand Path at 259 characters, so both the disk
    # safety check and the diskpart wipe ship as USB-root files, and each of these commands only
    # locates the USB (by the presence of its own marker file) and runs it. Order=1 runs the
    # safety check (and, via its own non-zero exit, aborts Windows Setup entirely before disk 0
    # is ever touched) strictly before Order=2's diskpart wipe.
    $diskCheckCommandLine = 'cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\{0} (call %d:\{0} %d:)' -f $script:DiskCheckScriptFileName
    if ($diskCheckCommandLine.Length -gt 259) {
        throw "Generated windowsPE disk-check RunSynchronous command is $($diskCheckCommandLine.Length) characters; the unattend Path limit is 259."
    }

    $diskPartCommandLine = 'cmd.exe /c for %d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %d:\{0} (diskpart /s %d:\{0} > %d:\{1} 2>&1)' -f $script:DiskPartScriptFileName, $script:DiskPartLogFileName
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
          <Description>Refuse to continue unless at least $minDiskCount disk(s) are visible and disk $diskId is at least $minTargetDiskGb GB, loading Deployment\Drivers\Storage drivers first if needed</Description>
          <Path><![CDATA[$diskCheckCommandLine]]></Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order>
          <Description>Wipe disk $diskId with USB-root $script:DiskPartScriptFileName and create OSIT Windows 11 UEFI partition layout</Description>
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

    return @{ SettingsBlock = $settingsBlock; DiskPartScript = $diskPartScript; DiskCheckScript = $diskCheckScript; DiskAssertScript = $diskAssertScript; DiskDiagScript = $diskDiagScript }
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
        DiskAssertScript    = $windowsPe.DiskAssertScript
        DiskDiagScript      = $windowsPe.DiskDiagScript
    }
}
