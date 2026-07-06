<#
    .SYNOPSIS
        Post-run assertion suite for the Tier 1 Hyper-V rehearsal harness (FABLE_TASKS.md T13).

    .DESCRIPTION
        Host-side tooling only, dot-sourced by Invoke-DeploymentRehearsal.ps1 alongside
        RehearsalCommon.ps1 (T09-T11) and RehearsalMonitoring.ps1 (T12). Requires a Windows
        10/11 host with Hyper-V for everything that touches a live guest; every function that
        needs Hyper-V calls RehearsalCommon.ps1's Assert-HyperVAvailable first, matching every
        other file in this folder.

        Test-RehearsalResult is the single entry point T13 adds: it runs a battery of small,
        independent assertions -- some against the guest via PowerShell Direct, some against the
        harvested artifact folder T12's Copy-RehearsalArtifacts produced on the host -- and
        writes a Markdown report (rehearsal-report-<timestamp>.md) alongside those artifacts.
        Invoke-DeploymentRehearsal.ps1 calls this once, after T12's monitoring finishes, unless
        -SkipAssertions was specified.

        Architecture (read this before adding a new assertion):
          1. "Fact gatherers" (Get-RehearsalGuest*Facts, Get-RehearsalArtifactFacts) do ONLY data
             collection -- one PowerShell Direct round trip per category, or one host-side file
             read -- and return a plain ordered hashtable of raw facts. They do not decide
             pass/fail. This keeps the guest-side script blocks small and keeps the interesting
             comparison logic on the host, where it can be unit tested without a live VM.
          2. "Assertion" logic consumes those facts and returns a Pass/Fail verdict via
             Test-RehearsalAssertion -Name <string> -ScriptBlock { ... returns @{Status;Message} },
             matching Validate-Unattend.ps1's Add-ValidationResult / RehearsalCommon.ps1's
             Test-RehearsalPrerequisites precedent for this codebase's own "run a battery of
             named checks, collect the results" pattern.
          3. Test-RehearsalResult wires both together per FABLE_TASKS.md T13's six assertion
             categories, aggregates the results (Get-RehearsalAssertionSummary), renders the
             Markdown report (ConvertTo-RehearsalReportMarkdown), and returns
             @{ Results; Summary; ReportPath; Passed }. The exit-code contract itself
             (exit 0 only when Passed, failed-assertion summary on stderr otherwise) is the
             caller's job (Invoke-DeploymentRehearsal.ps1), not this function's -- matching how
             Test-RehearsalPrerequisites (T09) returns data and lets the entry point decide what
             to print and which exit code to use.

        Credential scrub (the FABLE_ENHANCE.md P0 items): the "local handover .env" and "MSP WLAN
        profile" assertions below always run a real, unconditional check (Test-Path / netsh),
        never gated on whether this rehearsal's scenario enabled those features and never
        hardcoded. For the only scenario that exists today (Standard: local_deployment_handover
        and msp_wifi_setup both disabled), neither artifact is ever created in the first place,
        so these assertions genuinely -- not by assumption -- Pass. Once a scenario that enables
        either feature is exercised (T14's planned Handover scenario, or msp_wifi_setup.enabled
        flipped on), these same assertions will genuinely Fail, because Start-Deployment.ps1's
        real (non-dry-run) Complete step does not scrub either of them yet -- see
        Start-Deployment.ps1's Complete step and FABLE_ENHANCE.md's P0 section. Implementing
        that scrub fix is explicitly out of scope for T13.

        Dependencies expected to already be dot-sourced by the caller (matching the existing
        convention documented on RehearsalCommon.ps1's own Merge-RehearsalScenarioConfig):
          - Deployment\Scripts\Common.ps1 -- for Get-DeploymentSteps and Get-SafeComputerName.
          - Test\Rehearsal\RehearsalCommon.ps1 -- for Assert-HyperVAvailable and
            Get-RehearsalStandardWingetPackages.
          - Test\Rehearsal\RehearsalMonitoring.ps1 -- for Invoke-RehearsalGuestStatusPoll (reused
            here instead of re-implementing a fresh guest-status poll).
        Invoke-DeploymentRehearsal.ps1 already dot-sources all three ahead of this file.

    .NOTES
        UNVERIFIED ON REAL HYPER-V: every Get-RehearsalGuest*Facts function requires a live VM
        reachable via PowerShell Direct to exercise for real -- none of this can be executed in
        this toolkit's Linux CI/dev sandbox. What *is* verified here: the file parses cleanly and
        dot-sources without error alongside RehearsalCommon.ps1 and RehearsalMonitoring.ps1, and
        every genuinely pure/host-only helper (assertion-result construction and aggregation,
        Markdown rendering, partition-size-tolerance math, powercfg output parsing, expected
        computer name / expected local user set computation, and the harvested-artifact-folder
        fact gatherer and its assertions) has real Pester coverage in
        Tests\Unit\RehearsalAssertions.Tests.ps1. FABLE_TASKS.md T13's full acceptance criteria
        (green end-to-end on a real Standard rehearsal; a test-hook scenario that marks Complete
        done before the scrub runs turning the scrub assertions red) require a real Windows/
        Hyper-V host to verify.
#>

Set-StrictMode -Version 2.0

# The Windows Recovery Tools partition type GUID and GPT attribute bitmask
# UnattendGeneration.ps1's diskpart script sets on the WinRE partition (see its
# 'set id=...' / 'gpt attributes=...' lines) -- the WinRE partition assertions below compare
# against these exact literals.
$script:RehearsalWinReTypeGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$script:RehearsalWinReGptAttributesHex = '0x8000000000000001'

# ============================================================================================
# --- Pure / host-only helpers (no Hyper-V, no PowerShell Direct) ---
# ============================================================================================

function New-RehearsalAssertionResult {
    <#
        .SYNOPSIS
            Builds one structured assertion-result entry, matching the
            [ordered]@{ Name; Status; Message; Data } shape used throughout this file.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Fail')][string]$Status,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [object]$Data = $null
    )

    return [ordered]@{
        Name    = $Name
        Status  = $Status
        Message = $Message
        Data    = $Data
    }
}

