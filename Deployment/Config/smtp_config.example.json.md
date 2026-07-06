# smtp_config.example.json

This file documents `smtp_config.json`, which controls SMTP email notification for deployment reports and logs. Copy or edit `smtp_config.example.json` into `smtp_config.json` on the USB.

`Get-SmtpConfig` merges this file (or, if it is missing, `smtp_config.example.json`) with built-in defaults, the same pattern `deployment_config.json` uses.

Email notification is best-effort. Any SMTP failure is logged and does not stop or fail the deployment task sequence.

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Master switch for email notification. |
| `smtp_server` | string | `"smtp.office365.com"` | SMTP server hostname. |
| `smtp_port` | number | `587` | SMTP port. `587` (STARTTLS) is the common choice. |
| `encryption_mode` | string | `"starttls"` | `starttls` or `none`. .NET's `SmtpClient` only implements explicit TLS (STARTTLS on a plaintext port such as 587); it does not support implicit TLS on port 465. Use an internal relay on `none`/port 25 if your provider requires implicit TLS. |
| `username` | string | `""` | SMTP auth username. Leave blank for an unauthenticated internal relay. |
| `password_env_var` | string | `"OSIT_SMTP_PASSWORD"` | Secret name used for the SMTP password, resolved the same way as `OSIT_LOCAL_ADMIN_PASSWORD` and `OSIT_WIFI_PASSWORD`: environment variable first, then USB-root `.env`. Only required when `username` is set. |
| `from_address` | string | `"deployments@example.com"` | Envelope/header From address. |
| `from_display_name` | string | `"1S Windows 11 Deployment"` | Friendly From display name. |
| `to_addresses` | array of strings | `[ "dispatch@example.com" ]` | Recipient list. Required (non-empty) for email to send. |
| `cc_addresses` | array of strings | `[]` | Optional CC recipient list. |
| `subject_prefix` | string | `"[Win11 Deployment]"` | Prefixed onto the subject line, followed by status, computer name, and serial number. |
| `send_on_success` | boolean | `true` | Send an email when the deployment completes successfully. |
| `send_on_failure` | boolean | `true` | Send an email when the deployment stops on a failure. |
| `attach_reports` | boolean | `true` | Attach the run's JSON report, Markdown summary, and asset inventory. |
| `attach_logs` | boolean | `true` | Attach a zip of the run's log folder (transcript, structured JSONL event log, command logs). |
| `max_attachment_mb` | number | `20` | Any single attachment larger than this is skipped (with a warning logged) instead of blocking the email. |
| `timeout_seconds` | number | `30` | SMTP client timeout. |

## Password Setup

The SMTP password is not stored in this JSON file. When `smtp_config.json`'s `username` is non-blank, `Initialize-UsbDeployment.ps1` reads `OSIT_SMTP_PASSWORD` (or the name configured in `password_env_var`) from an environment variable or `.env` in the toolkit folder, then writes it to the USB-root `.env` so `Send-DeploymentEmail.ps1` can send from the deployed device, the same way `OSIT_WIFI_PASSWORD` is handled.

## When It Runs

Email is sent from the `EmailReport` step, which runs after `FinalReport` and before `Complete`. It is also sent from the top-level failure handler in `Start-Deployment.ps1` if the task sequence stops on an error, subject to `send_on_failure`.

If `local_deployment_handover` has moved the deployment onto the local disk by the time `EmailReport` runs, the email is sent using the local copy's reports and logs.
