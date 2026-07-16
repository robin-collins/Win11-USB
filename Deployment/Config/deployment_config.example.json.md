# deployment_config.example.json

This file documents the keys supported by `deployment_config.json`. Copy or edit `deployment_config.example.json` into `deployment_config.json` on the USB.

The active deployment script merges this config with built-in defaults. Values in `deployment_config.json` override the defaults.

## Disk And Windows Setup

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `minimum_free_space_gb` | number | `25` | Minimum free space required on the installed Windows system drive before deployment work continues. Preflight fails if the system drive is below this value. |
| `wipe_repartition_drive` | boolean | `false` | When `true`, `Initialize-UsbDeployment.ps1` generates a destructive `Autounattend.xml` that wipes the configured disk and creates the standard GPT/UEFI layout. |
| `wipe_repartition_disk_id` | number | `0` | Disk number to wipe when `wipe_repartition_drive` is `true`. Disk `0` is the normal internal OS disk target, but confirm hardware layout before enabling. |
| `wipe_minimum_disk_count` | number | `2` | Safety check: the generated USB refuses to wipe unless at least this many disks are visible in WinPE (the USB/boot media plus at least one internal disk; must be at least `2`) **and** the `wipe_repartition_disk_id` disk is strictly larger than every other visible disk. Guards against a missing storage driver leaving only the boot media visible, and against the USB/boot media enumerating at the configured target disk ID. This relative-size check replaced the earlier absolute `wipe_minimum_target_disk_gb`/`wipe_maximum_target_disk_gb` thresholds and `wipe_assert_*` WMI assertions, which false-failed on machines whose internal disk already had partitions from an existing Windows install. |
| `efi_partition_size_mb` | number | `512` | EFI System Partition size in MB. Used only when `wipe_repartition_drive` is `true`. |
| `msr_partition_size_mb` | number | `16` | Microsoft Reserved partition size in MB. Used only when `wipe_repartition_drive` is `true`. |
| `recovery_partition_size_mb` | number | `2048` | Windows Recovery partition size in MB. Used only when `wipe_repartition_drive` is `true`. |
| `windows_image_name` | string | `"Windows 11 Pro"` | Windows image name selected from the USB install media when automatic install targeting is enabled. |

`wipe_repartition_drive=true` is destructive. It cleans the target disk before Windows is installed.

## Preflight And Environment

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `require_ac_power` | boolean | `true` | If `true`, preflight fails on notebooks that appear to be running on battery. |
| `require_internet` | boolean | `true` | If `true`, preflight fails when internet connectivity checks fail. Required for Windows Update, winget, PSWindowsUpdate bootstrap, and Datto download. |
| `msp_wifi_setup` | object | see below | Optional early WiFi bootstrap used to connect to the MSP WiFi before preflight internet checks. |
| `fail_on_windows_home` | boolean | `true` | If `true`, preflight fails when the installed Windows edition appears to be Home/Core rather than Pro or higher. |
| `allow_continue_without_ac` | boolean | `false` | If `true`, a notebook on battery produces a warning instead of a failure. |
| `allow_continue_with_pending_reboot` | boolean | `false` | If `true`, an existing pending reboot produces a warning instead of a failure. Normally keep this `false`. |

### msp_wifi_setup keys

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enables the MSP WiFi setup step before preflight. |
| `ssid` | string | `"OneSolution"` | WiFi SSID to create/connect. |
| `password_env_var` | string | `"OSIT_WIFI_PASSWORD"` | Secret name used for the WiFi password. The documented standard is `OSIT_WIFI_PASSWORD`. |
| `authentication` | string | `"WPA2PSK"` | WLAN profile authentication mode. |
| `encryption` | string | `"AES"` | WLAN profile encryption mode. |
| `connect_timeout_seconds` | number | `60` | Maximum time to wait for the WiFi connection. |

The WiFi password is not stored in JSON. `Initialize-UsbDeployment.ps1` reads `OSIT_WIFI_PASSWORD` from the environment or `.env`, then writes it to the USB-root `.env` so the target machine can connect before internet-dependent stages.

### WiFi profile files (Deployment\WifiProfiles\)

An alternative to `msp_wifi_setup`'s discrete `ssid`/`password_env_var`/`authentication`/`encryption` fields: drop WLAN profile XML files exported via `netsh wlan export profile key=clear` into `Deployment\WifiProfiles\`.