function Test-RehearsalAssertion {
    <#
        .SYNOPSIS
            Runs one named assertion script block and converts its outcome (or any exception it
            throws) into a New-RehearsalAssertionResult record. Never throws.

        .DESCRIPTION
            -ScriptBlock is expected to return either:
              - a hashtable/ordered dictionary with a Status ('Pass'/'Fail') and Message key
                (and optionally Data) -- the expressive form every assertion in this file uses,
                since a good failure message is the whole point of the report; or
              - a plain [bool] -- true/false, converted to a generic Pass/Fail record.
            An exception thrown by -ScriptBlock is caught and converted into a Fail record
            carrying the exception message, so one bad assertion never aborts the whole suite.

            Pure with respect to its own inputs/outputs: this is safe (and is) unit-tested with
            fake script blocks that return canned records or deliberately throw, with no Hyper-V
            or PowerShell Direct dependency at all.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        $outcome = & $ScriptBlock
    } catch {
        return New-RehearsalAssertionResult -Name $Name -Status 'Fail' -Message "Assertion threw an exception: $($_.Exception.Message)"
    }

    if ($null -eq $outcome) {
        return New-RehearsalAssertionResult -Name $Name -Status 'Fail' -Message "Assertion script block for '$Name' returned nothing (`$null); expected a [bool] or a hashtable with Status/Message."
    }

    if ($outcome -is [bool]) {
        $status = if ($outcome) { 'Pass' } else { 'Fail' }
        return New-RehearsalAssertionResult -Name $Name -Status $status -Message "Assertion $(if ($outcome) { 'passed' } else { 'failed' })."
    }

    if ($outcome -is [System.Collections.IDictionary]) {
        $status = if ($outcome.Contains('Status')) { [string]$outcome['Status'] } else { 'Fail' }
        if ($status -ne 'Pass' -and $status -ne 'Fail') { $status = 'Fail' }
        $message = if ($outcome.Contains('Message')) { [string]$outcome['Message'] } else { '' }
        $data = if ($outcome.Contains('Data')) { $outcome['Data'] } else { $null }
        return New-RehearsalAssertionResult -Name $Name -Status $status -Message $message -Data $data
    }

    return New-RehearsalAssertionResult -Name $Name -Status 'Fail' -Message "Assertion script block for '$Name' returned an unsupported result type ($($outcome.GetType().FullName)); expected a [bool] or a hashtable with Status/Message."
}

function Get-RehearsalAssertionSummary {
    <#
        .SYNOPSIS
            Aggregates a list of assertion-result records into pass/fail counts and an overall
            verdict. Pure function.

        .DESCRIPTION
            OverallPass is true only when there is at least one result and none of them failed --
            an empty result list is never reported as an overall pass, so a caller that
            accidentally runs zero assertions cannot silently "succeed".
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Results = @())

    $all = @($Results)
    $total = $all.Count
    $passed = @($all | Where-Object { $_.Status -eq 'Pass' }).Count
    $failed = @($all | Where-Object { $_.Status -eq 'Fail' }).Count

    return [ordered]@{
        Total       = $total
        Passed      = $passed
        Failed      = $failed
        OverallPass = ($total -gt 0 -and $failed -eq 0)
    }
}

function ConvertTo-RehearsalReportMarkdown {
    <#
        .SYNOPSIS
            Renders a list of assertion-result records plus their summary into the Markdown
            content of rehearsal-report-<timestamp>.md. Pure function (no I/O): the caller
            writes the returned string to disk.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory = $true)][hashtable]$Summary,
        [hashtable]$Context = @{}
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# Rehearsal Assertion Report') | Out-Null
    $lines.Add('') | Out-Null

    foreach ($key in $Context.Keys) {
        $lines.Add("- **$key**: $($Context[$key])") | Out-Null
    }
    if (@($Context.Keys).Count -gt 0) { $lines.Add('') | Out-Null }

    $overallText = if ($Summary.OverallPass) { 'PASS' } else { 'FAIL' }
    $lines.Add("**Overall result: $overallText** ($($Summary.Passed)/$($Summary.Total) assertions passed)") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('| Status | Assertion | Message |') | Out-Null
    $lines.Add('| --- | --- | --- |') | Out-Null

    foreach ($result in @($Results)) {
        $statusMark = if ($result.Status -eq 'Pass') { 'PASS' } else { 'FAIL' }
        $escapedMessage = ([string]$result.Message) -replace '\|', '\|' -replace "`r?`n", ' '
        $lines.Add("| $statusMark | $($result.Name) | $escapedMessage |") | Out-Null
    }

    return ($lines -join "`r`n")
}

function Get-RehearsalReportPath {
    <#
        .SYNOPSIS
            Builds the rehearsal-report-<timestamp>.md path Test-RehearsalResult writes to.
            Pure function: mirrors RehearsalMonitoring.ps1's Get-RehearsalArtifactFolder.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReportFolder,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    return Join-Path $ReportFolder "rehearsal-report-$Timestamp.md"
}

function Test-RehearsalPartitionSizeWithinTolerance {
    <#
        .SYNOPSIS
            Returns whether -ActualMB is within -TolerancePercent of -ExpectedMB. Pure function.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$ExpectedMB,
        [Parameter(Mandatory = $true)][double]$ActualMB,
        [double]$TolerancePercent = 3.0
    )

    if ($ExpectedMB -le 0) { return $false }
    $delta = [math]::Abs($ActualMB - $ExpectedMB)
    $allowed = $ExpectedMB * ($TolerancePercent / 100.0)
    return ($delta -le $allowed)
}

function Get-PowerCfgTimeoutMinutes {
    <#
        .SYNOPSIS
            Parses a "Current <AC|DC> Power Setting Index: 0x........" line out of raw
            `powercfg /query` text output and returns the value in minutes (the raw value is
            seconds). Returns $null if that line is not present in -QueryOutput. Pure function.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$QueryOutput,
        [Parameter(Mandatory = $true)][ValidateSet('AC', 'DC')][string]$PowerSource
    )

    $match = [regex]::Match($QueryOutput, "Current $PowerSource Power Setting Index:\s*0x([0-9A-Fa-f]+)")
    if (-not $match.Success) { return $null }

    $seconds = [Convert]::ToInt64($match.Groups[1].Value, 16)
    return [int][math]::Round($seconds / 60.0)
}

