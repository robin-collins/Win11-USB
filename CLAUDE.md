# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Windows 11 Pro USB deployment toolkit for technician-led notebook imaging. It extends a Windows 11 install USB labelled `1S-WIN11` with an unattended-setup answer file plus a PowerShell orchestrator that runs after first logon: preflight checks, Windows Update, driver/app installation, asset capture, and reporting. It intentionally stops before domain join / Entra join / Autopilot / Intune / any customer identity work — see `README.md` for the full behaviour contract (this is the authoritative doc; read it before making user-visible changes).

## Commands

```powershell
# One-time setup on a fresh machine: PowerShell 7, a .NET SDK covering
# External\unattend-generator's TargetFrameworks, the submodule content, and the
# PSScriptAnalyzer/Pester modules the commands below assume are already present.
.\Install-Dependencies.ps1
.\Install-Dependencies.ps1 -IncludeHyperV -IncludeAdk   # also Tier 1 rehearsal + full XSD validation (heavier, optional)

# Lint (zero findings expected)
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Unit tests (Pester v5)
Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
Invoke-Pester -Path Tests/Unit -Output Detailed
Invoke-Pester -Path Tests/Unit/Common.Tests.ps1 -Output Detailed          # single file
Invoke-Pester -Path Tests/Unit -FullNameFilter '*Get-SafeName*' -Output Detailed   # by name

# Validate the Autounattend.xml template / a generated USB answer file
.\Validate-Unattend.ps1
.\Validate-Unattend.ps1 -Ci
.\Validate-Unattend.ps1 -Path E:\Autounattend.xml -Generated -ConfigPath E:\Deployment\Config\deployment_config.json

# Dry run the whole orchestrator against any checked-out copy (no USB label required)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Deployment\Scripts\Start-Deployment.ps1 -UsbRoot <path> -DryRun

# Hyper-V rehearsal (boots a real Gen-2 VM end-to-end; ~60-90 min, needs a Win11 ISO)
.\Test\Rehearsal\Invoke-DeploymentRehearsal.ps1 -IsoPath C:\ISOs\Win11.iso
.\Test\Rehearsal\Invoke-DeploymentRehearsal.ps1 -IsoPath C:\ISOs\Win11.iso -Scenario ResumeKill

# Refresh a bootable 1S-WIN11 VHD from the current repo state, then boot a fresh test VM from it
.\Test\Rehearsal\Invoke-VhdBootTestCycle.ps1 -Force -DisableSecureBoot

# Same VHD-boot test as one three-phase lifecycle: provision+boot, stop VM + mount both disks to read logs, tear down (keeps Deployment\VHD\1S-WIN11.vhd)
.\Invoke-VhdVmDeploymentTest.ps1 -DisableSecureBoot
.\Invoke-VhdVmDeploymentTest.ps1 -Finalize
.\Invoke-VhdVmDeploymentTest.ps1 -Destroy

# Write the toolkit + generated Autounattend.xml to a real USB
.\Initialize-UsbDeployment.ps1
```

`Tests/Unit` runs cross-platform (Linux/macOS/pwsh too); everything else that touches real Windows state is Windows-only. See `TESTING.md` for the full three-tier strategy and a decision guide on which tier a given change needs, and `Tests/README.md` for exactly what `Common.Tests.ps1` covers vs. intentionally leaves to the other tiers.

## Architecture

**Three run modes, one codebase.** `Deployment\Scripts\Start-Deployment.ps1` is the orchestrator; `Common.ps1` is dot-sourced everywhere and holds shared state/logging/config helpers. The same step scripts run in all three tiers:

