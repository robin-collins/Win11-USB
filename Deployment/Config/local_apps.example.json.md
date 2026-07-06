# local_apps.example.json

This file documents `local_apps.json`, which controls local USB installers under `Deployment\Apps\Local`.

The file has one top-level key:

| Key | Type | Meaning |
| --- | --- | --- |
| `apps` | array | List of local installer entries. Empty means no local USB apps are installed. |

Local installers are never run just because they exist on the USB. They must be explicitly configured here.

## App Entry Keys

| Key | Type | Required | Example | Meaning |
| --- | --- | --- | --- | --- |
| `name` | string | yes | `"Example MSI App"` | Friendly app name used in output, logs, and generated log file names. |
| `relative_path` | string | yes | `"Example\\installer.msi"` | Installer path relative to `Deployment\Apps\Local`. |
| `installer_type` | string | yes | `"msi"` | Installer handler. Supported values: `exe`, `msi`, `msix`, `appx`, `script`. |
| `silent_arguments` | string | no | `"/qn /norestart"` | Arguments passed to the installer. Use silent/no-restart switches suitable for that installer. |
| `detection` | object | recommended | see below | Detection rule used to skip already-installed apps. |
| `required` | boolean | no | `false` | If `true`, missing installer or failed install stops the task sequence when required-app failure is enabled. |
| `reboot_behavior` | string | no | `"suppress"` | Currently metadata for documenting expected installer behavior. The script allows common reboot-required exit codes but does not reboot from this key. |

## installer_type Behavior

| installer_type | Behavior |
| --- | --- |
| `msi` | Runs `msiexec.exe /i <installer> <silent_arguments>`. If `silent_arguments` is blank, defaults to `/qn /norestart`. |
| `exe` | Runs the executable directly with `silent_arguments`. |
| `msix` | Runs `Add-AppxPackage -Path <installer>`. |
| `appx` | Runs `Add-AppxPackage -Path <installer>`. |
| `script` | Runs `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> <silent_arguments>`. |

Accepted success/reboot-required exit codes for `exe`, `msi`, and `script` include `0`, `3010`, and MSI reboot code `1641` where applicable.

## Detection Rules

Detection avoids reinstalling apps unnecessarily.

### Registry Detection

```json
"detection": {
  "type": "registry",
  "display_name_pattern": "Example App*"
}
```

Checks installed program display names under standard uninstall registry locations. The pattern supports wildcard-style matching.

### Command Detection

```json
"detection": {
  "type": "command",
  "command": "Test-Path 'C:\\Program Files\\Example\\example.exe'"
}
```

Runs the PowerShell command and treats a truthy result as installed. Keep detection commands simple and deterministic.

### Path Detection

```json
"detection": {
  "type": "path",
  "path": "C:\\Program Files\\Example\\example.exe"
}
```

Checks whether the path exists.

## Example

```json
{
  "apps": [
    {
      "name": "Example MSI App",
      "relative_path": "Example\\installer.msi",
      "installer_type": "msi",
      "silent_arguments": "/qn /norestart",
      "detection": {
        "type": "registry",
        "display_name_pattern": "Example App*"
      },
      "required": false,
      "reboot_behavior": "suppress"
    }
  ]
}
```

## Ordering

Local USB apps install after Windows Updates, model drivers, winget apps, and optional Datto RMM. Desktop cleanup runs after local apps, so shortcuts created by local installers can be removed or normalised by `desktop_items` in `deployment_config.json`.
