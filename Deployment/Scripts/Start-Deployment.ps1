[Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingWriteHost', '', Justification = 'Interactive technician prompts (resume/restart/quit choices) and colored status output at the console; Write-Log is used in parallel for the audited/structured log.')]
[CmdletBinding()]
param(
    [string]$UsbRoot,
    [switch]$Reset,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

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
                if ($NonInteractive) {
                    Write-Log -Level Warn -Message 'computer_name_mode=prompt but the session is non-interactive; keeping the current computer name.'
                    return
                }
                Show-DeploymentToast -Title 'Windows 11 Deployment - Action Needed' -Message "Enter a computer name for $env:COMPUTERNAME to continue."
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

function Get-ConfigValue {
    param(
        [hashtable]$Hash,
        [string]$Key,
        [object]$Default = $null
    )

    if ($Hash -and $Hash.ContainsKey($Key) -and $null -ne $Hash[$Key]) { return $Hash[$Key] }
    return $Default
}

function Get-LocalUserDefinitions {
    param([hashtable]$Config)

    $ositUsername = [string](Get-ConfigValue -Hash $Config -Key 'osit_local_admin_username' -Default 'OSIT')
    $users = @(@{
            username               = $ositUsername
            full_name              = [string](Get-ConfigValue -Hash $Config -Key 'osit_local_admin_full_name' -Default 'OSIT Local Administrator')
            description            = [string](Get-ConfigValue -Hash $Config -Key 'osit_local_admin_description' -Default 'Primary OSIT local administrator account')
            groups                 = @('Administrators')
            password_mode          = 'osit_secret'
            password_never_expires = $true
            enabled                = $true
            primary_setup_user     = $true
        })

    $additionalUsers = @()
    if ($Config.ContainsKey('additional_local_users') -and $null -ne $Config.additional_local_users) {
        $additionalUsers = @($Config.additional_local_users)
    } elseif ($Config.ContainsKey('local_users') -and $null -ne $Config.local_users) {
        Write-Log -Level Warn -Message 'Config key local_users is deprecated. Rename it to additional_local_users. OSIT is now always the base local admin account.'
        $additionalUsers = @($Config.local_users)
    }

    foreach ($user in $additionalUsers) {
        $entry = ConvertTo-PlainHashtable $user
        if ($entry.ContainsKey('enabled') -and -not [bool]$entry.enabled) { continue }
        if ([string]$entry.username -ieq $ositUsername) {
            Write-Log -Level Warn -Message "Ignoring additional_local_users entry for $ositUsername because OSIT is managed as the base account."
            continue
        }
        $users += ,$entry
    }

    return $users
}

function New-ConfiguredLocalUserPassword {
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'New-LocalUser requires a SecureString credential. Both plaintext sources here are toolkit-managed secrets (the .env/config-plumbed OSIT password, or a freshly generated random password written to a protected report file), not user-typed console input, so ConvertTo-SecureString is the required bridge into the Microsoft.PowerShell.LocalAccounts API, not a security downgrade.')]
    param(
        [hashtable]$Account,
        [hashtable]$Config,
        [hashtable]$State,
        [string]$UsbRoot
    )

    $username = [string]$Account.username
    $mode = ([string](Get-ConfigValue -Hash $Account -Key 'password_mode' -Default 'prompt')).ToLowerInvariant()
    if ($mode -eq 'osit_secret') {
        $passwordValue = Get-OsitLocalAdminPassword -SearchRoots @($UsbRoot)
        if ([string]::IsNullOrWhiteSpace($passwordValue)) {
            throw "OSIT_LOCAL_ADMIN_PASSWORD was not found in environment variables or USB-root .env. Run Initialize-UsbDeployment.ps1 to prepare the USB."
        }
        return (ConvertTo-SecureString -String $passwordValue -AsPlainText -Force)
    }

    if ($mode -eq 'prompt') {
        return (Read-Host "Enter password for local user '$username'" -AsSecureString)
    }

    if ($mode -eq 'random') {
        if (-not [bool]$Config.allow_random_password_export) {
            throw "password_mode=random for '$username' requires allow_random_password_export=true so the generated credential is not lost."
        }
        $plain = New-RandomPassword -Length 22
        $password = ConvertTo-SecureString -String $plain -AsPlainText -Force
        $reportRoot = Get-DeploymentReportRoot -UsbRoot $UsbRoot
        $passwordPath = Join-Path $reportRoot ("local-user-password-{0}-{1}.txt" -f (Get-SafeName -Value $username), $State.deployment_run_id)
        Set-Content -LiteralPath $passwordPath -Value @(
            "Username: $username",
            "Password: $plain",
            "Generated: $((Get-Date).ToString('o'))",
            'Rotate this password during final customer onboarding.'
        ) -Encoding UTF8 -Force
        Write-Log -Level Warn -Message "Generated password for $username was written to $passwordPath. Treat this file as sensitive."
        return $password
    }

    throw "Unsupported password_mode '$mode' for local user '$username'. Valid values: prompt, random."
}