1. **Production** — boots from the `1S-WIN11`-labelled USB via `Autounattend.xml`, runs for real on a client notebook.
2. **`-DryRun`** — same orchestrator, same step order (`Get-DeploymentSteps` in `Common.ps1`), but every mutating action is replaced by a `Write-DryRunAction` log entry instead of executing. Detection/scan logic (CIM queries, Windows Update scan, winget checks, driver `.inf` enumeration) still runs for real — that's the point. Dry-run state/logs/reports are written to shadow files (`deployment_state.dryrun.json`, `dryrun-<RunId>\`) so a real run's state is never touched.
3. **Hyper-V rehearsal** (`Test\Rehearsal\`) — boots an actual Gen-2 VM with vTPM/Secure Boot from a Windows ISO plus generated media, and drives the real (non-dry-run) flow to completion, including reboots and resume. This is the only tier that proves the boot/reboot/resume/credential-scrub path actually works.

**Step sequence** (`Get-DeploymentSteps`): `LocalHandover → NetworkDrivers → MspWifiSetup → Preflight → ConfigureComputerName → CreateLocalAdmin → PowerSettings → WindowsUpdates → AssetInventory → ModelDrivers → AdditionalWifiProfiles → WingetApps → DattoRmm → LocalApps → SystemTweaks → DesktopItems → FinalReport → EmailReport → Complete`. `LocalHandover` (optional, off by default) runs first and needs no network (`require_network` defaults to `false`): it copies the whole toolkit to `C:\1S-WIN11` immediately so the USB can be ejected within the first minute; every later step then runs from the local copy. Network/WiFi drivers install next, before any step that needs connectivity, because a bare Windows image may lack an inbox WiFi driver. `SystemTweaks` (`Set-SystemTweaks.ps1`) applies config-driven bloatware removal, taskbar/Explorer tweaks, and hardening toggles as the logged-on OSIT session, after app installation and before desktop item cleanup. `AdditionalWifiProfiles` (`Import-AdditionalWifiProfiles.ps1`) imports every secondary WLAN profile from `Deployment\WifiProfiles\` (everything but `Primary.xml`, which `MspWifiSetup` already handles), verifies each on a best-effort basis, then reconnects to the primary network.

**Resume model.** Each step's completion is persisted to `Deployment\State\deployment_state.json`. The resume scheduled task (`OneSolutionWin11DeploymentResume`, under the `\1S-WIN11` Task Scheduler folder, bound by SID, with a plain-language description) is registered at every real run start — before the first step — with the `RunStart` trigger profile (at-logon + hourly retry for 14 days), so a failure at any step leaves an automatic retry armed; a reboot mid-run re-registers it with the faster `PostReboot` profile (at-logon + 5-min backstop for 3 days) and temporarily re-arms Windows autologon. Run start also creates two common-desktop shortcuts (`Resume 1S-WIN11 Deployment.lnk`, `1S-WIN11 Deployment Status.lnk`) that `Configure-DesktopItems.ps1` always preserves mid-run. The task (plus its scheduler folder, if empty), the shortcuts, and autologon are all removed/scrubbed in the `Complete` step along with cached Panther/sysprep answer-file copies. `Start-Deployment.ps1` takes an exclusive run lock so a racing resume trigger can't run two instances at once.

**Config layering.** `Deployment\Config\deployment_config.json` (plus `winget_packages.json`, `local_apps.json`, `smtp_config.json`) is baked into the generated `Autounattend.xml` by `Initialize-UsbDeployment.ps1` — editing config after initialising the USB has no effect until you rerun it. Rehearsal scenarios (`Test\Rehearsal\Scenarios\<name>\`) are config overlays merged on top of the repo's checked-in config via `Merge-RehearsalScenarioConfig`, and CI's `dryrun-smoke` job applies its own overlay to relax runner-specific settings (winget/WLAN/Datto RMM absence) — see the inline comments in `.github/workflows/ci.yml` for exactly which keys and why.

**Secrets** (OSIT local admin password, MSP WiFi password, SMTP password) are never stored in the JSON configs. They come from environment variables or a toolkit-root `.env` (see `.env.example`) and are written into generated, gitignored artifacts (USB-root `.env`, the generated `Autounattend.xml`) only at initialise/rehearsal-media-build time. `Deployment\WifiProfiles\*` (exported `netsh wlan export profile key=clear` XML files, which embed real WiFi passwords in plaintext) is gitignored the same way.

**Driver folder convention:** `Deployment\Drivers\<Manufacturer>\<Model>` for model-specific drivers (installed after Windows Update), `Deployment\Drivers\Network\<Vendor>` for WiFi/NIC drivers (installed first, before any network-dependent step). Manufacturer/model names are normalised by `ConvertTo-NormalizedManufacturer`/`ConvertTo-NormalizedModel` in `Common.ps1`.

## Working in this codebase

- **Runtime constraint:** everything under `Deployment\Scripts\` must keep running on Windows PowerShell 5.1, not just pwsh 7 — `Set-StrictMode -Version 2.0` conventions must hold on both. Test/rehearsal harness code may assume pwsh 7 and should say so if it does.
- **No behaviour change without a flag:** with `-DryRun` absent and no rehearsal involved, production behaviour must stay bit-identical; the unit suite is the tripwire for this.
- Pure, platform-independent helpers in `Common.ps1` (config merging, name normalisation, argument splitting, password generation, state round-trip) belong in `Tests/Unit/Common.Tests.ps1` with real execution; anything Windows-only (CIM, scheduled tasks, registry, toasts, external processes) gets mocked there and exercised for real only in the `-DryRun` and rehearsal tiers.
- PSScriptAnalyzer runs with the full default rule set (`IncludeDefaultRules = $true`) minus two rules excluded repo-wide (`PSUseShouldProcessForStateChangingFunctions`, `PSUseSingularNouns` — see `PSScriptAnalyzerSettings.psd1` for why). Genuine plaintext-password findings are suppressed inline per-function with `[Diagnostics.CodeAnalysis.SuppressMessage(...)]`, never blanket-excluded.
- Nothing under `Test\Rehearsal\Artifacts\` or any `*.dryrun.json` is committed; rehearsal `.env` files are generated per-run into gitignored paths.
- The toolkit finds the USB by volume label `1S-WIN11`, never by drive letter — keep that assumption when touching path resolution (`Get-UsbRoot` in `Common.ps1`).
