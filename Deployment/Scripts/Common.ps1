[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$script:DeploymentVolumeLabel = '1S-WIN11'
$script:DeploymentTaskName = 'OneSolutionWin11DeploymentResume'
$script:DeploymentRunMutexName = 'Global\OneSolutionWin11Deployment'
$script:DeploymentLogContext = $null

function Get-DeploymentSteps {
    @(
        'NetworkDrivers',
        'MspWifiSetup',
        'Preflight',
        'ConfigureComputerName',
        'CreateLocalAdmin',
        'PowerSettings',
        'WindowsUpdates',
        'AssetInventory',
        'ModelDrivers',
        'WingetApps',
        'DattoRmm',
        'LocalApps',
        'DesktopItems',
        'FinalReport',
        'Complete'
    )
}

function ConvertTo-PlainHashtable {
    param([Parameter(ValueFromPipeline = $true)][object]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = @{}
            foreach ($key in $InputObject.Keys) {
                $hash[$key] = ConvertTo-PlainHashtable $InputObject[$key]
            }
            return $hash
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-PlainHashtable $property.Value
            }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $items = @()
            foreach ($item in $InputObject) {
                $items += ,(ConvertTo-PlainHashtable $item)
            }
            return $items
        }
        return $InputObject
    }
}

function Get-UsbRoot {
    [CmdletBinding()]
    param([string]$VolumeLabel = $script:DeploymentVolumeLabel)

    $volume = $null
    try {
        $volume = Get-CimInstance -ClassName Win32_Volume -Filter "Label='$VolumeLabel'" -ErrorAction Stop |
            Where-Object { $_.DriveLetter } |
            Select-Object -First 1
    } catch {
        $volume = $null
    }

    if (-not $volume) {
        try {
            $volume = Get-Volume -FileSystemLabel $VolumeLabel -ErrorAction Stop |
                Where-Object { $_.DriveLetter } |
                Select-Object -First 1
        } catch {
            $volume = $null
        }
    }

    if (-not $volume) {
        throw "USB volume label '$VolumeLabel' was not found. Insert the deployment USB and try again."
    }

    if ($volume.PSObject.Properties.Name -contains 'DriveLetter') {
        $drive = [string]$volume.DriveLetter
        if ($drive.Length -eq 1) { return "$drive`:\" }
        return $drive.TrimEnd('\') + '\'
    }

    throw "USB volume label '$VolumeLabel' was found but no drive letter is assigned."
}

function Get-DeploymentPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    $root = (Resolve-Path -LiteralPath $UsbRoot -ErrorAction Stop).Path
    @{
        UsbRoot     = $root
        Deployment  = Join-Path $root 'Deployment'
        Config      = Join-Path $root 'Deployment\Config'
        Scripts     = Join-Path $root 'Deployment\Scripts'
        State       = Join-Path $root 'Deployment\State'
        Logs        = Join-Path $root 'Deployment\Logs'
        Reports     = Join-Path $root 'Deployment\Reports'
        Apps        = Join-Path $root 'Deployment\Apps'
        WingetApps  = Join-Path $root 'Deployment\Apps\Winget'
        LocalApps   = Join-Path $root 'Deployment\Apps\Local'
        Drivers     = Join-Path $root 'Deployment\Drivers'
        NetworkDrivers = Join-Path $root 'Deployment\Drivers\Network'
        Tools       = Join-Path $root 'Deployment\Tools'
        StateFile   = Join-Path $root 'Deployment\State\deployment_state.json'
        ConfigFile  = Join-Path $root 'Deployment\Config\deployment_config.json'
        WingetFile  = Join-Path $root 'Deployment\Config\winget_packages.json'
        LocalFile   = Join-Path $root 'Deployment\Config\local_apps.json'
    }
}

function Initialize-DeploymentDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    foreach ($path in @(
            $paths.Deployment, $paths.Config, $paths.Scripts, $paths.State, $paths.Logs,
            $paths.Reports, $paths.Apps, $paths.WingetApps, $paths.LocalApps,
            $paths.Drivers, (Join-Path $paths.Drivers 'Dell'), (Join-Path $paths.Drivers 'HP'),
            (Join-Path $paths.Drivers 'Lenovo'), (Join-Path $paths.Drivers 'Generic'),
            $paths.NetworkDrivers, (Join-Path $paths.NetworkDrivers 'Intel'),
            (Join-Path $paths.NetworkDrivers 'Realtek'), (Join-Path $paths.NetworkDrivers 'Qualcomm'),
            (Join-Path $paths.NetworkDrivers 'Broadcom'), (Join-Path $paths.NetworkDrivers 'Generic'),
            $paths.Tools
        )) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
    }
    return $paths
}

