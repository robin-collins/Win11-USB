[Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'StatePath', Justification = 'Accepted for calling-convention parity: Start-Deployment.ps1 invokes every step script uniformly with -UsbRoot/-StatePath. This step performs read-only checks and does not itself need to write state.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
$paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
$config = Get-DeploymentConfig -UsbRoot $UsbRoot

function Get-EffectivePreflightStatus {
    <#
        Pure decision function (FABLE_TASKS.md T07a): a dry run keeps every preflight check
        running for real -- that is the whole value of preflight in dry-run mode -- but a hard
        Fail on a check that is just a bench-PC environment reality (not elevated at the
        keyboard, no internet on this particular bench, no AC power / no battery info on a
        test rig) must not stop the dry run the way a genuine configuration defect should
        (missing/invalid deployment_config.json, Windows Home edition when Home is disallowed,
        a missing required script/folder, etc.). Only Fail results for the three named checks
        are downgraded, and only while Test-DeploymentDryRun is true; every other Fail (and
        every Warn/Pass) passes through unchanged, including in production.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [bool]$DryRun
    )

    $environmentDependentCheckNames = @('Administrator', 'Internet', 'AC Power')
    if ($DryRun -and $Status -eq 'Fail' -and ($environmentDependentCheckNames -contains $Name)) {
        return 'Warn'
    }
    return $Status
}

function Add-PreflightResult {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [string]$Name,
        [ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [string]$Message,
        [object]$Data
    )

    $effectiveStatus = Get-EffectivePreflightStatus -Name $Name -Status $Status -DryRun (Test-DeploymentDryRun)
    if ($effectiveStatus -ne $Status) {
        $Message = "$Message (dry run: downgraded from Fail to Warn -- this is a bench-PC environment condition, not a configuration defect)"
        Write-DryRunAction -State $null -Step 'Preflight' -Action "downgraded '$Name' from Fail to Warn for dry run" -Data ([ordered]@{ name = $Name; original_status = $Status })
    }

    $Results.Add([ordered]@{
            name    = $Name
            status  = $effectiveStatus
            message = $Message
            data    = $Data
        }) | Out-Null
    if ($effectiveStatus -eq 'Pass') {
        Write-Log -Level Success -Message "${Name}: $Message"
    } elseif ($effectiveStatus -eq 'Warn') {
        Write-Log -Level Warn -Message "${Name}: $Message"
    } else {
        Write-Log -Level Error -Message "${Name}: $Message"
    }
}

$results = New-Object 'System.Collections.Generic.List[object]'

Add-PreflightResult -Results $results -Name 'Administrator' -Status ($(if (Test-IsAdministrator) { 'Pass' } else { 'Fail' })) -Message 'PowerShell is running elevated.' -Data $null

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$isWin11 = ([int]$os.BuildNumber -ge 22000)
Add-PreflightResult -Results $results -Name 'Windows 11' -Status ($(if ($isWin11) { 'Pass' } else { 'Fail' })) -Message "$($os.Caption) build $($os.BuildNumber)" -Data @{ caption = $os.Caption; build = $os.BuildNumber }

$edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
$homeEdition = $edition -match 'Core|Home'
if ($homeEdition -and [bool]$config.fail_on_windows_home) {
    Add-PreflightResult -Results $results -Name 'Windows Edition' -Status 'Fail' -Message "Windows edition '$edition' is not Pro or higher." -Data @{ edition = $edition }
} elseif ($homeEdition) {
    Add-PreflightResult -Results $results -Name 'Windows Edition' -Status 'Warn' -Message "Windows edition '$edition' is not Pro or higher; config allows continuing." -Data @{ edition = $edition }
} else {
    Add-PreflightResult -Results $results -Name 'Windows Edition' -Status 'Pass' -Message "Windows edition '$edition' is acceptable." -Data @{ edition = $edition }
}

$psOk = ($PSVersionTable.PSVersion.Major -ge 5)
Add-PreflightResult -Results $results -Name 'PowerShell Version' -Status ($(if ($psOk) { 'Pass' } else { 'Fail' })) -Message "PowerShell $($PSVersionTable.PSVersion)" -Data $PSVersionTable.PSVersion.ToString()

