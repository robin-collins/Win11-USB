<#
    .SYNOPSIS
        Shared helpers for the OSIT Windows 11 USB deployment Hyper-V rehearsal harness.

    .DESCRIPTION
        Dot-sourced by Test\Rehearsal\Invoke-DeploymentRehearsal.ps1. This file is host-side
        tooling only: it runs on a technician's Windows 10/11 Pro/Enterprise/Education bench
        machine with Hyper-V, never on the client's notebook, and is never copied onto a
        production deployment USB (see Initialize-UsbDeployment.ps1's Copy-DeploymentFiles,
        which only ever copies the repo's Deployment\ folder).

        Requires pwsh 7+ on Windows. Functions that call Hyper-V/Windows-only cmdlets guard
        their calls so that running on a non-Windows or non-Hyper-V machine (including this
        toolkit's Linux CI/dev sandbox) produces a clear "not available on this platform"
        failure result instead of an unhandled exception.

        T09 (this task) provides Test-RehearsalPrerequisites and its per-check building
        blocks only. Later tasks append to this same file:
          - T10 adds New-RehearsalMedia (builds the "USB" VHDX + runs Initialize-UsbDeployment.ps1).
          - T11 adds New-RehearsalVm / Remove-RehearsalVm / Checkpoint-Rehearsal (VM lifecycle,
            vTPM + Secure Boot).
          - T12 adds guest monitoring and artifact-harvest helpers.
          - T13 adds Test-RehearsalResult (the post-run assertion suite).
        Keep this file additive: new functions go alongside these, existing ones are not
        repurposed for unrelated logic.

    .NOTES
        Nothing in this file is invoked automatically at dot-source time beyond variable
        setup, matching the convention in Deployment\Scripts\Common.ps1.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

# Hyper-V's built-in external switch, present on any host where the Hyper-V feature has been
# enabled with default settings. T11 attaches rehearsal VMs to this switch.
$script:RehearsalDefaultSwitchName = 'Default Switch'

# A real Windows 11 ISO (any edition/language, 22H2+) is routinely 4.5-6.5 GB. 3 GB is a
# conservative floor: comfortably below any genuine Win11 ISO, but high enough to reject an
# empty/truncated download, a Windows PE-only image, or an unrelated file that merely has a
# .iso extension. This is a plausibility check only -- T09 does not mount or validate ISO
# internals; that is out of scope here.
$script:RehearsalMinIsoSizeBytes = 3GB

# Extra free-space headroom required on top of -OsDiskGB. T10 builds a fixed 16 GB media VHDX
# (the rehearsal "USB"), and a running VM plus its checkpoints (T11: pre-boot, post-install,
# pre-complete) need working room for differencing disks and Hyper-V/host overhead. 20 GB
# comfortably covers the 16 GB media VHDX with a few GB of slack, so the minimum required free
# space is OsDiskGB + 20. The OS VHDX itself is created dynamic (thin-provisioned), so this is
# a safety margin against the disk filling up mid-rehearsal, not the VHDX's declared size.
$script:RehearsalDiskHeadroomGB = 20

function Test-RehearsalCommandAvailable {
    <#
        .SYNOPSIS
            Returns whether a cmdlet/function exists in the current session, without throwing.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function New-RehearsalCheckResult {
    <#
        .SYNOPSIS
            Builds one structured prerequisite-check result entry.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Fail')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Data = $null
    )

    [ordered]@{
        Check   = $Check
        Status  = $Status
        Message = $Message
        Data    = $Data
    }
}

function Test-RehearsalElevation {
    <#
        .SYNOPSIS
            Checks that the current session is running elevated (Administrator).
    #>
    [CmdletBinding()]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return New-RehearsalCheckResult -Check 'Elevation' -Status 'Pass' -Message 'PowerShell session is running elevated (Administrator).'
        }
        return New-RehearsalCheckResult -Check 'Elevation' -Status 'Fail' -Message 'PowerShell session is not elevated. Re-run this script from an Administrator PowerShell prompt.'
    } catch {
        return New-RehearsalCheckResult -Check 'Elevation' -Status 'Fail' -Message "Could not determine elevation state on this platform (Windows identity APIs unavailable): $($_.Exception.Message)"
    }
}

function Test-RehearsalHyperVFeature {
    <#
        .SYNOPSIS
            Checks that the Hyper-V Windows optional feature is enabled.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-RehearsalCommandAvailable -Name 'Get-WindowsOptionalFeature')) {
        return New-RehearsalCheckResult -Check 'Hyper-V Feature' -Status 'Fail' -Message 'Get-WindowsOptionalFeature is not available on this platform. The rehearsal harness requires Windows 10/11 Pro, Enterprise, or Education with the Hyper-V feature.'
    }

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All' -ErrorAction Stop
        if ($feature -and $feature.State -eq 'Enabled') {
            return New-RehearsalCheckResult -Check 'Hyper-V Feature' -Status 'Pass' -Message 'Hyper-V Windows feature is enabled.' -Data @{ state = [string]$feature.State }
        }
        $state = if ($feature) { [string]$feature.State } else { 'Unknown' }
        return New-RehearsalCheckResult -Check 'Hyper-V Feature' -Status 'Fail' -Message "Hyper-V Windows feature is not enabled (state: $state). Enable it with: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All, then reboot." -Data @{ state = $state }
    } catch {
        return New-RehearsalCheckResult -Check 'Hyper-V Feature' -Status 'Fail' -Message "Could not query the Hyper-V Windows feature: $($_.Exception.Message)"
    }
}