function Install-InfDriversFromFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [string]$LogName = 'pnputil-drivers.log'
    )

    $infFiles = @(Get-ChildItem -LiteralPath $Folder -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    if ($infFiles.Count -eq 0) {
        Write-Log -Level Info -Message "No .inf files found in $Folder."
        return [ordered]@{ installed = $false; count = 0; folder = $Folder }
    }

    # pnputil stages every matching driver into the driver store; INFs whose hardware ID is
    # not present on this device are simply skipped, so trying an unrelated vendor's package
    # here is harmless. This lets the toolkit carry drivers for several NIC vendors and try
    # them all without knowing in advance which chip a given machine has.
    $result = Invoke-ExternalCommand -FilePath pnputil.exe -Arguments @('/add-driver', (Join-Path $Folder '*.inf'), '/subdirs', '/install') -AllowedExitCodes @(0, 3010) -LogName $LogName
    $summary = [ordered]@{
        installed = $true
        count     = $infFiles.Count
        folder    = $Folder
        exit_code = $result.exit_code
    }
    Write-Log -Level Success -Message "Processed $($infFiles.Count) driver INF file(s) from $Folder."
    Write-StructuredLog -Level Info -Message 'Driver installation result' -Data $summary
    return $summary
}

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Required
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($Required) { throw "Required JSON file is missing: $Path" }
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        return ConvertTo-PlainHashtable ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function Write-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$InputObject
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $json = $InputObject | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -Force -ErrorAction Stop
}

function Get-DefaultDeploymentConfig {
    @{
        minimum_free_space_gb            = 25
        wipe_repartition_drive           = $false
        wipe_repartition_disk_id         = 0
        efi_partition_size_mb            = 512
        msr_partition_size_mb            = 16
        recovery_partition_size_mb       = 2048
        windows_image_name               = 'Windows 11 Pro'
        require_ac_power                 = $true
        require_internet                 = $true
        msp_wifi_setup                   = @{
            enabled = $true
            ssid = 'OneSolution'
            password_env_var = 'OSIT_WIFI_PASSWORD'
            authentication = 'WPA2PSK'
            encryption = 'AES'
            connect_timeout_seconds = 60
        }
        windows_update_max_cycles        = 5
        computer_name_mode               = 'prompt'
        computer_name_prefix             = 'NB'
        configure_power_settings         = $true
        power_timeout_battery_minutes    = 60
        power_timeout_ac_minutes         = 0
        power_manage_display_timeout     = $true
        power_manage_sleep_timeout       = $true
        power_manage_hibernate_timeout   = $true
        primary_setup_username           = 'OSIT'
        final_resultant_user             = 'OSIT'
        osit_local_admin_username        = 'OSIT'
        osit_local_admin_full_name       = 'OSIT Local Administrator'
        osit_local_admin_description     = 'Primary OSIT local administrator account'
        additional_local_users           = @()
        configure_desktop_items          = $true
        desktop_items                    = @{
            manage_common_desktop = $true
            manage_final_user_desktop = $true
            remove_unapproved_shortcuts = $true
            preserve_patterns = @('desktop.ini')
            common_desktop_items = @()
            final_user_desktop_items = @()
        }
        allow_random_password_export     = $false
        install_winget_apps              = $true
        datto_rmm_site_id_uuid           = ''
        datto_rmm_install_arguments      = ''
        datto_rmm_required               = $true
        install_local_apps               = $true
        install_offline_drivers          = $true
        install_network_drivers          = $true
        stop_before_domain_join          = $true
        fail_on_missing_required_app     = $true
        fail_on_windows_home             = $true
        allow_continue_without_ac        = $false
        allow_continue_with_pending_reboot = $false
        pswindowsupdate_bootstrap        = $true
        winget_bootstrap                 = $false
        windows_update_include_microsoft_update = $true
        local_admin_description          = 'Local administrator created by 1S Windows 11 deployment toolkit'
        generated_password_report_warning = 'Generated local admin passwords are sensitive. Store reports securely and rotate the password during customer onboarding.'
    }
}