function Get-RehearsalExpectedComputerName {
    <#
        .SYNOPSIS
            Computes the deterministic expected computer name for computer_name_mode 'serial' or
            'prefix_serial', mirroring Start-Deployment.ps1's own Invoke-ComputerNameStep naming
            logic exactly (same Get-SafeComputerName call, same prefix format string). Returns
            $null for 'skip'/'prompt'/an unrecognised mode, which have no deterministic expected
            name to assert against.

        .DESCRIPTION
            Requires Get-SafeComputerName (Deployment\Scripts\Common.ps1) to already be loaded in
            the current session -- otherwise pure (no I/O, no Hyper-V).
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$MergedConfig,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SerialNumber
    )

    $mode = ([string]$MergedConfig.computer_name_mode).ToLowerInvariant()
    switch ($mode) {
        'serial' { return (Get-SafeComputerName -Name $SerialNumber) }
        'prefix_serial' { return (Get-SafeComputerName -Name ('{0}-{1}' -f $MergedConfig.computer_name_prefix, $SerialNumber)) }
        default { return $null }
    }
}

function Get-RehearsalExpectedLocalUsernames {
    <#
        .SYNOPSIS
            Computes the set of local usernames a given merged config should have produced: the
            OSIT account plus every enabled additional_local_users entry. Pure function, mirrors
            Start-Deployment.ps1's own Get-LocalUserDefinitions filtering logic (enabled entries
            only, OSIT itself never duplicated even if also listed in additional_local_users).
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$MergedConfig)

    $ositUsername = [string]$MergedConfig.osit_local_admin_username
    if ([string]::IsNullOrWhiteSpace($ositUsername)) { $ositUsername = 'OSIT' }

    $expected = New-Object 'System.Collections.Generic.List[string]'
    $expected.Add($ositUsername) | Out-Null

    $additional = @()
    if ($MergedConfig.ContainsKey('additional_local_users') -and $null -ne $MergedConfig.additional_local_users) {
        $additional = @($MergedConfig.additional_local_users)
    }

    foreach ($entry in $additional) {
        if ($entry -isnot [System.Collections.IDictionary]) { continue }
        $isEnabled = -not ($entry.Contains('enabled') -and -not [bool]$entry['enabled'])
        $username = [string]$entry['username']
        if ($isEnabled -and -not [string]::IsNullOrWhiteSpace($username) -and ($username -ine $ositUsername)) {
            $expected.Add($username) | Out-Null
        }
    }

    return @($expected | Select-Object -Unique)
}

function Get-RehearsalUnexpectedLocalUsernames {
    <#
        .SYNOPSIS
            Returns which of -ActualUsernames are neither in -ExpectedUsernames nor a known
            Windows built-in account. Pure function (simple set difference).
    #>
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param(
        [string[]]$ActualUsernames = @(),
        [string[]]$ExpectedUsernames = @(),
        [string[]]$KnownBuiltInUsernames = @('Administrator', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount')
    )

    $allowed = @($ExpectedUsernames) + @($KnownBuiltInUsernames)
    return @($ActualUsernames | Where-Object { $allowed -notcontains $_ })
}

function Get-RehearsalArtifactFacts {
    <#
        .SYNOPSIS
            Gathers facts from the harvested artifact folder (Copy-RehearsalArtifacts' output):
            whether the deployment JSON report, Markdown summary, and asset-inventory JSON exist
            under it, and (for the two JSON files) whether they parse.

        .DESCRIPTION
            Real file I/O, but platform-independent -- no Hyper-V or Windows-only cmdlet is
            used, so this (and the assertions built from its output) is unit-tested directly
            against real temporary files/folders, not mocked.

            Searches recursively rather than assuming an exact device-folder path, since
            Copy-RehearsalArtifacts preserves Deployment\Reports\<device>\... structure under a
            'Deployment_Reports' folder and this function does not need to know the device's
            serial-derived folder name to find the files.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ArtifactFolder)

    $facts = [ordered]@{
        report_json_path     = $null
        report_json          = $null
        report_json_error    = $null
        summary_md_path      = $null
        summary_md_content   = $null
        inventory_json_path  = $null
        inventory_json       = $null
        inventory_json_error = $null
    }

    if (-not (Test-Path -LiteralPath $ArtifactFolder -PathType Container)) {
        return $facts
    }

    $reportFile = Get-ChildItem -Path $ArtifactFolder -Recurse -Filter 'deployment-report-*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($reportFile) {
        $facts.report_json_path = $reportFile.FullName
        try {
            $facts.report_json = Get-Content -LiteralPath $reportFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $facts.report_json_error = $_.Exception.Message
        }
    }

    $summaryFile = Get-ChildItem -Path $ArtifactFolder -Recurse -Filter 'deployment-summary-*.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($summaryFile) {
        $facts.summary_md_path = $summaryFile.FullName
        $facts.summary_md_content = Get-Content -LiteralPath $summaryFile.FullName -Raw -ErrorAction SilentlyContinue
    }

    $inventoryFile = Get-ChildItem -Path $ArtifactFolder -Recurse -Filter 'asset-inventory-*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($inventoryFile) {
        $facts.inventory_json_path = $inventoryFile.FullName
        try {
            $facts.inventory_json = Get-Content -LiteralPath $inventoryFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $facts.inventory_json_error = $_.Exception.Message
        }
    }

    return $facts
}

