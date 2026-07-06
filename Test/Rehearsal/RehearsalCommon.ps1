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
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function New-RehearsalCheckResult {
    <#
        .SYNOPSIS
            Builds one structured prerequisite-check result entry.
    #>
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

# =============================================================================
# --- T10: Rehearsal media builder ---
# =============================================================================
#
# New-RehearsalMedia builds the rehearsal "USB": a dynamic VHDX, initialised GPT,
# with a single NTFS volume labelled 1S-WIN11 (FABLE_TASKS.md Phase C's media-
# strategy note: the toolkit finds media by volume label, not bus type -- see
# Get-UsbRoot above/in Common.ps1 -- so a fixed disk with this label behaves
# identically to a physical USB stick to every script under Deployment\Scripts).
# It then runs the REAL Initialize-UsbDeployment.ps1 against the mounted volume,
# so the rehearsal exercises production's actual copy/generate/validate code
# path, not a reimplementation of it. See New-RehearsalMedia's own comment-based
# help below for why that requires two passes (real defaults, then scenario) and
# the exact order that makes that correct.
#
# The supporting helpers immediately below (Get-RehearsalStandardScenarioOverlay,
# Get-RehearsalStandardWingetPackages, Merge-RehearsalScenarioConfig,
# New-RehearsalDotEnvContent) are pure: no I/O, no Windows-only cmdlets. They are
# unit-tested on any platform in Tests\Unit\RehearsalMedia.Tests.ps1.
# New-RehearsalMedia itself calls Hyper-V/Storage cmdlets (New-VHD, Mount-VHD,
# Initialize-Disk, New-Partition, Format-Volume, Dismount-VHD) that only exist on
# a Windows host with Hyper-V, guarded the same way Test-RehearsalDefaultSwitch /
# Test-RehearsalVmNameAvailable above guard theirs (Get-Command -ErrorAction
# SilentlyContinue via Test-RehearsalCommandAvailable): a missing module fails
# with one clear message up front instead of a cryptic error partway through.

# This file always lives at <repo root>\Test\Rehearsal, so the repo root is two
# levels up. Resolved once here, at dot-source time, rather than recomputed on
# every New-RehearsalMedia call.
$script:RehearsalRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-RehearsalStandardScenarioOverlay {
    <#
        .SYNOPSIS
            The T10 'Standard' rehearsal scenario's deployment_config.json overlay.

        .DESCRIPTION
            T14 formalises named scenario overlays under Test\Rehearsal\Scenarios\<name>;
            until then this is the single inline default baseline described in
            FABLE_TASKS.md's T10 section. Pure data, no I/O -- combine it with a real
            resolved config via Merge-RehearsalScenarioConfig below.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        wipe_repartition_drive = $true
        # Verified in Deployment\Scripts\Invoke-PreflightChecks.ps1: when Get-CimInstance
        # Win32_Battery finds no battery device at all (the expected case for a Hyper-V VM),
        # the AC-power check is a Warn ("No battery was detected; assuming desktop or
        # AC-only device.") regardless of require_ac_power -- so this is belt-and-braces for
        # the (unverified on real Hyper-V) case where a VM configuration exposes a synthetic
        # battery that reports "on battery". T14 / the first real rehearsal run on a Windows/
        # Hyper-V host should confirm actual guest behaviour rather than take this on faith;
        # no Windows host was available to this task to verify it directly.
        require_ac_power       = $false
        msp_wifi_setup          = @{ enabled = $false }
        computer_name_mode      = 'serial'
        install_winget_apps     = $true
        datto_rmm_site_id_uuid  = ''
    }
}

