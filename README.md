# Windows 11 Pro USB Deployment Toolkit

This repository extends an existing Microsoft Windows 11 installation USB labelled `1S-WIN11`.

It is designed for technician-led notebook deployment. It automates Windows setup handoff, preflight checks, Windows Update, model driver installation, app installation, asset capture, durable state, logging, and final reporting. It intentionally stops before domain join, Entra join, Autopilot registration, Intune enrollment, or any customer-specific identity work.

## What The Technician Sees

The technician boots from the USB, completes the normal Windows install choices unless automatic repartitioning is enabled, then signs in with the OSIT local admin created by `Autounattend.xml`. The deployment console opens, checks prerequisites first, prompts only where a decision is needed, writes progress after every successful step, and stops with a report saying the device is ready for final customer onboarding.

```mermaid
flowchart TD
  A["Boot from USB labelled 1S-WIN11"] --> B["Windows setup runs with Autounattend.xml"]
  B --> C{"wipe_repartition_drive enabled?"}
  C -->|"No"| D["Technician completes disk and install choices"]
  C -->|"Yes"| E["Disk 0 is wiped and partitioned automatically"]
  D --> F["OOBE network and account blocks are bypassed"]
  E --> F
  F --> G["OSIT logs on once"]
  G --> H["Start-Deployment.ps1 opens from the USB"]
  H --> I["Preflight checks"]
  I --> J["Computer name and local admin prompts if configured"]
  J --> K["Power settings"]
  K --> L["Windows Updates"]
  L --> M["Model driver check"]
  M --> N["winget apps"]
  N --> O["Datto RMM if site UUID configured"]
  O --> P["local USB apps"]
  P --> Q["Final desktop cleanup"]
  Q --> R["Asset inventory and final reports"]
  R --> S["Ready for domain join or Entra join"]
```

```mermaid
flowchart TD
  A["Step starts"] --> B{"Step succeeds?"}
  B -->|"Yes"| C["Write deployment_state.json"]
  C --> D{"Reboot needed?"}
  D -->|"No"| E["Continue next step"]
  D -->|"Yes"| F["Register resume scheduled task"]
  F --> G["Reboot"]
  G --> H["Resume after logon from next incomplete step"]
  B -->|"No"| I["Write failure state and report"]
  I --> J["Stop immediately for technician review"]
```

Expect these interaction points:

- Preflight failures stop before real work starts, so missing internet, wrong Windows edition, no AC power, missing config, or USB write problems are caught early.
- Reboots during rename or Windows Update are normal. The scheduled task resumes the same deployment on next logon.
- If a model driver folder is missing, the script creates the exact folder and lets the technician copy drivers and recheck, or continue without extra offline drivers.
- App installers only run when configured. Required app failures stop the run; optional app failures are logged.
- The final screen and report confirm that customer identity onboarding has not been performed.

## USB Layout

Copy this project to the root of the Windows 11 USB so the USB contains:

```text
Autounattend.xml
Deployment\
  Config\
  Scripts\
  State\
  Logs\
  Reports\
  Apps\
    Winget\
    Local\
  Drivers\
    Dell\
    HP\
    Lenovo\
    Generic\
  Tools\
```

The toolkit always finds the USB by volume label `1S-WIN11`, not by drive letter.

## Initialise Or Update The USB