function Test-RehearsalIsoMedia {
    <#
        .SYNOPSIS
            Sanity-checks -IsoPath: exists, has a .iso extension, and is a plausible size.
            Does not mount or validate ISO internals.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$IsoPath)

    if ([string]::IsNullOrWhiteSpace($IsoPath)) {
        return New-RehearsalCheckResult -Check 'ISO Media' -Status 'Fail' -Message '-IsoPath was not supplied.'
    }

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        return New-RehearsalCheckResult -Check 'ISO Media' -Status 'Fail' -Message "ISO file was not found: $IsoPath" -Data @{ path = $IsoPath }
    }

    try {
        $item = Get-Item -LiteralPath $IsoPath -ErrorAction Stop
    } catch {
        return New-RehearsalCheckResult -Check 'ISO Media' -Status 'Fail' -Message "Could not read ISO file metadata for '$IsoPath': $($_.Exception.Message)"
    }

    if ($item.Extension -ine '.iso') {
        return New-RehearsalCheckResult -Check 'ISO Media' -Status 'Fail' -Message "File does not have a .iso extension: $IsoPath" -Data @{ path = $IsoPath; extension = $item.Extension }
    }

    if ($item.Length -lt $script:RehearsalMinIsoSizeBytes) {
        $minGb = [math]::Round($script:RehearsalMinIsoSizeBytes / 1GB, 1)
        $actualGb = [math]::Round($item.Length / 1GB, 2)
        return New-RehearsalCheckResult -Check 'ISO Media' -Status 'Fail' -Message "ISO file is only $actualGb GB; a real Windows 11 ISO is at least $minGb GB. This does not look like plausible bootable media." -Data @{ path = $IsoPath; size_bytes = $item.Length }
    }

    return New-RehearsalCheckResult -Check 'ISO Media' -Status 'Pass' -Message "ISO file exists, has a .iso extension, and is $([math]::Round($item.Length / 1GB, 2)) GB." -Data @{ path = $IsoPath; size_bytes = $item.Length }
}

function Test-RehearsalWorkingDirectory {
    <#
        .SYNOPSIS
            Ensures -WorkingDirectory exists (creating it if necessary) and is accessible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory)

    try {
        if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
            New-Item -ItemType Directory -Path $WorkingDirectory -Force -ErrorAction Stop | Out-Null
        }
        $resolved = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
        return New-RehearsalCheckResult -Check 'Working Directory' -Status 'Pass' -Message "Working directory is available: $resolved" -Data @{ path = $resolved }
    } catch {
        return New-RehearsalCheckResult -Check 'Working Directory' -Status 'Fail' -Message "Could not create or access -WorkingDirectory '$WorkingDirectory': $($_.Exception.Message)"
    }
}

function Test-RehearsalDiskSpace {
    <#
        .SYNOPSIS
            Checks free disk space on the volume that would hold -WorkingDirectory against
            OsDiskGB + the documented headroom (see $script:RehearsalDiskHeadroomGB above).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$OsDiskGB = 80
    )

    $requiredGb = $OsDiskGB + $script:RehearsalDiskHeadroomGB

    try {
        $probeDir = $WorkingDirectory
        while (-not [string]::IsNullOrWhiteSpace($probeDir) -and -not (Test-Path -LiteralPath $probeDir)) {
            $parent = Split-Path -Parent $probeDir
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probeDir) { $probeDir = $null; break }
            $probeDir = $parent
        }

        if ([string]::IsNullOrWhiteSpace($probeDir)) {
            return New-RehearsalCheckResult -Check 'Disk Space' -Status 'Fail' -Message "Could not resolve any existing ancestor directory of -WorkingDirectory '$WorkingDirectory' to check free space."
        }

        $resolvedProbeDir = (Resolve-Path -LiteralPath $probeDir -ErrorAction Stop).Path

        $drive = [System.IO.DriveInfo]::GetDrives() |
            Where-Object {
                try { $resolvedProbeDir.StartsWith($_.RootDirectory.FullName, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
            } |
            Sort-Object -Property { $_.RootDirectory.FullName.Length } -Descending |
            Select-Object -First 1

        if (-not $drive) {
            return New-RehearsalCheckResult -Check 'Disk Space' -Status 'Fail' -Message "Could not determine the volume containing '$resolvedProbeDir' to check free space."
        }

        $freeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        $data = @{ drive = $drive.Name; free_gb = $freeGb; required_gb = $requiredGb }

        if ($freeGb -lt $requiredGb) {
            return New-RehearsalCheckResult -Check 'Disk Space' -Status 'Fail' -Message "Only $freeGb GB free on $($drive.Name); a rehearsal needs at least $requiredGb GB (OsDiskGB=$OsDiskGB + $($script:RehearsalDiskHeadroomGB) GB headroom for the media VHDX and checkpoints)." -Data $data
        }
        return New-RehearsalCheckResult -Check 'Disk Space' -Status 'Pass' -Message "$freeGb GB free on $($drive.Name); at least $requiredGb GB required." -Data $data
    } catch {
        return New-RehearsalCheckResult -Check 'Disk Space' -Status 'Fail' -Message "Could not check free disk space for '$WorkingDirectory': $($_.Exception.Message)"
    }
}

