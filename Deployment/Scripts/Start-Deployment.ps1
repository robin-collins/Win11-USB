[CmdletBinding()]
param(
    [string]$UsbRoot,
    [switch]$Reset,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

function Get-DeploymentSteps {
    @(
        'Preflight',
        'ConfigureComputerName',
        'CreateLocalAdmin',
        'WindowsUpdates',
        'AssetInventory',
        'ModelDrivers',
        'WingetApps',
        'LocalApps',
        'FinalReport',
        'Complete'
    )
}

function Initialize-StateForRun {
    param(
        [string]$StatePath,
        [switch]$Reset,
        [switch]$NonInteractive
    )

    $existing = Read-DeploymentState -StatePath $StatePath
    if ($existing -and $Reset) {
        $archive = "$StatePath.archive-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
        Copy-Item -LiteralPath $StatePath -Destination $archive -Force -ErrorAction Stop
        Write-Host "Previous deployment state archived to $archive" -ForegroundColor Yellow
        return (New-DeploymentState -RunId (New-DeploymentRunId))
    }

    if (-not $existing) {
        return (New-DeploymentState -RunId (New-DeploymentRunId))
    }

    $matchesDevice = Test-StateMatchesDevice -State $existing
    if (-not $matchesDevice) {
        $message = 'Existing deployment state does not match this physical device by serial number or UUID.'
        if ($NonInteractive) { throw $message }
        Write-Host $message -ForegroundColor Red
        Write-Host 'R) Restart task sequence for this device'
        Write-Host 'Q) Quit without changing state'
        do { $choice = (Read-Host 'Choose R or Q').Trim().ToUpperInvariant() } until ($choice -in @('R', 'Q'))
        if ($choice -eq 'Q') { exit 2 }
        $archive = "$StatePath.archive-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
        Copy-Item -LiteralPath $StatePath -Destination $archive -Force -ErrorAction Stop
        return (New-DeploymentState -RunId (New-DeploymentRunId))
    }

    Write-Host "Prior deployment state found. Last successful step: $($existing.last_successful_step)" -ForegroundColor Cyan
    if (-not $NonInteractive) {
        Write-Host 'R) Resume from the next incomplete step'
        Write-Host 'S) Restart task sequence from scratch'
        Write-Host 'Q) Quit'
        do { $choice = (Read-Host 'Choose R, S, or Q').Trim().ToUpperInvariant() } until ($choice -in @('R', 'S', 'Q'))
        if ($choice -eq 'Q') { exit 0 }
        if ($choice -eq 'S') {
            $archive = "$StatePath.archive-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
            Copy-Item -LiteralPath $StatePath -Destination $archive -Force -ErrorAction Stop
            return (New-DeploymentState -RunId (New-DeploymentRunId))
        }
    }

    return $existing
}

function Invoke-ComputerNameStep {
    param(
        [string]$UsbRoot,
        [hashtable]$State,
        [string]$StatePath,
        [hashtable]$Config
    )

    $mode = ([string]$Config.computer_name_mode).ToLowerInvariant()
    if ($mode -eq 'skip') {
        Write-Log -Level Info -Message 'Computer rename is disabled by config.'
        return
    }

    $identity = Get-DeviceIdentity
    $desired = $null
    if ($State.ContainsKey('desired_computer_name') -and -not [string]::IsNullOrWhiteSpace([string]$State.desired_computer_name)) {
        $desired = [string]$State.desired_computer_name
    } else {
        switch ($mode) {
            'prompt' {
                do {
                    $inputName = Read-Host 'Enter desired computer name, or press Enter to keep current name'
                    if ([string]::IsNullOrWhiteSpace($inputName)) {
                        Write-Log -Level Info -Message 'Technician chose to keep the current computer name.'
                        return
                    }
                    try { $desired = Get-SafeComputerName -Name $inputName } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
                } until ($desired)
            }
            'serial' {
                $desired = Get-SafeComputerName -Name $identity.serial_number
            }
            'prefix_serial' {
                $desired = Get-SafeComputerName -Name ("{0}-{1}" -f $Config.computer_name_prefix, $identity.serial_number)
            }
            default {
                throw "Unsupported computer_name_mode '$mode'. Valid values: prompt, serial, prefix_serial, skip."
            }
        }
        $State.desired_computer_name = $desired
        Write-DeploymentState -State $State -StatePath $StatePath
    }

    if ($env:COMPUTERNAME -ieq $desired) {
        Write-Log -Level Success -Message "Computer name is already $desired."
        return
    }

    Write-Log -Level Warn -Message "Renaming computer from $env:COMPUTERNAME to $desired."
    Rename-Computer -NewName $desired -Force -ErrorAction Stop
    Request-DeploymentReboot -UsbRoot $UsbRoot -State $State -StatePath $StatePath -Reason "Computer rename to $desired requires reboot."
}

function Invoke-CreateLocalAdminStep {
    param(
        [string]$UsbRoot,
        [hashtable]$State,
        [string]$StatePath,
        [hashtable]$Config
    )

    if (-not [bool]$Config.create_local_admin) {
        Write-Log -Level Info -Message 'Local administrator creation is disabled by config.'
        return
    }

    $username = [string]$Config.local_admin_username
    if ([string]::IsNullOrWhiteSpace($username)) { throw 'local_admin_username must not be empty when create_local_admin is true.' }
    $existing = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log -Level Success -Message "Local user $username already exists."
    } else {
        $mode = ([string]$Config.local_admin_password_mode).ToLowerInvariant()
        $password = $null
        if ($mode -eq 'prompt') {
            $password = Read-Host "Enter password for local administrator '$username'" -AsSecureString
        } elseif ($mode -eq 'random') {
            if (-not [bool]$Config.allow_random_password_export) {
                throw 'local_admin_password_mode=random requires allow_random_password_export=true so the generated credential is not lost.'
            }
            $plain = New-RandomPassword -Length 22
            $password = ConvertTo-SecureString -String $plain -AsPlainText -Force
            $reportRoot = Get-DeploymentReportRoot -UsbRoot $UsbRoot
            $passwordPath = Join-Path $reportRoot "local-admin-password-$($State.deployment_run_id).txt"
            Set-Content -LiteralPath $passwordPath -Value @(
                "Username: $username",
                "Password: $plain",
                "Generated: $((Get-Date).ToString('o'))",
                'Rotate this password during final customer onboarding.'
            ) -Encoding UTF8 -Force
            Write-Log -Level Warn -Message "Generated local admin password was written to $passwordPath. Treat this file as sensitive."
        } else {
            throw "Unsupported local_admin_password_mode '$mode'. Valid values: prompt, random."
        }

        New-LocalUser -Name $username -Password $password -FullName $username -Description ([string]$Config.local_admin_description) -PasswordNeverExpires:$true -ErrorAction Stop | Out-Null
        Write-Log -Level Success -Message "Local user $username was created."
    }

    $members = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Select-Object -ExpandProperty Name)
    $localName = "$env:COMPUTERNAME\$username"
    if ($members -notcontains $localName -and $members -notcontains $username) {
        Add-LocalGroupMember -Group 'Administrators' -Member $username -ErrorAction Stop
        Write-Log -Level Success -Message "$username was added to the local Administrators group."
    } else {
        Write-Log -Level Success -Message "$username is already a local administrator."
    }
}

