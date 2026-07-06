<#
    .SYNOPSIS
        Guest monitoring and artifact collection for the Tier 1 Hyper-V rehearsal harness
        (FABLE_TASKS.md T12).

    .DESCRIPTION
        Host-side tooling only, dot-sourced by Invoke-DeploymentRehearsal.ps1 alongside
        RehearsalCommon.ps1 (T09-T11). Requires a Windows 10/11 host with Hyper-V; every public
        function here calls RehearsalCommon.ps1's Assert-HyperVAvailable first so a missing
        Hyper-V module fails with one clear message instead of partway through.

        Two monitoring phases, matching the VM's own lifecycle:

          Phase 1 (Wait-RehearsalSetupExit): while Windows Setup/WinPE is running, no guest
          agent or PowerShell Direct session is available yet. This phase watches the VM from
          the *host* side only -- Hyper-V's own view of VM Uptime (a genuine reboot resets it)
          and the Heartbeat integration service -- to detect Setup handing off to the installed
          OS's first boot. A configurable timeout here is exactly the "never left Setup" failure
          class FABLE_TASKS.md calls out (Windows Setup's own 0x80004005 error family); on
          timeout this captures a VM screenshot via WMI for diagnosis.

          Phase 2 (Watch-RehearsalDeployment): once the guest heartbeat is up, this polls via
          PowerShell Direct every 30 seconds (default), reusing the deployment toolkit's own
          Deployment\Scripts\Get-DeploymentStatus.ps1 -Json *inside the guest* rather than
          re-implementing step-progress/terminal-state logic on the host -- that script already
          computes overall_status ('Completed'/'Failed'/'Running'/'Stalled'/'WaitingForReboot'),
          which Get-RehearsalTerminalState below maps directly to Success/Failed/Running.
          PowerShell Direct connection failures during the deployment's own reboots (computer
          rename, Windows Update) are expected and tolerated, not treated as failures.

        Copy-RehearsalArtifacts harvests Deployment\Logs, \Reports, \State (from whichever root
        the guest deployment is actually running from -- the media, or C:\1S-WIN11 after a
        local handover), OSIT-DiskPart.log from the media volume root, and a final VM
        screenshot, into Test\Rehearsal\Artifacts\<timestamp>\ on the host.

    .NOTES
        UNVERIFIED ON REAL HYPER-V: every function below that touches Hyper-V, WMI, or
        PowerShell Direct requires a Windows host with a running/booting VM to exercise for
        real -- none of this can be executed in this toolkit's Linux CI/dev sandbox. What *is*
        verified here: every function parses cleanly, dot-sources without error alongside
        RehearsalCommon.ps1 and Invoke-DeploymentRehearsal.ps1, and the pure helpers
        (Get-RehearsalTerminalState, Get-RehearsalArtifactFolder) have real Pester coverage in
        Tests\Unit\RehearsalMonitoring.Tests.ps1.
#>

Set-StrictMode -Version 2.0

function Get-RehearsalTerminalState {
    <#
        .SYNOPSIS
            Maps Get-DeploymentStatus.ps1 -Json's own overall_status to the rehearsal harness's
            terminal-state vocabulary (FABLE_TASKS.md T12): 'Complete' in completed_steps means
            Get-DeploymentStatusSnapshot already reports overall_status 'Completed' -> Success;
            last_error present with no active process means it already reports 'Failed' ->
            Failed; every other overall_status ('Running', 'Stalled', 'WaitingForReboot',
            'NotStarted') is not yet terminal from the harness's point of view -> Running (the
            harness's own -TimeoutMinutes budget is what turns a stuck 'Running'/'Stalled' into
            a Timeout, in Watch-RehearsalDeployment below, not this function).

            Pure function: reused directly by Watch-RehearsalDeployment, and unit-tested
            independently of any live guest/PowerShell Direct state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$OverallStatus)

    switch ($OverallStatus) {
        'Completed' { return 'Success' }
        'Failed' { return 'Failed' }
        default { return 'Running' }
    }
}

