[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
$paths = Get-DeploymentPaths -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }
$config = Get-DeploymentConfig -UsbRoot $UsbRoot
$state = Read-DeploymentState -StatePath $StatePath

if (-not [bool]$config.configure_power_settings) {
    Write-Log -Level Info -Message 'Power settings configuration is disabled by config.'
    return
}

$batteryMinutes = [int]$config.power_timeout_battery_minutes
$acMinutes = [int]$config.power_timeout_ac_minutes
if ($batteryMinutes -lt 0) { throw 'power_timeout_battery_minutes must be 0 or greater. Use 0 for never.' }
if ($acMinutes -lt 0) { throw 'power_timeout_ac_minutes must be 0 or greater. Use 0 for never.' }

$commands = @()
if ([bool]$config.power_manage_display_timeout) {
    $commands += ,@('monitor-timeout-dc', $batteryMinutes)
    $commands += ,@('monitor-timeout-ac', $acMinutes)
}
if ([bool]$config.power_manage_sleep_timeout) {
    $commands += ,@('standby-timeout-dc', $batteryMinutes)
    $commands += ,@('standby-timeout-ac', $acMinutes)
}
if ([bool]$config.power_manage_hibernate_timeout) {
    $commands += ,@('hibernate-timeout-dc', $batteryMinutes)
    $commands += ,@('hibernate-timeout-ac', $acMinutes)
}

$results = @()
foreach ($command in $commands) {
    $setting = [string]$command[0]
    $minutes = [string]$command[1]

    if (Test-DeploymentDryRun) {
        # Explicit dry-run branch rather than relying only on Invoke-ExternalCommand's generic
        # refusal (Common.ps1, T05): this labels the audit trail entry with the real step name
        # ('PowerSettings' instead of the generic 'ExternalCommand' default) so it aggregates
        # correctly into state.dryrun_actions for the T08 summary report, and reuses
        # ConvertTo-ProcessArgumentString so the logged command line is formatted exactly the
        # way Invoke-ExternalCommand itself would format and log a real invocation.
        $argumentString = ConvertTo-ProcessArgumentString -Arguments @('/change', $setting, $minutes)
        Write-DryRunAction -State $state -Step 'PowerSettings' -Action "would run: powercfg.exe $argumentString" -Data ([ordered]@{
                file_path = 'powercfg.exe'
                arguments = @('/change', $setting, $minutes)
            })
        $results += ,([ordered]@{
                setting   = $setting
                minutes   = [int]$minutes
                exit_code = 0
            })
        continue
    }

    $result = Invoke-ExternalCommand -FilePath powercfg.exe -Arguments @('/change', $setting, $minutes) -LogName ("powercfg-{0}.log" -f $setting)
    $results += ,([ordered]@{
            setting = $setting
            minutes = [int]$minutes
            exit_code = $result.exit_code
        })
}

# /getactivescheme only queries the currently active power plan; it changes nothing, so
# -ReadOnly keeps it running for real even in dry-run (Common.ps1, T05) and the summary below
# reports the machine's genuine active scheme instead of a synthesized blank value.
$scheme = Invoke-ExternalCommand -FilePath powercfg.exe -Arguments @('/getactivescheme') -LogName 'powercfg-active-scheme.log' -ReadOnly
$summary = [ordered]@{
    battery_minutes = $batteryMinutes
    ac_minutes = $acMinutes
    display_timeout_managed = [bool]$config.power_manage_display_timeout
    sleep_timeout_managed = [bool]$config.power_manage_sleep_timeout
    hibernate_timeout_managed = [bool]$config.power_manage_hibernate_timeout
    active_scheme = ($scheme.stdout -replace '\s+', ' ').Trim()
    results = $results
    timestamp = (Get-Date).ToString('o')
}

if ($state) {
    $state.power_settings = $summary
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'Power settings configured' -Data $summary
Write-Log -Level Success -Message "Power settings configured: battery $batteryMinutes minute(s), AC $(if ($acMinutes -eq 0) { 'never' } else { "$acMinutes minute(s)" })."
