[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'This is a technician-facing status CLI; Write-Host provides the colored, human-readable console report (Write-DeploymentStatusReport) that this script exists to show. The machine-readable -Json path bypasses this entirely.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [switch]$Json,
    [int]$RefreshSeconds
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

function Format-DeploymentAgeText {
    # Pure helper: renders an age in seconds as a short human-readable string for the
    # verdict line ("45s", "12m 3s", "2h 5m"). $null (age unknown) renders as 'unknown'.
    [CmdletBinding()]
    [OutputType([string])]
    param([object]$Seconds)

    if ($null -eq $Seconds) { return 'unknown' }
    $totalSeconds = [int]$Seconds
    if ($totalSeconds -lt 0) { $totalSeconds = 0 }
    if ($totalSeconds -lt 60) { return ('{0}s' -f $totalSeconds) }
    if ($totalSeconds -lt 3600) { return ('{0}m {1}s' -f [math]::Floor($totalSeconds / 60), ($totalSeconds % 60)) }
    return ('{0}h {1}m' -f [math]::Floor($totalSeconds / 3600), [math]::Floor(($totalSeconds % 3600) / 60))
}

function Get-DeploymentFailureHistory {
    # Pure helper: extracts every 'step_failed' event from state.history (entries are
    # @{timestamp; event; data} where data is the last_error shape @{timestamp; step; message})
    # as a flat @{timestamp; step; message} list, oldest first. Every key read is guarded:
    # state files from older toolkit versions may lack 'history' entirely, and individual
    # entries are treated as best-effort.
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([System.Collections.IDictionary]$State)

    # Output is enumerated onto the pipeline (no unary comma); callers wrap with @() so
    # zero/one/many failures all land as a flat array of @{timestamp; step; message}.
    $failures = @()
    if ($null -eq $State) { return $failures }
    if (-not ($State.Contains('history') -and $null -ne $State['history'])) { return $failures }

    foreach ($entry in @($State['history'])) {
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $eventName = ''
        if ($entry.Contains('event')) { $eventName = [string]$entry['event'] }
        if ($eventName -ne 'step_failed') { continue }

        $timestamp = $null
        if ($entry.Contains('timestamp')) { $timestamp = $entry['timestamp'] }
        $step = ''
        $message = ''
        if ($entry.Contains('data') -and $entry['data'] -is [System.Collections.IDictionary]) {
            $data = $entry['data']
            if ($data.Contains('step')) { $step = [string]$data['step'] }
            if ($data.Contains('message')) { $message = [string]$data['message'] }
        }
        $failures += , ([ordered]@{ timestamp = $timestamp; step = $step; message = $message })
    }
    return $failures
}

function Get-DeploymentVerdict {
    # Pure helper: derives the single technician-facing verdict line from an
    # already-computed snapshot. It never changes overall_status (whose five values are
    # pinned by Test\Rehearsal\RehearsalMonitoring.ps1's terminal-state mapping); it only
    # translates it, plus additive context, into one actionable sentence. Every snapshot
    # read is guarded so partial snapshots (e.g. NotStarted) and old shapes are safe.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Snapshot)

    $status = ''
    if ($Snapshot.Contains('overall_status')) { $status = [string]$Snapshot['overall_status'] }

    $currentStep = ''
    if ($Snapshot.Contains('current_step')) { $currentStep = [string]$Snapshot['current_step'] }
    if ([string]::IsNullOrWhiteSpace($currentStep) -and $Snapshot.Contains('last_successful_step')) {
        # After a step completes, current_step is cleared; the last successful step is then
        # the most useful "where we got to" anchor for the technician.
        $currentStep = [string]$Snapshot['last_successful_step']
    }
    if ([string]::IsNullOrWhiteSpace($currentStep)) { $currentStep = '(unknown)' }

    $completedCount = 0
    if ($Snapshot.Contains('completed_step_count') -and $null -ne $Snapshot['completed_step_count']) {
        $completedCount = [int]$Snapshot['completed_step_count']
    }
    $totalCount = 0
    if ($Snapshot.Contains('total_step_count') -and $null -ne $Snapshot['total_step_count']) {
        $totalCount = [int]$Snapshot['total_step_count']
    }

    # Prefer the live log heartbeat for "last activity"; fall back to the state file's age.
    $activityAgeSeconds = $null
    if ($Snapshot.Contains('log_heartbeat') -and $Snapshot['log_heartbeat'] -is [System.Collections.IDictionary]) {
        $heartbeat = $Snapshot['log_heartbeat']
        if ($heartbeat.Contains('seconds_since_activity')) { $activityAgeSeconds = $heartbeat['seconds_since_activity'] }
    }
    if ($null -eq $activityAgeSeconds -and $Snapshot.Contains('state_age_seconds')) {
        $activityAgeSeconds = $Snapshot['state_age_seconds']
    }
    $ageText = Format-DeploymentAgeText -Seconds $activityAgeSeconds

    $retryArmed = $false
    $nextAttempt = $null
    if ($Snapshot.Contains('retry') -and $Snapshot['retry'] -is [System.Collections.IDictionary]) {
        $retry = $Snapshot['retry']
        if ($retry.Contains('armed')) { $retryArmed = [bool]$retry['armed'] }
        if ($retry.Contains('next_attempt')) { $nextAttempt = $retry['next_attempt'] }
    }
    $nextAttemptText = if ($null -ne $nextAttempt -and -not [string]::IsNullOrWhiteSpace([string]$nextAttempt)) {
        " (next attempt $nextAttempt)"
    } else { '' }

    $failStep = $currentStep
    $failMessage = ''
    if ($Snapshot.Contains('last_error') -and $Snapshot['last_error'] -is [System.Collections.IDictionary]) {
        $lastError = $Snapshot['last_error']
        if ($lastError.Contains('step') -and -not [string]::IsNullOrWhiteSpace([string]$lastError['step'])) {
            $failStep = [string]$lastError['step']
        }
        if ($lastError.Contains('message')) { $failMessage = [string]$lastError['message'] }
    }

    switch ($status) {
        'Completed' {
            $finishedAt = $null
            if ($Snapshot.Contains('state_last_updated')) { $finishedAt = $Snapshot['state_last_updated'] }
            $stepsText = if ($totalCount -gt 0) { $totalCount } else { $completedCount }
            $finishedText = if ($null -ne $finishedAt -and -not [string]::IsNullOrWhiteSpace([string]$finishedAt)) {
                " at $finishedAt"
            } else { '' }
            return "COMPLETE - all $stepsText steps finished$finishedText."
        }
        'Running' {
            return "IN PROGRESS - step '$currentStep' ($completedCount of $totalCount complete), last activity $ageText ago."
        }
        'Failed' {
            if ($retryArmed) {
                return "FAILED at step '$failStep': $failMessage - will retry automatically$nextAttemptText; fix the underlying problem and it will resume, or run Resume-Deployment.ps1 / the desktop 'Resume 1S-WIN11 Deployment' shortcut to retry now."
            }
            return "FAILED at step '$failStep': $failMessage - run Resume-Deployment.ps1 to retry from this step."
        }
        'WaitingForReboot' {
            if ($retryArmed) {
                return "WAITING FOR REBOOT - deployment will resume at step '$currentStep' after restart/logon$nextAttemptText; restart the device to continue."
            }
            return "WAITING FOR REBOOT - a reboot is pending but no resume task is registered; restart the device, then run Resume-Deployment.ps1 to continue from step '$currentStep'."
        }
        'Stalled' {
            return "STALLED - no active deployment process, no pending reboot ($completedCount of $totalCount complete, last activity $ageText ago); check the newest log, then run Resume-Deployment.ps1 to continue from step '$currentStep'."
        }
        'NotStarted' {
            return 'NOT STARTED - no deployment state found on this device; run Start-Deployment.ps1 to begin.'
        }
        default {
            if ($Snapshot.Contains('message')) { return [string]$Snapshot['message'] }
            return $status
        }
    }
}

function Get-DeploymentStatusSnapshot {
    param([string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $state = Read-DeploymentState -StatePath $paths.StateFile
    $steps = Get-DeploymentSteps
    $processes = @(Get-DeploymentProcessInfo)

    if (-not $state) {
        $notStarted = [ordered]@{
            usb_root           = $UsbRoot
            overall_status     = 'NotStarted'
            message            = 'No deployment state file found. Start-Deployment.ps1 has not been run on this device yet.'
            deployment_process = $processes
            retry              = [ordered]@{ armed = $false; next_attempt = $null }
            failure_history    = @()
            log_files          = @()
        }
        $notStarted.verdict = Get-DeploymentVerdict -Snapshot $notStarted
        return $notStarted
    }

    $completedSteps = @($state.completed_steps)
    $totalSteps = @($steps).Count
    $isComplete = $completedSteps -contains 'Complete'

    $resumeTask = $null
    try {
        $task = Get-ScheduledTask -TaskName $script:DeploymentTaskName -ErrorAction SilentlyContinue
        if ($task) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $script:DeploymentTaskName -ErrorAction SilentlyContinue
            $resumeTask = [ordered]@{
                registered      = $true
                state           = [string]$task.State
                last_run_time   = if ($taskInfo) { $taskInfo.LastRunTime } else { $null }
                last_task_result = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
                next_run_time   = if ($taskInfo) { $taskInfo.NextRunTime } else { $null }
            }
        }
    } catch {
        Write-Verbose "Could not query the resume scheduled task (non-fatal): $($_.Exception.Message)"
    }
    if (-not $resumeTask) { $resumeTask = [ordered]@{ registered = $false } }

    $pendingReboot = $false
    try {
        $pendingReboot = Test-PendingReboot
    } catch {
        Write-Verbose "Could not determine pending-reboot status (non-fatal): $($_.Exception.Message)"
    }

    $logHeartbeat = $null
    $logFiles = @()
    try {
        $identity = Get-DeviceIdentity
        $safeDevice = Get-DeviceFolderName -Identity $identity
        $runId = if ($state.ContainsKey('deployment_run_id')) { [string]$state.deployment_run_id } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($runId)) {
            $logDir = Join-Path (Join-Path $paths.Logs $safeDevice) $runId
            if (Test-Path -LiteralPath $logDir -PathType Container) {
                # Point the technician at what to open: the newest few files in this run's
                # log folder (transcript, events.jsonl, step logs - whatever is freshest).
                $logFiles = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 3 |
                        ForEach-Object { $_.FullName })
            }
            $eventsLog = Join-Path $logDir 'events.jsonl'
            if (Test-Path -LiteralPath $eventsLog -PathType Leaf) {
                $lastWrite = (Get-Item -LiteralPath $eventsLog).LastWriteTime
                $logHeartbeat = [ordered]@{
                    path              = $eventsLog
                    last_activity     = $lastWrite
                    seconds_since_activity = [int]((Get-Date) - $lastWrite).TotalSeconds
                }
            }
        }
    } catch {
        Write-Verbose "Could not read the log heartbeat (non-fatal): $($_.Exception.Message)"
    }

    $stateAgeSeconds = $null
    try {
        $stateAgeSeconds = [int]((Get-Date) - [datetime]$state.timestamp).TotalSeconds
    } catch {
        Write-Verbose "Could not compute state age (non-fatal): $($_.Exception.Message)"
    }

    $overallStatus = 'Stalled'
    $message = 'Deployment state exists but no active process, pending reboot, or error explains the current state. This may indicate a crashed or killed process.'

    # A recorded last_error is a specific, deliberate signal from the deployment itself and
    # takes priority over the live Windows pending-reboot check, which reflects any pending
    # reboot on the machine (for example a manual Windows Update run before this deployment
    # started) and would otherwise mask a genuine failure that has nothing to do with it.
    # state.reboot_pending (the deployment's own recorded intent) is authoritative for
    # WaitingForReboot; the live Windows flag is reported alongside only as extra context.
    if ($isComplete) {
        $overallStatus = 'Completed'
        $message = 'Deployment task sequence completed. Device is ready for customer onboarding.'
    } elseif ($processes.Count -gt 0) {
        $overallStatus = 'Running'
        $message = "Deployment is actively running (PID $($processes[0].ProcessId)), currently on step '$($state.current_step)'."
    } elseif ($state.last_error) {
        $overallStatus = 'Failed'
        $message = "Last error at step '$($state.last_error.step)': $($state.last_error.message)"
    } elseif ([bool]$state.reboot_pending) {
        $overallStatus = 'WaitingForReboot'
        $message = if ($resumeTask.registered) {
            "Waiting for reboot/logon to resume from step '$($state.current_step)'. Resume task is registered (state: $($resumeTask.state))."
        } else {
            "A reboot is pending but the resume scheduled task is not registered. Resume may require a manual run of Resume-Deployment.ps1 or Start-Deployment.ps1."
        }
    }

    # Additive enrichment (never a new overall_status value): retry summarises the resume
    # scheduled task in "will it retry by itself?" terms, failure_history surfaces every
    # step_failed event from state.history, and log_files tells the technician what to open.
    $retry = [ordered]@{
        armed        = [bool]$resumeTask.registered
        next_attempt = $null
    }
    if ($resumeTask.Contains('next_run_time')) { $retry.next_attempt = $resumeTask.next_run_time }

    $failureHistory = @(Get-DeploymentFailureHistory -State $state)

    $snapshot = [ordered]@{
        usb_root             = $UsbRoot
        overall_status       = $overallStatus
        message               = $message
        run_id                = $state.deployment_run_id
        computer_name         = $state.computer_name
        current_step          = $state.current_step
        last_successful_step  = $state.last_successful_step
        completed_step_count  = @($completedSteps).Count
        total_step_count      = $totalSteps
        completed_steps       = $completedSteps
        last_error            = $state.last_error
        state_last_updated    = $state.timestamp
        state_age_seconds     = $stateAgeSeconds
        reboot_pending_in_state = [bool]$state.reboot_pending
        windows_pending_reboot  = $pendingReboot
        deployment_process    = $processes
        resume_task           = $resumeTask
        log_heartbeat         = $logHeartbeat
        retry                 = $retry
        failure_history       = $failureHistory
        log_files             = $logFiles
    }
    $snapshot.verdict = Get-DeploymentVerdict -Snapshot $snapshot
    return $snapshot
}

