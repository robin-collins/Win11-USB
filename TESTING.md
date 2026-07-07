# Testing

This toolkit ships a three-tier testing strategy (see `FABLE_TASKS.md` for the full implementation plan), so a change can be validated at a cost proportional to how risky it is, instead of every change requiring a full hardware rehearsal.

| Tier | What it proves | Typical duration |
| --- | --- | --- |
| 3 — CI | Syntax is clean, pure helper functions behave, the generated answer file is well-formed. | ~3 minutes |
| 2 — `-DryRun` | The orchestrator would walk every step correctly, on any machine, without changing anything. | ~5-10 minutes |
| 1 — Hyper-V rehearsal | The entire unattended flow — wipe, reboots, resume, scrub — actually completes end-to-end on real (virtual) hardware. | ~60-90 minutes per scenario |

## Which tier do I need?

- **Changing a pure helper function** (`Common.ps1`, `UnattendGeneration.ps1`, etc.) → Tier 3 covers you. Run the unit suite locally before opening a PR.
- **Changing `deployment_config.json`, `winget_packages.json`, `smtp_config.json`, or any other config/profile file** → run a Tier 2 dry run on a bench PC as a sanity check before touching a real USB.
- **Changing anything in the boot/reboot/resume/credential-scrub path, or preparing a release** → run a Tier 1 rehearsal, minimum `Standard` + `ResumeKill`, before regenerating production USBs.

Tiers are cumulative in confidence, not a substitute for each other: passing Tier 3 does not mean a dry run would succeed, and a clean dry run does not prove the machine actually reboots and resumes correctly under Windows Setup.

---

## Tier 3 — CI (`Tests/Unit`, `PSScriptAnalyzerSettings.psd1`, `Validate-Unattend.ps1 -Ci`)