From an elevated PowerShell prompt on an admin workstation:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Initialize-UsbDeployment.ps1
```

If you are preparing files in a staging folder and want to target a known USB path:

```powershell
.\Initialize-UsbDeployment.ps1 -UsbRoot E:\
```

## Configuration

Edit the active config files under `Deployment\Config`:

- `deployment_config.json`
- `winget_packages.json`
- `local_apps.json`

Matching `.example.json` files are included as templates.

Detailed config references:

- `Deployment\Config\deployment_config.example.json.md`
- `Deployment\Config\winget_packages.example.json.md`
- `Deployment\Config\local_apps.example.json.md`

Important `deployment_config.json` options:

- `wipe_repartition_drive`: when `true`, the generated USB `Autounattend.xml` wipes the configured disk and creates the standard OSIT UEFI/GPT layout before installing Windows. Default is `false`.
- `wipe_repartition_disk_id`: disk number to wipe. Default is `0`.
- `efi_partition_size_mb`, `msr_partition_size_mb`, `recovery_partition_size_mb`: default to `512`, `16`, and `2048`.
- `windows_image_name`: image name to install from the USB. Default is `Windows 11 Pro`.
- `require_ac_power`: fail preflight on battery power for notebooks.
- `require_internet`: fail preflight when Windows Update and winget cannot reach the internet.
- `windows_update_max_cycles`: maximum update/reboot scan cycles. Default is `5`.
- `computer_name_mode`: `prompt`, `serial`, `prefix_serial`, or `skip`.
- `configure_power_settings`: sets power timeouts before long-running update and install stages.
- `power_timeout_battery_minutes`: defaults to `60`, meaning display/sleep/hibernate after 1 hour on battery.
- `power_timeout_ac_minutes`: defaults to `0`, meaning never while plugged in.
- `osit_local_admin_username`: defaults to `OSIT`. This is the always-present primary local admin.
- `primary_setup_username`: defaults to `OSIT`.
- `final_resultant_user`: user profile whose Desktop should represent the final technician-ready desktop. Defaults to `OSIT`.
- `additional_local_users`: creates optional extra local accounts. Each entry supports `username`, `full_name`, `description`, `groups`, `password_mode`, `password_never_expires`, `enabled`, and `primary_setup_user`.
- `configure_desktop_items`: runs final desktop cleanup after app installation.
- `desktop_items`: controls Public Desktop and final user Desktop desired state.
- `datto_rmm_site_id_uuid`: optional Datto RMM site UUID. When present, Datto installs after hostname, Windows Updates, drivers, and winget, but before local USB apps.
- `datto_rmm_install_arguments`: optional arguments passed to the Datto installer.
- `datto_rmm_required`: when `true`, fail if the installer completes but Datto/CentraStage is not detected.
- `install_winget_apps`, `install_local_apps`, `install_offline_drivers`: enable or skip those phases.
- `stop_before_domain_join`: documents the intended stopping point. The scripts do not perform customer identity joins.

Do not store customer domain credentials in any config file.

The OSIT password is not stored in `deployment_config.json`. `Initialize-UsbDeployment.ps1` reads it from either:

- environment variable: `OSIT_LOCAL_ADMIN_PASSWORD`
- `.env` in the toolkit folder: `OSIT_LOCAL_ADMIN_PASSWORD=...`

If neither exists, `Initialize-UsbDeployment.ps1` prompts to create one.

Example additional local account config:

```json
"primary_setup_username": "OSIT",
"additional_local_users": [
  {
    "username": "TechSupport",
    "full_name": "Technician Support",
    "description": "Optional technician support account",
    "groups": [ "Administrators" ],
    "password_mode": "prompt",
    "password_never_expires": true,
    "enabled": true,
    "primary_setup_user": false
  }
]
```

Example desktop config:

```json
"final_resultant_user": "OSIT",
"configure_desktop_items": true,
"desktop_items": {
  "manage_common_desktop": true,
  "manage_final_user_desktop": true,
  "remove_unapproved_shortcuts": true,
  "preserve_patterns": [ "desktop.ini" ],
  "common_desktop_items": [],
  "final_user_desktop_items": [
    {
      "name": "Company Portal",
      "type": "url",
      "url": "https://portal.manage.microsoft.com",
      "enabled": false
    }
  ]
}
```

With `remove_unapproved_shortcuts=true` and an empty `common_desktop_items` list, winget/MSI shortcuts dropped onto the Public Desktop are removed. Add approved entries to keep or create only the shortcuts you want.

Example Datto RMM config:

```json
"datto_rmm_site_id_uuid": "1193f864-66b2-49fd-bafe-950ba1e803e5",
"datto_rmm_install_arguments": "",
"datto_rmm_required": true
```

The Datto UUID is validated during preflight. If it is blank, the Datto install step is skipped.

## Security Notes

`Autounattend.xml` creates the OSIT local administrator account and auto-logs it on once to start the deployment console.

The repository `Autounattend.xml` contains the placeholder `__OSIT_LOCAL_ADMIN_PASSWORD__`. `Initialize-UsbDeployment.ps1` replaces that placeholder when writing the USB-root `Autounattend.xml`. The generated USB answer file contains the OSIT password in plaintext because Windows setup requires it for local account creation and auto-logon. Protect physical access to the USB.

There are two account stages:

- `Autounattend.xml`: controls the always-present OSIT account that logs in first and launches the deployment console.
- `Deployment\Config\deployment_config.json`: controls optional extra accounts. Use `additional_local_users` only when accounts beyond OSIT are required.

The script does not silently switch Windows sessions after creating accounts. If `primary_setup_username` differs from the current logged-in user, the console warns the technician to sign out and sign in as the primary setup user before continuing or resuming.

If an additional account `password_mode` is set to `random`, the toolkit only generates the password when `allow_random_password_export` is also `true`, because otherwise the credential would be lost. Generated password reports are sensitive and must be protected.

## Autounattend

Place `Autounattend.xml` at the USB root.

The repository `Autounattend.xml` is a template. `Initialize-UsbDeployment.ps1` writes the real USB-root file after injecting the OSIT password and, if configured, the disk partitioning block.

By default, `wipe_repartition_drive` is `false`, so disk selection, deletion, partitioning, and image selection remain technician-led.

When `wipe_repartition_drive` is `true`, the generated USB answer file wipes `wipe_repartition_disk_id` and creates this GPT/UEFI layout:

| Partition | Filesystem | Size | Notes |
| --- | --- | ---: | --- |
| EFI System (ESP) | FAT32 | 512 MB | Larger than Microsoft's minimum. |
| MSR | None | 16 MB | Microsoft's standard. |
| Windows (C:) | NTFS | Remaining space minus WinRE | Main OS partition. |
| Windows Recovery (WinRE) | NTFS | 2 GB | Room for future WinRE updates and recovery tools. |

The generated file:

- can wipe and repartition the configured disk when `wipe_repartition_drive` is `true`.
- sets OOBE options to avoid Microsoft account and network blocking prompts.
- writes the Windows 11 `BypassNRO` registry value during setup instead of requiring `Shift+F10` and `oobe\BypassNRO.cmd`.
- creates the `OSIT` local administrator.
- auto-logs on once and starts `Deployment\Scripts\Start-Deployment.ps1` from the USB found by label.

Treat `wipe_repartition_drive=true` as destructive. It is intended for standardised deployments where disk 0 is the target OS disk.

Validate the repository template:

```powershell
.\Validate-Unattend.ps1
```

Validate a generated USB-root answer file:

```powershell
.\Validate-Unattend.ps1 -Path E:\Autounattend.xml -Generated -ConfigPath E:\Deployment\Config\deployment_config.json
```

For full Microsoft schema validation, install the Windows ADK or pass `-DllPath` pointing to `Microsoft.ComponentStudio.ComponentPlatformInterface.dll`. Without that DLL, the validator still performs XML and toolkit-specific semantic checks.

To let the validator install the ADK packages with winget when the schema DLL is missing:

```powershell
.\Validate-Unattend.ps1 -InstallAdkWithWinget -RequireSchema
```

This uses winget IDs `Microsoft.WindowsADK` and `Microsoft.WindowsADK.WinPEAddon`.

The `windowsPE` pass is the Windows Setup phase that runs inside Windows PE before the installed operating system is applied. This toolkit uses it only in generated answer files when `wipe_repartition_drive=true`, because that is where disk wipe, GPT partitioning, and image install target settings must be applied.

## Driver Folders

Drivers must be stored as:

```text
Deployment\Drivers\<Manufacturer>\<Model>
```

Examples:

```text
Deployment\Drivers\HP\Pro_x360_435_G10
Deployment\Drivers\Dell\Latitude_5440
Deployment\Drivers\Lenovo\ThinkPad_T14_G4
```

Manufacturer names are normalised, for example:

- `HP Inc.` and `Hewlett-Packard` become `HP`
- `Dell Inc.` becomes `Dell`
- `LENOVO` becomes `Lenovo`

Model names are normalised by removing common noisy words and replacing spaces or invalid path characters with underscores.

After Windows Updates complete, `Install-ModelDrivers.ps1` detects the model and checks the expected folder:

- folder exists with `.inf` files: installs them with `pnputil /add-driver /subdirs /install`.
- folder exists but is empty: treats this as intentional and continues.
- folder is missing: creates it, shows the exact path, and lets the technician recheck after copying drivers or continue without offline drivers.

## App Installation

### winget

`Deployment\Config\winget_packages.json` contains package entries:

```json
{ "id": "Google.Chrome", "display_name": "Google Chrome", "required": true, "install_arguments": "" }
```

The script checks whether each package is already installed before installing it and accepts source/package agreements. Required package failures stop the task sequence when `fail_on_missing_required_app` is `true`.

### Local USB Apps

Place installers under:

```text
Deployment\Apps\Local
```

Configure each one in `Deployment\Config\local_apps.json`. Supported installer types are:

- `exe`
- `msi`
- `msix`
- `appx`
- `script`

Local installers are never run just because they exist. They must be explicitly configured with silent arguments and detection logic.

## State, Logs, And Reports

State is stored at:

```text
Deployment\State\deployment_state.json
```

After each successful step, the toolkit records device identity, current step, completed steps, timestamps, Windows build, manufacturer/model, run ID, last successful step, and errors.

Logs are written to:

```text
Deployment\Logs\<SerialOrComputerName>\<RunId>\
```

Reports are written to:

```text
Deployment\Reports\<SerialOrComputerName>\
```

Each run writes:

- PowerShell transcript log.
- JSONL structured event log.
- command stdout/stderr logs.
- JSON deployment report.
- Markdown deployment summary.
- JSON asset inventory.

## Resume And Reboot Handling

The toolkit registers a scheduled task named `OneSolutionWin11DeploymentResume` when a reboot is required. Repeated runs use the same task name and replace it rather than creating duplicates.

On rerun, the script:

- loads `deployment_state.json`.
- confirms serial number or UUID matches the current device.
- shows the last successful step.
- resumes from the next incomplete step.
- offers a safe restart-from-scratch option when running interactively.

Run manually at any time:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Deployment\Scripts\Start-Deployment.ps1
```

