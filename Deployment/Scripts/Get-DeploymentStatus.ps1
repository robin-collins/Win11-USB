[CmdletBinding()]
param(
    [string]$UsbRoot,
    [switch]$Json,
    [int]$RefreshSeconds
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

function Get-DeploymentStatusSnapshot {
    param([string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $state = Read-DeploymentState -StatePath $paths.StateFile
    $steps = Get-DeploymentSteps
    $processes = @(Get-DeploymentProcessInfo)

    if (-not $state) {
        return [ordered]@{
            usb_root           = $UsbRoot
            overall_status     = 'NotStarted'
            message            = 'No deployment state file found. Start-Deployment.ps1 has not been run on this device yet.'
            deployment_process = $processes
        }
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
    } catch {}
    if (-not $resumeTask) { $resumeTask = [ordered]@{ registered = $false } }

    $pendingReboot = $false
    try { $pendingReboot = Test-PendingReboot } catch {}

    $logHeartbeat = $null
    try {
        $identity = Get-DeviceIdentity
        $safeDevice = Get-DeviceFolderName -Identity $identity
        $logDir = Join-Path (Join-Path $paths.Logs $safeDevice) $state.deployment_run_id
        $eventsLog = Join-Path $logDir 'events.jsonl'
        if (Test-Path -LiteralPath $eventsLog -PathType Leaf) {
            $lastWrite = (Get-Item -LiteralPath $eventsLog).LastWriteTime
            $logHeartbeat = [ordered]@{
                path              = $eventsLog
                last_activity     = $lastWrite
                seconds_since_activity = [int]((Get-Date) - $lastWrite).TotalSeconds
            }
        }
    } catch {}

    $stateAgeSeconds = $null
    try { $stateAgeSeconds = [int]((Get-Date) - [datetime]$state.timestamp).TotalSeconds } catch {}

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

    return [ordered]@{
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
    }
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
    Write-Host ''
}

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }

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