function Write-DeploymentStatusReport {
    param([hashtable]$Snapshot)

    $statusColor = switch ($Snapshot.overall_status) {
        'Completed' { 'Green' }
        'Running' { 'Cyan' }
        'WaitingForReboot' { 'Yellow' }
        'Failed' { 'Red' }
        'Stalled' { 'Red' }
        default { 'White' }
    }

    Write-Host ''
    if ($Snapshot.ContainsKey('verdict') -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot.verdict)) {
        Write-Host $Snapshot.verdict -ForegroundColor $statusColor
        Write-Host ''
    }
    Write-Host "Deployment status: $($Snapshot.overall_status)" -ForegroundColor $statusColor
    Write-Host $Snapshot.message
    Write-Host ''

    if ($Snapshot.overall_status -eq 'NotStarted') { return }

    Write-Host "USB root:              $($Snapshot.usb_root)"
    Write-Host "Run ID:                $($Snapshot.run_id)"
    Write-Host "Computer name:         $($Snapshot.computer_name)"
    Write-Host "Current step:          $($Snapshot.current_step)"
    Write-Host "Last successful step:  $($Snapshot.last_successful_step)"
    Write-Host "Progress:              $($Snapshot.completed_step_count) of $($Snapshot.total_step_count) steps completed"
    Write-Host "State last updated:    $($Snapshot.state_last_updated) ($($Snapshot.state_age_seconds)s ago)"

    if ($Snapshot.log_heartbeat) {
        Write-Host "Last log activity:     $($Snapshot.log_heartbeat.last_activity) ($($Snapshot.log_heartbeat.seconds_since_activity)s ago)"
    }

    if ($Snapshot.deployment_process.Count -gt 0) {
        foreach ($proc in $Snapshot.deployment_process) {
            Write-Host "Active process:        PID $($proc.ProcessId), started $($proc.CreationDate)"
        }
    } else {
        Write-Host 'Active process:        none detected'
    }

    Write-Host "Resume task:           registered=$($Snapshot.resume_task.registered)$(if ($Snapshot.resume_task.registered) { ", state=$($Snapshot.resume_task.state), next run=$($Snapshot.resume_task.next_run_time)" })"
    Write-Host "Reboot pending:        state=$($Snapshot.reboot_pending_in_state), windows=$($Snapshot.windows_pending_reboot)"

    if ($Snapshot.last_error) {
        Write-Host ''
        Write-Host "Last error (step '$($Snapshot.last_error.step)'):" -ForegroundColor Red
        Write-Host "  $($Snapshot.last_error.message)" -ForegroundColor Red
    }

    if ($Snapshot.ContainsKey('failure_history') -and @($Snapshot.failure_history).Count -gt 0) {
        Write-Host ''
        Write-Host 'Recent failures:' -ForegroundColor Yellow
        foreach ($failure in @($Snapshot.failure_history | Select-Object -Last 3)) {
            Write-Host ("  [{0}] step '{1}': {2}" -f $failure.timestamp, $failure.step, $failure.message)
        }
    }

    if ($Snapshot.ContainsKey('log_files') -and @($Snapshot.log_files).Count -gt 0) {
        Write-Host ''
        Write-Host 'Logs:'
        foreach ($logFile in @($Snapshot.log_files)) {
            Write-Host "  $logFile"
        }
    }
    Write-Host ''
}

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-DeploymentRoot }

if ($RefreshSeconds -gt 0) {
    while ($true) {
        Clear-Host
        Write-Host "Refreshing every $RefreshSeconds second(s). Press Ctrl+C to stop." -ForegroundColor DarkGray
        $snapshot = Get-DeploymentStatusSnapshot -UsbRoot $UsbRoot
        if ($Json) { $snapshot | ConvertTo-Json -Depth 10 } else { Write-DeploymentStatusReport -Snapshot $snapshot }
        Start-Sleep -Seconds $RefreshSeconds
    }
} else {
    $snapshot = Get-DeploymentStatusSnapshot -UsbRoot $UsbRoot
    if ($Json) { $snapshot | ConvertTo-Json -Depth 10 } else { Write-DeploymentStatusReport -Snapshot $snapshot }
}