To force a new run:

```powershell
.\Deployment\Scripts\Start-Deployment.ps1 -Reset
```

## Workflow

1. Create a Windows 11 USB with Microsoft `mediacreationtool.exe`.
2. Set the USB volume label to `1S-WIN11`.
3. Copy this toolkit to the USB root or run `Initialize-UsbDeployment.ps1`.
4. Edit config files under `Deployment\Config`.
5. Add model drivers under `Deployment\Drivers\<Manufacturer>\<Model>` when available.
6. Add configured local installers under `Deployment\Apps\Local`.
7. Boot the target notebook from the USB.
8. Install Windows 11 Pro using the technician-led setup flow, or let `wipe_repartition_drive=true` wipe and target disk 0 automatically.
9. Let `Autounattend.xml` bypass OOBE network/account blocking and launch the deployment script.
10. Follow prompts for computer name, local admin password, and any missing driver folder decision.
11. Review the final report.
12. Perform final customer onboarding manually: domain join, Entra join, Autopilot/Intune, customer apps, and handover steps.

## Failure Behaviour

Critical prerequisite failures stop immediately. Runtime task failures are written to state and reports before the script exits.

The toolkit does not continue blindly after a failed required update, driver, or app phase. Fix the cause, rerun `Start-Deployment.ps1`, and resume from the next incomplete step.