function Test-RehearsalDefaultSwitch {
    <#
        .SYNOPSIS
            Checks that the Hyper-V "Default Switch" virtual switch exists.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-RehearsalCommandAvailable -Name 'Get-VMSwitch')) {
        return New-RehearsalCheckResult -Check 'Default Switch' -Status 'Fail' -Message 'Get-VMSwitch is not available on this platform (Hyper-V PowerShell module is not present).'
    }

    try {
        $switch = Get-VMSwitch -Name $script:RehearsalDefaultSwitchName -ErrorAction Stop
        if ($switch) {
            return New-RehearsalCheckResult -Check 'Default Switch' -Status 'Pass' -Message "Hyper-V virtual switch '$($script:RehearsalDefaultSwitchName)' exists."
        }
        return New-RehearsalCheckResult -Check 'Default Switch' -Status 'Fail' -Message "Hyper-V virtual switch '$($script:RehearsalDefaultSwitchName)' was not found."
    } catch {
        return New-RehearsalCheckResult -Check 'Default Switch' -Status 'Fail' -Message "Hyper-V virtual switch '$($script:RehearsalDefaultSwitchName)' was not found or could not be queried: $($_.Exception.Message)"
    }
}

function Test-RehearsalVmNameAvailable {
    <#
        .SYNOPSIS
            Checks that -VmName does not collide with an existing Hyper-V VM.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VmName)

    if (-not (Test-RehearsalCommandAvailable -Name 'Get-VM')) {
        return New-RehearsalCheckResult -Check 'VM Name' -Status 'Fail' -Message 'Get-VM is not available on this platform (Hyper-V PowerShell module is not present).'
    }

    try {
        $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($existing) {
            return New-RehearsalCheckResult -Check 'VM Name' -Status 'Fail' -Message "A VM named '$VmName' already exists. Choose a different -VmName or remove the existing VM first."
        }
        return New-RehearsalCheckResult -Check 'VM Name' -Status 'Pass' -Message "No existing VM named '$VmName'."
    } catch {
        return New-RehearsalCheckResult -Check 'VM Name' -Status 'Fail' -Message "Could not check for an existing VM named '$VmName': $($_.Exception.Message)"
    }
}

function Test-RehearsalPrerequisites {
    <#
        .SYNOPSIS
            Runs every rehearsal prerequisite check and returns a structured pass/fail list.

        .DESCRIPTION
            Never throws: every individual check function traps its own errors and degrades to
            a 'Fail' result with an explanatory message, so this is safe to call on a machine
            that has no Hyper-V support at all (including non-Windows platforms). The caller
            (Invoke-DeploymentRehearsal.ps1) prints the itemised list and exits non-zero when
            any entry's Status is 'Fail'.

        .OUTPUTS
            System.Collections.Generic.List[object] of ordered hashtables:
            @{ Check = <string>; Status = 'Pass'|'Fail'; Message = <string>; Data = <object> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [string]$WorkingDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'DeploymentRehearsal'),
        [string]$VmName = ('Rehearsal-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')),
        [int]$OsDiskGB = 80
    )

    $results = New-Object 'System.Collections.Generic.List[object]'

    $results.Add((Test-RehearsalElevation)) | Out-Null
    $results.Add((Test-RehearsalHyperVFeature)) | Out-Null
    $results.Add((Test-RehearsalIsoMedia -IsoPath $IsoPath)) | Out-Null
    $results.Add((Test-RehearsalWorkingDirectory -WorkingDirectory $WorkingDirectory)) | Out-Null
    $results.Add((Test-RehearsalDiskSpace -WorkingDirectory $WorkingDirectory -OsDiskGB $OsDiskGB)) | Out-Null
    $results.Add((Test-RehearsalDefaultSwitch)) | Out-Null
    $results.Add((Test-RehearsalVmNameAvailable -VmName $VmName)) | Out-Null

    return $results
}