function Merge-Config {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Base,
        [Parameter(Mandatory = $true)][hashtable]$Override
    )

    $merged = @{}
    foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) { $merged[$key] = $Override[$key] }
    return $merged
}

function Get-DeploymentConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $default = Get-DefaultDeploymentConfig
    if (Test-Path -LiteralPath $paths.ConfigFile -PathType Leaf) {
        return Merge-Config -Base $default -Override (Read-JsonFile -Path $paths.ConfigFile -Required)
    }
    $example = Join-Path $paths.Config 'deployment_config.example.json'
    if (Test-Path -LiteralPath $example -PathType Leaf) {
        return Merge-Config -Base $default -Override (Read-JsonFile -Path $example -Required)
    }
    return $default
}

function Get-SafeName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [string]$Fallback = 'Unknown'
    )

    $name = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $Fallback }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($char in $invalid) { $name = $name.Replace([string]$char, '_') }
    $name = $name -replace '[\s\-]+', '_'
    $name = $name -replace '_+', '_'
    $name = $name.Trim('_')
    if ([string]::IsNullOrWhiteSpace($name)) { return $Fallback }
    return $name
}

function ConvertTo-NormalizedManufacturer {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Manufacturer)

    $m = ($Manufacturer | ForEach-Object { [string]$_ }).Trim()
    switch -Regex ($m) {
        '^(HP|HP Inc\.?|Hewlett-Packard|Hewlett Packard)$' { return 'HP' }
        '^Dell(\s+Inc\.?)?$' { return 'Dell' }
        '^LENOVO$|^Lenovo$' { return 'Lenovo' }
        default { return (Get-SafeName -Value $m -Fallback 'Generic') }
    }
}

function ConvertTo-NormalizedModel {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Model,
        [AllowEmptyString()][string]$Manufacturer = ''
    )

    $value = ($Model | ForEach-Object { [string]$_ }).Trim()
    $value = $value -replace '\(R\)', ''
    $value = $value -replace '\bNotebook\b', ''
    $value = $value -replace '\bLaptop\b', ''
    $value = $value -replace '\bComputer\b', ''
    $value = $value -replace '\bDesktop\b', ''
    $value = $value -replace '\bPC\b', ''
    $value = $value -replace '\bSystem\b', ''
    $value = $value -replace '^\s*HP\s+', ''
    $value = $value -replace '^\s*Dell\s+', ''
    $value = $value -replace '^\s*Lenovo\s+', ''
    $value = $value -replace '[,;]+', ' '
    return (Get-SafeName -Value $value -Fallback 'Unknown_Model')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DeviceIdentity {
    [CmdletBinding()]
    param()

    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

    @{
        serial_number = if ($bios) { [string]$bios.SerialNumber } else { '' }
        uuid          = if ($product) { [string]$product.UUID } else { '' }
        computer_name = $env:COMPUTERNAME
        manufacturer  = if ($system) { [string]$system.Manufacturer } else { '' }
        model         = if ($system) { [string]$system.Model } else { '' }
        windows_caption = if ($os) { [string]$os.Caption } else { '' }
        windows_version = if ($os) { [string]$os.Version } else { '' }
        windows_build = if ($os) { [string]$os.BuildNumber } else { '' }
    }
}

function New-DeploymentRunId {
    (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
}

function New-DeploymentState {
    [CmdletBinding()]
    param([string]$RunId)

    $identity = Get-DeviceIdentity
    @{
        device_serial_number = $identity.serial_number
        device_uuid          = $identity.uuid
        computer_name        = $identity.computer_name
        current_step         = ''
        completed_steps      = @()
        timestamp            = (Get-Date).ToString('o')
        windows_version      = $identity.windows_version
        windows_build        = $identity.windows_build
        manufacturer         = $identity.manufacturer
        model                = $identity.model
        deployment_run_id    = $RunId
        last_successful_step = ''
        last_error           = $null
        reboot_pending       = $false
        update_cycle         = 0
        history              = @()
    }
}

function Read-DeploymentState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StatePath)

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try {
        return Read-JsonFile -Path $StatePath -Required
    } catch {
        $backup = "$StatePath.bak"
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Write-Log -Level Warn -Message "Deployment state file is unreadable ($($_.Exception.Message)); falling back to backup $backup"
            return Read-JsonFile -Path $backup -Required
        }
        throw
    }
}

