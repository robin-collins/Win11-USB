# FABLE_ENHANCE — Enhancement Recommendations

An analysis of the Win11-USB deployment toolkit with prioritised recommendations. Goal restated: a reliable, robust, near-unattended Windows 11 notebook setup that gets each device as close as possible to "ready to connect to the client's network", repeatable at MSP scale, with clear progress visibility for technicians.

## Where The Toolkit Already Stands

This is a genuinely mature framework and most of the hard plumbing is done well:

- Durable resumable state (`deployment_state.json`), device-identity matching, SID-bound resume task with a 5-minute backstop trigger, exclusive run lock, and temporary autologon re-arming across reboots.
- Layered logging (transcript + JSONL structured events + per-command stdout/stderr), per-device/per-run folders, JSON + Markdown reports, asset inventory, SMTP delivery on success *and* failure.
- Preflight that fails early on the things that actually burn technician time (no internet, Home edition, battery power, corrupt config, unwritable USB).
- Network drivers installed *before* any network-dependent step, local handover so the USB can be ejected early, credential scrubbing of Panther/sysprep unattend caches and Winlogon autologon values at `Complete`.
- Secrets kept out of JSON config via `.env`/environment variables, generated-password export gated behind an explicit opt-in, password reports excluded from email attachments.

The recommendations below build on that foundation rather than rework it. They are grouped into: an immediate security fix, progress tracking & technician information (your explicit focus), reliability & robustness, "closer to client-network-ready", MSP fleet operations, and engineering quality.

---

## P0 — Security Fix (Do This First)

### 1. Scrub secrets left behind by Local Handover and MSP WiFi

**Gap.** `Invoke-LocalHandover.ps1` copies the USB-root `.env` — containing `OSIT_LOCAL_ADMIN_PASSWORD`, `OSIT_WIFI_PASSWORD`, and `OSIT_SMTP_PASSWORD` — to `C:\1S-WIN11\.env` (lines 75–78). The `Complete` step in `Start-Deployment.ps1` scrubs Panther unattend caches and Winlogon values, but **never deletes the local `.env`**, so every handover-deployed device ships to the client with the MSP's local-admin, WiFi, and SMTP passwords in plaintext on `C:`. Similarly, the `OneSolution` WLAN profile created by `Configure-MspWifi.ps1` (which embeds the WiFi key) remains on the device forever.

**Fix.** Extend the `Complete` step to:
- Delete `<local_path>\.env` (and consider deleting `Deployment\State` under the local copy, which is no longer needed once complete).
- Remove the MSP WLAN profile: `netsh wlan delete profile name="OneSolution"` (driven by `msp_wifi_setup.ssid`, and only after confirming the run no longer needs the MSP network — i.e. at `Complete`, after `EmailReport`).
- Log each scrub action the same way the existing Winlogon scrubbing does.

Optionally add a `retain_msp_wifi_profile` config flag for the rare case a device stays on the bench. This is a small change with an outsized payoff: it closes the one place where the current design leaks MSP credentials onto client-owned hardware.

---

## Progress Tracking & Technician Information

The current visibility model is good bones (step counter, `Get-DeploymentStatus.ps1`, toasts) but progress is measured in *steps completed out of 17*, and the steps are wildly unequal — `WindowsUpdates` can be 45+ minutes across multiple reboots while `PowerSettings` is 2 seconds. "9 of 17" tells a technician almost nothing about time remaining.

### 2. Per-step timing in state and reports

Record `started_at` / `completed_at` / `duration_seconds` for every step in `deployment_state.json` (the hooks already exist: `Set-StateStepStarted` / `Set-StateStepCompleted` in `Common.ps1`). Surface a per-step duration table in the Markdown summary and JSON report. Benefits: technicians learn what "normal" looks like per model, you get defensible time-per-device data for costing, and it feeds the ETA work below.

### 3. Weighted progress + ETA

Give each step a weight (static defaults, e.g. `WindowsUpdates: 50, WingetApps: 15, ModelDrivers: 10, …`) so the console and `Get-DeploymentStatus.ps1` can show *weighted* percent complete instead of raw step count. Phase 2: persist per-model historical durations into a small `Deployment\Reports\timing-history.json` on the USB, and estimate remaining time from actual history ("~25 min remaining based on 6 prior Latitude 5440 runs"). Even a rough ETA transforms the technician experience when juggling several benches.