# --- T11: VM lifecycle module ---
#
# New-RehearsalVm / Checkpoint-Rehearsal / Remove-RehearsalVm and their private helpers.
# Appended as its own block per FABLE_TASKS.md T11 so this addition does not interleave with
# T09's prerequisite-check functions above, or with T10's New-RehearsalMedia (built
# concurrently on a separate branch against this same file). Nothing above this banner was
# reordered or reformatted.
#
# Design summary (see FABLE_TASKS.md, Phase C intro and T11, for the full spec this
# implements):
#   - Gen-2 VM, dynamic memory OFF (fixed size), attached to the Hyper-V 'Default Switch'.
#   - OS disk (new dynamic VHDX) at SCSI 0/LUN 0; the media VHDX built by T10's
#     New-RehearsalMedia at SCSI 0/LUN 1; a DVD drive with the Win11 ISO. Firmware boot order
#     is DVD then OS disk. This SCSI ordering is what guarantees WinPE enumerates the OS disk
#     as disk 0, matching the config's wipe_repartition_disk_id default (see the Phase C intro
#     paragraph in FABLE_TASKS.md) -- New-RehearsalVm always attaches the OS disk at LUN 0 and
#     the media disk at LUN 1, never the reverse.
#   - vTPM + Secure Boot are enabled so the rehearsal is representative of real TPM-gated Win11
#     setup (and BitLocker-capable), using a local (non-HGS-attested) key protector.
#   - Checkpoint-Rehearsal is a thin, idempotent wrapper over Checkpoint-VM. Deciding *when* to
#     call it for the pre-boot / post-install / pre-complete moments is T12's job (guest
#     monitoring); T11 only provides the primitive.
#   - Remove-RehearsalVm tears the VM and its disks down unless -KeepVm is specified, matching
#     Invoke-DeploymentRehearsal.ps1's own -KeepVm switch from the T09 scaffold.
#
# Every public function below starts with Assert-HyperVAvailable, so a missing Hyper-V module
# (including this toolkit's own Linux dev/CI sandbox) fails fast with one clear, actionable
# error instead of a raw "the term '...' is not recognized" partway through VM creation --
# the same convention Test-RehearsalPrerequisites established above, just consolidated into a
# single reusable guard rather than repeated per check.

# Name of the local HgsGuardian used to key-protect rehearsal VMs' vTPMs. Reused across every
# rehearsal VM on a given bench host (see Get-RehearsalHgsGuardian) rather than created fresh
# per VM.
$script:RehearsalGuardianName = 'RehearsalGuardian'

function Assert-HyperVAvailable {
    <#
        .SYNOPSIS
            Throws a clear, actionable error unless the Hyper-V PowerShell cmdlets this module
            needs are present in the current session.

        .DESCRIPTION
            Test-RehearsalPrerequisites (T09, above) reports missing Hyper-V support as an
            itemised Pass/Fail check for the *harness's own* pre-flight report and never throws.
            The functions below are past that point -- they are the harness actually doing the
            work -- so a missing cmdlet here throws immediately with guidance, rather than
            surfacing PowerShell's generic "is not recognized as a name of a cmdlet" error deep
            inside VM creation. This is a single guard called once at the top of each public
            T11 function (New-RehearsalVm, Checkpoint-Rehearsal, Remove-RehearsalVm) rather than
            wrapping every individual Hyper-V cmdlet call -- see Test-RehearsalCommandAvailable
            above for the availability-check primitive this reuses.
    #>
    [CmdletBinding()]
    param()

    $requiredCommands = @(
        'New-VM', 'Get-VM', 'Set-VM', 'Remove-VM', 'Stop-VM',
        'Set-VMMemory', 'Set-VMProcessor',
        'New-VHD', 'Add-VMHardDiskDrive', 'Get-VMHardDiskDrive',
        'Add-VMDvdDrive', 'Get-VMDvdDrive',
        'Set-VMFirmware', 'Set-VMKeyProtector', 'Enable-VMTPM',
        'New-HgsGuardian', 'Get-HgsGuardian',
        'Checkpoint-VM', 'Get-VMSnapshot', 'Remove-VMSnapshot'
    )

    $missing = @($requiredCommands | Where-Object { -not (Test-RehearsalCommandAvailable -Name $_) })
    if ($missing.Count -gt 0) {
        throw "The Hyper-V PowerShell module is not available on this platform (missing cmdlet(s): $($missing -join ', ')). New-RehearsalVm, Checkpoint-Rehearsal, and Remove-RehearsalVm require a Windows 10/11 Pro/Enterprise/Education host with the Hyper-V feature (and its PowerShell management tools) enabled. Run Test-RehearsalPrerequisites for a full actionable check list before calling these functions."
    }
}

