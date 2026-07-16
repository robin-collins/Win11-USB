[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath,
    [switch]$Failure,
    [string]$FailureMessage
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-DeploymentRoot }
$paths = Get-DeploymentPaths -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }

# Emailing the run's logs/reports is a convenience for faster USB turnaround, not a
# deployment requirement, so anything that goes wrong here is logged and swallowed rather
# than allowed to fail (or re-fail) the deployment task sequence.
try {
    $smtp = Get-SmtpConfig -UsbRoot $UsbRoot
    if (-not [bool]$smtp.enabled) {
        Write-Log -Level Info -Message 'SMTP email notification is disabled by config.'
        return
    }

    $state = Read-DeploymentState -StatePath $StatePath
    if (-not $state) { throw 'Deployment state is unavailable; cannot compose the notification email.' }

    $isFailure = [bool]$Failure -or [bool]$state.last_error
    if ($isFailure -and -not [bool]$smtp.send_on_failure) {
        Write-Log -Level Info -Message 'SMTP email notification is disabled for failed runs by config.'
        return
    }
    if (-not $isFailure -and -not [bool]$smtp.send_on_success) {
        Write-Log -Level Info -Message 'SMTP email notification is disabled for successful runs by config.'
        return
    }

    $toAddresses = @($smtp.to_addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($toAddresses.Count -eq 0) {
        Write-Log -Level Warn -Message 'smtp_config.json is enabled but to_addresses is empty; skipping email notification.'
        return
    }
    $smtpServer = [string]$smtp.smtp_server
    if ([string]::IsNullOrWhiteSpace($smtpServer)) {
        Write-Log -Level Warn -Message 'smtp_config.json is enabled but smtp_server is empty; skipping email notification.'
        return
    }

    $username = [string]$smtp.username
    $password = $null
    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $envVarName = [string]$smtp.password_env_var
        if ([string]::IsNullOrWhiteSpace($envVarName)) { $envVarName = 'OSIT_SMTP_PASSWORD' }
        $password = Get-OsitSmtpPassword -SearchRoots @($UsbRoot) -EnvVarName $envVarName
        if ([string]::IsNullOrWhiteSpace($password)) {
            Write-Log -Level Warn -Message "$envVarName was not found in environment variables or USB-root .env; skipping email notification. Run Initialize-UsbDeployment.ps1 to prepare the USB."
            return
        }
    }

    $runId = [string]$state.deployment_run_id
    $reportRoot = Get-DeploymentReportRoot -UsbRoot $UsbRoot
    $jsonReport = Join-Path $reportRoot "deployment-report-$runId.json"
    $mdReport = Join-Path $reportRoot "deployment-summary-$runId.md"
    $inventoryPath = Join-Path $reportRoot "asset-inventory-$runId.json"

    $identity = Get-DeviceIdentity
    $safeDevice = Get-DeviceFolderName -Identity $identity
    $logDir = Join-Path (Join-Path $paths.Logs $safeDevice) $runId

    $attachments = New-Object System.Collections.Generic.List[string]
    $tempFiles = New-Object System.Collections.Generic.List[string]
    $maxBytes = [int64]([double]$smtp.max_attachment_mb * 1MB)

    function Add-EmailAttachment {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
        $size = (Get-Item -LiteralPath $Path).Length
        if ($size -gt $maxBytes) {
            Write-Log -Level Warn -Message "Skipping email attachment $Path ($([math]::Round($size / 1MB, 1)) MB) because it exceeds max_attachment_mb ($($smtp.max_attachment_mb))."
            return
        }
        $attachments.Add($Path)
    }

    if ([bool]$smtp.attach_reports) {
        Add-EmailAttachment -Path $mdReport
        Add-EmailAttachment -Path $jsonReport
        Add-EmailAttachment -Path $inventoryPath
    }

    if ([bool]$smtp.attach_logs -and (Test-Path -LiteralPath $logDir -PathType Container)) {
        $zipPath = Join-Path $env:TEMP ("deployment-logs-{0}.zip" -f $runId)
        try {
            if (Test-Path -LiteralPath $zipPath -PathType Leaf) { Remove-Item -LiteralPath $zipPath -Force }
            Compress-Archive -Path (Join-Path $logDir '*') -DestinationPath $zipPath -Force -ErrorAction Stop
            $tempFiles.Add($zipPath)
            Add-EmailAttachment -Path $zipPath
        } catch {
            Write-Log -Level Warn -Message "Could not compress deployment logs for email attachment: $($_.Exception.Message)"
        }
    }

    $computer = $identity.computer_name
    $status = if ($isFailure) { 'FAILED' } else { 'Ready for customer onboarding' }
    $subject = "$([string]$smtp.subject_prefix) $status - $computer ($($identity.serial_number))"

    $body = if (Test-Path -LiteralPath $mdReport -PathType Leaf) {
        Get-Content -LiteralPath $mdReport -Raw
    } else {
        $errorMessage = if ($FailureMessage) { $FailureMessage } elseif ($state.last_error) { $state.last_error.message } else { 'None' }
        "Windows 11 deployment status: $status`nComputer: $computer`nRun ID: $runId`nLast error: $errorMessage"
    }

    if (Test-DeploymentDryRun) {
        # Full SMTP config validation and attachment resolution above already ran for real
        # (FABLE_TASKS.md T07c) -- including the real logs zip, so max_attachment_mb checks are
        # accurate. No SmtpClient/MailMessage is ever constructed here, so an unreachable SMTP
        # host cannot make this throw: no connection is attempted at all in dry-run.
        Write-DryRunAction -State $state -Step 'EmailReport' -Action "would send email via $smtpServer`:$($smtp.smtp_port) to $($toAddresses -join ', ') with $(@($attachments).Count) attachment(s)" -Data ([ordered]@{
                smtp_server  = $smtpServer
                smtp_port    = [int]$smtp.smtp_port
                to_addresses = $toAddresses
                cc_addresses = @($smtp.cc_addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                subject      = $subject
                attachments  = @($attachments)
            })
        Write-Log -Level Success -Message "Dry run: deployment notification email would be sent to $($toAddresses -join ', ') via $smtpServer`:$($smtp.smtp_port) (not sent)."
        foreach ($tempFile in $tempFiles) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        return
    }

    $mail = New-Object System.Net.Mail.MailMessage
    try {
        $fromAddress = [string]$smtp.from_address
        if ([string]::IsNullOrWhiteSpace($fromAddress)) { $fromAddress = "deployment@$env:COMPUTERNAME.local" }
        $mail.From = New-Object System.Net.Mail.MailAddress($fromAddress, [string]$smtp.from_display_name)
        foreach ($to in $toAddresses) { $mail.To.Add($to) }
        foreach ($cc in @($smtp.cc_addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) { $mail.CC.Add($cc) }
        $mail.Subject = $subject
        $mail.Body = $body
        $mail.IsBodyHtml = $false

        foreach ($attachmentPath in $attachments) {
            $mail.Attachments.Add((New-Object System.Net.Mail.Attachment($attachmentPath)))
        }

        $port = [int]$smtp.smtp_port
        Write-Log -Level Info -Message "Sending deployment email to $($toAddresses -join ', ') via $smtpServer`:$port with $(@($attachments).Count) attachment(s) (encryption=$([string]$smtp.encryption_mode), timeout $([int]$smtp.timeout_seconds)s)."
        $client = New-Object System.Net.Mail.SmtpClient($smtpServer, $port)
        try {
            $client.Timeout = [int]$smtp.timeout_seconds * 1000
            # .NET Framework's SmtpClient only implements explicit TLS (STARTTLS on a plaintext
            # port such as 587), not implicit TLS on port 465; encryption_mode therefore only
            # supports 'starttls' or 'none', which is documented in smtp_config.example.json.md.
            $client.EnableSsl = (([string]$smtp.encryption_mode).ToLowerInvariant() -eq 'starttls')
            if (-not [string]::IsNullOrWhiteSpace($username)) {
                $client.Credentials = New-Object System.Net.NetworkCredential($username, $password)
            }
            $client.Send($mail)
            Write-Log -Level Success -Message "Deployment notification email sent to $($toAddresses -join ', ') via $smtpServer`:$port."
            Write-StructuredLog -Level Info -Message 'Deployment email sent' -Data @{ to = $toAddresses; subject = $subject; attachments = @($attachments) }
        } finally {
            $client.Dispose()
        }
    } finally {
        foreach ($attachment in @($mail.Attachments)) { $attachment.Dispose() }
        $mail.Dispose()
        foreach ($tempFile in $tempFiles) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
    }
} catch {
    Write-Log -Level Warn -Message "Deployment email notification failed (non-fatal): $($_.Exception.Message). The deployment itself is unaffected; rerun Deployment\Scripts\Send-DeploymentEmail.ps1 manually to retry once SMTP is reachable."
}
