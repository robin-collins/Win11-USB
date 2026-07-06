[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$script:DeploymentVolumeLabel = '1S-WIN11'
$script:DeploymentTaskName = 'OneSolutionWin11DeploymentResume'
$script:DeploymentLogContext = $null

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
            (Join-Path $paths.Drivers 'Lenovo'), (Join-Path $paths.Drivers 'Generic'), $paths.Tools
        )) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
    }
    return $paths
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
        require_ac_power                 = $true
        require_internet                 = $true
        windows_update_max_cycles        = 5
        computer_name_mode               = 'prompt'
        computer_name_prefix             = 'NB'
        create_local_admin               = $true
        local_admin_username             = 'LocalAdmin'
        local_admin_password_mode        = 'prompt'
        allow_random_password_export     = $false
        install_winget_apps              = $true
        install_local_apps               = $true
        install_offline_drivers          = $true
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

function Normalize-Manufacturer {
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

function Normalize-Model {
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
    return Read-JsonFile -Path $StatePath -Required
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

    if (-not $State.ContainsKey('history') -or $null -eq $State.history) { $State.history = @() }
    $State.history += ,([ordered]@{
            timestamp = (Get-Date).ToString('o')
            event     = $Event
            data      = $Data
        })
}

function Set-StateStepStarted {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    $State.current_step = $Step
    $State.last_error = $null
    Add-StateHistory -State $State -Event 'step_started' -Data @{ step = $Step }
    Write-DeploymentState -State $State -StatePath $StatePath
}

function Set-StateStepCompleted {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    if (-not ($State.completed_steps -contains $Step)) {
        $State.completed_steps += ,$Step
    }
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

function Test-StateMatchesDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $identity = Get-DeviceIdentity
    $serialMatches = -not [string]::IsNullOrWhiteSpace($State.device_serial_number) -and
        -not [string]::IsNullOrWhiteSpace($identity.serial_number) -and
        ($State.device_serial_number -eq $identity.serial_number)
    $uuidMatches = -not [string]::IsNullOrWhiteSpace($State.device_uuid) -and
        -not [string]::IsNullOrWhiteSpace($identity.uuid) -and
        ($State.device_uuid -eq $identity.uuid)
    return ($serialMatches -or $uuidMatches)
}

function Initialize-DeploymentLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UsbRoot,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $identity = Get-DeviceIdentity
    $safeDevice = Get-SafeName -Value $identity.serial_number -Fallback $identity.computer_name
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
    $argumentLine = ($Arguments | ForEach-Object {
            if ($_ -match '\s|"' ) { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '

    Write-Log -Level Info -Message "Running: $FilePath $argumentLine"
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

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
    $matches = [regex]::Matches($ArgumentString, '("[^"]*"|''[^'']*''|\S+)')
    $args = @()
    foreach ($match in $matches) {
        $value = $match.Value
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $args += $value
    }
    return $args
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

function Register-DeploymentResumeTask {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $resumeScript = Join-Path $paths.Scripts 'Resume-Deployment.ps1'
    if (-not (Test-Path -LiteralPath $resumeScript -PathType Leaf)) {
        throw "Resume script missing: $resumeScript"
    }

    $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`""
    Invoke-ExternalCommand -FilePath schtasks.exe -Arguments @('/Create', '/TN', $script:DeploymentTaskName, '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/F', '/TR', $action) -LogName 'register-resume-task.log' | Out-Null
    Write-Log -Level Success -Message "Resume scheduled task is registered: $script:DeploymentTaskName"
}

function Unregister-DeploymentResumeTask {
    [CmdletBinding()]
    param()

    try {
        Invoke-ExternalCommand -FilePath schtasks.exe -Arguments @('/Delete', '/TN', $script:DeploymentTaskName, '/F') -AllowedExitCodes @(0, 1) -LogName 'unregister-resume-task.log' | Out-Null
    } catch {
        Write-Log -Level Warn -Message "Unable to remove resume task: $($_.Exception.Message)"
    }
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
    Register-DeploymentResumeTask -UsbRoot $UsbRoot
    Write-Log -Level Warn -Message "Reboot required: $Reason"
    Write-Log -Level Info -Message 'The deployment will resume after the next administrator logon.'
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

function Get-DeploymentReportRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UsbRoot)

    $paths = Get-DeploymentPaths -UsbRoot $UsbRoot
    $identity = Get-DeviceIdentity
    $safeDevice = Get-SafeName -Value $identity.serial_number -Fallback $identity.computer_name
    $reportRoot = Join-Path $paths.Reports $safeDevice
    New-Item -ItemType Directory -Path $reportRoot -Force -ErrorAction Stop | Out-Null
    return $reportRoot
}
