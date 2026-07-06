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

function Add-PreflightResult {
    param(
        [System.Collections.Generic.List[object]]$Results,
        [string]$Name,
        [ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [string]$Message,
        [object]$Data
    )
    $Results.Add([ordered]@{
            name    = $Name
            status  = $Status
            message = $Message
            data    = $Data
        }) | Out-Null
    if ($Status -eq 'Pass') {
        Write-Log -Level Success -Message "${Name}: $Message"
    } elseif ($Status -eq 'Warn') {
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
    'Install-ModelDrivers.ps1', 'Install-WingetApps.ps1', 'Install-LocalApps.ps1',
    'Configure-DesktopItems.ps1', 'Get-AssetInventory.ps1', 'Write-DeploymentReport.ps1',
    'Resume-Deployment.ps1', 'Common.ps1'
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
