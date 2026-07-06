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

function Get-ConfigValue {
    param(
        [hashtable]$Hash,
        [string]$Key,
        [object]$Default = $null
    )

    if ($Hash -and $Hash.ContainsKey($Key) -and $null -ne $Hash[$Key]) { return $Hash[$Key] }
    return $Default
}

function Get-DesktopItemConfig {
    param([hashtable]$Config)

    $defaults = @{
        manage_common_desktop = $true
        manage_final_user_desktop = $true
        remove_unapproved_shortcuts = $true
        preserve_patterns = @('desktop.ini')
        common_desktop_items = @()
        final_user_desktop_items = @()
    }

    if ($Config.ContainsKey('desktop_items') -and $null -ne $Config.desktop_items) {
        $override = ConvertTo-PlainHashtable $Config.desktop_items
        foreach ($key in $override.Keys) { $defaults[$key] = $override[$key] }
    }
    return $defaults
}

function Get-CommonDesktopPath {
    $path = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $env:PUBLIC 'Desktop' }
    New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
    return $path
}

function Get-UserDesktopPath {
    param([Parameter(Mandatory = $true)][string]$Username)

    $profile = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Special -and
            $_.LocalPath -and
            ((Split-Path -Leaf $_.LocalPath) -ieq $Username)
        } |
        Select-Object -First 1

    $profilePath = if ($profile) { $profile.LocalPath } else { Join-Path 'C:\Users' $Username }
    $desktopPath = Join-Path $profilePath 'Desktop'
    New-Item -ItemType Directory -Path $desktopPath -Force -ErrorAction Stop | Out-Null
    return $desktopPath
}

function Get-ShortcutFileName {
    param([hashtable]$Item)

    $name = [string](Get-ConfigValue -Hash $Item -Key 'name' -Default '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Desktop item entry is missing name.' }
    $type = ([string](Get-ConfigValue -Hash $Item -Key 'type' -Default 'shortcut')).ToLowerInvariant()

    if ([IO.Path]::GetExtension($name)) { return $name }
    if ($type -eq 'url') { return "$name.url" }
    return "$name.lnk"
}

function Resolve-DesktopItemSource {
    param(
        [hashtable]$Item,
        [string]$UsbRoot
    )

    $sourcePath = [string](Get-ConfigValue -Hash $Item -Key 'source_shortcut_path' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sourcePath)) { return $sourcePath }

    $relativePath = [string](Get-ConfigValue -Hash $Item -Key 'source_shortcut_relative_path' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($relativePath)) { return (Join-Path $UsbRoot $relativePath) }

    return ''
}