- `Primary.xml`, if present, is imported directly for the primary network instead of building a profile from `msp_wifi_setup`'s fields -- no `OSIT_WIFI_PASSWORD` lookup happens in that case, since the exported file already carries its own key. `msp_wifi_setup.ssid` should still match the SSID inside `Primary.xml`; a mismatch produces a warning but the file's own SSID wins.
- Every other `.xml` file in the folder is a secondary profile, imported later by a dedicated `AdditionalWifiProfiles` step (see "Additional WiFi Profiles" below) -- typically a customer's own site network, captured ahead of time and not necessarily in range during deployment.
- `key=clear` means these files contain **plaintext WiFi passwords**. `Deployment\WifiProfiles\*` is gitignored (same treatment as `.env`) -- never commit real exported profiles.

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `configure_additional_wifi_profiles` | boolean | `true` | Enables the `AdditionalWifiProfiles` step, which imports every secondary profile in `Deployment\WifiProfiles\` (everything except `Primary.xml`). |
| `additional_wifi_profiles_connect_timeout_seconds` | number | `20` | Per-profile best-effort connection-verification timeout. A profile that cannot connect within this time is still imported and saved -- this is expected for a network not currently in range, not a failure. |

## Computer Name

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `computer_name_mode` | string | `"prompt"` | Controls rename behavior. Valid values: `prompt`, `serial`, `prefix_serial`, `skip`. |
| `computer_name_prefix` | string | `"NB"` | Prefix used when `computer_name_mode` is `prefix_serial`. |

If a rename is required, the toolkit records state, registers resume, and reboots.

## Power Settings

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `configure_power_settings` | boolean | `true` | Enables the power configuration step before Windows Updates. |
| `power_timeout_battery_minutes` | number | `60` | Timeout in minutes while on battery. `60` means one hour. `0` means never. |
| `power_timeout_ac_minutes` | number | `0` | Timeout in minutes while plugged in. `0` means never. |
| `power_manage_display_timeout` | boolean | `true` | Applies the timeout values to display-off settings. |
| `power_manage_sleep_timeout` | boolean | `true` | Applies the timeout values to sleep/standby settings. |
| `power_manage_hibernate_timeout` | boolean | `true` | Applies the timeout values to hibernate settings. Ignored when `power_disable_hibernate` is `true` (nothing left to time out to). |
| `power_disable_hibernate` | boolean | `true` | Runs `powercfg.exe /HIBERNATE OFF`, fully disabling hibernation (removes `hiberfil.sys` and the "Hibernate" option from the shutdown menu) and, as a side effect, disables Fast Startup (which depends on hibernation being available). Takes priority over `power_manage_hibernate_timeout`. |

The default means display and sleep timeout after one hour on battery and never while plugged in, with hibernation disabled entirely.

## Local Users

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `primary_setup_username` | string | `"OSIT"` | Preferred local account for technician setup work and resume context. |
| `final_resultant_user` | string | `"OSIT"` | User profile whose Desktop should represent the final technician-ready desktop. |
| `osit_local_admin_username` | string | `"OSIT"` | Always-present primary local admin account. Keep as `OSIT` unless the business standard changes. |
| `osit_local_admin_full_name` | string | `"OSIT Local Administrator"` | Full name applied to the OSIT local user. |
| `osit_local_admin_description` | string | `"Primary OSIT local administrator account"` | Description applied to the OSIT local user. |
| `additional_local_users` | array | see below | Optional additional local users created after OSIT. |
| `allow_random_password_export` | boolean | `false` | Required before any additional account can use `password_mode: "random"`. Generated passwords are written to reports and must be protected. |

The OSIT password is not stored in this JSON file. `Initialize-UsbDeployment.ps1` reads `OSIT_LOCAL_ADMIN_PASSWORD` from an environment variable or `.env`, then writes it into the generated USB-root `Autounattend.xml`.

### additional_local_users entries

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `username` | string | `"TechSupport"` | Local username to create. Must not be `OSIT`; OSIT is managed separately. |
| `full_name` | string | `"Technician Support"` | Full name for the local user. |
| `description` | string | `"Optional technician support account"` | Local user description. |
| `groups` | array of strings | `[ "Administrators" ]` | Local groups to add the user to. |
| `password_mode` | string | `"prompt"` | `prompt` asks the technician for a password. `random` generates one only when `allow_random_password_export=true`. |
| `password_never_expires` | boolean | `true` | Sets the local account password-never-expires flag. |
| `enabled` | boolean | `false` | Disabled entries are ignored. |
| `primary_setup_user` | boolean | `false` | Marks this user as the preferred setup user if `primary_setup_username` is not explicitly set. |

## System Tweaks

Runs after app installation, before desktop item cleanup, as the logged-on OSIT session -- so every setting below applies directly to the real interactive profile driving the deployment.

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `configure_system_tweaks` | boolean | `true` | Enables the bloatware removal / taskbar / hardening tweaks below. |
| `system_tweaks` | object | see below | Individual tweak toggles. |

### system_tweaks keys

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `remove_bloatware` | array of strings | `[ "RemoveBingSearch", "RemoveCortana", "RemoveZuneVideo", "RemoveStepsRecorder", "RemoveGetStarted", "RemoveWordPad", "RemoveXboxApps" ]` | Windows Appx/capability packages to remove. Valid ids are the keys `Get-BloatwareSelectors` (`Deployment\Scripts\Common.ps1`) returns; removing an id not present on the image is a harmless no-op. |
| `disable_widgets` | boolean | `true` | Disables the Widgets (news and interests) taskbar button via policy. |
| `left_align_taskbar` | boolean | `true` | Left-aligns the Windows 11 taskbar instead of centering it. |
| `disable_bing_search_suggestions` | boolean | `true` | Disables Bing web search suggestions in File Explorer's search box. |
| `taskbar_search_mode` | string | `"Hide"` | Taskbar search box display. Valid values: `Hide`, `Icon`, `Box`, `Label`. Restarts Explorer when set to anything other than `Box` so the change is immediately visible. |
| `show_end_task_in_taskbar` | boolean | `true` | Adds "End task" to the taskbar's right-click menu on running apps. |
| `launch_file_explorer_to_this_pc` | boolean | `true` | Opens File Explorer to This PC instead of Quick Access. |
| `enable_long_paths` | boolean | `true` | Sets `LongPathsEnabled`, lifting the 260-character `MAX_PATH` limit for apps that opt in. |
| `harden_system_drive_acl` | boolean | `true` | Removes the Authenticated Users group's write access to `C:\`. |
| `allow_powershell_scripts` | boolean | `true` | Sets the machine PowerShell execution policy to `RemoteSigned`. |
| `disable_sticky_keys` | boolean | `true` | Disables the 5x-Shift StickyKeys accessibility shortcut prompt. |
| `start_folders` | array of strings | `[ "Documents", "Downloads", "FileExplorer", "Network", "Pictures", "Settings" ]` | Folders pinned next to the Start menu's power button. Valid names: `Documents`, `Downloads`, `FileExplorer`, `Music`, `Network`, `PersonalFolder`, `Pictures`, `Settings`, `Videos` (spaces are ignored, so `"File Explorer"` also works). |

The specific commands behind `remove_bloatware` and `start_folders` (package/capability selectors, the Start-folder registry blob) are adapted from [cschneegans/unattend-generator](https://github.com/cschneegans/unattend-generator), vendored as a reference-only git submodule at `External\unattend-generator` -- see `Build-UnattendGeneratorLibrary.ps1`'s header for why this toolkit does not call that project's compiled library at runtime for settings this simple.

## Desktop Items

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `configure_desktop_items` | boolean | `true` | Enables final desktop cleanup after app installation. |
| `desktop_items` | object | see below | Desired desktop state configuration. |

### desktop_items keys

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `manage_common_desktop` | boolean | `true` | Manage `C:\Users\Public\Desktop`. This is where many installers place shortcuts for all users. |
| `manage_final_user_desktop` | boolean | `true` | Manage the Desktop folder for `final_resultant_user`. |
| `remove_unapproved_shortcuts` | boolean | `true` | Remove unapproved `.lnk` and `.url` files from managed Desktop folders. |
| `preserve_patterns` | array of strings | `[ "desktop.ini" ]` | File name patterns to preserve even when cleanup is enabled. |
| `common_desktop_items` | array | `[]` | Approved or created items for the Public Desktop. Empty means no common desktop shortcuts should remain. |
| `final_user_desktop_items` | array | `[]` | Approved or created items for the final user's Desktop. |

### Desktop item entries

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `name` | string | `"Company Portal"` | Shortcut file name. If no extension is supplied, `.lnk` is used for shortcuts and `.url` for URL items. |
| `type` | string | `"shortcut"` | Optional. `shortcut` creates a `.lnk`; `url` creates an internet shortcut. Defaults to `shortcut`. |
| `target_path` | string | `"C:\\Program Files\\App\\App.exe"` | Target executable for a `.lnk`. If omitted, the name is treated as approved-only and no shortcut is created. |
| `arguments` | string | `""` | Optional command-line arguments for a `.lnk`. |
| `working_directory` | string | `"C:\\Program Files\\App"` | Optional working directory for a `.lnk`. |
| `icon_path` | string | `"C:\\Program Files\\App\\App.exe,0"` | Optional icon location for a `.lnk`. |
| `url` | string | `"https://example.com"` | URL used when `type` is `url`. |
| `source_shortcut_path` | string | `"C:\\Path\\Shortcut.lnk"` | Copy an existing shortcut from an absolute path. |
| `source_shortcut_relative_path` | string | `"Deployment\\Apps\\Local\\Shortcuts\\App.lnk"` | Copy an existing shortcut from a path relative to the USB root. |
| `enabled` | boolean | `true` | Disabled items are ignored. |

## Windows Update

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `windows_update_max_cycles` | number | `5` | Maximum Windows Update scan/install/reboot cycles. |
| `pswindowsupdate_bootstrap` | boolean | `true` | Allows the toolkit to install/import `PSWindowsUpdate` from PowerShell Gallery if missing. |
| `windows_update_include_microsoft_update` | boolean | `true` | Attempts to include Microsoft Update content, not just Windows Update. |

If `PSWindowsUpdate` cannot be used, the script falls back to Windows Update COM automation.

## Application Installation

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `install_winget_apps` | boolean | `true` | Enables `winget_packages.json` installation. |
| `winget_bootstrap` | boolean | `false` | If `true` and winget is not yet available at first logon, re-registers App Installer and falls back to `Repair-WinGetPackageManager` before installing apps. If `false` (or bootstrap fails), preflight/install fails when winget is required but absent. |
| `install_local_apps` | boolean | `true` | Enables `local_apps.json` installation from `Deployment\Apps\Local`. |
| `fail_on_missing_required_app` | boolean | `true` | Required app failures stop the task sequence. |

## Datto RMM

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `datto_rmm_site_id_uuid` | string | `""` | Optional Datto site UUID. Blank means skip Datto RMM install. If present, preflight validates UUID format. |
| `datto_rmm_install_arguments` | string | `""` | Optional arguments passed to the downloaded Datto installer. |
| `datto_rmm_required` | boolean | `true` | If `true`, fail when the installer completes but Datto/CentraStage is not detected. |
| `datto_rmm_install_timeout_seconds` | number | `300` | Maximum time to wait for the installer. The installer is known to sometimes stay running after the agent is already installed, so the toolkit polls for the agent's presence alongside the process and stops waiting as soon as either is true, rather than only waiting for the process to exit. |

Datto installs after hostname, Windows Updates, model drivers, and winget apps, but before local USB apps.

## Drivers And Stop Point

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `install_offline_drivers` | boolean | `true` | Enables model-specific driver install from `Deployment\Drivers\<Manufacturer>\<Model>`, run after Windows Updates. |
| `install_network_drivers` | boolean | `true` | Enables the `NetworkDrivers` step, which runs first (before MSP WiFi setup and preflight) and installs every vendor folder under `Deployment\Drivers\Network\<Vendor>` (for example `Intel`, `Realtek`, `Qualcomm`). Use this to carry WiFi/NIC drivers for chips a bare Windows image does not have inbox drivers for, so the machine can reach the network before Preflight's internet check runs. Any subfolder name is tried; unrelated vendor packages are skipped harmlessly by pnputil rather than erroring. |
| `local_deployment_handover` | object | see below | Optional copy-to-local-disk step so the USB can be ejected before the remaining deployment steps finish. |
| `stop_before_domain_join` | boolean | `true` | Documents the intentional stop point. The toolkit does not domain join, Entra join, or customer identity join. |

### local_deployment_handover keys

| Key | Type | Example | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Enables the `LocalHandover` step, which runs after `Preflight` and before `ConfigureComputerName`, once a network connection (WiFi or Ethernet) has been established. |
| `local_path` | string | `"C:\\1S-WIN11"` | Local destination for a full copy of the `Deployment` folder (Config, Scripts, Apps, Drivers, Tools, and the current State/Logs/Reports) plus the USB-root `.env`. |
| `require_network` | boolean | `true` | If `true`, handover is skipped (not failed) when no network connection is currently available. Handover is not retried automatically later in the run, so a device that stays offline simply completes entirely from the USB. |

When handover succeeds, every remaining step (computer name, local admin, power settings, Windows Updates, drivers, apps, Datto RMM, desktop items, reports, email) runs from `local_path` instead of the USB, and the resume scheduled task and deployment logging are both switched over automatically. The console (and a toast notification) announce that the USB can be safely ejected. If the machine is offline when `LocalHandover` runs, the step is skipped and the whole deployment simply continues from the USB as it does today.
