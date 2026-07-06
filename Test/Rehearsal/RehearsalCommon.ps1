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