### 4. Sub-step progress for the long steps

The two steps that dominate wall-clock time are opaque while running:
- **WindowsUpdates**: write `update_cycle`, count of updates found, and per-update install progress into state (`state.step_detail = "Cycle 2/15 — installing update 3 of 12: 2025-07 Cumulative Update…"`). PSWindowsUpdate exposes enough to do this per-update.
- **WingetApps / LocalApps**: write `"Installing 4 of 9: Google Chrome"` into `state.step_detail` before each package.

`Get-DeploymentStatus.ps1` then shows a meaningful *current activity* line instead of just the step name, and `Stalled` detection (below) gets a much finer heartbeat to work with.

### 5. Persistent console status banner

`Start-Deployment.ps1` currently scrolls log lines. Add a compact status header the orchestrator re-renders between steps:

```
════════════════════════════════════════════════════════
 1S-WIN11 Deployment   PI-ABC1234 (Dell Latitude 5440)
 Run f3a9…  Step 8/17: WindowsUpdates  [██████░░░░] 58%
 Elapsed 00:41:12   Est. remaining ~00:22:00
 Current: Cycle 2/15 — installing update 3 of 12
════════════════════════════════════════════════════════
```

Cheap to implement (a `Write-DeploymentBanner` function in `Common.ps1` called from the orchestrator loop), and it means a technician glancing at a bench of machines can read state from across the room. Consider colour-coding the window title too (`$Host.UI.RawUI.WindowTitle = "Step 8/17 WindowsUpdates — PI-ABC1234"`), which survives even when output scrolls.

### 6. Milestone webhook notifications (Teams/Slack/ntfy)

Email arrives only at the end. Add an optional `webhook_config.json` (same pattern as `smtp_config.json`, best-effort, never fails the run) that POSTs milestone events — started, handover complete (USB ejectable), reboot, technician action needed, failed, complete — to a Teams/Slack incoming webhook or `ntfy.sh` topic. For an MSP this is the single biggest visibility win: a channel showing every in-flight deployment across all technicians and benches in real time, with the failure message right in the card. The `Show-DeploymentToast` call sites are already exactly the right hook points; a `Send-DeploymentWebhook` in `Common.ps1` invoked alongside each toast covers it.

### 7. Fleet rollup report on the USB