function Write-DeploymentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    $State.timestamp = (Get-Date).ToString('o')
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $backup = "$StatePath.bak"
        Copy-Item -LiteralPath $StatePath -Destination $backup -Force -ErrorAction SilentlyContinue
    }
    Write-JsonFile -Path $StatePath -InputObject $State
}

function Add-StateHistory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Event,
        [object]$Data
    )

    $existingHistory = @()
    if ($State.ContainsKey('history') -and $null -ne $State.history) {
        $existingHistory = @($State.history)
    }
    $State.history = @($existingHistory + ([ordered]@{
            timestamp = (Get-Date).ToString('o')
            event     = $Event
            data      = $Data
        }))
}

function Set-StateStepStarted {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    $State.current_step = $Step
    $State.last_error = $null
    # A stale reboot_pending from an interrupted earlier run must not make the orchestrator
    # stop after this step completes without requesting its own reboot.
    $State.reboot_pending = $false
    Add-StateHistory -State $State -Event 'step_started' -Data @{ step = $Step }
    Write-DeploymentState -State $State -StatePath $StatePath
}

function Set-StateStepCompleted {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    $completedSteps = @()
    if ($State.ContainsKey('completed_steps') -and $null -ne $State.completed_steps) {
        $completedSteps = @($State.completed_steps)
    }
    if ($completedSteps -notcontains $Step) {
        $completedSteps = @($completedSteps + $Step)
    }
    $State.completed_steps = $completedSteps
    $State.last_successful_step = $Step
    $State.current_step = ''
    $State.last_error = $null
    $State.reboot_pending = $false
    Add-StateHistory -State $State -Event 'step_completed' -Data @{ step = $Step }
    Write-DeploymentState -State $State -StatePath $StatePath
}

function Set-StateFailure {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    $State.current_step = $Step
    $State.last_error = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        step      = $Step
        message   = $Message
    }
    Add-StateHistory -State $State -Event 'step_failed' -Data $State.last_error
    Write-DeploymentState -State $State -StatePath $StatePath
}

function Test-UsableSerialNumber {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$SerialNumber)

    if ([string]::IsNullOrWhiteSpace($SerialNumber)) { return $false }
    # Whitebox and some VM firmware report these instead of a real serial; treating them as
    # identity would make unrelated devices match each other's state and share log folders.
    $placeholders = @(
        'to be filled by o.e.m.', 'default string', 'system serial number',
        'none', 'unknown', 'not specified', 'not available', 'na', 'n/a', '0', '0123456789'
    )
    return ($placeholders -notcontains $SerialNumber.Trim().ToLowerInvariant())
}

function Test-UsableDeviceUuid {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Uuid)

    if ([string]::IsNullOrWhiteSpace($Uuid)) { return $false }
    $value = $Uuid.Trim()
    if ($value -match '^0{8}-0{4}-0{4}-0{4}-0{12}$') { return $false }
    if ($value -match '^[Ff]{8}-[Ff]{4}-[Ff]{4}-[Ff]{4}-[Ff]{12}$') { return $false }
    return $true
}

function Get-DeviceFolderName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Identity)

    if (Test-UsableSerialNumber -SerialNumber $Identity.serial_number) {
        return (Get-SafeName -Value $Identity.serial_number -Fallback $Identity.computer_name)
    }
    return (Get-SafeName -Value $Identity.computer_name -Fallback 'Unknown_Device')
}