Add-PreflightResult -Results $results -Name 'USB Label' -Status 'Pass' -Message "Using deployment root $UsbRoot" -Data @{ usb_root = $UsbRoot }

$requiredDirs = @($paths.Config, $paths.Scripts, $paths.State, $paths.Logs, $paths.Reports, $paths.Apps, $paths.LocalApps, $paths.Drivers, $paths.Tools)
foreach ($dir in $requiredDirs) {
    Add-PreflightResult -Results $results -Name "Folder $dir" -Status ($(if (Test-Path -LiteralPath $dir -PathType Container) { 'Pass' } else { 'Fail' })) -Message 'Folder exists.' -Data $null
}

$requiredScripts = @(
    'Start-Deployment.ps1', 'Invoke-PreflightChecks.ps1', 'Install-WindowsUpdates.ps1',
    'Install-ModelDrivers.ps1', 'Install-NetworkDrivers.ps1', 'Install-WingetApps.ps1', 'Install-DattoRmm.ps1',
    'Install-LocalApps.ps1', 'Configure-MspWifi.ps1', 'Import-AdditionalWifiProfiles.ps1', 'Configure-PowerSettings.ps1',
    'Set-SystemTweaks.ps1', 'Configure-DesktopItems.ps1', 'Get-AssetInventory.ps1', 'Write-DeploymentReport.ps1',
    'Send-DeploymentEmail.ps1', 'Invoke-LocalHandover.ps1', 'Resume-Deployment.ps1', 'Common.ps1'
)
foreach ($script in $requiredScripts) {
    $scriptPath = Join-Path $paths.Scripts $script
    Add-PreflightResult -Results $results -Name "Script $script" -Status ($(if (Test-Path -LiteralPath $scriptPath -PathType Leaf) { 'Pass' } else { 'Fail' })) -Message 'Required script is present.' -Data @{ path = $scriptPath }
}

$requiredConfigs = @($paths.ConfigFile, $paths.WingetFile, $paths.LocalFile)
foreach ($file in $requiredConfigs) {
    try {
        Read-JsonFile -Path $file -Required | Out-Null
        Add-PreflightResult -Results $results -Name "Config $file" -Status 'Pass' -Message 'JSON is present and valid.' -Data $null
    } catch {
        Add-PreflightResult -Results $results -Name "Config $file" -Status 'Fail' -Message $_.Exception.Message -Data $null
    }
}

$dattoSiteId = if ($config.ContainsKey('datto_rmm_site_id_uuid')) { ([string]$config.datto_rmm_site_id_uuid).Trim() } else { '' }
if (-not [string]::IsNullOrWhiteSpace($dattoSiteId)) {
    if ($dattoSiteId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        try {
            [guid]$dattoSiteId | Out-Null
            Add-PreflightResult -Results $results -Name 'Datto RMM Site ID' -Status 'Pass' -Message "Datto site UUID format is valid: $dattoSiteId" -Data @{ site_id_uuid = $dattoSiteId }
        } catch {
            Add-PreflightResult -Results $results -Name 'Datto RMM Site ID' -Status 'Fail' -Message "Datto site UUID is invalid: $dattoSiteId" -Data @{ site_id_uuid = $dattoSiteId }
        }
    } else {
        Add-PreflightResult -Results $results -Name 'Datto RMM Site ID' -Status 'Fail' -Message "Datto site UUID must look like 1193f864-66b2-49fd-bafe-950ba1e803e5." -Data @{ site_id_uuid = $dattoSiteId }
    }
} else {
    Add-PreflightResult -Results $results -Name 'Datto RMM Site ID' -Status 'Warn' -Message 'Datto RMM site ID is blank; Datto RMM install step will be skipped.' -Data $null
}

$handoverConfig = if ($config.ContainsKey('local_deployment_handover') -and $null -ne $config.local_deployment_handover) { ConvertTo-PlainHashtable $config.local_deployment_handover } else { @{ enabled = $false } }
if ([bool]$handoverConfig.enabled) {
    Add-PreflightResult -Results $results -Name 'Local Deployment Handover' -Status 'Pass' -Message "Deployment files will be copied to $($handoverConfig.local_path) once network is available, so the USB can be ejected early." -Data $null
} else {
    Add-PreflightResult -Results $results -Name 'Local Deployment Handover' -Status 'Warn' -Message 'Local deployment handover is disabled; the USB must stay inserted for the entire deployment.' -Data $null
}

