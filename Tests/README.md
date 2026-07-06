# Tests

Unit tests for the Win11-USB toolkit, using [Pester](https://pester.dev/) v5.

This directory is Tier 3 ("CI") of the toolkit's three-tier testing strategy
described in `FABLE_TASKS.md` — the cheapest, fastest feedback loop, meant to
catch broken helper functions before they reach a client's notebook. It is
plain unit testing of pure PowerShell functions; it does not boot Windows, run
the orchestrator, or touch a real machine. For the other two tiers (`-DryRun`
mode and the Hyper-V rehearsal harness), see `FABLE_TASKS.md`.

## What's covered

`Tests/Unit/Common.Tests.ps1` covers the **platform-independent, pure**
functions in `Deployment/Scripts/Common.ps1`:

- `ConvertTo-PlainHashtable`
- `Merge-Config`
- `Get-SafeName`
- `Get-SafeComputerName`
- `ConvertTo-NormalizedManufacturer`
- `ConvertTo-NormalizedModel`
- `Split-CommandLineArguments`
- `ConvertTo-ProcessArgumentString`
- `New-RandomPassword`
- `Get-DotEnvValue`
- The deployment state round trip: `New-DeploymentState` -> `Write-DeploymentState` -> `Read-DeploymentState`

### What's intentionally out of scope

Anything in `Common.ps1` that depends on Windows-only functionality is **not**
tested here: CIM/WMI (`Get-CimInstance`, e.g. `Get-DeviceIdentity`), scheduled
tasks (`Register-DeploymentResumeTask`, `Unregister-DeploymentResumeTask`),
toast notifications (`Show-DeploymentToast`), the registry
(`Enable-DeploymentAutoLogon`, `Test-PendingReboot`), and anything that shells
out to an external process (`Invoke-ExternalCommand`). Those get exercised by
the Tier 2 (`-DryRun`) and Tier 1 (Hyper-V rehearsal) suites instead, where a
real or virtual Windows machine is actually available.

Where a covered function calls a Windows-only function internally
(`New-DeploymentState` calls `Get-DeviceIdentity`), the test suite uses
Pester's `Mock` to stand in for the Windows-only dependency rather than
touching `Common.ps1` to add a testing seam. `Common.ps1` itself needed no
changes for this suite: dot-sourcing it has no side effects (it only sets
script-scoped variables and defines functions), which was confirmed by
dot-sourcing it in isolation before writing any tests.

## Running the tests locally

Prerequisites: [PowerShell 7+](https://github.com/PowerShell/PowerShell) (or
Windows PowerShell 5.1, the toolkit's production runtime) and the
[Pester](https://pester.dev/) module (v5+).

Install Pester once, if you don't already have it:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

Run the whole unit suite from the repository root:

```powershell
Invoke-Pester -Path Tests/Unit -Output Detailed
```

Run a single test file:

```powershell
Invoke-Pester -Path Tests/Unit/Common.Tests.ps1 -Output Detailed
```

Run only tests whose name matches a pattern (useful while iterating on one
function):

```powershell
Invoke-Pester -Path Tests/Unit -FullNameFilter '*Get-SafeName*' -Output Detailed
```

### A note on `New-RandomPassword`

`New-RandomPassword` calls `[System.Web.Security.Membership]::GeneratePassword`,
a full .NET Framework API. It works everywhere the toolkit actually runs in
production (Windows PowerShell 5.1) and is expected to work under PowerShell 7
on Windows too. On PowerShell 7 on Linux/macOS, .NET's trimmed-down
`System.Web` compatibility shim does not implement `Membership`, so those
specific test cases detect that at runtime and report `Skipped` (with a reason)
rather than `Failed` — this is expected on non-Windows dev machines and CI
runners, not a bug in the test suite.

## Expected result

A clean run reports zero failures, for example:

```
Tests Passed: 62, Failed: 0, Skipped: 5, Inconclusive: 0, NotRun: 0
```

Some `Skipped` count is expected on non-Windows platforms (see above); `Failed`
should always be `0`.