function Invoke-DeploymentStep {
    param(
        [string]$Step,
        [string]$UsbRoot,
        [hashtable]$State,
        [string]$StatePath,
        [hashtable]$Config
    )

    switch ($Step) {
        'Preflight' { & (Join-Path $PSScriptRoot 'Invoke-PreflightChecks.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'ConfigureComputerName' { Invoke-ComputerNameStep -UsbRoot $UsbRoot -State $State -StatePath $StatePath -Config $Config }
        'CreateLocalAdmin' { Invoke-CreateLocalAdminStep -UsbRoot $UsbRoot -State $State -StatePath $StatePath -Config $Config }
        'WindowsUpdates' { & (Join-Path $PSScriptRoot 'Install-WindowsUpdates.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'AssetInventory' {
            $reportRoot = Get-DeploymentReportRoot -UsbRoot $UsbRoot
            $inventoryPath = Join-Path $reportRoot "asset-inventory-$($State.deployment_run_id).json"
            & (Join-Path $PSScriptRoot 'Get-AssetInventory.ps1') -UsbRoot $UsbRoot -OutputPath $inventoryPath | Out-Null
        }
        'ModelDrivers' {
            if ([bool]$Config.install_offline_drivers) { & (Join-Path $PSScriptRoot 'Install-ModelDrivers.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'Offline driver installation is disabled by config.' }
        }
        'WingetApps' {
            if ([bool]$Config.install_winget_apps) { & (Join-Path $PSScriptRoot 'Install-WingetApps.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'winget app installation is disabled by config.' }
        }
        'LocalApps' {
            if ([bool]$Config.install_local_apps) { & (Join-Path $PSScriptRoot 'Install-LocalApps.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'Local app installation is disabled by config.' }
        }
        'FinalReport' { & (Join-Path $PSScriptRoot 'Write-DeploymentReport.ps1') -UsbRoot $UsbRoot -StatePath $StatePath | Out-Null }
        'Complete' {
            Unregister-DeploymentResumeTask
            Write-Log -Level Success -Message 'Deployment task sequence complete. Device is ready for domain join / Entra join / customer onboarding.'
        }
        default { throw "Unknown deployment step '$Step'." }
    }
}

$paths = $null
try {
    if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
    $paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
    $state = Initialize-StateForRun -StatePath $paths.StateFile -Reset:$Reset -NonInteractive:$NonInteractive
    Write-DeploymentState -State $state -StatePath $paths.StateFile
    Initialize-DeploymentLogging -UsbRoot $UsbRoot -State $state | Out-Null
    $config = Get-DeploymentConfig -UsbRoot $UsbRoot
    $steps = Get-DeploymentSteps

    foreach ($step in $steps) {
        $state = Read-DeploymentState -StatePath $paths.StateFile
        if (@($state.completed_steps) -contains $step) {
            Write-Log -Level Info -Message "Skipping completed step: $step"
            continue
        }

        Set-StateStepStarted -State $state -Step $step -StatePath $paths.StateFile
        Write-Log -Level Info -Message "Starting deployment step: $step"
        Invoke-DeploymentStep -Step $step -UsbRoot $UsbRoot -State $state -StatePath $paths.StateFile -Config $config
        $state = Read-DeploymentState -StatePath $paths.StateFile
        Set-StateStepCompleted -State $state -Step $step -StatePath $paths.StateFile
        Write-Log -Level Success -Message "Completed deployment step: $step"
    }
} catch {
    $message = $_.Exception.Message
    Write-Log -Level Error -Message "Deployment failed: $message"
    try {
        if ($paths -and (Test-Path -LiteralPath $paths.StateFile -PathType Leaf)) {
            $failedState = Read-DeploymentState -StatePath $paths.StateFile
            if ($failedState) {
                $failedStep = if ($failedState.current_step) { $failedState.current_step } else { 'Unknown' }
                Set-StateFailure -State $failedState -Step $failedStep -Message $message -StatePath $paths.StateFile
                & (Join-Path $PSScriptRoot 'Write-DeploymentReport.ps1') -UsbRoot $UsbRoot -StatePath $paths.StateFile -Failure -FailureMessage $message | Out-Null
            }
        }
    } catch {
        Write-Log -Level Error -Message "Failed to write failure report: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host 'Deployment stopped. Review the log and report folders on the USB before rerunning.' -ForegroundColor Red
    exit 1
} finally {
    Stop-DeploymentLogging
}