function Get-RehearsalArtifactFileAssertions {
    <#
        .SYNOPSIS
            Builds the "report/summary/asset-inventory files exist and parse, dry_run is
            absent/false" assertion results from an already-gathered Get-RehearsalArtifactFacts
            fact set. Pure function given -Facts (no I/O of its own).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'Facts', Justification = 'Referenced inside each Test-RehearsalAssertion -ScriptBlock below via closure capture; PSScriptAnalyzer''s static analysis does not trace variable usage into nested scriptblock literals.')]
    [OutputType([System.Object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Facts)

    $results = New-Object 'System.Collections.Generic.List[object]'

    $results.Add((Test-RehearsalAssertion -Name 'Deployment JSON report exists and parses' -ScriptBlock {
                if (-not $Facts.report_json_path) { return @{ Status = 'Fail'; Message = 'No deployment-report-*.json found under the harvested artifact folder.' } }
                if ($Facts.report_json_error) { return @{ Status = 'Fail'; Message = "Found $($Facts.report_json_path) but it failed to parse as JSON: $($Facts.report_json_error)" } }
                return @{ Status = 'Pass'; Message = "Found and parsed $($Facts.report_json_path)." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name 'Deployment Markdown summary exists' -ScriptBlock {
                if (-not $Facts.summary_md_path) { return @{ Status = 'Fail'; Message = 'No deployment-summary-*.md found under the harvested artifact folder.' } }
                if ([string]::IsNullOrWhiteSpace($Facts.summary_md_content)) { return @{ Status = 'Fail'; Message = "Found $($Facts.summary_md_path) but it is empty." } }
                return @{ Status = 'Pass'; Message = "Found $($Facts.summary_md_path)." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name 'Asset inventory JSON exists and parses' -ScriptBlock {
                if (-not $Facts.inventory_json_path) { return @{ Status = 'Fail'; Message = 'No asset-inventory-*.json found under the harvested artifact folder.' } }
                if ($Facts.inventory_json_error) { return @{ Status = 'Fail'; Message = "Found $($Facts.inventory_json_path) but it failed to parse as JSON: $($Facts.inventory_json_error)" } }
                return @{ Status = 'Pass'; Message = "Found and parsed $($Facts.inventory_json_path)." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name "Deployment report's dry_run flag is absent or false" -ScriptBlock {
                if (-not $Facts.report_json) { return @{ Status = 'Fail'; Message = 'Cannot check dry_run: deployment-report-*.json was not found or did not parse.' } }
                $hasDryRun = $Facts.report_json.PSObject.Properties.Match('dry_run').Count -gt 0
                if ($hasDryRun -and [bool]$Facts.report_json.dry_run) {
                    return @{ Status = 'Fail'; Message = "Report's dry_run flag is true; a rehearsal must be a REAL run of the deployment inside the VM, never a dry run of it." }
                }
                return @{ Status = 'Pass'; Message = 'dry_run is absent or false, as expected for a real rehearsal run.' }
            })) | Out-Null

    return $results.ToArray()
}

# ============================================================================================
# --- Guest fact gatherers (Hyper-V + PowerShell Direct required) ---
# ============================================================================================

function Get-RehearsalGuestScrubFacts {
    <#
        .SYNOPSIS
            Gathers the FABLE_TASKS.md T13 credential-scrub facts from the guest in one
            PowerShell Direct round trip: Panther/sysprep unattend files, the three Winlogon
            autologon values, the resume scheduled task's registration state, the local handover
            .env, and the MSP WLAN profile.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest reachable via PowerShell Direct.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [string]$HandoverLocalPath = 'C:\1S-WIN11',
        [string]$WifiSsid = 'OneSolution',
        [string]$ResumeTaskName = 'OneSolutionWin11DeploymentResume'
    )

    Assert-HyperVAvailable

    return Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        param($HandoverPath, $Ssid, $TaskName)

        $unattendFiles = @()
        $pantherRoot = Join-Path $env:windir 'Panther'
        if (Test-Path -LiteralPath $pantherRoot) {
            $unattendFiles += @(Get-ChildItem -LiteralPath $pantherRoot -Recurse -Filter '*unattend*' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
        $sysprepUnattend = Join-Path $env:windir 'System32\sysprep\unattend.xml'
        if (Test-Path -LiteralPath $sysprepUnattend -PathType Leaf) { $unattendFiles += $sysprepUnattend }

        $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $winlogonPresent = @{}
        foreach ($valueName in @('DefaultPassword', 'AutoAdminLogon', 'AutoLogonCount')) {
            $winlogonPresent[$valueName] = [bool](Get-ItemProperty -LiteralPath $winlogonKey -Name $valueName -ErrorAction SilentlyContinue)
        }

        $resumeTaskRegistered = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)

        $handoverEnvPath = Join-Path $HandoverPath '.env'
        $handoverEnvExists = Test-Path -LiteralPath $handoverEnvPath -PathType Leaf

        $wlanProfileExists = $false
        try {
            & netsh.exe wlan show profile "name=$Ssid" 2>&1 | Out-Null
            $wlanProfileExists = ($LASTEXITCODE -eq 0)
        } catch {
            $wlanProfileExists = $false
        }

        [ordered]@{
            unattend_files          = @($unattendFiles)
            winlogon_values_present = $winlogonPresent
            resume_task_registered  = $resumeTaskRegistered
            handover_env_path       = $handoverEnvPath
            handover_env_exists     = $handoverEnvExists
            wlan_ssid               = $Ssid
            wlan_profile_exists     = $wlanProfileExists
        }
    } -ArgumentList $HandoverLocalPath, $WifiSsid, $ResumeTaskName
}

function Get-RehearsalGuestIdentityFacts {
    <#
        .SYNOPSIS
            Gathers the FABLE_TASKS.md T13 identity facts from the guest in one PowerShell
            Direct round trip: computer name, BIOS serial number, whether the OSIT account
            exists/is enabled, Administrators group membership, and every local username.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest reachable via PowerShell Direct.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [string]$OsitUsername = 'OSIT'
    )

    Assert-HyperVAvailable

    return Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        param($OsitName)

        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $ositUser = Get-LocalUser -Name $OsitName -ErrorAction SilentlyContinue

        $adminMembers = @()
        try {
            $adminMembers = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | ForEach-Object {
                    # Members come back as "COMPUTERNAME\Username"; keep just the account name so
                    # host-side comparisons never need to know the guest's own computer name.
                    ($_.Name -split '\\')[-1]
                })
        } catch {
            $adminMembers = @()
        }

        $allUsers = @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })

        [ordered]@{
            computer_name          = $env:COMPUTERNAME
            serial_number          = if ($bios) { [string]$bios.SerialNumber } else { '' }
            osit_user_exists       = [bool]$ositUser
            osit_user_enabled      = if ($ositUser) { [bool]$ositUser.Enabled } else { $false }
            administrators_members = $adminMembers
            all_local_usernames    = $allUsers
        }
    } -ArgumentList $OsitUsername
}

function Get-RehearsalGuestPowerFacts {
    <#
        .SYNOPSIS
            Captures the raw `powercfg /query` text for the display/sleep/hibernate power
            settings from the guest in one PowerShell Direct round trip. Parsing is deliberately
            left to the pure Get-PowerCfgTimeoutMinutes helper on the host, not done here.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest reachable via PowerShell Direct.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential
    )

    Assert-HyperVAvailable

    return Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        [ordered]@{
            video_query     = (& powercfg.exe /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Out-String)
            standby_query   = (& powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Out-String)
            hibernate_query = (& powercfg.exe /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE | Out-String)
        }
    }
}