function Get-RehearsalStandardWingetPackages {
    <#
        .SYNOPSIS
            The T10 'Standard' rehearsal scenario's winget_packages.json content.

        .DESCRIPTION
            A single small, freely-installable placeholder package, replacing the repo's real
            list (which includes licensed/interactive apps such as Microsoft.Office and
            TeamViewer.TeamViewer.QuickSupport that a disposable rehearsal VM cannot and should
            not attempt to install). Pure data, no I/O.

            Returns a PowerShell array: wrap the call in @(...) at the use site (as
            New-RehearsalMedia and the accompanying Pester suite both do) so a 1-element result
            is not unwrapped to a bare hashtable by PowerShell's pipeline enumeration.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param()

    return @(
        @{ id = '7zip.7zip'; display_name = '7-Zip'; required = $true; install_arguments = '' }
    )
}

function Merge-RehearsalScenarioConfig {
    <#
        .SYNOPSIS
            Merges a rehearsal scenario overlay over a resolved deployment config.

        .DESCRIPTION
            Pure function (no I/O): thin wrapper around Common.ps1's Merge-Config, with one
            addition -- msp_wifi_setup is deep-merged (base then overlay) instead of wholesale-
            replaced. Merge-Config's own merge is a shallow, one-level Base/Override merge, and
            msp_wifi_setup is a nested hashtable (ssid, password_env_var, authentication,
            encryption, connect_timeout_seconds); a scenario overlay that only wants to flip
            `enabled` must not silently blank out the rest of that nested object.

            Does not mutate BaseConfig or Overlay; always returns a new hashtable tree.

            Requires Merge-Config (Deployment\Scripts\Common.ps1) to already be loaded in the
            current session -- New-RehearsalMedia dot-sources it before calling this, and the
            accompanying Pester suite (Tests\Unit\RehearsalMedia.Tests.ps1) does the same.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$BaseConfig,
        [Parameter(Mandatory = $true)][hashtable]$Overlay
    )

    $effectiveOverlay = @{}
    foreach ($key in $Overlay.Keys) { $effectiveOverlay[$key] = $Overlay[$key] }

    if ($Overlay.ContainsKey('msp_wifi_setup') -and ($Overlay.msp_wifi_setup -is [hashtable])) {
        $baseWifiSetup = @{}
        if ($BaseConfig.ContainsKey('msp_wifi_setup') -and ($BaseConfig.msp_wifi_setup -is [hashtable])) {
            $baseWifiSetup = $BaseConfig.msp_wifi_setup
        }
        # Merge-Config always builds a fresh hashtable, so this neither aliases nor mutates
        # $BaseConfig.msp_wifi_setup or $Overlay.msp_wifi_setup.
        $effectiveOverlay.msp_wifi_setup = Merge-Config -Base $baseWifiSetup -Override $Overlay.msp_wifi_setup
    }

    return Merge-Config -Base $BaseConfig -Override $effectiveOverlay
}