try {
    $smtpConfig = Get-SmtpConfig -UsbRoot $UsbRoot
    if ([bool]$smtpConfig.enabled) {
        $smtpToAddresses = @($smtpConfig.to_addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ([string]::IsNullOrWhiteSpace([string]$smtpConfig.smtp_server) -or $smtpToAddresses.Count -eq 0) {
            # Email notification is a convenience, not a deployment gate, so a misconfiguration
            # here warns rather than stopping a customer's laptop deployment.
            Add-PreflightResult -Results $results -Name 'SMTP Email' -Status 'Warn' -Message 'smtp_config.json is enabled but smtp_server or to_addresses is empty; email notification will be skipped.' -Data $null
        } else {
            Add-PreflightResult -Results $results -Name 'SMTP Email' -Status 'Pass' -Message "Email notification configured for $($smtpToAddresses -join ', ') via $($smtpConfig.smtp_server)." -Data $null
        }
    } else {
        Add-PreflightResult -Results $results -Name 'SMTP Email' -Status 'Warn' -Message 'SMTP email notification is disabled by config.' -Data $null
    }
} catch {
    Add-PreflightResult -Results $results -Name 'SMTP Email' -Status 'Warn' -Message "smtp_config.json could not be read: $($_.Exception.Message)" -Data $null
}

$systemDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
$freeGb = [math]::Round($systemDrive.FreeSpace / 1GB, 2)
$minGb = [double]$config.minimum_free_space_gb
Add-PreflightResult -Results $results -Name 'Free Disk Space' -Status ($(if ($freeGb -ge $minGb) { 'Pass' } else { 'Fail' })) -Message "$freeGb GB free on $env:SystemDrive; minimum is $minGb GB." -Data @{ free_gb = $freeGb; minimum_gb = $minGb }

$internet = Test-InternetConnectivity
if ($internet) {
    Add-PreflightResult -Results $results -Name 'Internet' -Status 'Pass' -Message 'HTTPS connectivity test succeeded.' -Data $null
} elseif ([bool]$config.require_internet) {
    Add-PreflightResult -Results $results -Name 'Internet' -Status 'Fail' -Message 'Internet connectivity is required but unavailable.' -Data $null
} else {
    Add-PreflightResult -Results $results -Name 'Internet' -Status 'Warn' -Message 'Internet connectivity is unavailable; config allows continuing.' -Data $null
}

$policy = Get-ExecutionPolicy -Scope Process
Add-PreflightResult -Results $results -Name 'Execution Policy' -Status 'Pass' -Message "Process execution policy is $policy. Scripts are launched with -ExecutionPolicy Bypass when resumed." -Data @{ process_policy = $policy }

$winget = Get-WingetCommand
if ($winget) {
    Add-PreflightResult -Results $results -Name 'winget' -Status 'Pass' -Message "winget found at $winget" -Data @{ path = $winget }
} elseif ([bool]$config.install_winget_apps -and -not [bool]$config.winget_bootstrap) {
    Add-PreflightResult -Results $results -Name 'winget' -Status 'Fail' -Message 'winget is required for configured app installs and automatic bootstrap is disabled.' -Data $null
} elseif ([bool]$config.install_winget_apps) {
    Add-PreflightResult -Results $results -Name 'winget' -Status 'Warn' -Message 'winget is missing. Bootstrap is enabled, but App Installer provisioning may still require Microsoft Store infrastructure.' -Data $null
} else {
    Add-PreflightResult -Results $results -Name 'winget' -Status 'Warn' -Message 'winget is missing but winget app installation is disabled.' -Data $null
}

try {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop
    Add-PreflightResult -Results $results -Name 'PowerShell Gallery' -Status 'Pass' -Message "PSGallery is registered with installation policy $($repo.InstallationPolicy)." -Data @{ source = $repo.SourceLocation }
} catch {
    if ([bool]$config.pswindowsupdate_bootstrap) {
        Add-PreflightResult -Results $results -Name 'PowerShell Gallery' -Status 'Fail' -Message 'PSGallery is required to bootstrap PSWindowsUpdate but is unavailable.' -Data $null
    } else {
        Add-PreflightResult -Results $results -Name 'PowerShell Gallery' -Status 'Warn' -Message 'PSGallery is unavailable and PSWindowsUpdate bootstrap is disabled.' -Data $null
    }
}

try {
    $bitlocker = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    Add-PreflightResult -Results $results -Name 'BitLocker' -Status 'Warn' -Message "BitLocker status on $env:SystemDrive is $($bitlocker.ProtectionStatus)." -Data @{ protection_status = [string]$bitlocker.ProtectionStatus; volume_status = [string]$bitlocker.VolumeStatus }
} catch {
    Add-PreflightResult -Results $results -Name 'BitLocker' -Status 'Warn' -Message 'BitLocker status could not be queried.' -Data $_.Exception.Message
}

$pendingReboot = Test-PendingReboot
if ($pendingReboot -and -not [bool]$config.allow_continue_with_pending_reboot) {
    Add-PreflightResult -Results $results -Name 'Pending Reboot' -Status 'Fail' -Message 'A pending reboot was detected before deployment.' -Data $null
} elseif ($pendingReboot) {
    Add-PreflightResult -Results $results -Name 'Pending Reboot' -Status 'Warn' -Message 'A pending reboot was detected; config allows continuing.' -Data $null
} else {
    Add-PreflightResult -Results $results -Name 'Pending Reboot' -Status 'Pass' -Message 'No pending reboot was detected.' -Data $null
}

$battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
$onBattery = $false
if ($battery) {
    $onBattery = ($battery.BatteryStatus -eq 1)
    $batteryMessage = "Battery status $($battery.BatteryStatus), estimated charge $($battery.EstimatedChargeRemaining)%."
    if ([bool]$config.require_ac_power -and $onBattery -and -not [bool]$config.allow_continue_without_ac) {
        Add-PreflightResult -Results $results -Name 'AC Power' -Status 'Fail' -Message "Notebook appears to be on battery. $batteryMessage" -Data $battery
    } elseif ($onBattery) {
        Add-PreflightResult -Results $results -Name 'AC Power' -Status 'Warn' -Message "Notebook appears to be on battery. $batteryMessage" -Data $battery
    } else {
        Add-PreflightResult -Results $results -Name 'AC Power' -Status 'Pass' -Message $batteryMessage -Data $battery
    }
} else {
    Add-PreflightResult -Results $results -Name 'AC Power' -Status 'Warn' -Message 'No battery was detected; assuming desktop or AC-only device.' -Data $null
}

$adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' }
Add-PreflightResult -Results $results -Name 'Network Adapter' -Status ($(if ($adapters) { 'Pass' } else { 'Fail' })) -Message "$(@($adapters).Count) enabled physical network adapter(s) detected." -Data ($adapters | Select-Object Name, InterfaceDescription, Status, MacAddress)

foreach ($writePath in @($paths.State, $paths.Logs, $paths.Reports)) {
    try {
        $testFile = Join-Path $writePath ("write-test-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $testFile -Value 'test' -Force -ErrorAction Stop
        Remove-Item -LiteralPath $testFile -Force -ErrorAction Stop
        Add-PreflightResult -Results $results -Name "Write Access $writePath" -Status 'Pass' -Message 'Write test succeeded.' -Data $null
    } catch {
        Add-PreflightResult -Results $results -Name "Write Access $writePath" -Status 'Fail' -Message $_.Exception.Message -Data $null
    }
}

Write-StructuredLog -Level Info -Message 'Preflight results' -Data $results
$failures = @($results | Where-Object { $_.status -eq 'Fail' })
if ($failures.Count -gt 0) {
    $summary = ($failures | ForEach-Object { "$($_.name): $($_.message)" }) -join "`n"
    throw "Preflight failed with $($failures.Count) critical issue(s):`n$summary"
}

Write-Log -Level Success -Message 'Preflight checks passed.'