function Get-RehearsalGuestWingetFacts {
    <#
        .SYNOPSIS
            Checks whether each of -PackageIds is detected as installed via `winget list --id
            <id> --exact`, from the guest, in one PowerShell Direct round trip.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest reachable via PowerShell Direct.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string[]]$PackageIds
    )

    Assert-HyperVAvailable

    return Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        param($Ids)

        $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        $installed = [ordered]@{}
        foreach ($id in $Ids) {
            if (-not $wingetCmd) { $installed[$id] = $false; continue }
            & $wingetCmd.Source list --id $id --exact --accept-source-agreements 2>&1 | Out-Null
            # winget list exits with NO_APPLICATIONS_FOUND (-1978335212 / 0x8A150014) when absent.
            $installed[$id] = ($LASTEXITCODE -eq 0)
        }

        [ordered]@{ package_installed = $installed }
    } -ArgumentList (, $PackageIds)
}

function Get-RehearsalGuestDiskFacts {
    <#
        .SYNOPSIS
            Reads the OS disk's partition table from the guest via Get-Partition in one
            PowerShell Direct round trip: partition number, size (MB), GPT type GUID, and GPT
            attributes (formatted as a hex string in-guest so the value survives PS Direct's
            serialization as a plain comparable string).

        .NOTES
            UNVERIFIED ON REAL HYPER-V: requires a live guest reachable via PowerShell Direct.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [int]$DiskNumber = 0
    )

    Assert-HyperVAvailable

    return Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
        param($DiskNum)

        $partitions = @(Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue | Sort-Object PartitionNumber | ForEach-Object {
                $gptType = try { ([guid]$_.GptType).ToString() } catch { [string]$_.GptType }
                [ordered]@{
                    partition_number = $_.PartitionNumber
                    size_mb          = [math]::Round($_.Size / 1MB, 2)
                    gpt_type         = $gptType
                    attributes_hex   = '0x{0:X16}' -f [uint64]$_.Attributes
                }
            })

        [ordered]@{ partitions = $partitions }
    } -ArgumentList $DiskNumber
}

# ============================================================================================
# --- Orchestration ---
# ============================================================================================