function Get-RehearsalVmPaths {
    <#
        .SYNOPSIS
            Derives the on-disk file/folder paths New-RehearsalVm creates (and Remove-RehearsalVm
            cleans up) from -VmName and -WorkingDirectory alone.

        .DESCRIPTION
            Pure string/path logic only: no Hyper-V cmdlets are called and nothing is read from
            or written to disk, so this is safe to unit test on any platform, including this
            toolkit's Linux dev/CI sandbox where the rest of T11 cannot run at all.

            New-RehearsalVm passes VmFolder to New-VM -Path, so Hyper-V's own VM configuration
            files and default checkpoint/snapshot storage land inside it alongside the OS disk
            this function also locates -- letting Remove-RehearsalVm reclaim all of that with a
            single recursive delete of VmFolder, without needing to enumerate checkpoint files
            individually.

        .OUTPUTS
            Ordered hashtable: @{ VmFolder = <string>; OsDiskPath = <string> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $vmFolder = Join-Path $WorkingDirectory $VmName

    return [ordered]@{
        VmFolder   = $vmFolder
        OsDiskPath = Join-Path $vmFolder "$VmName-OS.vhdx"
    }
}

function Get-RehearsalHgsGuardian {
    <#
        .SYNOPSIS
            Returns the local HgsGuardian used to key-protect rehearsal VMs, creating it once if
            it does not already exist. Idempotent: safe to call on every rehearsal run.

        .DESCRIPTION
            A single named guardian ($script:RehearsalGuardianName, 'RehearsalGuardian') is
            reused across every rehearsal VM on this bench host rather than created fresh per
            VM -- Get-HgsGuardian is checked first and New-HgsGuardian -GenerateCertificates is
            only called the first time, so re-running a rehearsal (or running several scenarios
            back to back) never errors on "a guardian with that name already exists".

            Note for whoever revisits this: Set-VMKeyProtector -NewLocalKeyProtector (used by
            New-RehearsalVm below) generates its key protector from the host's own local
            certificate material and does not take this guardian object as a parameter --
            unlike the fully HGS-attested pattern (New-HgsKeyProtector -Owner <guardian> ...
            -AllowUntrustedRoot, then Set-VMKeyProtector -KeyProtector $kp.RawData), which does.
            Ensuring a named guardian exists here regardless is what FABLE_TASKS.md T11
            specifies, and matches the common pattern for bootstrapping a bench host's local
            guardian/certificate infrastructure the first time any VM on it is TPM-enabled.
            This could not be exercised against a real Hyper-V host in this sandbox -- verify
            on Windows that -NewLocalKeyProtector behaves as expected once this guardian
            exists, and that repeat runs stay idempotent.

        .OUTPUTS
            The Microsoft.HyperV.PowerShell.HgsGuardian object (existing or newly created).
    #>
    [CmdletBinding()]
    param([string]$GuardianName = $script:RehearsalGuardianName)

    $existing = Get-HgsGuardian -Name $GuardianName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Get-RehearsalHgsGuardian: reusing existing local HgsGuardian '$GuardianName'."
        return $existing
    }

    Write-Verbose "Get-RehearsalHgsGuardian: no local HgsGuardian named '$GuardianName' found; creating it (New-HgsGuardian -GenerateCertificates)."
    return New-HgsGuardian -Name $GuardianName -GenerateCertificates
}