function Test-StateMatchesDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $identity = Get-DeviceIdentity
    $stateSerial = [string]$State.device_serial_number
    $stateUuid = [string]$State.device_uuid

    $currentSerialUsable = Test-UsableSerialNumber -SerialNumber $identity.serial_number
    $currentUuidUsable = Test-UsableDeviceUuid -Uuid $identity.uuid
    $stateSerialUsable = Test-UsableSerialNumber -SerialNumber $stateSerial
    $stateUuidUsable = Test-UsableDeviceUuid -Uuid $stateUuid

    if ($stateSerialUsable -and $currentSerialUsable -and ($stateSerial -eq $identity.serial_number)) { return $true }
    if ($stateUuidUsable -and $currentUuidUsable -and ($stateUuid -ieq $identity.uuid)) { return $true }

    if (-not $currentSerialUsable -and -not $currentUuidUsable -and -not $stateSerialUsable -and -not $stateUuidUsable) {
        # Neither this device's firmware nor the recorded state offers usable identity, so
        # the computer name (including a pending rename recorded in state) is the only
        # remaining way to recognise the device.
        $knownNames = @([string]$State.computer_name)
        if ($State.ContainsKey('desired_computer_name')) { $knownNames += [string]$State.desired_computer_name }
        if (@($knownNames | Where-Object { $_ -and ($_ -ieq $env:COMPUTERNAME) }).Count -gt 0) {
            Write-Log -Level Warn -Message 'Device serial number and UUID are unusable placeholders; matched deployment state by computer name instead.'
            return $true
        }
    }

    return $false
}

function Initialize-DeploymentLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UsbRoot,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $identity = Get-DeviceIdentity
    $safeDevice = Get-DeviceFolderName -Identity $identity
    $runId = $State.deployment_run_id
    $logDir = Join-Path (Join-Path $paths.Logs $safeDevice) $runId
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null

    $transcriptPath = Join-Path $logDir 'transcript.log'
    $jsonLogPath = Join-Path $logDir 'events.jsonl'
    $script:DeploymentLogContext = [ordered]@{
        LogDir         = $logDir
        TranscriptPath = $transcriptPath
        JsonLogPath    = $jsonLogPath
    }

    if (-not (Test-Path -LiteralPath $jsonLogPath -PathType Leaf)) {
        New-Item -ItemType File -Path $jsonLogPath -Force | Out-Null
    }

    try {
        Start-Transcript -Path $transcriptPath -Append -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Unable to start transcript: $($_.Exception.Message)"
    }
    Write-Log -Level Info -Message "Logging initialised at $logDir"
    return $script:DeploymentLogContext
}

function Stop-DeploymentLogging {
    try { Stop-Transcript | Out-Null } catch {}
}

function Write-StructuredLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Data
    )

    if ($null -eq $script:DeploymentLogContext) { return }
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level     = $Level
        message   = $Message
        data      = $Data
    }
    Add-Content -LiteralPath $script:DeploymentLogContext.JsonLogPath -Value ($entry | ConvertTo-Json -Depth 12 -Compress) -Encoding UTF8
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Info', 'Warn', 'Error', 'Success')][string]$Level = 'Info',
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Data
    )

    $prefix = "[$Level]"
    $color = 'White'
    switch ($Level) {
        'Debug' { $color = 'DarkGray' }
        'Info' { $color = 'Cyan' }
        'Warn' { $color = 'Yellow' }
        'Error' { $color = 'Red' }
        'Success' { $color = 'Green' }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
    Write-StructuredLog -Level $Level -Message $Message -Data $Data
}