function Add-UserToConfiguredGroups {
    param(
        [string]$Username,
        [object[]]$Groups
    )

    foreach ($group in @($Groups)) {
        $groupName = [string]$group
        if ([string]::IsNullOrWhiteSpace($groupName)) { continue }
        $members = @(Get-LocalGroupMember -Group $groupName -ErrorAction Stop | Select-Object -ExpandProperty Name)
        $localName = "$env:COMPUTERNAME\$Username"
        if ($members -notcontains $localName -and $members -notcontains $Username) {
            Add-LocalGroupMember -Group $groupName -Member $Username -ErrorAction Stop
            Write-Log -Level Success -Message "$Username was added to local group $groupName."
        } else {
            Write-Log -Level Success -Message "$Username is already a member of local group $groupName."
        }
    }
}

function Invoke-CreateLocalAdminStep {
    param(
        [string]$UsbRoot,
        [hashtable]$State,
        [string]$StatePath,
        [hashtable]$Config
    )

    $accounts = @(Get-LocalUserDefinitions -Config $Config)
    if ($accounts.Count -eq 0) {
        Write-Log -Level Info -Message 'Local user creation is disabled by config.'
        return
    }

    $primary = [string](Get-ConfigValue -Hash $Config -Key 'primary_setup_username' -Default '')
    if ([string]::IsNullOrWhiteSpace($primary)) {
        $markedPrimary = @($accounts | Where-Object { $_.ContainsKey('primary_setup_user') -and [bool]$_.primary_setup_user } | Select-Object -First 1)
        if ($markedPrimary.Count -gt 0) { $primary = [string]$markedPrimary[0].username }
    }
    if ([string]::IsNullOrWhiteSpace($primary) -and $accounts.Count -eq 1) { $primary = [string]$accounts[0].username }

    $createdUsers = @()
    foreach ($account in $accounts) {
        $username = [string](Get-ConfigValue -Hash $account -Key 'username' -Default '')
        if ([string]::IsNullOrWhiteSpace($username)) { throw 'Each additional_local_users entry must include username.' }

        $groups = @(Get-ConfigValue -Hash $account -Key 'groups' -Default @('Administrators'))
        if ($groups.Count -eq 0) { $groups = @('Users') }
        $description = [string](Get-ConfigValue -Hash $account -Key 'description' -Default '')
        $fullName = [string](Get-ConfigValue -Hash $account -Key 'full_name' -Default $username)
        $passwordNeverExpires = [bool](Get-ConfigValue -Hash $account -Key 'password_never_expires' -Default $true)

        $existing = Get-LocalUser -Name $username -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log -Level Success -Message "Local user $username already exists."
        } else {
            $password = New-ConfiguredLocalUserPassword -Account $account -Config $Config -State $State -UsbRoot $UsbRoot
            New-LocalUser -Name $username -Password $password -FullName $fullName -Description $description -PasswordNeverExpires:$passwordNeverExpires -ErrorAction Stop | Out-Null
            Write-Log -Level Success -Message "Local user $username was created."
        }

        Add-UserToConfiguredGroups -Username $username -Groups $groups
        $createdUsers += ,([ordered]@{
                username = $username
                groups   = $groups
                primary_setup_user = ($username -ieq $primary)
            })
    }

    if (-not [string]::IsNullOrWhiteSpace($primary)) {
        if (-not ($createdUsers | Where-Object { $_.username -ieq $primary })) {
            throw "primary_setup_username '$primary' does not match OSIT or any enabled additional_local_users entry."
        }
        $State.primary_setup_username = $primary
        Write-DeploymentState -State $State -StatePath $StatePath
        Write-Log -Level Info -Message "Primary setup user is configured as $primary."
        if ($env:USERNAME -ine $primary) {
            Write-Log -Level Warn -Message "Current session is running as $env:USERNAME. To continue under primary setup user $primary, sign out and sign in as $primary, then rerun Resume-Deployment.ps1 or Start-Deployment.ps1."
        }
    }

    $State.local_users = $createdUsers
    Write-DeploymentState -State $State -StatePath $StatePath
    Write-StructuredLog -Level Info -Message 'Local user configuration completed' -Data $createdUsers
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
        'NetworkDrivers' {
            if ([bool]$Config.install_network_drivers) { & (Join-Path $PSScriptRoot 'Install-NetworkDrivers.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'Network driver installation is disabled by config.' }
        }
        'MspWifiSetup' { & (Join-Path $PSScriptRoot 'Configure-MspWifi.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'Preflight' { & (Join-Path $PSScriptRoot 'Invoke-PreflightChecks.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'LocalHandover' { & (Join-Path $PSScriptRoot 'Invoke-LocalHandover.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'ConfigureComputerName' { Invoke-ComputerNameStep -UsbRoot $UsbRoot -State $State -StatePath $StatePath -Config $Config }
        'CreateLocalAdmin' { Invoke-CreateLocalAdminStep -UsbRoot $UsbRoot -State $State -StatePath $StatePath -Config $Config }
        'PowerSettings' {
            if ([bool]$Config.configure_power_settings) { & (Join-Path $PSScriptRoot 'Configure-PowerSettings.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'Power settings configuration is disabled by config.' }
        }
        'WindowsUpdates' { & (Join-Path $PSScriptRoot 'Install-WindowsUpdates.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'AssetInventory' {
            $reportRoot = Get-DeploymentReportRoot -UsbRoot $UsbRoot
            $inventoryPath = Join-Path $reportRoot "asset-inventory-$($State.deployment_run_id).json"
            & (Join-Path $PSScriptRoot 'Get-AssetInventory.ps1') -UsbRoot $UsbRoot -OutputPath $inventoryPath | Out-Null
        }
        'ModelDrivers' {
            if ([bool]$Config.install_offline_drivers) { & (Join-Path $PSScriptRoot 'Install-ModelDrivers.ps1') -UsbRoot $UsbRoot -StatePath $StatePath -NonInteractive:$NonInteractive }
            else { Write-Log -Level Info -Message 'Offline driver installation is disabled by config.' }
        }
        'WingetApps' {
            if ([bool]$Config.install_winget_apps) { & (Join-Path $PSScriptRoot 'Install-WingetApps.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'winget app installation is disabled by config.' }
        }
        'DattoRmm' { & (Join-Path $PSScriptRoot 'Install-DattoRmm.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'LocalApps' {
            if ([bool]$Config.install_local_apps) { & (Join-Path $PSScriptRoot 'Install-LocalApps.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'Local app installation is disabled by config.' }
        }
        'DesktopItems' {
            if ([bool]$Config.configure_desktop_items) { & (Join-Path $PSScriptRoot 'Configure-DesktopItems.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
            else { Write-Log -Level Info -Message 'Desktop item configuration is disabled by config.' }
        }
        'FinalReport' { & (Join-Path $PSScriptRoot 'Write-DeploymentReport.ps1') -UsbRoot $UsbRoot -StatePath $StatePath | Out-Null }
        'EmailReport' { & (Join-Path $PSScriptRoot 'Send-DeploymentEmail.ps1') -UsbRoot $UsbRoot -StatePath $StatePath }
        'Complete' {
            Unregister-DeploymentResumeTask
            $unattendPaths = @(
                "$env:windir\Panther\unattend.xml",
                "$env:windir\Panther\Autounattend.xml",
                "$env:windir\Panther\Unattend\unattend.xml",
                "$env:windir\Panther\UnattendGC\unattend.xml",
                "$env:windir\System32\sysprep\unattend.xml"
            )
            foreach ($xmlPath in $unattendPaths) {
                if (Test-Path -LiteralPath $xmlPath -PathType Leaf) {
                    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
                    Write-Log -Level Info -Message "Scrubbed cached unattend file at $xmlPath to protect credentials."
                }
            }
            # Unattend AutoLogon can leave the OSIT password in plaintext under Winlogon.
            $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            foreach ($valueName in @('DefaultPassword', 'AutoAdminLogon', 'AutoLogonCount')) {
                if (Get-ItemProperty -LiteralPath $winlogonKey -Name $valueName -ErrorAction SilentlyContinue) {
                    Remove-ItemProperty -LiteralPath $winlogonKey -Name $valueName -ErrorAction SilentlyContinue
                    Write-Log -Level Info -Message "Scrubbed Winlogon value $valueName to protect credentials."
                }
            }
            Write-Log -Level Success -Message 'Deployment task sequence complete. Device is ready for domain join / Entra join / customer onboarding.'
            Show-DeploymentToast -Title 'Windows 11 Deployment Complete' -Message "$env:COMPUTERNAME is ready for customer onboarding."
        }
        default { throw "Unknown deployment step '$Step'." }
    }
}

$runLock = Enter-DeploymentRunLock
if (-not $runLock.Acquired) {
    Write-Host 'Another deployment instance is already running on this device (resume task overlap or a manual re-run). Exiting without changing state.' -ForegroundColor Yellow
    Exit-DeploymentRunLock -Lock $runLock
    exit 0
}

$paths = $null
try {
    if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-DeploymentRoot }
    $paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
    $state = Initialize-StateForRun -StatePath $paths.StateFile -Reset:$Reset -NonInteractive:$NonInteractive
    Write-DeploymentState -State $state -StatePath $paths.StateFile
    Initialize-DeploymentLogging -UsbRoot $UsbRoot -State $state | Out-Null
    $config = Get-DeploymentConfig -UsbRoot $UsbRoot
    $steps = Get-DeploymentSteps

    $startMessage = if (@($state.completed_steps).Count -gt 0) { "Resuming from last successful step: $($state.last_successful_step)" } else { 'Deployment started' }
    Write-Log -Level Info -Message $startMessage
    Show-DeploymentToast -Title 'Windows 11 Deployment' -Message "$startMessage on $env:COMPUTERNAME."

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

        # Request-DeploymentReboot's exit only terminates the child step script, not this
        # orchestrator, so the reboot request must be detected here. The step is left
        # incomplete on purpose: it resumes from the same step after the reboot.
        if ($state.ContainsKey('reboot_pending') -and [bool]$state.reboot_pending) {
            Write-Log -Level Warn -Message "Step $step requested a reboot. The deployment will resume from this step after the next administrator logon."
            exit 3010
        }

        Set-StateStepCompleted -State $state -Step $step -StatePath $paths.StateFile
        Write-Log -Level Success -Message "Completed deployment step: $step"

        if ($step -eq 'LocalHandover') {
            $state = Read-DeploymentState -StatePath $paths.StateFile
            $handoverRoot = if ($state.ContainsKey('local_deployment_root')) { [string]$state.local_deployment_root } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($handoverRoot)) {
                $resolvedHandoverRoot = (Resolve-Path -LiteralPath $handoverRoot -ErrorAction SilentlyContinue).Path
                $resolvedCurrentRoot = (Resolve-Path -LiteralPath $UsbRoot -ErrorAction SilentlyContinue).Path
                if ($resolvedHandoverRoot -and ($resolvedHandoverRoot -ine $resolvedCurrentRoot)) {
                    # Switch the running orchestrator over to the local copy for every remaining
                    # step (and future resumes): reopen logging there first so nothing tries to
                    # keep writing to the USB once the technician ejects it.
                    $newPaths = Get-DeploymentPaths -UsbRoot $handoverRoot
                    Write-DeploymentState -State $state -StatePath $newPaths.StateFile
                    Stop-DeploymentLogging
                    $UsbRoot = $handoverRoot
                    $paths = $newPaths
                    $config = Get-DeploymentConfig -UsbRoot $UsbRoot
                    Initialize-DeploymentLogging -UsbRoot $UsbRoot -State $state | Out-Null
                    Write-Log -Level Success -Message "Deployment root switched to $UsbRoot after local handover. Remaining steps and resumes now use this path; the USB can be ejected."
                    Show-DeploymentToast -Title 'Windows 11 Deployment' -Message 'Deployment moved to local disk. The USB can now be ejected.'
                }
            }
        }
    }
} catch {
    $message = $_.Exception.Message
    Write-Log -Level Error -Message "Deployment failed: $message"
    Show-DeploymentToast -Title 'Windows 11 Deployment - Stopped' -Message "Deployment failed on $env:COMPUTERNAME`: $message"
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
    try {
        if ($paths -and (Test-Path -LiteralPath $paths.StateFile -PathType Leaf)) {
            & (Join-Path $PSScriptRoot 'Send-DeploymentEmail.ps1') -UsbRoot $UsbRoot -StatePath $paths.StateFile -Failure -FailureMessage $message | Out-Null
        }
    } catch {
        Write-Log -Level Warn -Message "Failed to send failure notification email: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host 'Deployment stopped. Review the log and report folders on the USB before rerunning.' -ForegroundColor Red
    exit 1
} finally {
    Stop-DeploymentLogging
    Exit-DeploymentRunLock -Lock $runLock
}