function New-RehearsalVm {
    <#
        .SYNOPSIS
            Creates a Gen-2 Hyper-V VM for the rehearsal harness: fixed memory, the OS disk at
            SCSI 0/LUN 0, the T10-built media disk at SCSI 0/LUN 1, a DVD drive with the Win11
            ISO, firmware boot order DVD-then-OS-disk, and vTPM + Secure Boot enabled.

        .DESCRIPTION
            Requires -MediaVhdxPath: the VHDX built by T10's New-RehearsalMedia. This function
            does not call New-RehearsalMedia itself -- the caller (Invoke-DeploymentRehearsal.ps1)
            builds the media first and passes its path in, keeping T10 and T11 independent of
            each other's internals.

            Disk placement matters here beyond tidiness: WinPE/Windows Setup enumerates fixed
            disks in the order their controllers present them, and the deployment config's
            wipe_repartition_disk_id defaults to 0 (see FABLE_TASKS.md's Phase C intro
            paragraph). Attaching the OS disk at SCSI 0/LUN 0 and the media disk at SCSI 0/LUN 1
            -- always in that order -- is what keeps the wiped disk and the config's assumed
            disk id in agreement.

        .PARAMETER VmName
            Name of the Hyper-V VM to create. Must not already exist (see
            Test-RehearsalVmNameAvailable, T09, for a pre-flight check of this).

        .PARAMETER IsoPath
            Path to the Windows 11 ISO attached as the virtual DVD drive.

        .PARAMETER MediaVhdxPath
            Path to the "USB" VHDX built by T10's New-RehearsalMedia (volume label 1S-WIN11).

        .PARAMETER WorkingDirectory
            Scratch directory this VM's own folder (VM configuration, OS disk, default
            checkpoint storage) is created under -- see Get-RehearsalVmPaths.

        .PARAMETER MemoryGB
            Fixed VM memory in GB. Dynamic memory is explicitly disabled: a real client
            notebook does not have Hyper-V's dynamic memory ballooning, so a rehearsal with it
            enabled would not be representative.

        .PARAMETER CpuCount
            Virtual CPU count.

        .PARAMETER OsDiskGB
            Size of the new dynamic OS VHDX, in GB.

        .PARAMETER SwitchName
            Hyper-V virtual switch to attach the VM's network adapter to. Defaults to
            $script:RehearsalDefaultSwitchName ('Default Switch'), the same switch
            Test-RehearsalDefaultSwitch (T09) checks for.

        .PARAMETER GuardianName
            Name of the local HgsGuardian used to key-protect this VM's vTPM. Defaults to
            $script:RehearsalGuardianName; see Get-RehearsalHgsGuardian.

        .OUTPUTS
            Ordered hashtable describing what was created, so the caller (and later
            Remove-RehearsalVm) do not need to re-derive it:
            @{ VmName; VmFolder; OsDiskPath; MediaVhdxPath; IsoPath }

        .NOTES
            UNVERIFIED ON REAL HYPER-V: this entire function requires a Windows host with
            Hyper-V and vTPM/Secure Boot support (Assert-HyperVAvailable makes it fail cleanly
            on this Linux sandbox instead of partway through). The full acceptance criterion --
            the resulting VM actually boots the ISO with Secure Boot ON and TPM present per
            Get-VMSecurity -- can only be checked on such a host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][string]$MediaVhdxPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [ValidateRange(1, [int]::MaxValue)][int]$MemoryGB = 8,
        [ValidateRange(1, [int]::MaxValue)][int]$CpuCount = 4,
        [ValidateRange(1, [int]::MaxValue)][int]$OsDiskGB = 80,
        [string]$SwitchName = $script:RehearsalDefaultSwitchName,
        [string]$GuardianName = $script:RehearsalGuardianName
    )

    Assert-HyperVAvailable

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "New-RehearsalVm: ISO file was not found: $IsoPath"
    }
    if (-not (Test-Path -LiteralPath $MediaVhdxPath -PathType Leaf)) {
        throw "New-RehearsalVm: media VHDX was not found: $MediaVhdxPath (expected to already exist -- New-RehearsalVm does not build it; run T10's New-RehearsalMedia first)."
    }
    if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
        throw "New-RehearsalVm: a VM named '$VmName' already exists. Remove it first (Remove-RehearsalVm -VmName $VmName) or choose a different -VmName."
    }

    $paths = Get-RehearsalVmPaths -VmName $VmName -WorkingDirectory $WorkingDirectory
    if (Test-Path -LiteralPath $paths.OsDiskPath) {
        throw "New-RehearsalVm: a file already exists at the OS disk path '$($paths.OsDiskPath)' from a previous run. Remove it (or the whole folder '$($paths.VmFolder)') before retrying."
    }
    New-Item -ItemType Directory -Path $paths.VmFolder -Force | Out-Null

    Write-Verbose "New-RehearsalVm: creating dynamic OS disk (${OsDiskGB} GB) at $($paths.OsDiskPath)."
    New-VHD -Path $paths.OsDiskPath -Dynamic -SizeBytes ([int64]$OsDiskGB * 1GB) | Out-Null

    Write-Verbose "New-RehearsalVm: creating Gen-2 VM '$VmName' (Memory=${MemoryGB}GB, CPU=$CpuCount, Switch='$SwitchName')."
    New-VM -Name $VmName -Generation 2 -Path $paths.VmFolder -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -NoVHD -SwitchName $SwitchName | Out-Null

    # Dynamic memory OFF: fixed-size memory per -MemoryGB (see the function's .DESCRIPTION).
    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGB * 1GB)
    Set-VMProcessor -VMName $VmName -Count $CpuCount

    # Standard (not production) checkpoints for this VM for the lifetime of the rehearsal.
    # Checkpoint-VM itself has no per-call -CheckpointType parameter (confirmed against the
    # Hyper-V module's own reference docs while writing this) -- checkpoint type is a property
    # of the VM, set once via Set-VM -CheckpointType, and Checkpoint-VM (called later by
    # Checkpoint-Rehearsal) simply uses whatever that is set to. Forcing it explicitly here
    # -- rather than trusting whatever a given Hyper-V version defaults new VMs to (modern
    # Hyper-V defaults to 'Production', which silently falls back to Standard only when the
    # guest doesn't support VSS-based checkpoints) -- keeps rehearsal checkpoints fast,
    # host-side, and crash-consistent by design rather than by accident of guest state at
    # checkpoint time.
    Set-VM -Name $VmName -CheckpointType Standard

    # Disks: OS disk at SCSI 0/LUN 0, media disk at SCSI 0/LUN 1 -- see the function's
    # .DESCRIPTION for why this exact ordering matters (wipe_repartition_disk_id).
    $osDiskDrive = Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $paths.OsDiskPath -Passthru
    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 -Path $MediaVhdxPath | Out-Null

    $dvdDrive = Add-VMDvdDrive -VMName $VmName -Path $IsoPath -Passthru

    # Firmware boot order: DVD (Windows Setup) then the OS disk (so a later reboot out of
    # WinPE/Setup continues from the OS disk rather than re-booting the ISO). The media disk
    # and the VM's network adapter are deliberately left out of -BootOrder: Set-VMFirmware
    # removes any boot entry not listed, so this is also what stops the VM ever attempting a
    # network/PXE boot.
    Set-VMFirmware -VMName $VmName -BootOrder $dvdDrive, $osDiskDrive

    # vTPM + Secure Boot -- see Get-RehearsalHgsGuardian's notes for the local (non-HGS
    # -attested) key protector caveat.
    Get-RehearsalHgsGuardian -GuardianName $GuardianName | Out-Null
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VmName
    # SecureBootTemplate 'MicrosoftWindows' is required for a Windows 11 guest to start at all
    # with secure boot on; Gen-2 VMs are created with secure boot already enabled by default,
    # but this is set explicitly rather than relied upon so behaviour does not depend on a
    # default that could change.
    Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

    return [ordered]@{
        VmName        = $VmName
        VmFolder      = $paths.VmFolder
        OsDiskPath    = $paths.OsDiskPath
        MediaVhdxPath = (Resolve-Path -LiteralPath $MediaVhdxPath).Path
        IsoPath       = (Resolve-Path -LiteralPath $IsoPath).Path
    }
}