**Prerequisites:** PowerShell 7+ (or Windows PowerShell 5.1, the toolkit's production runtime), the [Pester](https://pester.dev/) v5 module, and (for lint) the [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) module. No Windows-only features are required — this tier runs identically on Linux, macOS, and Windows.

Runs automatically on every pull request and push to `main` via `.github/workflows/ci.yml` (jobs: `lint`, `unit` — matrix of ubuntu-latest/pwsh, windows-latest/pwsh, windows-latest/Windows PowerShell 5.1 — `unattend`, and the Tier 2 `dryrun-smoke` smoke test described below).

Run it locally:

```powershell
# Lint: zero PSScriptAnalyzer findings expected.
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Unit tests: see Tests/README.md for full details (what's covered, expected Skipped count).
Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
Invoke-Pester -Path Tests/Unit -Output Detailed

# Validate the checked-in Autounattend.xml template and the config it would actually generate.
pwsh -File Validate-Unattend.ps1 -Ci
```

Expected result: PSScriptAnalyzer reports no findings; Pester reports `Failed: 0` (some `Skipped` is expected on non-Windows platforms — see `Tests/README.md`); `Validate-Unattend.ps1 -Ci` exits `0`.

## Tier 2 — `-DryRun` (`Deployment\Scripts\Start-Deployment.ps1 -DryRun`)

**Prerequisites:** a Windows machine (dry run still exercises Windows-only detection code — CIM queries, registry reads, `winget`/Windows Update scans). Does not require the `1S-WIN11` USB label; point `-UsbRoot` at any checked-out copy of the toolkit.

See the [`## Dry Run`](README.md#dry-run) section of the README for the full behaviour contract (what still runs for real, what never happens, where the shadow state/logs/report land). Run it with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Deployment\Scripts\Start-Deployment.ps1 -UsbRoot <path> -DryRun
```

**How to read the result:** the console and log print a one-line summary (`DRYRUN RESULT: steps=17 actions=23 would-reboot=1`), and a full breakdown is written to `Deployment\Reports\<SerialOrComputerName>\dryrun\dryrun-summary-<RunId>.md`, grouped by step, with every recorded action's timestamp and data. A clean dry run walks every step in `Get-DeploymentSteps` order and exits `0`.

The `dryrun-smoke` CI job runs this same command against the checked-out repository itself on every pull request (with a CI-safe config overlay), so a broken dry-run code path is caught automatically — you do not need to run this manually before every PR, only after a config change you want to sanity-check locally first.

## Tier 1 — Hyper-V rehearsal (`Test\Rehearsal\Invoke-DeploymentRehearsal.ps1`)

**Prerequisites:** a Windows 10/11 Pro, Enterprise, or Education host with the Hyper-V feature enabled, ~60 GB free disk space, a Windows 11 ISO, and an elevated PowerShell session. `Test-RehearsalPrerequisites` checks all of this up front and fails with an actionable list rather than partway through a run.

This is the only tier that boots a real (virtual) Gen-2 VM with vTPM and Secure Boot from the Windows 11 ISO plus generated media, and drives the entire unattended flow to completion — the strongest proof a change is safe before it reaches a client notebook.

Run the `Standard` scenario:

```powershell
.\Test\Rehearsal\Invoke-DeploymentRehearsal.ps1 -IsoPath C:\ISOs\Win11.iso
```

Or a specific scenario:

```powershell
.\Test\Rehearsal\Invoke-DeploymentRehearsal.ps1 -IsoPath C:\ISOs\Win11.iso -Scenario ResumeKill
```

### Scenarios

Each scenario is a named `deployment_config.json` overlay under `Test\Rehearsal\Scenarios\<name>\`, applied on top of the repo's own checked-in config:

| Scenario | Exercises |
| --- | --- |
| `Standard` (default) | The baseline path: disk wipe on, serial-derived computer naming, one placeholder winget app. |
| `NoWipe` | The technician-led setup path when `wipe_repartition_drive=false`. |
| `Handover` | `local_deployment_handover.enabled=true`, plus a failure injection that hot-removes the rehearsal media VHDX right after the handover completes — the strongest possible proof the "eject the USB early" promise holds. |
| `ResumeKill` | A failure injection that force-stops the VM once Windows Update starts, then restarts it, proving the resume scheduled task and autologon chain bring the run to `Complete` anyway. |
| `AdditionalUsers` | One `additional_local_users` entry with a randomly generated, exported password — asserts the account exists and its password report file exists on the media but was never attached to the deployment email. |

**How to read the result:** live step progress prints to the console throughout the run (`step 8/17 - current: WindowsUpdates - status: Running`). On completion (success, failure, or timeout), artifacts are harvested to `Test\Rehearsal\Artifacts\<timestamp>\` (logs, reports, state, the diskpart log, a final VM screenshot), and the post-run assertion suite writes `rehearsal-report-<timestamp>.md` alongside them — a Pass/Fail table covering completion, credential scrub, identity, config effects, disk layout, and (for `AdditionalUsers`) the scenario-specific password-report checks. The harness exits `0` only when every assertion passes; a non-zero exit prints the failed-assertion summary to stderr.

Useful flags: `-KeepVm` leaves the VM and its disks in place for post-mortem inspection instead of tearing them down; `-SkipAssertions` skips the T13 assertion suite (media build, VM run, and artifact harvest still happen).

---

## Release checklist

Before regenerating production USBs, confirm all three tiers are green:

- [ ] **Tier 3:** `Invoke-ScriptAnalyzer` reports zero findings; `Invoke-Pester -Path Tests/Unit` reports `Failed: 0`; `Validate-Unattend.ps1 -Ci` exits `0`. (Trigger: every PR — should already be green from CI.)
- [ ] **Tier 2:** a fresh `-DryRun` against the current `deployment_config.json` completes with `would-reboot` and step counts matching expectations, and the summary report has no surprising entries. (Trigger: any config/profile change since the last release.)
- [ ] **Tier 1:** `Standard` and `ResumeKill` rehearsals both pass end-to-end; run `Handover` and `AdditionalUsers` too if this release touches either feature; run `NoWipe` if the technician-led setup path changed. (Trigger: any change to the boot/reboot/resume/credential-scrub path, or before a scheduled release.)

Only regenerate and ship USBs once every applicable box above is checked.