`Deployment\Reports\<Serial>\` accumulates per-device history, but nobody reads N folders. Add a small `Update-FleetIndex` at `FinalReport` time that appends one row per run to `Deployment\Reports\fleet-index.csv` (serial, model, computer name, run id, started, finished, duration, status, updates installed, apps installed, Datto detected). One glance at the USB tells you everything that stick has deployed. A tiny static `fleet-index.html` generated from the same data is a nice stretch goal.

---

## Reliability & Robustness

### 8. Step watchdog / hang detection

Today `Stalled` in `Get-DeploymentStatus.ps1` only fires when the process has *died*. A hung `winget` or a wedged Windows Update session looks like `Running` forever. Two complementary fixes:
- **In-run heartbeat**: have long-running loops touch `state.heartbeat_at` (or just rely on the `step_detail` writes from item 4).
- **Per-step soft timeout**: a `step_timeout_minutes` map in config (generous defaults — e.g. WindowsUpdates 120, WingetApps 45). The orchestrator can't easily preempt a child script mid-flight in the current architecture, but `Get-DeploymentStatus.ps1` can flag `Running (over expected duration — possible hang)` and a webhook (item 6) can alert on it, which is what actually saves the technician's afternoon.

### 9. Configurable retry for network-dependent steps

`Invoke-WithRetry` exists in `Common.ps1` but transient failures in `WingetApps`, `DattoRmm`, and PSWindowsUpdate bootstrap can still fail a run on a WiFi blip. Standardise: wrap each network-touching operation (winget install per-package, Datto download, PSGallery bootstrap) with `Invoke-WithRetry` + a connectivity re-check between attempts, with counts in config (`network_retry_count`, default 3). The run should stop for *real* failures, not for a 10-second AP roam.

### 10. Post-deployment verification step (`Verify` before `Complete`)

The report currently states what the toolkit *did*; add a step that independently confirms the machine *is* in the desired state:
- Every `required: true` winget/local app resolves as installed.
- Datto/CentraStage agent service exists **and is running** (not just detected post-install).
- No pending reboot; Windows Update reports no outstanding critical updates.
- Computer name matches `desired_computer_name`; OSIT account present and in Administrators; autologon values scrubbed.
- Time correct (see item 12), activation status (see item 13).

Emit a pass/fail checklist into the report and fail the run (or warn, per `verify_strictness` config) on misses. This converts "the script finished" into "the device is verified ready", which is the claim your MSP is actually making to the client.

### 11. USB content integrity + version stamp

USB sticks corrupt, and stale sticks get reused. At `Initialize-UsbDeployment.ps1` time, write a `Deployment\manifest.json` containing toolkit version/git commit, generation timestamp, and SHA-256 hashes of every script and config file. Preflight then: (a) verifies hashes — catching bit-rot and half-finished manual edits before they burn a deployment; (b) warns when the stick was generated more than N days ago ("regenerate to pick up config changes"). Report the toolkit version in every deployment report so you can trace any device back to the exact toolkit revision that built it.

---

## Closer To "Ready For The Client Network"

These close the gap between where the toolkit stops today and the state a notebook actually needs before domain/Entra join.

### 12. Region, time zone, locale, and NTP step

Nothing currently sets time zone, region, or keyboard layout, and OOBE bypass can leave defaults wrong. Wrong clocks also break TLS, winget, and Kerberos at join time. Add a small `ConfigureRegion` step early (right after `Preflight`): `Set-TimeZone` (e.g. `Cen. Australia Standard Time`), `Set-WinHomeLocation` / `Set-Culture` / `Set-WinUserLanguageList` from config, force `w32tm /resync`. Low effort, removes a whole class of "why is winget failing / why is the clock wrong at handover" issues.

### 13. Windows activation check

Add activation status (`slmgr /xpr` equivalent via CIM `SoftwareLicensingProduct`) to `Verify` and the asset inventory. A notebook that isn't activated is not client-ready, and catching it on the bench beats catching it at the client's site.

### 14. Debloat / provisioned-app removal step

Fresh Win 11 Pro ships consumer noise (Xbox, Solitaire, Spotify stubs, consumer OneDrive prompts, Teams personal). Add an optional `RemoveProvisionedApps` step driven by a config list of appx package-family names to deprovision (`Remove-AppxProvisionedPackage -Online`), plus common registry policies (`DisableConsumerFeatures`, disable Fast Startup — a frequent source of "it wasn't really rebooted" support tickets on managed fleets). Keep the list in config, default conservative, so it is a per-MSP policy rather than hardcoded opinion.

### 15. Vendor driver/BIOS tooling integration

Model driver folders are the right offline fallback, but the big three all ship silent-capable updaters that pull the *correct current* drivers and BIOS: Dell Command | Update (`dcu-cli.exe /applyUpdates -silent`), HP Image Assistant, Lenovo System Update / Commercial Vendor Services. Add an optional `VendorUpdates` step (after `WindowsUpdates`, before `ModelDrivers`) that detects manufacturer and runs the matching tool if present under `Deployment\Tools\<Vendor>` or installable via winget (`Dell.CommandUpdate`). BIOS currency matters for fleets (firmware CVEs, dock/WiFi stability) and this removes the largest remaining manual driver chore. Gate BIOS updates behind their own config flag since they add reboot risk.

### 16. Defender definitions + quick scan

A one-liner-ish step near the end: `Update-MpSignature` then optionally `Start-MpScan -ScanType QuickScan`. The device arrives at the client with current definitions and a clean baseline scan logged in the report — a nice line item on the handover summary.

---

## MSP Fleet Operations

### 17. Per-client configuration profiles

Today one USB = one baked config; serving multiple clients means maintaining multiple sticks or re-initialising between jobs. Add `Deployment\Config\Profiles\<client>\` overlays (each may carry `deployment_config.json`, `winget_packages.json`, `local_apps.json` fragments merged over the base via the existing `Merge-Config`). Selection: `-Profile` parameter, or an interactive pick-list at deployment start persisted into state (so resume keeps the same profile). Note the constraint: anything baked into `Autounattend.xml` (partitioning, image name) stays global per-stick; the profile governs the post-install phase — worth stating in the docs. This turns one physical USB into an any-client tool, which is the difference between a lab convenience and an MSP instrument.

### 18. Datto RMM as the fleet dashboard you already own

Since every deployment installs Datto, consider writing deployment metadata where Datto can see it — e.g. a registry key (`HKLM:\SOFTWARE\OneSolution\Deployment` with run id, toolkit version, completion timestamp, verify result) that a Datto UDF/component can read. Your existing RMM then becomes the permanent record of "which toolkit version built this device, when, and did it verify clean" — with zero new infrastructure.

---

## Engineering Quality

### 19. CI: PSScriptAnalyzer + Pester + unattend validation

Commit history shows PSScriptAnalyzer passes done by hand. Add a GitHub Actions workflow (alongside the existing GitLab mirror workflow) that on every PR runs: PSScriptAnalyzer across all scripts, `Validate-Unattend.ps1` against the template, and Pester unit tests for the pure functions in `Common.ps1` that most repay testing (`ConvertTo-NormalizedModel`, `Get-SafeComputerName`, `Merge-Config`, `ConvertTo-PlainHashtable`, `Split-CommandLineArguments`, state read/write round-trips). These functions run on Linux runners fine under PowerShell 7. Right now every change is effectively tested in production on a client's notebook; CI moves the cheap half of that risk to the PR.

### 20. Machine-readable exit summary + documented exit codes

`Start-Deployment.ps1` exits 0/1/2/3010 but the meanings live only in the code. Document them in the README and have the final console output end with a single stable summary line (`RESULT: Completed run=<id> duration=<t> …`) so any future wrapper (RMM script, webhook, kiosk shell) can parse the outcome without scraping logs.

---

## Suggested Roadmap

| Phase | Items | Rationale |
| --- | --- | --- |
| **Now** | 1 (secret scrub), 2 (step timing), 5 (console banner), 12 (timezone/NTP), 20 (exit summary) | Security fix + highest value-per-line-of-code |
| **Next** | 4 (sub-step progress), 6 (webhooks), 10 (Verify step), 9 (retries), 11 (manifest/version), 13 (activation) | Turns "finished" into "verified ready" and makes progress visible off-bench |
| **Then** | 3 (ETA), 7 (fleet index), 14 (debloat), 16 (Defender), 17 (client profiles), 19 (CI) | Scale-out for multi-client MSP use |
| **Later** | 8 (watchdog), 15 (vendor BIOS/driver tools), 18 (Datto metadata) | Larger integrations; highest ongoing payoff for large mixed fleets |

---

## The Final Question

> *"What is the MOST important question I should be asking you that you know will benefit me, that I am not asking?"*

**"How do I test this toolkit without burning a real notebook — and how do I know a change is safe before it reaches a client's machine?"**

Right now, the only full rehearsal of this system is a production deployment on client-bound hardware. Every enhancement above — and every config tweak you make on a Friday afternoon — is validated the first time it runs for real, on a machine with a deadline attached, often with `wipe_repartition_drive=true` armed. The failure modes that hurt most (a bad answer file that bricks setup at `0x80004005`, a resume task that doesn't fire after rename, a scrub step that misses a credential) are exactly the ones you can't see in a code review.

The answer has three tiers, in order of value:

1. **A Hyper-V/VM rehearsal harness.** A script that takes a Win11 ISO plus your generated USB contents, builds a Gen-2 VM (TPM + Secure Boot, so it matches real notebooks), attaches the USB image, and runs the entire unattended flow end-to-end — including the wipe path, the reboots, and resume — with checkpoints before each destructive stage. One command, ~an hour, zero hardware. Every toolkit change gets a full dress rehearsal before any client notebook sees it.
2. **A `-DryRun` mode** through the orchestrator: every step logs exactly what it *would* do (packages it would install, names it would set, files it would scrub) without doing it — cheap validation of config and profile changes on any machine, including the bench PC you initialise USBs from.
3. **CI (item 19)** to catch the cheap defects — syntax, analyzer findings, broken helper functions, invalid unattend XML — before a human even reviews the PR.

You asked how to make deployment reliable and robust; this is the question underneath that one. Reliability isn't a property you add to the scripts — it's a property of how changes to them are proven. A toolkit this good deserves a test bench, not just a client bench.