function Checkpoint-Rehearsal {
    <#
        .SYNOPSIS
            Takes a named standard checkpoint of a rehearsal VM.

        .DESCRIPTION
            Thin wrapper over Checkpoint-VM. T11's job is to provide this primitive only --
            deciding *when* to call it for the rehearsal spec's three named moments (see below)
            is T12's job (guest monitoring), since only T12's monitoring loop knows the guest's
            boot/deployment state.

            The three canonical checkpoint names the spec defines are:
              - 'pre-boot'      : before the VM's first Start-VM.
              - 'post-install'  : first guest heartbeat after OOBE.
              - 'pre-complete'  : when in-guest state first reaches the EmailReport step.
            This wrapper accepts any -CheckpointName so it stays reusable for ad-hoc checkpoints
            during harness development too, but T12 is expected to only ever pass these three.

            Standard, not production, checkpoints: production checkpoints use the guest's own
            VSS/backup machinery to produce an application-consistent snapshot, and are meant
            for restoring a live production workload without data loss. A rehearsal VM is
            disposable test infrastructure being deliberately driven through reboots, a wipe,
            and OOBE -- a fast, host-side, crash-consistent snapshot of disk+memory state is
            exactly what's wanted, and is also the only kind that is guaranteed to succeed
            before the guest has integration services up (e.g. the 'pre-boot' checkpoint, taken
            before Windows Setup has even started). New-RehearsalVm sets the VM's CheckpointType
            to Standard once at creation (Set-VM -CheckpointType Standard) -- Checkpoint-VM
            itself has no -CheckpointType parameter of its own, it just uses whatever the VM is
            currently configured for. This function re-asserts that setting defensively before
            every checkpoint (idempotent, cheap) so it behaves correctly even if called against
            a VM whose CheckpointType was changed after creation by something else.

            IMPORTANT -- vTPM checkpoint restorability: because New-RehearsalVm enables a
            virtual TPM (Enable-VMTPM) backed by a local HgsGuardian, checkpoints of these VMs
            are encrypted against that guardian's key material. A checkpoint taken here can
            only be *applied* (restored) on a Hyper-V host that holds the same guardian's
            private key. For the single bench host a rehearsal normally runs on, that is a
            non-issue -- but a checkpoint copied or exported to a different Hyper-V host will
            fail to restore there unless that host's guardian is exported/imported first. Do
            not assume rehearsal checkpoints are portable between machines.

        .PARAMETER VmName
            Name of the rehearsal VM to checkpoint. Must already exist.

        .PARAMETER CheckpointName
            Name for the checkpoint (e.g. 'pre-boot', 'post-install', 'pre-complete').

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a Windows Hyper-V host to exercise. In
            particular the vTPM-checkpoint-restorability behaviour documented above is
            documented from Hyper-V's published guardian/key-protector design, not observed
            first-hand in this sandbox -- confirm it on a bench host before relying on it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$CheckpointName
    )

    Assert-HyperVAvailable

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "Checkpoint-Rehearsal: no VM named '$VmName' exists."
    }

    if ($vm.CheckpointType -ne 'Standard') {
        Write-Verbose "Checkpoint-Rehearsal: VM '$VmName' CheckpointType was '$($vm.CheckpointType)'; forcing it to Standard before checkpointing."
        Set-VM -Name $VmName -CheckpointType Standard
    }

    Write-Verbose "Checkpoint-Rehearsal: taking standard checkpoint '$CheckpointName' of VM '$VmName'."
    Checkpoint-VM -Name $VmName -SnapshotName $CheckpointName
}