function Write-DesktopItem {
    param(
        [hashtable]$Item,
        [string]$DesktopPath,
        [string]$UsbRoot
    )

    if ($Item.ContainsKey('enabled') -and -not [bool]$Item.enabled) {
        return [ordered]@{ name = $Item.name; action = 'SkippedDisabled' }
    }

    $fileName = Get-ShortcutFileName -Item $Item
    $destination = Join-Path $DesktopPath $fileName
    $source = Resolve-DesktopItemSource -Item $Item -UsbRoot $UsbRoot
    if (-not [string]::IsNullOrWhiteSpace($source)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Configured desktop source item missing: $source" }
        Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        return [ordered]@{ name = $fileName; action = 'Copied'; path = $destination; source = $source }
    }

    $type = ([string](Get-ConfigValue -Hash $Item -Key 'type' -Default 'shortcut')).ToLowerInvariant()
    if ($type -eq 'url') {
        $url = [string](Get-ConfigValue -Hash $Item -Key 'url' -Default '')
        if ([string]::IsNullOrWhiteSpace($url)) {
            return [ordered]@{ name = $fileName; action = 'ApprovedOnly'; path = $destination }
        }
        Set-Content -LiteralPath $destination -Value @('[InternetShortcut]', "URL=$url") -Encoding ASCII -Force -ErrorAction Stop
        return [ordered]@{ name = $fileName; action = 'CreatedUrl'; path = $destination; url = $url }
    }

    $target = [string](Get-ConfigValue -Hash $Item -Key 'target_path' -Default '')
    if ([string]::IsNullOrWhiteSpace($target)) {
        return [ordered]@{ name = $fileName; action = 'ApprovedOnly'; path = $destination }
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($destination)
    $shortcut.TargetPath = $target
    $arguments = [string](Get-ConfigValue -Hash $Item -Key 'arguments' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($arguments)) { $shortcut.Arguments = $arguments }
    $workingDirectory = [string](Get-ConfigValue -Hash $Item -Key 'working_directory' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) { $shortcut.WorkingDirectory = $workingDirectory }
    $iconPath = [string](Get-ConfigValue -Hash $Item -Key 'icon_path' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($iconPath)) { $shortcut.IconLocation = $iconPath }
    $shortcut.Save()

    return [ordered]@{ name = $fileName; action = 'CreatedShortcut'; path = $destination; target = $target }
}

function Sync-DesktopItems {
    param(
        [string]$DesktopPath,
        [object[]]$DesiredItems,
        [object[]]$PreservePatterns,
        [bool]$RemoveUnapproved,
        [string]$UsbRoot
    )

    $enabledItems = @($DesiredItems | ForEach-Object { ConvertTo-PlainHashtable $_ } | Where-Object { -not ($_.ContainsKey('enabled') -and -not [bool]$_.enabled) })
    $approvedNames = @()
    foreach ($item in $enabledItems) { $approvedNames += (Get-ShortcutFileName -Item $item) }

    $removed = @()
    if ($RemoveUnapproved) {
        $shortcutFiles = @(Get-ChildItem -LiteralPath $DesktopPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.lnk', '.url') })
        foreach ($file in $shortcutFiles) {
            $preserved = $false
            foreach ($pattern in @($PreservePatterns)) {
                if ($file.Name -like [string]$pattern) { $preserved = $true; break }
            }
            if ($approvedNames -contains $file.Name -or $preserved) { continue }
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removed += ,$file.Name
        }
    }

    $written = @()
    foreach ($item in $enabledItems) {
        $written += ,(Write-DesktopItem -Item $item -DesktopPath $DesktopPath -UsbRoot $UsbRoot)
    }

    return [ordered]@{
        desktop_path = $DesktopPath
        removed = $removed
        written = $written
    }
}

if (-not [bool]$config.configure_desktop_items) {
    Write-Log -Level Info -Message 'Desktop item configuration is disabled by config.'
    return
}

$desktopConfig = Get-DesktopItemConfig -Config $config
$finalUser = [string](Get-ConfigValue -Hash $config -Key 'final_resultant_user' -Default $config.primary_setup_username)
if ([string]::IsNullOrWhiteSpace($finalUser)) { $finalUser = 'OSIT' }

$results = @()
if ([bool]$desktopConfig.manage_common_desktop) {
    $results += ,(Sync-DesktopItems -DesktopPath (Get-CommonDesktopPath) -DesiredItems @($desktopConfig.common_desktop_items) -PreservePatterns @($desktopConfig.preserve_patterns) -RemoveUnapproved ([bool]$desktopConfig.remove_unapproved_shortcuts) -UsbRoot $UsbRoot)
}

if ([bool]$desktopConfig.manage_final_user_desktop) {
    $results += ,(Sync-DesktopItems -DesktopPath (Get-UserDesktopPath -Username $finalUser) -DesiredItems @($desktopConfig.final_user_desktop_items) -PreservePatterns @($desktopConfig.preserve_patterns) -RemoveUnapproved ([bool]$desktopConfig.remove_unapproved_shortcuts) -UsbRoot $UsbRoot)
}

if ($state) {
    $state.final_resultant_user = $finalUser
    $state.desktop_items = $results
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'Desktop item configuration completed' -Data $results
Write-Log -Level Success -Message "Desktop items configured for final user '$finalUser'."
