<#
    .SYNOPSIS
        Applies technician-curated bloatware removal, taskbar/Explorer tweaks, and system
        hardening toggles, driven by deployment_config.json's system_tweaks block.

    .DESCRIPTION
        Runs late in the task sequence (after app installation, before desktop item cleanup) as
        the logged-on OSIT session, so every per-user (HKCU) tweak here applies directly to the
        real interactive profile driving this deployment -- no offline default-user-hive loading
        is needed the way a pre-logon answer file would require.

        The specific settings and their exact underlying commands (bloatware package/capability
        selectors, Start-folder registry blob) are adapted from cschneegans/unattend-generator
        (External\unattend-generator, a reference-only git submodule -- see
        Build-UnattendGeneratorLibrary.ps1's header for why this repo does not call that project's
        compiled library at runtime for settings this simple).
#>
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
$tweaks = ConvertTo-PlainHashtable $config.system_tweaks

function Invoke-SystemTweak {
    <#
        .SYNOPSIS
            Central dry-run/real-action switch for this script, matching the
            Test-DeploymentDryRun / Write-DryRunAction convention used throughout Deployment\Scripts.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][hashtable]$DryRunData,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    if (Test-DeploymentDryRun) {
        Write-DryRunAction -State $state -Step 'SystemTweaks' -Action "would $Description" -Data $DryRunData
        return
    }
    & $Action
}

if (-not [bool]$config.configure_system_tweaks) {
    Write-Log -Level Info -Message 'System tweaks configuration is disabled by config.'
    return
}

$bloatwareIds = @($tweaks.remove_bloatware)
if ($bloatwareIds.Count -gt 0) {
    $catalog = Get-BloatwareSelectors
    $unknownIds = @($bloatwareIds | Where-Object { -not $catalog.ContainsKey($_) })
    if ($unknownIds.Count -gt 0) {
        throw "system_tweaks.remove_bloatware contains unknown id(s): $($unknownIds -join ', '). Known ids: $($catalog.Keys -join ', ')."
    }

    # Bracket notation, not dot notation: under Set-StrictMode -Version 2.0, a hashtable's own
    # dot-notation property access throws for a key that is absent (e.g. RemoveStepsRecorder has
    # no 'Packages' key, only 'Capabilities') -- confirmed by reproducing this exact failure in a
    # real dry run before switching to bracket notation, which returns $null instead.
    $packageSelectors = @($bloatwareIds | ForEach-Object { $catalog[$_]['Packages'] } | Where-Object { $_ })
    $capabilitySelectors = @($bloatwareIds | ForEach-Object { $catalog[$_]['Capabilities'] } | Where-Object { $_ })

    if ($packageSelectors.Count -gt 0) {
        Invoke-SystemTweak -Description "remove provisioned package(s): $($packageSelectors -join ', ')" -DryRunData ([ordered]@{ packages = $packageSelectors }) -Action {
            Get-AppxProvisionedPackage -Online |
                Where-Object { $packageSelectors -contains $_.DisplayName } |
                Remove-AppxProvisionedPackage -AllUsers -Online -ErrorAction Continue | Out-Null
        }
    }

    if ($capabilitySelectors.Count -gt 0) {
        Invoke-SystemTweak -Description "remove Windows capability(-ies): $($capabilitySelectors -join ', ')" -DryRunData ([ordered]@{ capabilities = $capabilitySelectors }) -Action {
            Get-WindowsCapability -Online |
                Where-Object { ($capabilitySelectors -contains ($_.Name -split '~')[0]) -and $_.State -notin @('NotPresent', 'Removed') } |
                Remove-WindowsCapability -Online -ErrorAction Continue | Out-Null
        }
    }

    foreach ($id in $bloatwareIds) {
        $defaultUserRegistry = $catalog[$id]['DefaultUserRegistry']
        if ($defaultUserRegistry) {
            Invoke-SystemTweak -Description "set $($defaultUserRegistry.Path)\$($defaultUserRegistry.Name) = $($defaultUserRegistry.Value) (part of $id)" -DryRunData ([ordered]@{ path = $defaultUserRegistry.Path; name = $defaultUserRegistry.Name; value = $defaultUserRegistry.Value }) -Action {
                if (-not (Test-Path -LiteralPath $defaultUserRegistry.Path)) { New-Item -Path $defaultUserRegistry.Path -Force | Out-Null }
                Set-ItemProperty -LiteralPath $defaultUserRegistry.Path -Name $defaultUserRegistry.Name -Value $defaultUserRegistry.Value -Type DWord -Force
            }
        }
    }
}

if ([bool]$tweaks.disable_widgets) {
    Invoke-SystemTweak -Description 'disable Widgets (news and interests)' -DryRunData ([ordered]@{ path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; name = 'AllowNewsAndInterests' }) -Action {
        if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh')) { New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Force | Out-Null }
        Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type DWord -Force
    }
}

if ([bool]$tweaks.left_align_taskbar) {
    Invoke-SystemTweak -Description 'left-align the taskbar' -DryRunData ([ordered]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'TaskbarAl' }) -Action {
        Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarAl' -Value 0 -Type DWord -Force
    }
}

