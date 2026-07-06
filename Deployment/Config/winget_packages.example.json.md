# winget_packages.example.json

This file documents `winget_packages.json`, which controls packages installed by `Install-WingetApps.ps1`.

The file has one top-level key:

| Key | Type | Meaning |
| --- | --- | --- |
| `packages` | array | List of winget package entries to check and install. |

## Package Entry Keys

| Key | Type | Required | Example | Meaning |
| --- | --- | --- | --- | --- |
| `id` | string | yes | `"Google.Chrome"` | Exact winget package ID. The script uses `winget list --id <id> --exact` before installing. |
| `display_name` | string | no | `"Google Chrome"` | Friendly name used in console output and logs. If omitted, the package ID is used. |
| `required` | boolean | no | `true` | If `true`, install failure stops the task sequence when `fail_on_missing_required_app=true` in `deployment_config.json`. Defaults to `true` when omitted. |
| `install_arguments` | string | no | `""` | Optional installer override passed to winget with `--override`. Leave blank unless the package requires custom silent arguments. |

## Behavior

- The winget step runs after Windows Updates and model drivers.
- The Datto RMM step runs after winget when `datto_rmm_site_id_uuid` is configured.
- The script accepts source and package agreements automatically.
- The script uses `--silent` and `--disable-interactivity`.
- Already-installed packages are skipped.
- Required package failures stop the run when `fail_on_missing_required_app=true`.
- Optional package failures are logged and the task sequence continues.

## Example

```json
{
  "packages": [
    {
      "id": "Google.Chrome",
      "display_name": "Google Chrome",
      "required": true,
      "install_arguments": ""
    }
  ]
}
```

## Notes

Use `winget search <name>` on a reference machine to confirm exact IDs. Package IDs can change upstream, so verify them when standard app lists are updated.