function Get-RehearsalArtifactFolder {
    <#
        .SYNOPSIS
            Builds the Test\Rehearsal\Artifacts\<timestamp>\ path artifacts are harvested into.

            Pure function (no I/O): callers create the directory themselves once they have the
            path (Copy-RehearsalArtifacts does this).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$ArtifactRoot,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    return Join-Path $ArtifactRoot $Timestamp
}

function Save-RehearsalVmScreenshot {
    <#
        .SYNOPSIS
            Captures a screenshot of a rehearsal VM's console via WMI and saves it as a PNG.

        .DESCRIPTION
            Hyper-V's PowerShell module has no built-in "take a screenshot" cmdlet; this uses
            Msvm_VirtualSystemManagementService's GetVirtualSystemThumbnailImage WMI method
            (root\virtualization\v2 namespace) -- the same technique long used by community
            Hyper-V screenshot tooling. The method returns raw RGB565 pixel data (2 bytes per
            pixel, WidthPixels x HeightPixels), not an encoded image, so this converts each
            pixel into a .NET Bitmap and saves it as PNG so the artifact is directly viewable.
            A per-pixel SetPixel loop is deliberately simple rather than using LockBits for
            speed: this is occasional diagnostic tooling (a timeout event or a run's final
            state), not a hot path, so correctness-over-speed is the right tradeoff here.

        .PARAMETER VmName
            Name of the rehearsal VM to screenshot. Must already exist.

        .PARAMETER OutputPath
            File path to save the PNG to. Parent directory is created if missing.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a Windows host with a live VM and WMI access
            to root\virtualization\v2 to exercise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [int]$WidthPixels = 1024,
        [int]$HeightPixels = 768
    )

    Assert-HyperVAvailable
    if (-not (Test-RehearsalCommandAvailable -Name 'Get-CimInstance')) {
        throw 'Save-RehearsalVmScreenshot requires Get-CimInstance (Windows CIM/WMI), not available on this platform.'
    }

    $vm = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem -Filter "ElementName='$VmName'" -ErrorAction Stop
    if (-not $vm) { throw "Save-RehearsalVmScreenshot: no VM named '$VmName' found via WMI (root\virtualization\v2)." }

    $vsms = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_VirtualSystemManagementService -ErrorAction Stop
    $result = Invoke-CimMethod -InputObject $vsms -MethodName GetVirtualSystemThumbnailImage -Arguments @{
        TargetSystem = $vm
        WidthPixels  = $WidthPixels
        HeightPixels = $HeightPixels
    }

    if ($result.ReturnValue -ne 0 -or -not $result.ImageData) {
        throw "Save-RehearsalVmScreenshot: GetVirtualSystemThumbnailImage failed (ReturnValue=$($result.ReturnValue)) for VM '$VmName'. The VM may not yet have a rendered console frame (very early boot)."
    }

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap($WidthPixels, $HeightPixels)
    try {
        $bytes = [byte[]]$result.ImageData
        $pixelIndex = 0
        for ($y = 0; $y -lt $HeightPixels; $y++) {
            for ($x = 0; $x -lt $WidthPixels; $x++) {
                $value = [BitConverter]::ToUInt16($bytes, $pixelIndex)
                $pixelIndex += 2
                $r = [int]((($value -shr 11) -band 0x1F) * 255 / 31)
                $g = [int]((($value -shr 5) -band 0x3F) * 255 / 63)
                $b = [int](($value -band 0x1F) * 255 / 31)
                $bitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($r, $g, $b))
            }
        }

        $parent = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }

    return $OutputPath
}