if ([bool]$tweaks.disable_bing_search_suggestions) {
    Invoke-SystemTweak -Description 'disable Bing web search suggestions in File Explorer search' -DryRunData ([ordered]@{ path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; name = 'DisableSearchBoxSuggestions' }) -Action {
        if (-not (Test-Path -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\Explorer')) { New-Item -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Force | Out-Null }
        Set-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -Value 1 -Type DWord -Force
    }
}

if ($tweaks.taskbar_search_mode) {
    $searchModes = @{ Hide = 0; Icon = 1; Box = 2; Label = 3 }
    $requestedMode = [string]$tweaks.taskbar_search_mode
    if (-not $searchModes.ContainsKey($requestedMode)) {
        throw "system_tweaks.taskbar_search_mode '$requestedMode' is invalid. Valid values: $($searchModes.Keys -join ', ')."
    }
    $searchModeValue = $searchModes[$requestedMode]
    Invoke-SystemTweak -Description "set taskbar search box mode to $requestedMode" -DryRunData ([ordered]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; name = 'SearchboxTaskbarMode'; value = $searchModeValue }) -Action {
        Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value $searchModeValue -Type DWord -Force
    }
    if ($requestedMode -ne 'Box') {
        # Matches modifier\Optimizations.cs: this is the one setting in this script the library
        # itself restarts Explorer for -- the taskbar does not pick up a changed search box mode
        # live otherwise.
        Invoke-SystemTweak -Description 'restart Explorer so the new taskbar search box mode takes visible effect' -DryRunData ([ordered]@{ process = 'explorer.exe' }) -Action {
            Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            if (-not (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) { Start-Process -FilePath 'explorer.exe' }
        }
    }
}

if ([bool]$tweaks.show_end_task_in_taskbar) {
    Invoke-SystemTweak -Description 'show "End task" in the taskbar right-click menu' -DryRunData ([ordered]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; name = 'TaskbarEndTask' }) -Action {
        if (-not (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings')) { New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' -Force | Out-Null }
        Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' -Name 'TaskbarEndTask' -Value 1 -Type DWord -Force
    }
}

if ([bool]$tweaks.launch_file_explorer_to_this_pc) {
    Invoke-SystemTweak -Description 'open File Explorer to This PC instead of Quick Access' -DryRunData ([ordered]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'LaunchTo' }) -Action {
        Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Value 1 -Type DWord -Force
    }
}

if ([bool]$tweaks.enable_long_paths) {
    Invoke-SystemTweak -Description 'enable long path support (LongPathsEnabled)' -DryRunData ([ordered]@{ path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; name = 'LongPathsEnabled' }) -Action {
        Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord -Force
    }
}

if ([bool]$tweaks.harden_system_drive_acl) {
    Invoke-SystemTweak -Description 'remove Authenticated Users write access from C:\' -DryRunData ([ordered]@{ file_path = 'icacls.exe'; arguments = @('C:\', '/remove:g', '*S-1-5-11') }) -Action {
        Invoke-ExternalCommand -FilePath icacls.exe -Arguments @('C:\', '/remove:g', '*S-1-5-11') -LogName 'icacls-harden-system-drive.log' | Out-Null
    }
}

if ([bool]$tweaks.allow_powershell_scripts) {
    Invoke-SystemTweak -Description 'set the machine PowerShell execution policy to RemoteSigned' -DryRunData ([ordered]@{ scope = 'LocalMachine'; execution_policy = 'RemoteSigned' }) -Action {
        Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force
    }
}

if ([bool]$tweaks.disable_sticky_keys) {
    # SKF_AVAILABLE | SKF_CONFIRMHOTKEY only (no HotKeyActive, Indicator, TriState, TwoKeysOff,
    # AudibleFeedback, or HotKeySound flags) -- matches modifier\Optimizations.cs's
    # DisabledStickyKeysSettings: the 5x-Shift toggle no longer does anything.
    $stickyKeysFlags = '506'
    Invoke-SystemTweak -Description 'disable the StickyKeys 5x-Shift accessibility shortcut' -DryRunData ([ordered]@{ path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; name = 'Flags'; value = $stickyKeysFlags }) -Action {
        Set-ItemProperty -LiteralPath 'HKCU:\Control Panel\Accessibility\StickyKeys' -Name 'Flags' -Value $stickyKeysFlags -Type String -Force
    }
}

$startFolderNames = @($tweaks.start_folders)
if ($startFolderNames.Count -gt 0) {
    $blob = Get-StartFolderBlob -Names $startFolderNames
    Invoke-SystemTweak -Description "pin Start folders next to the power button: $($startFolderNames -join ', ')" -DryRunData ([ordered]@{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'; name = 'VisiblePlaces'; folders = $startFolderNames }) -Action {
        Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' -Name 'VisiblePlaces' -Value $blob -Type Binary -Force
    }
}

$summary = [ordered]@{
    bloatware_removed  = $bloatwareIds
    start_folders       = $startFolderNames
    timestamp          = (Get-Date).ToString('o')
}
if ($state) {
    $state.system_tweaks = $summary
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'System tweaks applied' -Data $summary
Write-Log -Level Success -Message "System tweaks applied: $($bloatwareIds.Count) bloatware item(s) removed, $($startFolderNames.Count) Start folder(s) configured."