function ConvertTo-ProcessArgumentString {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    # Windows PowerShell 5.1 Start-Process joins an -ArgumentList array with spaces WITHOUT
    # quoting, so any argument containing a space is split by the target process. Arguments
    # are therefore quoted here (Win32 CommandLineToArgvW rules) and passed as one string.
    $quoted = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value.Length -gt 0 -and $value -notmatch '[\s"]') {
            $value
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $pendingBackslashes = 0
        foreach ($char in $value.ToCharArray()) {
            if ($char -eq '\') { $pendingBackslashes++; continue }
            if ($char -eq '"') {
                [void]$builder.Append('\' * ($pendingBackslashes * 2 + 1))
                [void]$builder.Append('"')
                $pendingBackslashes = 0
                continue
            }
            if ($pendingBackslashes -gt 0) {
                [void]$builder.Append('\' * $pendingBackslashes)
                $pendingBackslashes = 0
            }
            [void]$builder.Append($char)
        }
        if ($pendingBackslashes -gt 0) { [void]$builder.Append('\' * ($pendingBackslashes * 2)) }
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return (@($quoted) -join ' ')
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$AllowedExitCodes = @(0),
        [string]$WorkingDirectory = $PWD.Path,
        [string]$LogName
    )

    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable not found: $FilePath"
    }

    $tempBase = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString('N'))
    $stdoutPath = "$tempBase.out"
    $stderrPath = "$tempBase.err"
    $argumentLine = ConvertTo-ProcessArgumentString -Arguments $Arguments

    Write-Log -Level Info -Message "Running: $FilePath $argumentLine"
    $startParams = @{
        FilePath               = $FilePath
        WorkingDirectory       = $WorkingDirectory
        NoNewWindow            = $true
        Wait                   = $true
        PassThru               = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError  = $stderrPath
    }
    if (-not [string]::IsNullOrEmpty($argumentLine)) { $startParams.ArgumentList = $argumentLine }
    $process = Start-Process @startParams

    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    $result = [ordered]@{
        file_path = $FilePath
        arguments = $Arguments
        exit_code = $process.ExitCode
        stdout    = $stdout
        stderr    = $stderr
    }

    if ($LogName -and $script:DeploymentLogContext) {
        $commandLog = Join-Path $script:DeploymentLogContext.LogDir $LogName
        Set-Content -LiteralPath $commandLog -Value ("COMMAND: $FilePath $argumentLine`r`nEXIT CODE: $($process.ExitCode)`r`n`r`nSTDOUT:`r`n$stdout`r`nSTDERR:`r`n$stderr") -Encoding UTF8 -Force
    }

    Write-StructuredLog -Level Info -Message 'External command completed' -Data $result
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath $argumentLine`n$stderr"
    }
    return $result
}

function Split-CommandLineArguments {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ArgumentString)

    if ([string]::IsNullOrWhiteSpace($ArgumentString)) { return @() }
    $tokenMatches = [regex]::Matches($ArgumentString, '("[^"]*"|''[^'']*''|\S+)')
    $parsedArguments = @()
    foreach ($match in $tokenMatches) {
        $value = $match.Value
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $parsedArguments += $value
    }
    return $parsedArguments
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 10,
        [string]$OperationName = 'operation'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $ScriptBlock)
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Log -Level Warn -Message "$OperationName attempt $attempt of $MaxAttempts failed: $($_.Exception.Message). Retrying in $DelaySeconds second(s)."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Test-InternetConnectivity {
    [CmdletBinding()]
    param([string[]]$Hosts = @('www.microsoft.com', 'cdn.winget.microsoft.com', 'www.powershellgallery.com'))

    foreach ($hostName in $Hosts) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($hostName, 443, $null, $null)
            $success = $async.AsyncWaitHandle.WaitOne(5000, $false)
            if ($success) {
                $client.EndConnect($async)
                $client.Close()
                return $true
            }
            $client.Close()
        } catch {}
    }
    return $false
}

function Test-PendingReboot {
    [CmdletBinding()]
    param()

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    if (Test-Path -LiteralPath $paths[0]) { return $true }
    if (Test-Path -LiteralPath $paths[1]) { return $true }
    try {
        $session = Get-ItemProperty -LiteralPath $paths[2] -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($session.PendingFileRenameOperations) { return $true }
    } catch {}
    return $false
}

function Get-LocalAccountSid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Username)

    try {
        $account = New-Object System.Security.Principal.NTAccount($env:COMPUTERNAME, $Username)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $null
    }
}

function Register-DeploymentResumeTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UsbRoot,
        [string]$TriggerUsername
    )

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $resumeScript = Join-Path $paths.Scripts 'Resume-Deployment.ps1'
    if (-not (Test-Path -LiteralPath $resumeScript -PathType Leaf)) {
        throw "Resume script missing: $resumeScript"
    }

    if ([string]::IsNullOrWhiteSpace($TriggerUsername)) { $TriggerUsername = $env:USERNAME }

    # A logon trigger built from "COMPUTERNAME\User" resolves to a SID at registration time,
    # but ConfigureComputerName's own reboot can rename the computer at the same reboot this
    # task is meant to survive. Resolving the SID explicitly here removes any dependency on
    # the computer name at all, so the trigger keeps matching the account after a rename.
    $userSid = Get-LocalAccountSid -Username $TriggerUsername
    $userId = if ($userSid) { $userSid } else { "$env:COMPUTERNAME\$TriggerUsername" }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $resumeScript)

    # The AtLogOn trigger is the primary path (fires immediately once someone is logged on).
    # The recurring trigger is a backstop so the deployment resumes within a few minutes even
    # if automatic logon does not occur for some reason and no technician is present to log
    # on manually, instead of waiting indefinitely for a fresh logon event.
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $backstopTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3)

    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $script:DeploymentTaskName -Action $action -Trigger @($logonTrigger, $backstopTrigger) -Principal $principal -Force -ErrorAction Stop | Out-Null
    Write-Log -Level Success -Message "Resume scheduled task is registered for '$TriggerUsername': $script:DeploymentTaskName (logon trigger plus a 5-minute backstop check)"
}

function Unregister-DeploymentResumeTask {
    [CmdletBinding()]
    param()

    try {
        if (Get-ScheduledTask -TaskName $script:DeploymentTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $script:DeploymentTaskName -Confirm:$false -ErrorAction Stop
            Write-Log -Level Success -Message "Resume scheduled task removed: $script:DeploymentTaskName"
        }
    } catch {
        Write-Log -Level Warn -Message "Unable to remove resume task: $($_.Exception.Message)"
    }
}

function Enable-DeploymentAutoLogon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    # Autounattend's AutoLogon only fires once (LogonCount=1), covering the very first boot
    # after Windows install. Every later deployment-triggered reboot (rename, Windows Update)
    # would otherwise sit at the lock screen until a technician physically logs back on as
    # OSIT before the resume task's logon trigger can fire. Re-enabling autologon here for
    # just the next boot keeps the resume genuinely unattended. This is scrubbed again in the
    # Complete step, matching the same plaintext-password handling Autounattend.xml already
    # documents and accepts for the first boot.
    $config = Get-DeploymentConfig -UsbRoot $UsbRoot
    $username = [string]$config.osit_local_admin_username
    if ([string]::IsNullOrWhiteSpace($username)) { $username = 'OSIT' }

    $password = Get-OsitLocalAdminPassword -SearchRoots @($UsbRoot)
    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-Log -Level Warn -Message "OSIT password was not found; cannot enable automatic logon for the next reboot. A technician must log on as $username manually to resume."
        return $null
    }

    try {
        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -LiteralPath $winlogonKey -Name AutoAdminLogon -Value '1' -Type String -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $winlogonKey -Name DefaultUserName -Value $username -Type String -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath $winlogonKey -Name DefaultPassword -Value $password -Type String -Force -ErrorAction Stop
        Remove-ItemProperty -LiteralPath $winlogonKey -Name DefaultDomainName -ErrorAction SilentlyContinue
        Write-Log -Level Info -Message "Automatic logon for '$username' is enabled for the next reboot so the deployment resumes without technician intervention."
        return $username
    } catch {
        Write-Log -Level Warn -Message "Could not enable automatic logon: $($_.Exception.Message). A technician must log on manually to resume."
        return $null
    }
}

function Show-DeploymentToast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message
    )

    # Best-effort only: toasts are a convenience for the technician, not a deployment
    # requirement. A missing WinRT type (non-interactive/SYSTEM session, older PowerShell)
    # must never fail or slow down the actual deployment.
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]

        $escapedTitle = [System.Security.SecurityElement]::Escape($Title)
        $escapedMessage = [System.Security.SecurityElement]::Escape($Message)
        $template = "<toast><visual><binding template=`"ToastGeneric`"><text>$escapedTitle</text><text>$escapedMessage</text></binding></visual></toast>"

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $appId = (Get-Process -Id $PID -ErrorAction Stop).Path
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Log -Level Debug -Message "Toast notification could not be shown (non-fatal): $($_.Exception.Message)"
    }
}

function Get-DeploymentProcessInfo {
    [CmdletBinding()]
    param()

    try {
        # Named $matchingProcesses deliberately: a variable named $matches collides with the
        # automatic $Matches populated by the -match operator used in this same filter, which
        # silently corrupts the assignment.
        $matchingProcesses = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Where-Object {
            $_.Name -ieq 'powershell.exe' -and $_.CommandLine -and
            ($_.CommandLine -match 'Start-Deployment\.ps1' -or $_.CommandLine -match 'Resume-Deployment\.ps1') -and
            $_.ProcessId -ne $PID
        }
        return @($matchingProcesses | Select-Object ProcessId, CommandLine, CreationDate)
    } catch {
        return @()
    }
}

function Enter-DeploymentRunLock {
    [CmdletBinding()]
    param()

    $mutex = New-Object System.Threading.Mutex($false, $script:DeploymentRunMutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # A previous run crashed or was killed without releasing the mutex; the deployment
        # state file (not the mutex) is the source of truth for progress, so it is safe to
        # take over rather than treat this as "already running".
        $acquired = $true
    }
    return [ordered]@{ Mutex = $mutex; Acquired = $acquired }
}

function Exit-DeploymentRunLock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Lock)

    if ($Lock.Acquired) {
        try { $Lock.Mutex.ReleaseMutex() | Out-Null } catch {}
    }
    $Lock.Mutex.Dispose()
}