function Remove-RehearsalVm {
    <#
        .SYNOPSIS
            Tears down a rehearsal VM: stops it, removes its checkpoints and VM configuration,
            then deletes its VHDX files (OS + media) -- unless -KeepVm is specified, in which
            case this is a complete no-op.

        .DESCRIPTION
            Matches Invoke-DeploymentRehearsal.ps1's own -KeepVm switch (T09 scaffold): callers
            are expected to call `Remove-RehearsalVm -VmName $VmName -KeepVm:$KeepVm` unconditionally
            at the end of a run and let this function decide whether teardown actually happens.

            Works from just -VmName (matching the T09 scaffold's TODO comment for how this gets
            called): if the VM still exists, its attached disks' backing file paths are
            discovered via Get-VMHardDiskDrive *before* the VM is removed (this is what finds
            the T10 media VHDX, which normally lives outside this VM's own working folder), and
            its own configuration folder is read from the VM object's Path property. Explicit
            -OsDiskPath / -MediaVhdxPath / -VmFolder parameters are accepted as a fallback (or a
            belt-and-braces addition) for cleaning up a VM that no longer exists but left files
            behind, e.g. after an interrupted previous run.

            Checkpoints are removed (Get-VMSnapshot | Remove-VMSnapshot) before Remove-VM rather
            than left for Remove-VM to discard implicitly, so Hyper-V's normal checkpoint-merge
            path runs first. Checkpoint merge is asynchronous in general; since this VM is being
            deleted outright immediately afterwards, the explicit file deletion below -- not a
            clean merge -- is what actually guarantees nothing is left behind on disk.

        .PARAMETER VmName
            Name of the VM to tear down.

        .PARAMETER VmFolder
            The VM's own working folder (as returned by New-RehearsalVm in .VmFolder). If not
            supplied and the VM still exists, this is read from the VM object's own Path
            property.

        .PARAMETER OsDiskPath
            Extra/fallback path to delete in addition to whatever is discovered from the live
            VM. Not required when the VM still exists (its disks are discovered automatically).

        .PARAMETER MediaVhdxPath
            Extra/fallback path to delete in addition to whatever is discovered from the live
            VM. Not required when the VM still exists (its disks are discovered automatically).

        .PARAMETER KeepVm
            Skip teardown entirely and leave the VM, its disks, and its checkpoints in place for
            post-mortem inspection.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a Windows Hyper-V host to exercise. In
            particular, whether checkpoint-merge-then-delete leaves any stray *.avhdx files
            behind under real timing (rather than the idealised sequence described above) needs
            confirming on a bench host; the recursive VmFolder delete at the end is this
            function's actual backstop against that.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [string]$VmFolder,
        [string]$OsDiskPath,
        [string]$MediaVhdxPath,
        [switch]$KeepVm
    )

    if ($KeepVm) {
        Write-Verbose "Remove-RehearsalVm: -KeepVm was specified; leaving VM '$VmName' (and its disks/checkpoints, if any) in place."
        return
    }

    Assert-HyperVAvailable

    $discoveredDiskPaths = @()
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue

    if ($vm) {
        if ([string]::IsNullOrWhiteSpace($VmFolder) -and $vm.Path) {
            $VmFolder = $vm.Path
        }

        try {
            $discoveredDiskPaths = @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop | ForEach-Object { $_.Path } | Where-Object { $_ })
        } catch {
            Write-Warning "Remove-RehearsalVm: could not enumerate attached disks for VM '$VmName'; falling back to any explicitly supplied -OsDiskPath/-MediaVhdxPath only: $($_.Exception.Message)"
        }

        if ($vm.State -ne 'Off') {
            Write-Verbose "Remove-RehearsalVm: VM '$VmName' is in state '$($vm.State)'; forcing it off before teardown."
            Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        }

        $snapshots = @(Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue)
        if ($snapshots.Count -gt 0) {
            Write-Verbose "Remove-RehearsalVm: removing $($snapshots.Count) checkpoint(s) for VM '$VmName'."
            $snapshots | Remove-VMSnapshot -ErrorAction SilentlyContinue
        }

        Write-Verbose "Remove-RehearsalVm: removing VM '$VmName'."
        Remove-VM -Name $VmName -Force -ErrorAction Stop
    } else {
        Write-Verbose "Remove-RehearsalVm: no VM named '$VmName' exists; skipping VM removal and proceeding straight to file cleanup."
    }

    $pathsToDelete = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($OsDiskPath, $MediaVhdxPath) + $discoveredDiskPaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and -not $pathsToDelete.Contains($candidate)) {
            $pathsToDelete.Add($candidate) | Out-Null
        }
    }

    foreach ($diskPath in $pathsToDelete) {
        if (Test-Path -LiteralPath $diskPath) {
            Write-Verbose "Remove-RehearsalVm: deleting disk file '$diskPath'."
            Remove-Item -LiteralPath $diskPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($VmFolder) -and (Test-Path -LiteralPath $VmFolder)) {
        # Removes the VM's configuration files and default checkpoint/snapshot storage, and
        # (since New-RehearsalVm places the OS VHDX inside this same folder) the OS disk too,
        # in one shot -- this is the actual backstop for anything the steps above missed.
        Write-Verbose "Remove-RehearsalVm: deleting VM folder '$VmFolder'."
        Remove-Item -LiteralPath $VmFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