function Test-RehearsalResult {
    <#
        .SYNOPSIS
            FABLE_TASKS.md T13's top-level entry point: runs every post-run assertion category
            (completion, credential scrub, identity, config effects, disk layout) against the
            guest (via PowerShell Direct) and the harvested artifact folder, writes
            rehearsal-report-<timestamp>.md, and returns the aggregated result.

        .DESCRIPTION
            Disk-layout assertions only run when -MergedConfig.wipe_repartition_drive is true
            (the Standard scenario's default); a NoWipe-style scenario (T14) has no wiped disk to
            assert about. Every other category always runs.

            Never throws for a guest-reachability failure: each guest fact gatherer is wrapped in
            its own try/catch, so a VM that never booted, or lost PowerShell Direct entirely,
            still produces a complete report with the relevant assertions cleanly marked Fail
            (with the underlying error in the message) rather than aborting the whole suite.

        .PARAMETER VmName
            Name of the rehearsal VM to query via PowerShell Direct. Must still exist.

        .PARAMETER Credential
            OSIT PowerShell Direct credential, matching RehearsalMonitoring.ps1's own pattern
            (built from $media.OsitPassword by the caller).

        .PARAMETER ArtifactFolder
            The folder Copy-RehearsalArtifacts (T12) harvested this run's Logs/Reports/State
            into -- also where rehearsal-report-<timestamp>.md is written by default.

        .PARAMETER MergedConfig
            The resolved/merged scenario config actually shipped to the rehearsal media
            ($media.MergedConfig from New-RehearsalMedia, T10).

        .PARAMETER ReportFolder
            Where to write rehearsal-report-<timestamp>.md. Defaults to -ArtifactFolder.

        .PARAMETER DiskNumber
            The OS disk number to inspect for the disk-layout assertions. Defaults to 0, matching
            deployment_config.json's own wipe_repartition_disk_id default; the caller should pass
            -MergedConfig.wipe_repartition_disk_id explicitly if a scenario ever changes it.

        .PARAMETER PartitionSizeTolerancePercent
            Tolerance (as a percentage of the expected size) for the EFI/MSR/recovery partition
            size comparisons. Defaults to 3.0, per FABLE_TASKS.md T13.

        .OUTPUTS
            Ordered hashtable: @{ Results (assertion records); Summary (Get-RehearsalAssertionSummary
            output); ReportPath (string); Passed (bool) }.

        .NOTES
            UNVERIFIED ON REAL HYPER-V: ties together every Get-RehearsalGuest*Facts function,
            all of which require a real Windows Hyper-V host with a live, reachable guest.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'PartitionSizeTolerancePercent', Justification = 'Referenced inside the disk-layout Test-RehearsalAssertion -ScriptBlock further down via closure capture; PSScriptAnalyzer''s static analysis does not trace variable usage into nested scriptblock literals.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$ArtifactFolder,
        [Parameter(Mandatory = $true)][hashtable]$MergedConfig,
        [string]$ReportFolder,
        [string]$VolumeLabel = '1S-WIN11',
        [int]$DiskNumber = 0,
        [double]$PartitionSizeTolerancePercent = 3.0
    )

    Assert-HyperVAvailable

    if ([string]::IsNullOrWhiteSpace($ReportFolder)) { $ReportFolder = $ArtifactFolder }
    if (-not (Test-Path -LiteralPath $ReportFolder)) {
        New-Item -ItemType Directory -Path $ReportFolder -Force -ErrorAction Stop | Out-Null
    }

    $results = New-Object 'System.Collections.Generic.List[object]'

    # --- 1. Completion ----------------------------------------------------------------------
    # Reuses RehearsalMonitoring.ps1's own Invoke-RehearsalGuestStatusPoll (T12) rather than
    # re-implementing a fresh status poll -- a single, fresh, post-run read of the guest's own
    # Get-DeploymentStatus.ps1 -Json snapshot.
    $statusPoll = Invoke-RehearsalGuestStatusPoll -VmName $VmName -Credential $Credential -VolumeLabel $VolumeLabel
    $snapshot = $statusPoll.snapshot
    $expectedSteps = @(Get-DeploymentSteps)

    $results.Add((Test-RehearsalAssertion -Name 'Guest deployment status snapshot is reachable' -ScriptBlock {
                if (-not $statusPoll.reachable) { return @{ Status = 'Fail'; Message = "PowerShell Direct could not reach VM '$VmName': $($statusPoll.error)" } }
                if (-not $statusPoll.media_found) { return @{ Status = 'Fail'; Message = 'Rehearsal media (1S-WIN11) or Get-DeploymentStatus.ps1 was not found in-guest.' } }
                return @{ Status = 'Pass'; Message = 'Guest deployment status snapshot was read successfully via PowerShell Direct.' }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name "Deployment state shows 'Complete'" -ScriptBlock {
                if (-not $snapshot) { return @{ Status = 'Fail'; Message = 'No guest status snapshot available.' } }
                $completed = @($snapshot.completed_steps)
                if ($completed -contains 'Complete') { return @{ Status = 'Pass'; Message = "'Complete' is present in completed_steps." } }
                return @{ Status = 'Fail'; Message = "'Complete' is not present in completed_steps (current: $($completed -join ', '))." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name 'Every deployment step is completed' -ScriptBlock {
                if (-not $snapshot) { return @{ Status = 'Fail'; Message = 'No guest status snapshot available.' } }
                $completed = @($snapshot.completed_steps)
                $missing = @($expectedSteps | Where-Object { $completed -notcontains $_ })
                if ($missing.Count -eq 0) { return @{ Status = 'Pass'; Message = "All $($expectedSteps.Count) deployment step(s) are in completed_steps." } }
                return @{ Status = 'Fail'; Message = "Missing step(s) from completed_steps: $($missing -join ', ')." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name 'last_error is empty' -ScriptBlock {
                if (-not $snapshot) { return @{ Status = 'Fail'; Message = 'No guest status snapshot available.' } }
                if ($snapshot.last_error) { return @{ Status = 'Fail'; Message = "last_error is present at step '$($snapshot.last_error.step)': $($snapshot.last_error.message)" } }
                return @{ Status = 'Pass'; Message = 'last_error is empty/null.' }
            })) | Out-Null

    # --- 2. Credential scrub (the FABLE_ENHANCE.md P0 items) ---------------------------------
    $handoverConfig = @{}
    if ($MergedConfig.ContainsKey('local_deployment_handover') -and $MergedConfig.local_deployment_handover) {
        $handoverConfig = $MergedConfig.local_deployment_handover
    }
    $handoverLocalPath = 'C:\1S-WIN11'
    if ($handoverConfig.ContainsKey('local_path') -and -not [string]::IsNullOrWhiteSpace([string]$handoverConfig.local_path)) {
        $handoverLocalPath = [string]$handoverConfig.local_path
    }

    $wifiConfig = @{}
    if ($MergedConfig.ContainsKey('msp_wifi_setup') -and $MergedConfig.msp_wifi_setup) {
        $wifiConfig = $MergedConfig.msp_wifi_setup
    }
    $wifiSsid = 'OneSolution'
    if ($wifiConfig.ContainsKey('ssid') -and -not [string]::IsNullOrWhiteSpace([string]$wifiConfig.ssid)) {
        $wifiSsid = [string]$wifiConfig.ssid
    }

    $scrubFacts = $null
    $scrubFactsError = $null
    try {
        $scrubFacts = Get-RehearsalGuestScrubFacts -VmName $VmName -Credential $Credential -HandoverLocalPath $handoverLocalPath -WifiSsid $wifiSsid
    } catch {
        $scrubFactsError = $_.Exception.Message
    }

    $results.Add((Test-RehearsalAssertion -Name 'No Panther/sysprep unattend files remain in-guest' -ScriptBlock {
                if (-not $scrubFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest scrub facts: $scrubFactsError" } }
                $files = @($scrubFacts.unattend_files)
                if ($files.Count -eq 0) { return @{ Status = 'Pass'; Message = 'No Panther/sysprep unattend files were found.' } }
                return @{ Status = 'Fail'; Message = "Found $($files.Count) unattend file(s) still present: $($files -join ', ')" }
            })) | Out-Null

    foreach ($valueName in @('DefaultPassword', 'AutoAdminLogon', 'AutoLogonCount')) {
        $results.Add((Test-RehearsalAssertion -Name "Winlogon value '$valueName' is absent" -ScriptBlock {
                    if (-not $scrubFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest scrub facts: $scrubFactsError" } }
                    if ([bool]$scrubFacts.winlogon_values_present[$valueName]) { return @{ Status = 'Fail'; Message = "Winlogon value '$valueName' is still present." } }
                    return @{ Status = 'Pass'; Message = "Winlogon value '$valueName' is absent." }
                })) | Out-Null
    }

    $results.Add((Test-RehearsalAssertion -Name 'Resume scheduled task is unregistered' -ScriptBlock {
                if (-not $scrubFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest scrub facts: $scrubFactsError" } }
                if ($scrubFacts.resume_task_registered) { return @{ Status = 'Fail'; Message = 'The resume scheduled task is still registered.' } }
                return @{ Status = 'Pass'; Message = 'The resume scheduled task is unregistered.' }
            })) | Out-Null

    # Conditional-by-scenario P0 items: always a real check, never skipped or hardcoded. See
    # this file's header comment for why a Standard rehearsal genuinely (not by assumption)
    # passes these today, and why they will genuinely fail once a scenario that enables the
    # underlying feature is exercised, ahead of the FABLE_ENHANCE.md P0 fix landing.
    $results.Add((Test-RehearsalAssertion -Name 'Local handover .env is scrubbed (FABLE_ENHANCE.md P0)' -ScriptBlock {
                if (-not $scrubFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest scrub facts: $scrubFactsError" } }
                if ($scrubFacts.handover_env_exists) { return @{ Status = 'Fail'; Message = "$($scrubFacts.handover_env_path) still exists (the P0 scrub fix is not implemented yet; see FABLE_ENHANCE.md)." } }
                return @{ Status = 'Pass'; Message = "$($scrubFacts.handover_env_path) is absent." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name 'MSP WLAN profile is scrubbed (FABLE_ENHANCE.md P0)' -ScriptBlock {
                if (-not $scrubFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest scrub facts: $scrubFactsError" } }
                if ($scrubFacts.wlan_profile_exists) { return @{ Status = 'Fail'; Message = "WLAN profile '$($scrubFacts.wlan_ssid)' still exists (the P0 scrub fix is not implemented yet; see FABLE_ENHANCE.md)." } }
                return @{ Status = 'Pass'; Message = "WLAN profile '$($scrubFacts.wlan_ssid)' is absent." }
            })) | Out-Null

    # --- 3. Identity --------------------------------------------------------------------------
    $ositUsername = [string]$MergedConfig.osit_local_admin_username
    if ([string]::IsNullOrWhiteSpace($ositUsername)) { $ositUsername = 'OSIT' }

    $identityFacts = $null
    $identityFactsError = $null
    try {
        $identityFacts = Get-RehearsalGuestIdentityFacts -VmName $VmName -Credential $Credential -OsitUsername $ositUsername
    } catch {
        $identityFactsError = $_.Exception.Message
    }

    $results.Add((Test-RehearsalAssertion -Name 'Computer name matches computer_name_mode' -ScriptBlock {
                if (-not $identityFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest identity facts: $identityFactsError" } }
                $mode = ([string]$MergedConfig.computer_name_mode).ToLowerInvariant()
                if ($mode -eq 'skip' -or $mode -eq 'prompt') {
                    return @{ Status = 'Pass'; Message = "computer_name_mode='$mode' has no deterministic expected name; not asserted (actual: $($identityFacts.computer_name))." }
                }
                $expected = Get-RehearsalExpectedComputerName -MergedConfig $MergedConfig -SerialNumber ([string]$identityFacts.serial_number)
                if (-not $expected) { return @{ Status = 'Fail'; Message = "Could not compute an expected computer name for computer_name_mode '$mode'." } }
                if ($identityFacts.computer_name -ieq $expected) { return @{ Status = 'Pass'; Message = "Computer name '$($identityFacts.computer_name)' matches the expected '$expected' (mode: $mode)." } }
                return @{ Status = 'Fail'; Message = "Computer name is '$($identityFacts.computer_name)'; expected '$expected' (mode: $mode)." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name "OSIT account '$ositUsername' exists and is enabled" -ScriptBlock {
                if (-not $identityFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest identity facts: $identityFactsError" } }
                if (-not $identityFacts.osit_user_exists) { return @{ Status = 'Fail'; Message = "Local user '$ositUsername' does not exist." } }
                if (-not $identityFacts.osit_user_enabled) { return @{ Status = 'Fail'; Message = "Local user '$ositUsername' exists but is disabled." } }
                return @{ Status = 'Pass'; Message = "Local user '$ositUsername' exists and is enabled." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name "OSIT account '$ositUsername' is in Administrators" -ScriptBlock {
                if (-not $identityFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest identity facts: $identityFactsError" } }
                if (@($identityFacts.administrators_members) -contains $ositUsername) { return @{ Status = 'Pass'; Message = "'$ositUsername' is a member of Administrators." } }
                return @{ Status = 'Fail'; Message = "'$ositUsername' was not found in the local Administrators group (members: $($identityFacts.administrators_members -join ', '))." }
            })) | Out-Null

    $results.Add((Test-RehearsalAssertion -Name 'No unexpected extra local users' -ScriptBlock {
                if (-not $identityFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest identity facts: $identityFactsError" } }
                $expectedUsers = Get-RehearsalExpectedLocalUsernames -MergedConfig $MergedConfig
                $unexpected = Get-RehearsalUnexpectedLocalUsernames -ActualUsernames $identityFacts.all_local_usernames -ExpectedUsernames $expectedUsers
                if ($unexpected.Count -eq 0) { return @{ Status = 'Pass'; Message = "Local users match the scenario configuration (expected: $($expectedUsers -join ', '))." } }
                return @{ Status = 'Fail'; Message = "Unexpected local user(s) found: $($unexpected -join ', ')." }
            })) | Out-Null

    # --- 4. Config effects ----------------------------------------------------------------------
    if ([bool]$MergedConfig.configure_power_settings) {
        $batteryMinutes = [int]$MergedConfig.power_timeout_battery_minutes
        $acMinutes = [int]$MergedConfig.power_timeout_ac_minutes

        $powerFacts = $null
        $powerFactsError = $null
        try {
            $powerFacts = Get-RehearsalGuestPowerFacts -VmName $VmName -Credential $Credential
        } catch {
            $powerFactsError = $_.Exception.Message
        }

        $powerChecks = @()
        if ([bool]$MergedConfig.power_manage_display_timeout) { $powerChecks += , @('Display', 'video_query') }
        if ([bool]$MergedConfig.power_manage_sleep_timeout) { $powerChecks += , @('Sleep/standby', 'standby_query') }
        if ([bool]$MergedConfig.power_manage_hibernate_timeout) { $powerChecks += , @('Hibernate', 'hibernate_query') }

        foreach ($check in $powerChecks) {
            $label = $check[0]
            $queryKey = $check[1]
            $results.Add((Test-RehearsalAssertion -Name "powercfg $label timeout matches config" -ScriptBlock {
                        if (-not $powerFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest power facts: $powerFactsError" } }
                        $queryText = [string]$powerFacts[$queryKey]
                        $actualAc = Get-PowerCfgTimeoutMinutes -QueryOutput $queryText -PowerSource 'AC'
                        $actualDc = Get-PowerCfgTimeoutMinutes -QueryOutput $queryText -PowerSource 'DC'
                        if ($null -eq $actualAc -or $null -eq $actualDc) { return @{ Status = 'Fail'; Message = "Could not parse powercfg /query output for $label." } }
                        if ($actualAc -eq $acMinutes -and $actualDc -eq $batteryMinutes) {
                            return @{ Status = 'Pass'; Message = "$label timeout matches config (AC=$actualAc min, battery/DC=$actualDc min)." }
                        }
                        return @{ Status = 'Fail'; Message = "$label timeout mismatch: AC actual=$actualAc expected=$acMinutes min; battery/DC actual=$actualDc expected=$batteryMinutes min." }
                    })) | Out-Null
        }
    }

    if ([bool]$MergedConfig.install_winget_apps) {
        # T14 formalises per-scenario winget lists; until then the Standard scenario's own
        # 1-package placeholder (RehearsalCommon.ps1) is the only one this harness knows about.
        $configuredPackageIds = @(Get-RehearsalStandardWingetPackages | ForEach-Object { [string]$_.id })

        $wingetFacts = $null
        $wingetFactsError = $null
        try {
            $wingetFacts = Get-RehearsalGuestWingetFacts -VmName $VmName -Credential $Credential -PackageIds $configuredPackageIds
        } catch {
            $wingetFactsError = $_.Exception.Message
        }

        foreach ($packageId in $configuredPackageIds) {
            $results.Add((Test-RehearsalAssertion -Name "winget package '$packageId' is installed" -ScriptBlock {
                        if (-not $wingetFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest winget facts: $wingetFactsError" } }
                        if ([bool]$wingetFacts.package_installed[$packageId]) { return @{ Status = 'Pass'; Message = "winget reports '$packageId' as installed." } }
                        return @{ Status = 'Fail'; Message = "winget does not report '$packageId' as installed." }
                    })) | Out-Null
        }
    }

    $artifactFacts = Get-RehearsalArtifactFacts -ArtifactFolder $ArtifactFolder
    foreach ($assertion in (Get-RehearsalArtifactFileAssertions -Facts $artifactFacts)) {
        $results.Add($assertion) | Out-Null
    }

    # --- 5. Disk layout (wipe scenarios only) --------------------------------------------------
    if ([bool]$MergedConfig.wipe_repartition_drive) {
        $diskFacts = $null
        $diskFactsError = $null
        try {
            $diskFacts = Get-RehearsalGuestDiskFacts -VmName $VmName -Credential $Credential -DiskNumber $DiskNumber
        } catch {
            $diskFactsError = $_.Exception.Message
        }

        $results.Add((Test-RehearsalAssertion -Name "Disk $DiskNumber has exactly 4 partitions (ESP/MSR/OS/WinRE)" -ScriptBlock {
                    if (-not $diskFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest disk facts: $diskFactsError" } }
                    $count = @($diskFacts.partitions).Count
                    if ($count -eq 4) { return @{ Status = 'Pass'; Message = 'Found exactly 4 partitions.' } }
                    return @{ Status = 'Fail'; Message = "Found $count partition(s) on disk $DiskNumber; expected 4 (ESP/MSR/OS/WinRE)." }
                })) | Out-Null

        $expectedSizesByPartitionNumber = @{
            1 = @{ Label = 'EFI'; ExpectedMB = [double]$MergedConfig.efi_partition_size_mb }
            2 = @{ Label = 'MSR'; ExpectedMB = [double]$MergedConfig.msr_partition_size_mb }
            4 = @{ Label = 'WinRE'; ExpectedMB = [double]$MergedConfig.recovery_partition_size_mb }
        }

        foreach ($partitionNumber in @(1, 2, 4)) {
            $expected = $expectedSizesByPartitionNumber[$partitionNumber]
            $results.Add((Test-RehearsalAssertion -Name "$($expected.Label) partition (partition $partitionNumber) size is within tolerance" -ScriptBlock {
                        if (-not $diskFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest disk facts: $diskFactsError" } }
                        $partition = @($diskFacts.partitions) | Where-Object { $_.partition_number -eq $partitionNumber } | Select-Object -First 1
                        if (-not $partition) { return @{ Status = 'Fail'; Message = "Partition $partitionNumber was not found." } }
                        $withinTolerance = Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB $expected.ExpectedMB -ActualMB $partition.size_mb -TolerancePercent $PartitionSizeTolerancePercent
                        if ($withinTolerance) { return @{ Status = 'Pass'; Message = "$($expected.Label) partition is $($partition.size_mb) MB (expected $($expected.ExpectedMB) MB +/- $PartitionSizeTolerancePercent%)." } }
                        return @{ Status = 'Fail'; Message = "$($expected.Label) partition is $($partition.size_mb) MB; expected $($expected.ExpectedMB) MB +/- $PartitionSizeTolerancePercent%." }
                    })) | Out-Null
        }

        $results.Add((Test-RehearsalAssertion -Name 'OS partition (partition 3) exists' -ScriptBlock {
                    if (-not $diskFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest disk facts: $diskFactsError" } }
                    $partition = @($diskFacts.partitions) | Where-Object { $_.partition_number -eq 3 } | Select-Object -First 1
                    if ($partition) { return @{ Status = 'Pass'; Message = "OS partition found ($($partition.size_mb) MB)." } }
                    return @{ Status = 'Fail'; Message = 'Partition 3 (OS) was not found.' }
                })) | Out-Null

        $results.Add((Test-RehearsalAssertion -Name 'WinRE partition type GUID is correct' -ScriptBlock {
                    if (-not $diskFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest disk facts: $diskFactsError" } }
                    $partition = @($diskFacts.partitions) | Where-Object { $_.partition_number -eq 4 } | Select-Object -First 1
                    if (-not $partition) { return @{ Status = 'Fail'; Message = 'Partition 4 (WinRE) was not found.' } }
                    if ($partition.gpt_type -ieq $script:RehearsalWinReTypeGuid) { return @{ Status = 'Pass'; Message = "WinRE partition type GUID is $($partition.gpt_type)." } }
                    return @{ Status = 'Fail'; Message = "WinRE partition type GUID is $($partition.gpt_type); expected $script:RehearsalWinReTypeGuid." }
                })) | Out-Null

        $results.Add((Test-RehearsalAssertion -Name 'WinRE partition GPT attributes are correct' -ScriptBlock {
                    if (-not $diskFacts) { return @{ Status = 'Fail'; Message = "Could not gather in-guest disk facts: $diskFactsError" } }
                    $partition = @($diskFacts.partitions) | Where-Object { $_.partition_number -eq 4 } | Select-Object -First 1
                    if (-not $partition) { return @{ Status = 'Fail'; Message = 'Partition 4 (WinRE) was not found.' } }
                    if ($partition.attributes_hex -ieq $script:RehearsalWinReGptAttributesHex) { return @{ Status = 'Pass'; Message = "WinRE partition GPT attributes are $($partition.attributes_hex)." } }
                    return @{ Status = 'Fail'; Message = "WinRE partition GPT attributes are $($partition.attributes_hex); expected $script:RehearsalWinReGptAttributesHex." }
                })) | Out-Null
    }

    # --- Aggregate, render, write -------------------------------------------------------------
    $allResults = $results.ToArray()
    $summary = Get-RehearsalAssertionSummary -Results $allResults
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportPath = Get-RehearsalReportPath -ReportFolder $ReportFolder -Timestamp $timestamp
    $context = [ordered]@{
        'VM name'         = $VmName
        'Artifact folder' = $ArtifactFolder
        'Generated at'    = (Get-Date).ToString('o')
    }
    $markdown = ConvertTo-RehearsalReportMarkdown -Results $allResults -Summary $summary -Context $context
    Set-Content -LiteralPath $reportPath -Value $markdown -Encoding UTF8 -Force -ErrorAction Stop

    return [ordered]@{
        Results    = $allResults
        Summary    = $summary
        ReportPath = $reportPath
        Passed     = [bool]$summary.OverallPass
    }
}