function Request-DeploymentReboot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UsbRoot,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $State.reboot_pending = $true
    Add-StateHistory -State $State -Event 'reboot_requested' -Data @{ reason = $Reason; current_step = $State.current_step }
    Write-DeploymentState -State $State -StatePath $StatePath
    $autoLogonUser = Enable-DeploymentAutoLogon -UsbRoot $UsbRoot
    Register-DeploymentResumeTask -UsbRoot $UsbRoot -TriggerUsername $autoLogonUser
    Write-Log -Level Warn -Message "Reboot required: $Reason"
    Write-Log -Level Info -Message 'The deployment will resume after the next administrator logon.'
    Show-DeploymentToast -Title 'Windows 11 Deployment' -Message "Restarting to continue: $Reason. Will resume automatically after logon."
    Restart-Computer -Force
    exit 3010
}

function Get-WingetCommand {
    [CmdletBinding()]
    param()

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Get-InstalledProgramNames {
    [CmdletBinding()]
    param()

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $names = @()
    foreach ($root in $roots) {
        try {
            $names += Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object -ExpandProperty DisplayName
        } catch {}
    }
    return ($names | Sort-Object -Unique)
}

function Test-ProgramInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Pattern)

    $programs = Get-InstalledProgramNames
    return [bool]($programs | Where-Object { $_ -like $Pattern -or $_ -match $Pattern } | Select-Object -First 1)
}