function New-RehearsalDotEnvContent {
    <#
        .SYNOPSIS
            Builds the line content for a rehearsal .env file from a name/value secrets map.

        .DESCRIPTION
            Pure function (no I/O): returns "NAME=value" lines, one per non-blank secret,
            sorted by name for deterministic output. A null/empty/whitespace-only value is
            omitted rather than written as "NAME=" -- Get-DotEnvValue (Common.ps1) and this
            toolkit's Resolve-Osit*PasswordForInitialisation helpers already treat a blank
            value as "not set", so omitting it here matches how it will actually be read back.

            Returns a PowerShell array: wrap the call in @(...) at the use site if you need
            guaranteed array semantics (for example to check .Count), matching this codebase's
            existing convention (see @($existingActions + $record) in Write-DryRunAction,
            Common.ps1) -- a 1-line result would otherwise be unwrapped to a bare string by
            PowerShell's pipeline enumeration.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][hashtable]$Secrets)

    $lines = @()
    foreach ($name in ($Secrets.Keys | Sort-Object)) {
        $value = [string]$Secrets[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $lines += "$name=$value"
    }
    return $lines
}

function New-RehearsalMedia {
    <#
        .SYNOPSIS
            Builds the rehearsal "USB" media VHDX and populates it via the real
            Initialize-UsbDeployment.ps1, with the scenario's config overlay applied.

        .DESCRIPTION
            Sequencing (read this before changing the order below):

              1. Create + mount a dynamic VHDX; GPT; single NTFS volume labelled -VolumeLabel.
              2. Write a throwaway per-run rehearsal .env onto the mounted volume root, so
                 Initialize-UsbDeployment.ps1's interactive Read-Host prompts
                 (Resolve-Osit*PasswordForInitialisation) never fire during an unattended
                 rehearsal run.
              3. Run the REAL Initialize-UsbDeployment.ps1 -UsbRoot <mounted>, no special
                 flags. This is the key design point (FABLE_TASKS.md Phase C intro): the
                 rehearsal must exercise the exact copy + generation + validation path
                 production uses. At this point Autounattend.xml and OSIT-DiskPart.txt on the
                 media reflect the REPO'S OWN checked-in deployment_config.json, not the
                 scenario overlay yet -- see the note below on why a naive "write merged
                 config to the media, then run Initialize-UsbDeployment.ps1" ordering does
                 not work.
              4. Merge the scenario overlay over the config Initialize-UsbDeployment.ps1 just
                 copied to the media (and the scenario's winget_packages.json placeholder),
                 and overwrite both files on the media with the result.
              5. Re-run ONLY the generation half (New-GeneratedUnattendContent -- the exact
                 function Initialize-UsbDeployment.ps1 itself calls, via
                 UnattendGeneration.ps1) directly against the merged config, and overwrite the
                 media's Autounattend.xml / OSIT-DiskPart.txt with the result, so what ships
                 on the rehearsal media matches the scenario, not the repo defaults. Then
                 re-validate that regenerated pair with Validate-Unattend.ps1, the same way
                 Initialize-UsbDeployment.ps1 validates its own (pass-1) output.
              6. Dismount (try/finally, so this always runs, even on error).

            WHY NOT "write the merged config to the media first, then run
            Initialize-UsbDeployment.ps1 -UsbRoot <mounted>" in one pass?
            Initialize-UsbDeployment.ps1 resolves its config from Get-DeploymentConfig
            -UsbRoot $sourceRoot, where $sourceRoot is wherever Initialize-UsbDeployment.ps1
            ITSELF lives (the repo root here) -- see its own source -- never from -UsbRoot,
            and it does so before it copies anything to the target. Pre-seeding a config file
            on an as-yet-empty mounted volume has no effect on what it generates, and
            Copy-DeploymentFiles would overwrite that pre-seeded file with the repo's own copy
            immediately afterwards regardless. The only way to make the SHIPPED
            Autounattend.xml/OSIT-DiskPart.txt reflect the scenario is to let
            Initialize-UsbDeployment.ps1 run its real (repo-default) pass first, then
            deliberately regenerate a second time against the scenario-merged config, as this
            function does. Getting this order backwards would silently ship the repo's
            default disk-wipe/computer-naming/etc. config to the rehearsal VM instead of the
            scenario actually under test.

        .PARAMETER WorkingDirectory
            Scratch directory the VHDX is created in (matches
            Invoke-DeploymentRehearsal.ps1's -WorkingDirectory). Created if it does not exist.

        .PARAMETER Scenario
            Named overlay to apply. Only 'Standard' exists until T14 formalises named scenario
            overlays under Test\Rehearsal\Scenarios\<name>. Case-insensitive.

        .PARAMETER VolumeLabel
            NTFS label to format the media volume with. Defaults to '1S-WIN11', matching
            Common.ps1's own $script:DeploymentVolumeLabel constant; overridable here purely
            so a test/negative-scenario can exercise a non-default label without touching
            Common.ps1.

        .PARAMETER SizeGB
            Dynamic VHDX declared size in GB. Default 16, per FABLE_TASKS.md T10.

        .OUTPUTS
            An ordered hashtable: VhdxPath, VolumeLabel, Scenario, MergedConfig (the resolved
            config actually written to the media and used to generate its Autounattend.xml).
            The media (including its .env, holding OSIT_LOCAL_ADMIN_PASSWORD for whichever
            later task drives the guest, e.g. T12's PowerShell Direct) lives on the dismounted
            VHDX at VhdxPath, not in this return value.

        .NOTES
            Cannot be executed or tested end-to-end in a Linux sandbox with no Hyper-V: the
            VHDX create/mount/partition/format/dismount lifecycle, and running
            Initialize-UsbDeployment.ps1 against a real mounted NTFS volume, all require an
            actual Windows host. This function's up-front platform guard (below) and its pure
            helpers above are unit-tested in Tests\Unit\RehearsalMedia.Tests.ps1; the acceptance
            criteria in FABLE_TASKS.md T10 (byte-for-byte Validate-Unattend.ps1 -Generated pass,
            idempotent re-run, exact volume label) require a real Windows/Hyper-V host to verify.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$Scenario = 'Standard',
        [string]$VolumeLabel = '1S-WIN11',
        [int]$SizeGB = 16
    )

    if ($Scenario -ine 'Standard') {
        throw "Rehearsal scenario '$Scenario' is not recognised. Only 'Standard' is implemented (T14 formalises named scenario overlays under Test\Rehearsal\Scenarios\<name>)."
    }

    # Guard every Hyper-V/Storage cmdlet this function needs up front, matching the
    # Get-Command -ErrorAction SilentlyContinue convention already used by
    # Test-RehearsalDefaultSwitch / Test-RehearsalVmNameAvailable above: one clear, actionable
    # failure before any work starts, instead of a cryptic "term not recognized" partway
    # through building the VHDX.
    foreach ($cmdletName in @('New-VHD', 'Mount-VHD', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Dismount-VHD')) {
        if (-not (Test-RehearsalCommandAvailable -Name $cmdletName)) {
            throw "$cmdletName is not available on this platform. New-RehearsalMedia requires Windows 10/11 Pro, Enterprise, or Education with the Hyper-V feature enabled (New-VHD/Mount-VHD/Dismount-VHD ship with Hyper-V; Initialize-Disk/New-Partition/Format-Volume ship with Windows itself but are listed here too so every dependency this function needs is checked in one place)."
        }
    }

    $commonScript = Join-Path $script:RehearsalRepoRoot 'Deployment\Scripts\Common.ps1'
    $unattendGenScript = Join-Path $script:RehearsalRepoRoot 'Deployment\Scripts\UnattendGeneration.ps1'
    $initializeScript = Join-Path $script:RehearsalRepoRoot 'Initialize-UsbDeployment.ps1'
    $templatePath = Join-Path $script:RehearsalRepoRoot 'Autounattend.xml'
    $validatorPath = Join-Path $script:RehearsalRepoRoot 'Validate-Unattend.ps1'

    foreach ($requiredFile in @($commonScript, $unattendGenScript, $initializeScript, $templatePath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Required toolkit file not found: $requiredFile"
        }
    }

    # Common.ps1/UnattendGeneration.ps1 have no side effects at dot-source time (confirmed by
    # Tests\Unit\Common.Tests.ps1's own BeforeAll comment), so loading them lazily here -- only
    # if not already present in this session -- keeps a caller who only wants
    # Test-RehearsalPrerequisites from paying for or depending on the production scripts.
    if (-not (Test-RehearsalCommandAvailable -Name 'Merge-Config')) { . $commonScript }
    if (-not (Test-RehearsalCommandAvailable -Name 'New-GeneratedUnattendContent')) { . $unattendGenScript }

    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        New-Item -ItemType Directory -Path $WorkingDirectory -Force -ErrorAction Stop | Out-Null
    }
    $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path

    # Idempotency (FABLE_TASKS.md T10 acceptance criteria: "re-running the builder is
    # idempotent -- fresh VHDX each time"): timestamp plus a short guid segment, matching the
    # New-DeploymentRunId convention in Common.ps1, so rapid/concurrent re-runs never collide.
    $vhdxFileName = 'Rehearsal-Media-{0}-{1}-{2}.vhdx' -f $Scenario, (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $vhdxPath = Join-Path $resolvedWorkingDirectory $vhdxFileName

    Write-Verbose "Creating dynamic VHDX (${SizeGB} GB): $vhdxPath"
    New-VHD -Path $vhdxPath -SizeBytes ([int64]$SizeGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null

    try {
        $mountedVhd = Mount-VHD -Path $vhdxPath -Passthru -ErrorAction Stop
        Initialize-Disk -Number $mountedVhd.DiskNumber -PartitionStyle GPT -Confirm:$false -ErrorAction Stop

        $partition = New-Partition -DiskNumber $mountedVhd.DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel $VolumeLabel -Confirm:$false -ErrorAction Stop | Out-Null

        $mountedDriveLetter = [string]$partition.DriveLetter
        if ([string]::IsNullOrWhiteSpace($mountedDriveLetter)) {
            throw 'New-Partition did not assign a drive letter to the rehearsal media volume.'
        }
        $mountedRoot = "$mountedDriveLetter`:\"

        # --- Throwaway per-run rehearsal secrets --------------------------------------------
        $ositPassword = New-RandomPassword -Length 24
        $envSecrets = @{ OSIT_LOCAL_ADMIN_PASSWORD = $ositPassword }

        # Initialize-UsbDeployment.ps1's pass 1 below resolves its config from the REPO'S OWN
        # checked-in deployment_config.json (see the sequencing note above), which today has
        # msp_wifi_setup.enabled=true, so that pass will prompt (Read-Host) for
        # OSIT_WIFI_PASSWORD unless one is already resolvable -- hanging a non-interactive
        # rehearsal. A throwaway value is written defensively so pass 1 always finds one; it
        # is never actually used at deployment runtime once the scenario overlay (applied
        # after pass 1) disables msp_wifi_setup.enabled in the config that ships.
        $envSecrets.OSIT_WIFI_PASSWORD = New-RandomPassword -Length 24

        # Same defensive reasoning for SMTP: only pre-seeded if the repo's real
        # smtp_config.json currently both enables SMTP and configures a username
        # (Initialize-UsbDeployment.ps1's own Test-SmtpPasswordRequired condition, replicated
        # here since that helper is private to that script). Today's checked-in
        # smtp_config.json has enabled=false, so this is a no-op in practice; kept so a future
        # change to that file cannot silently reintroduce a Read-Host hang here.
        $repoSmtpConfig = Get-SmtpConfig -UsbRoot $script:RehearsalRepoRoot
        $smtpPasswordEnvVarName = [string]$repoSmtpConfig.password_env_var
        if ([string]::IsNullOrWhiteSpace($smtpPasswordEnvVarName)) { $smtpPasswordEnvVarName = 'OSIT_SMTP_PASSWORD' }
        if ([bool]$repoSmtpConfig.enabled -and -not [string]::IsNullOrWhiteSpace([string]$repoSmtpConfig.username)) {
            $envSecrets[$smtpPasswordEnvVarName] = New-RandomPassword -Length 24
        }

        $envPath = Join-Path $mountedRoot '.env'
        Set-Content -LiteralPath $envPath -Value @(New-RehearsalDotEnvContent -Secrets $envSecrets) -Encoding UTF8 -Force -ErrorAction Stop

        # --- Pass 1: run the REAL Initialize-UsbDeployment.ps1 (repo-default config) --------
        # This is the point of the whole design (FABLE_TASKS.md Phase C intro): exercise
        # production's actual copy + generate + validate path, not a reimplementation. After
        # this call the media has the repo's OWN checked-in deployment_config.json and an
        # Autounattend.xml/OSIT-DiskPart.txt generated from it -- not yet the scenario.
        Write-Verbose "Running the real Initialize-UsbDeployment.ps1 -UsbRoot $mountedRoot"
        & $initializeScript -UsbRoot $mountedRoot

        # --- Scenario overlay: merge, then re-run ONLY the generation step ------------------
        $mediaConfigPath = Join-Path $mountedRoot 'Deployment\Config\deployment_config.json'
        if (-not (Test-Path -LiteralPath $mediaConfigPath -PathType Leaf)) {
            throw "Initialize-UsbDeployment.ps1 did not produce a deployment_config.json on the media at $mediaConfigPath."
        }

        $baseConfig = Get-DeploymentConfig -UsbRoot $mountedRoot
        $scenarioOverlay = Get-RehearsalStandardScenarioOverlay
        $mergedConfig = Merge-RehearsalScenarioConfig -BaseConfig $baseConfig -Overlay $scenarioOverlay
        Write-JsonFile -Path $mediaConfigPath -InputObject $mergedConfig
        Write-Verbose "Scenario '$Scenario' overlay merged and written to $mediaConfigPath"

        $mediaWingetPackagesPath = Join-Path $mountedRoot 'Deployment\Config\winget_packages.json'
        Write-JsonFile -Path $mediaWingetPackagesPath -InputObject @{ packages = @(Get-RehearsalStandardWingetPackages) }

        $generatedUnattend = New-GeneratedUnattendContent -TemplatePath $templatePath -Config $mergedConfig -Password $ositPassword

        $mediaAutounattendPath = Join-Path $mountedRoot 'Autounattend.xml'
        Set-Content -LiteralPath $mediaAutounattendPath -Value $generatedUnattend.AutounattendContent -Encoding UTF8 -Force -ErrorAction Stop

        $mediaDiskPartScriptPath = Join-Path $mountedRoot $script:DiskPartScriptFileName
        $mediaDiskPartLogPath = Join-Path $mountedRoot $script:DiskPartLogFileName
        if ($null -ne $generatedUnattend.DiskPartScript) {
            # ASCII, matching Initialize-UsbDeployment.ps1's own write: a UTF-8 BOM is misread
            # by `diskpart /s` as part of its first command.
            Set-Content -LiteralPath $mediaDiskPartScriptPath -Value $generatedUnattend.DiskPartScript -Encoding ASCII -Force -ErrorAction Stop
        } elseif (Test-Path -LiteralPath $mediaDiskPartScriptPath -PathType Leaf) {
            Remove-Item -LiteralPath $mediaDiskPartScriptPath -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $mediaDiskPartLogPath -PathType Leaf) {
            Remove-Item -LiteralPath $mediaDiskPartLogPath -Force -ErrorAction SilentlyContinue
        }

        # Re-validate: pass 1's own validation (inside Initialize-UsbDeployment.ps1) only ever
        # checked the repo-default generation. This checks the scenario-regenerated pair that
        # actually ships to the rehearsal VM, matching FABLE_TASKS.md T10's acceptance
        # criterion. Cannot be exercised in this sandbox (no Windows host) -- see task report.
        if (Test-Path -LiteralPath $validatorPath -PathType Leaf) {
            Write-Verbose 'Validating the scenario-regenerated Autounattend.xml...'
            & $validatorPath -Path $mediaAutounattendPath -Generated -ConfigPath $mediaConfigPath
            if ($LASTEXITCODE -ne 0) {
                throw "Scenario '$Scenario' Autounattend.xml failed validation. Fix the scenario overlay or the Autounattend.xml template, then rerun New-RehearsalMedia."
            }
        }

        Write-Verbose "Rehearsal media build complete: $vhdxPath"

        return [ordered]@{
            VhdxPath     = $vhdxPath
            VolumeLabel  = $VolumeLabel
            Scenario     = $Scenario
            MergedConfig = $mergedConfig
        }
    } finally {
        # Always attempted, even on error above (task spec: "Dismount cleanly ... even on
        # error"). Best-effort: a failure here is logged, not thrown, so it never masks the
        # real error from the try block above (or, on the success path, hide the return value).
        try {
            Dismount-VHD -Path $vhdxPath -ErrorAction Stop
        } catch {
            Write-Warning "Could not cleanly dismount rehearsal media VHDX '$vhdxPath': $($_.Exception.Message)"
        }
    }
}