function Wait-RehearsalSetupExit {
    <#
        .SYNOPSIS
            Phase 1 monitoring: waits for a rehearsal VM to leave Windows Setup/WinPE and reach
            a live, heartbeat-reporting guest OS.

        .DESCRIPTION
            No guest agent or PowerShell Direct session exists during WinPE/Setup, so this polls
            purely host-side signals: VM Uptime (a genuine reboot -- wipe-and-install completing
            its first restart into the installed OS -- resets Uptime to a small value) combined
            with the Heartbeat integration service reporting a healthy status (confirms the
            guest OS's own integration services, not just the VM, are up). Both signals must
            agree before this returns success, since Uptime alone can reset on transient WinPE
            reboots that are still part of Setup.

            On timeout (default 40 minutes -- FABLE_TASKS.md T12's own default for "never left
            Setup", the 0x80004005-class failure), captures a screenshot for diagnosis if
            -ScreenshotPath is supplied.

        .PARAMETER VmName
            Name of the rehearsal VM to watch. Must already exist and be running.

        .PARAMETER TimeoutMinutes
            How long to wait for Setup to hand off to the installed OS before giving up.

        .PARAMETER PollSeconds
            Interval between Uptime/Heartbeat checks.

        .PARAMETER ScreenshotPath
            Optional path to save a diagnostic screenshot to if this phase times out.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: the exact Uptime-reset and Heartbeat-status-string
            behaviour during a real Windows Setup wipe/install/OOBE sequence needs confirming
            on a bench host; the status strings checked below ('OK' and the "Applications
            Healthy" variant) are Hyper-V's documented Heartbeat states, not observed first-hand
            in this sandbox.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [int]$TimeoutMinutes = 40,
        [int]$PollSeconds = 15,
        [string]$ScreenshotPath
    )

    Assert-HyperVAvailable

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $sawReboot = $false
    $lastUptime = $null

    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if (-not $vm) { throw "Wait-RehearsalSetupExit: no VM named '$VmName' exists." }

        if ($null -ne $lastUptime -and $vm.Uptime -lt $lastUptime) { $sawReboot = $true }
        $lastUptime = $vm.Uptime

        $heartbeat = Get-VMIntegrationService -VMName $VmName -Name 'Heartbeat' -ErrorAction SilentlyContinue
        $heartbeatOk = [bool]($heartbeat -and $heartbeat.PrimaryStatusDescription -match '^OK\b')

        if ($sawReboot -and $heartbeatOk) {
            Write-Host "[Rehearsal] VM '$VmName' left Setup/WinPE and guest heartbeat is up." -ForegroundColor Green
            return [ordered]@{ LeftSetup = $true; TimedOut = $false }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    Write-Warning "Wait-RehearsalSetupExit: VM '$VmName' did not leave Setup/WinPE within $TimeoutMinutes minute(s) (the 0x80004005-class failure FABLE_TASKS.md T12 calls out)."
    if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
        try {
            Save-RehearsalVmScreenshot -VmName $VmName -OutputPath $ScreenshotPath | Out-Null
            Write-Host "[Rehearsal] Saved a timeout diagnostic screenshot to $ScreenshotPath" -ForegroundColor Yellow
        } catch {
            Write-Warning "Could not capture the Setup-timeout screenshot: $($_.Exception.Message)"
        }
    }
    return [ordered]@{ LeftSetup = $false; TimedOut = $true }
}

function Invoke-RehearsalGuestStatusPoll {
    <#
        .SYNOPSIS
            One Phase 2 poll cycle: reads the guest's own deployment status via PowerShell
            Direct, reusing Get-DeploymentStatus.ps1 -Json inside the guest rather than
            re-implementing its step-progress/terminal-state logic on the host.

        .DESCRIPTION
            Resolves the rehearsal media in-guest by volume label (mirroring how the toolkit's
            own Get-UsbRoot finds it by label, not bus type), then invokes
            Deployment\Scripts\Get-DeploymentStatus.ps1 -UsbRoot <resolved> -Json remotely and
            parses the returned JSON. Tolerates PowerShell Direct connection failures (expected
            during the deployment's own reboots) by catching and reporting them via
            .reachable = $false rather than throwing, so a caller's polling loop can keep going.

        .OUTPUTS
            Ordered hashtable: reachable (bool), media_found (bool), snapshot (the parsed
            Get-DeploymentStatusSnapshot object, or $null), error (present only when
            unreachable).

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest with PowerShell Direct available
            (guest integration services up) and the rehearsal media actually mounted/labelled
            1S-WIN11 inside the guest.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [string]$VolumeLabel = '1S-WIN11'
    )

    Assert-HyperVAvailable

    try {
        $json = Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
            param($Label)
            $volume = Get-Volume -FileSystemLabel $Label -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1
            if (-not $volume) { return $null }
            $root = "$($volume.DriveLetter):\"
            $statusScript = Join-Path $root 'Deployment\Scripts\Get-DeploymentStatus.ps1'
            if (-not (Test-Path -LiteralPath $statusScript -PathType Leaf)) { return $null }
            & $statusScript -UsbRoot $root -Json
        } -ArgumentList $VolumeLabel

        if ([string]::IsNullOrWhiteSpace($json)) {
            return [ordered]@{ reachable = $true; media_found = $false; snapshot = $null }
        }
        return [ordered]@{ reachable = $true; media_found = $true; snapshot = ($json | ConvertFrom-Json) }
    } catch {
        # Tolerate PowerShell Direct outages across the deployment's own reboots
        # (FABLE_TASKS.md T12): a connection failure here is expected mid-run, not fatal.
        return [ordered]@{ reachable = $false; media_found = $false; snapshot = $null; error = $_.Exception.Message }
    }
}

function Watch-RehearsalDeployment {
    <#
        .SYNOPSIS
            Phase 2 monitoring loop: polls the guest's deployment status every -PollSeconds
            until a terminal state is reached or -Deadline passes, printing live progress to
            the host console and taking the 'pre-complete' checkpoint the first time the guest
            state reaches the EmailReport step.

        .PARAMETER VmName
            Name of the rehearsal VM to watch.

        .PARAMETER Credential
            OSIT credential for the PowerShell Direct session (built from the rehearsal .env
            password T10's New-RehearsalMedia returns as .OsitPassword).

        .PARAMETER Deadline
            Absolute wall-clock time to give up by (the harness's overall -TimeoutMinutes
            budget), not a relative duration -- this lets a caller share one deadline across
            both monitoring phases.

        .OUTPUTS
            Ordered hashtable: Result ('Success'/'Failed'/'Timeout'), Snapshot (the last guest
            status snapshot seen, or $null if the guest was never reachable), TimedOut (bool).

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest running the actual deployment
            toolkit and reachable via PowerShell Direct.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][datetime]$Deadline,
        [string]$VolumeLabel = '1S-WIN11',
        [int]$PollSeconds = 30
    )

    Assert-HyperVAvailable

    $preCompleteCheckpointTaken = $false
    $lastSnapshot = $null

    while ((Get-Date) -lt $Deadline) {
        $poll = Invoke-RehearsalGuestStatusPoll -VmName $VmName -Credential $Credential -VolumeLabel $VolumeLabel

        if (-not $poll.reachable) {
            Write-Host "[Rehearsal] PowerShell Direct unreachable (tolerated -- likely mid-reboot): $($poll.error)" -ForegroundColor DarkYellow
        } elseif (-not $poll.media_found) {
            Write-Host '[Rehearsal] Guest reachable, but rehearsal media (1S-WIN11) or Get-DeploymentStatus.ps1 was not found yet.' -ForegroundColor DarkYellow
        } else {
            $snapshot = $poll.snapshot
            $lastSnapshot = $snapshot
            Write-Host "[Rehearsal] step $($snapshot.completed_step_count)/$($snapshot.total_step_count) - current: $($snapshot.current_step) - status: $($snapshot.overall_status)" -ForegroundColor Cyan

            $reachedEmailReport = (@($snapshot.completed_steps) -contains 'EmailReport') -or ($snapshot.current_step -eq 'EmailReport')
            if (-not $preCompleteCheckpointTaken -and $reachedEmailReport) {
                try {
                    Checkpoint-Rehearsal -VmName $VmName -CheckpointName 'pre-complete'
                    $preCompleteCheckpointTaken = $true
                    Write-Host "[Rehearsal] Took the 'pre-complete' checkpoint (guest state reached EmailReport)." -ForegroundColor Green
                } catch {
                    Write-Warning "Could not take the 'pre-complete' checkpoint: $($_.Exception.Message)"
                }
            }

            $terminalState = Get-RehearsalTerminalState -OverallStatus $snapshot.overall_status
            if ($terminalState -ne 'Running') {
                return [ordered]@{ Result = $terminalState; Snapshot = $snapshot; TimedOut = $false }
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return [ordered]@{ Result = 'Timeout'; Snapshot = $lastSnapshot; TimedOut = $true }
}

function Copy-RehearsalArtifacts {
    <#
        .SYNOPSIS
            Harvests deployment logs, reports, state, the diskpart log, and a final screenshot
            from a rehearsal VM into Test\Rehearsal\Artifacts\<timestamp>\ on the host.

        .DESCRIPTION
            Resolves the guest's actual deployment root the same way Common.ps1's own
            Get-DeploymentRoot does conceptually: the media volume (by label) normally, or
            -HandoverLocalPath if this is a handover scenario and that path exists in-guest
            (mirroring local_deployment_handover.local_path, default C:\1S-WIN11) -- the
            deployment may have switched itself over to the local disk mid-run, at which point
            the media's own Deployment\ tree is stale. Harvests Deployment\Logs, \Reports,
            \State from whichever root that resolves to, OSIT-DiskPart.log from the media
            volume root specifically (that file only ever lives on the media, never the
            handover copy), and a final VM screenshot. Best-effort throughout: a harvest
            failure for one item is logged and does not stop the rest from being attempted, so
            a partial artifact set is still produced on a forced/unexpected failure.

        .PARAMETER IsHandoverScenario
            Whether the scenario under test has local_deployment_handover.enabled = true, so
            the deployment root may have switched to -HandoverLocalPath mid-run.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live (or, for a terminal/crashed VM, at least
            still-startable) guest reachable via PowerShell Direct to harvest files from, and a
            real WMI screenshot capture.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$ArtifactFolder,
        [string]$VolumeLabel = '1S-WIN11',
        [bool]$IsHandoverScenario,
        [string]$HandoverLocalPath = 'C:\1S-WIN11'
    )

    Assert-HyperVAvailable
    New-Item -ItemType Directory -Path $ArtifactFolder -Force -ErrorAction Stop | Out-Null

    try {
        $session = New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
        try {
            $remoteRoots = Invoke-Command -Session $session -ScriptBlock {
                param($Label, $IsHandover, $HandoverPath)
                $volume = Get-Volume -FileSystemLabel $Label -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1
                $mediaRoot = if ($volume) { "$($volume.DriveLetter):\" } else { $null }
                $deploymentRoot = if ($IsHandover -and (Test-Path -LiteralPath $HandoverPath)) { $HandoverPath } elseif ($mediaRoot) { $mediaRoot } else { $null }
                [ordered]@{ media_root = $mediaRoot; deployment_root = $deploymentRoot }
            } -ArgumentList $VolumeLabel, $IsHandoverScenario, $HandoverLocalPath

            if ($remoteRoots.deployment_root) {
                foreach ($subfolder in @('Deployment\Logs', 'Deployment\Reports', 'Deployment\State')) {
                    $remotePath = Join-Path $remoteRoots.deployment_root $subfolder
                    $localPath = Join-Path $ArtifactFolder ($subfolder -replace '\\', '_')
                    try {
                        Copy-Item -FromSession $session -Path $remotePath -Destination $localPath -Recurse -Force -ErrorAction Stop
                    } catch {
                        Write-Warning "Could not harvest '$remotePath' from the guest: $($_.Exception.Message)"
                    }
                }
            } else {
                Write-Warning 'Copy-RehearsalArtifacts: could not resolve a deployment root in-guest (media not found and no handover path present); Logs/Reports/State were not harvested.'
            }

            if ($remoteRoots.media_root) {
                $diskPartLogRemote = Join-Path $remoteRoots.media_root 'OSIT-DiskPart.log'
                try {
                    Copy-Item -FromSession $session -Path $diskPartLogRemote -Destination (Join-Path $ArtifactFolder 'OSIT-DiskPart.log') -Force -ErrorAction Stop
                } catch {
                    Write-Warning "Could not harvest OSIT-DiskPart.log from the guest: $($_.Exception.Message)"
                }
            }
        } finally {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Copy-RehearsalArtifacts: could not establish a PowerShell Direct session to harvest guest artifacts: $($_.Exception.Message)"
    }

    try {
        Save-RehearsalVmScreenshot -VmName $VmName -OutputPath (Join-Path $ArtifactFolder 'final-screenshot.png') | Out-Null
    } catch {
        Write-Warning "Could not capture the final screenshot: $($_.Exception.Message)"
    }

    return $ArtifactFolder
}

function Invoke-RehearsalMonitoring {
    <#
        .SYNOPSIS
            Top-level T12 orchestration: Phase 1 (Wait-RehearsalSetupExit) -> 'post-install'
            checkpoint -> Phase 2 (Watch-RehearsalDeployment) -> artifact harvest
            (Copy-RehearsalArtifacts), sharing one overall -TimeoutMinutes budget across both
            phases. This is the single call site Invoke-DeploymentRehearsal.ps1 uses for all of
            T12's work.

        .PARAMETER TimeoutMinutes
            Overall wall-clock budget (matches Invoke-DeploymentRehearsal.ps1's own parameter)
            covering both Setup and the guest deployment.

        .PARAMETER SetupTimeoutMinutes
            Phase 1's own sub-budget (default 40, per FABLE_TASKS.md T12) -- capped to whatever
            of the overall budget remains, so a short -TimeoutMinutes on a quick smoke test
            still fails fast rather than always waiting the full 40 minutes for Phase 1 alone.

        .OUTPUTS
            Ordered hashtable: Result ('Success'/'Failed'/'Timeout'), Phase ('Setup' or
            'Deployment' -- which phase produced the result), Snapshot (last guest status seen,
            Phase 'Deployment' only), ArtifactFolder (harvested artifact path).

        .NOTES
            UNVERIFIED ON REAL HYPER-V: this ties together every other function in this file,
            all of which require a real Windows Hyper-V host and a live VM to exercise.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$ArtifactRoot,
        [Parameter(Mandatory = $true)][int]$TimeoutMinutes,
        [int]$SetupTimeoutMinutes = 40,
        [string]$VolumeLabel = '1S-WIN11',
        [bool]$IsHandoverScenario,
        [string]$HandoverLocalPath = 'C:\1S-WIN11'
    )

    Assert-HyperVAvailable

    $overallDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $artifactFolder = Get-RehearsalArtifactFolder -ArtifactRoot $ArtifactRoot -Timestamp $timestamp

    $remainingMinutes = [Math]::Max(1, [int](($overallDeadline - (Get-Date)).TotalMinutes))
    $setupBudget = [Math]::Min($SetupTimeoutMinutes, $remainingMinutes)
    $setupResult = Wait-RehearsalSetupExit -VmName $VmName -TimeoutMinutes $setupBudget -ScreenshotPath (Join-Path $artifactFolder 'setup-timeout-screenshot.png')

    if (-not $setupResult.LeftSetup) {
        $harvested = Copy-RehearsalArtifacts -VmName $VmName -Credential $Credential -ArtifactFolder $artifactFolder -VolumeLabel $VolumeLabel -IsHandoverScenario $IsHandoverScenario -HandoverLocalPath $HandoverLocalPath
        return [ordered]@{ Result = 'Timeout'; Phase = 'Setup'; Snapshot = $null; ArtifactFolder = $harvested }
    }

    try {
        Checkpoint-Rehearsal -VmName $VmName -CheckpointName 'post-install'
    } catch {
        Write-Warning "Could not take the 'post-install' checkpoint: $($_.Exception.Message)"
    }

    $watchResult = Watch-RehearsalDeployment -VmName $VmName -Credential $Credential -Deadline $overallDeadline -VolumeLabel $VolumeLabel
    $harvestedFolder = Copy-RehearsalArtifacts -VmName $VmName -Credential $Credential -ArtifactFolder $artifactFolder -VolumeLabel $VolumeLabel -IsHandoverScenario $IsHandoverScenario -HandoverLocalPath $HandoverLocalPath

    return [ordered]@{
        Result         = $watchResult.Result
        Phase          = 'Deployment'
        Snapshot       = $watchResult.Snapshot
        ArtifactFolder = $harvestedFolder
    }
}