function Get-SafeComputerName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $candidate = $Name.Trim().ToUpperInvariant()
    $candidate = $candidate -replace '[^A-Z0-9-]', '-'
    $candidate = $candidate.Trim('-')
    if ($candidate.Length -gt 15) { $candidate = $candidate.Substring(0, 15).Trim('-') }
    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'Computer name cannot be empty after normalisation.' }
    return $candidate
}

function New-RandomPassword {
    [CmdletBinding()]
    param([int]$Length = 20)

    Add-Type -AssemblyName System.Web
    return [System.Web.Security.Membership]::GeneratePassword($Length, 4)
}

function ConvertFrom-SecureStringToPlainText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][securestring]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-DotEnvValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.*)\s*$") {
            $value = $Matches[1].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return $null
}

function Get-OsitLocalAdminPassword {
    [CmdletBinding()]
    param([string[]]$SearchRoots = @())

    foreach ($target in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable('OSIT_LOCAL_ADMIN_PASSWORD', $target)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    foreach ($root in $SearchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $envPath = Join-Path $root '.env'
        $value = Get-DotEnvValue -Path $envPath -Name 'OSIT_LOCAL_ADMIN_PASSWORD'
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    return $null
}

function Get-OsitWifiPassword {
    [CmdletBinding()]
    param([string[]]$SearchRoots = @())

    foreach ($target in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable('OSIT_WIFI_PASSWORD', $target)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    foreach ($root in $SearchRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $envPath = Join-Path $root '.env'
        $value = Get-DotEnvValue -Path $envPath -Name 'OSIT_WIFI_PASSWORD'
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    return $null
}

function Get-DeploymentReportRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $identity = Get-DeviceIdentity
    $safeDevice = Get-DeviceFolderName -Identity $identity
    $reportRoot = Join-Path $paths.Reports $safeDevice
    New-Item -ItemType Directory -Path $reportRoot -Force -ErrorAction Stop | Out-Null
    return $reportRoot
}
