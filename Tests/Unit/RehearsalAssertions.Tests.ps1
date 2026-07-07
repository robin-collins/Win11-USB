#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for Test\Rehearsal\RehearsalAssertions.ps1 (FABLE_TASKS.md T13 -- post-run
    assertion suite).

    Only the pure/host-only helpers below are tested here: New-RehearsalAssertionResult,
    Test-RehearsalAssertion, Get-RehearsalAssertionSummary, ConvertTo-RehearsalReportMarkdown,
    Get-RehearsalReportPath, Test-RehearsalPartitionSizeWithinTolerance,
    Get-PowerCfgTimeoutMinutes, Get-RehearsalExpectedComputerName,
    Get-RehearsalExpectedLocalUsernames, Get-RehearsalUnexpectedLocalUsernames,
    Get-RehearsalArtifactFacts and Get-RehearsalArtifactFileAssertions (real file I/O against
    real temporary files/folders, but platform-independent). Every other function in that file
    (the Get-RehearsalGuest*Facts gatherers and Test-RehearsalResult itself) requires a live
    Hyper-V guest reachable via PowerShell Direct -- none of which exists on this pwsh 7/Linux
    sandbox. Those were verified instead by dot-sourcing RehearsalAssertions.ps1 alongside
    RehearsalCommon.ps1/RehearsalMonitoring.ps1 and confirming every function loads without
    error, plus manual code review.
#>

BeforeAll {
    $script:CommonScriptPath = Join-Path $PSScriptRoot '..\..\Deployment\Scripts\Common.ps1'
    $script:MonitoringScriptPath = Join-Path $PSScriptRoot '..\..\Test\Rehearsal\RehearsalMonitoring.ps1'
    $script:AssertionsScriptPath = Join-Path $PSScriptRoot '..\..\Test\Rehearsal\RehearsalAssertions.ps1'
    . $script:CommonScriptPath
    . $script:MonitoringScriptPath
    . $script:AssertionsScriptPath
}

Describe 'New-RehearsalAssertionResult' {

    It 'builds an ordered Name/Status/Message/Data record' {
        $result = New-RehearsalAssertionResult -Name 'Some check' -Status 'Pass' -Message 'All good' -Data @{ foo = 'bar' }
        $result.Name | Should -Be 'Some check'
        $result.Status | Should -Be 'Pass'
        $result.Message | Should -Be 'All good'
        $result.Data.foo | Should -Be 'bar'
    }

    It 'defaults Data to $null when not supplied' {
        $result = New-RehearsalAssertionResult -Name 'Some check' -Status 'Fail' -Message 'Nope'
        $result.Data | Should -BeNullOrEmpty
    }

    It 'allows an empty Message string' {
        { New-RehearsalAssertionResult -Name 'Some check' -Status 'Pass' -Message '' } | Should -Not -Throw
    }

    It 'rejects a Status outside Pass/Fail' {
        { New-RehearsalAssertionResult -Name 'Some check' -Status 'Warn' -Message 'x' } | Should -Throw
    }
}

Describe 'Test-RehearsalAssertion' {

    It 'converts a $true scriptblock result to a generic Pass record' {
        $result = Test-RehearsalAssertion -Name 'True check' -ScriptBlock { $true }
        $result.Status | Should -Be 'Pass'
        $result.Name | Should -Be 'True check'
    }

    It 'converts a $false scriptblock result to a generic Fail record' {
        $result = Test-RehearsalAssertion -Name 'False check' -ScriptBlock { $false }
        $result.Status | Should -Be 'Fail'
    }

    It 'passes through a hashtable Status/Message/Data result untouched' {
        $result = Test-RehearsalAssertion -Name 'Hashtable check' -ScriptBlock { @{ Status = 'Pass'; Message = 'Custom message'; Data = @{ n = 1 } } }
        $result.Status | Should -Be 'Pass'
        $result.Message | Should -Be 'Custom message'
        $result.Data.n | Should -Be 1
    }

    It 'defaults a hashtable result missing Status to Fail' {
        $result = Test-RehearsalAssertion -Name 'No status' -ScriptBlock { @{ Message = 'huh' } }
        $result.Status | Should -Be 'Fail'
    }

    It 'coerces an invalid hashtable Status value to Fail' {
        $result = Test-RehearsalAssertion -Name 'Bad status' -ScriptBlock { @{ Status = 'Maybe'; Message = 'huh' } }
        $result.Status | Should -Be 'Fail'
    }

    It 'defaults a hashtable result missing Message to an empty string' {
        $result = Test-RehearsalAssertion -Name 'No message' -ScriptBlock { @{ Status = 'Pass' } }
        $result.Message | Should -Be ''
    }

    It 'catches an exception thrown by the scriptblock and converts it to a Fail record' {
        $result = Test-RehearsalAssertion -Name 'Throws' -ScriptBlock { throw 'boom' }
        $result.Status | Should -Be 'Fail'
        $result.Message | Should -Match 'boom'
    }

    It 'converts a $null scriptblock result to a Fail record rather than throwing' {
        $result = Test-RehearsalAssertion -Name 'Null result' -ScriptBlock { $null }
        $result.Status | Should -Be 'Fail'
        $result.Message | Should -Match 'returned nothing'
    }

    It 'converts an unsupported result type (e.g. a string) to a Fail record rather than throwing' {
        $result = Test-RehearsalAssertion -Name 'String result' -ScriptBlock { 'just a string' }
        $result.Status | Should -Be 'Fail'
        $result.Message | Should -Match 'unsupported result type'
    }

    It 'never throws regardless of what the scriptblock does' {
        { Test-RehearsalAssertion -Name 'Throws' -ScriptBlock { throw 'boom' } } | Should -Not -Throw
        { Test-RehearsalAssertion -Name 'Null' -ScriptBlock { $null } } | Should -Not -Throw
        { Test-RehearsalAssertion -Name 'String' -ScriptBlock { 'x' } } | Should -Not -Throw
    }
}

Describe 'Get-RehearsalAssertionSummary' {

    It 'counts total/passed/failed correctly' {
        $results = @(
            (New-RehearsalAssertionResult -Name 'a' -Status 'Pass' -Message ''),
            (New-RehearsalAssertionResult -Name 'b' -Status 'Pass' -Message ''),
            (New-RehearsalAssertionResult -Name 'c' -Status 'Fail' -Message '')
        )
        $summary = Get-RehearsalAssertionSummary -Results $results
        $summary.Total | Should -Be 3
        $summary.Passed | Should -Be 2
        $summary.Failed | Should -Be 1
    }

    It 'reports OverallPass true when every result passed' {
        $results = @(
            (New-RehearsalAssertionResult -Name 'a' -Status 'Pass' -Message ''),
            (New-RehearsalAssertionResult -Name 'b' -Status 'Pass' -Message '')
        )
        (Get-RehearsalAssertionSummary -Results $results).OverallPass | Should -BeTrue
    }

    It 'reports OverallPass false when any result failed' {
        $results = @(
            (New-RehearsalAssertionResult -Name 'a' -Status 'Pass' -Message ''),
            (New-RehearsalAssertionResult -Name 'b' -Status 'Fail' -Message '')
        )
        (Get-RehearsalAssertionSummary -Results $results).OverallPass | Should -BeFalse
    }

    It 'adversarial: an empty result list is never reported as an overall pass' {
        $summary = Get-RehearsalAssertionSummary -Results @()
        $summary.Total | Should -Be 0
        $summary.OverallPass | Should -BeFalse
    }

    It 'defaults to an empty result set when -Results is not supplied' {
        $summary = Get-RehearsalAssertionSummary
        $summary.Total | Should -Be 0
        $summary.OverallPass | Should -BeFalse
    }
}

Describe 'ConvertTo-RehearsalReportMarkdown' {

    It 'renders an overall PASS heading and a table row per result' {
        $results = @(
            (New-RehearsalAssertionResult -Name 'Check one' -Status 'Pass' -Message 'Looks good')
        )
        $summary = Get-RehearsalAssertionSummary -Results $results
        $markdown = ConvertTo-RehearsalReportMarkdown -Results $results -Summary $summary
        $markdown | Should -Match 'Overall result: PASS'
        $markdown | Should -Match '\| PASS \| Check one \| Looks good \|'
    }

    It 'renders an overall FAIL heading when a result failed' {
        $results = @((New-RehearsalAssertionResult -Name 'Check one' -Status 'Fail' -Message 'Broke'))
        $summary = Get-RehearsalAssertionSummary -Results $results
        (ConvertTo-RehearsalReportMarkdown -Results $results -Summary $summary) | Should -Match 'Overall result: FAIL'
    }

    It 'renders each -Context entry as a bullet line' {
        $summary = Get-RehearsalAssertionSummary -Results @()
        $markdown = ConvertTo-RehearsalReportMarkdown -Results @() -Summary $summary -Context @{ VmName = 'rehearsal-vm-01' }
        $markdown | Should -Match '\*\*VmName\*\*: rehearsal-vm-01'
    }

    It 'escapes embedded newlines in a message so the Markdown table row stays on one line' {
        $results = @((New-RehearsalAssertionResult -Name 'Multiline' -Status 'Fail' -Message "line one`r`nline two"))
        $summary = Get-RehearsalAssertionSummary -Results $results
        $markdown = ConvertTo-RehearsalReportMarkdown -Results $results -Summary $summary
        ($markdown -split "`r`n" | Where-Object { $_ -match '^\| FAIL \|' }) | Should -HaveCount 1
    }

    It 'produces no table rows when -Results is empty' {
        $summary = Get-RehearsalAssertionSummary -Results @()
        $markdown = ConvertTo-RehearsalReportMarkdown -Results @() -Summary $summary
        $markdown | Should -Match '0/0 assertions passed'
    }
}

Describe 'Get-RehearsalReportPath' {

    It 'joins the report folder and timestamp into the expected filename' {
        # A drive-letter-free path is used deliberately: Join-Path with a literal 'C:\...' path
        # throws DriveNotFoundException on non-Windows pwsh (no C: PSDrive exists), which this
        # test suite must run under.
        Get-RehearsalReportPath -ReportFolder 'Artifacts\20260706-143000' -Timestamp '20260706-143000' |
            Should -Be (Join-Path 'Artifacts\20260706-143000' 'rehearsal-report-20260706-143000.md')
    }
}

Describe 'Test-RehearsalPartitionSizeWithinTolerance' {

    It 'passes when actual matches expected exactly' {
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 100000 -ActualMB 100000 | Should -BeTrue
    }

    It 'passes when actual is within the default 3% tolerance' {
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 100000 -ActualMB 102000 | Should -BeTrue
    }

    It 'fails when actual exceeds the default 3% tolerance' {
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 100000 -ActualMB 105000 | Should -BeFalse
    }

    It 'honours a custom -TolerancePercent' {
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 100000 -ActualMB 105000 -TolerancePercent 10 | Should -BeTrue
    }

    It 'treats a negative deviation symmetrically' {
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 100000 -ActualMB 95000 | Should -BeFalse
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 100000 -ActualMB 98500 | Should -BeTrue
    }

    It 'adversarial: returns $false rather than dividing by zero when -ExpectedMB is zero or negative' {
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB 0 -ActualMB 100 | Should -BeFalse
        Test-RehearsalPartitionSizeWithinTolerance -ExpectedMB -50 -ActualMB 100 | Should -BeFalse
    }
}

Describe 'Get-PowerCfgTimeoutMinutes' {

    It 'parses the AC power setting index and converts seconds to minutes' {
        $query = @'
Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Sleep after)
  GUID Alias: SUB_SLEEP
Current AC Power Setting Index: 0x00000708
Current DC Power Setting Index: 0x00000000
'@
        Get-PowerCfgTimeoutMinutes -QueryOutput $query -PowerSource 'AC' | Should -Be 30
    }

    It 'parses the DC power setting index independently of AC' {
        $query = @'
Current AC Power Setting Index: 0x00000708
Current DC Power Setting Index: 0x00000258
'@
        Get-PowerCfgTimeoutMinutes -QueryOutput $query -PowerSource 'DC' | Should -Be 10
    }

    It 'treats a 0x00000000 index as never (0 minutes) rather than $null' {
        $query = 'Current AC Power Setting Index: 0x00000000'
        Get-PowerCfgTimeoutMinutes -QueryOutput $query -PowerSource 'AC' | Should -Be 0
    }

    It 'returns $null when the requested power source line is absent' {
        $query = 'Current DC Power Setting Index: 0x00000258'
        Get-PowerCfgTimeoutMinutes -QueryOutput $query -PowerSource 'AC' | Should -BeNullOrEmpty
    }

    It 'adversarial: returns $null for empty query output rather than throwing' {
        { Get-PowerCfgTimeoutMinutes -QueryOutput '' -PowerSource 'AC' } | Should -Not -Throw
        Get-PowerCfgTimeoutMinutes -QueryOutput '' -PowerSource 'AC' | Should -BeNullOrEmpty
    }
}

Describe 'Get-RehearsalExpectedComputerName' {

    It "computes the expected name for computer_name_mode 'serial'" {
        $config = @{ computer_name_mode = 'serial' }
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' | Should -Be 'ABC12345'
    }

    It "computes the expected name for computer_name_mode 'prefix_serial'" {
        $config = @{ computer_name_mode = 'prefix_serial'; computer_name_prefix = 'OSIT' }
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' | Should -Be 'OSIT-ABC12345'
    }

    It 'normalises the computed name the same way Get-SafeComputerName does (uppercase, 15-char cap)' {
        $config = @{ computer_name_mode = 'serial' }
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'abc-def-0123456789' | Should -Be (Get-SafeComputerName -Name 'abc-def-0123456789')
    }

    It "returns `$null for computer_name_mode 'skip'" {
        $config = @{ computer_name_mode = 'skip' }
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' | Should -BeNullOrEmpty
    }

    It "returns `$null for computer_name_mode 'prompt'" {
        $config = @{ computer_name_mode = 'prompt' }
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' | Should -BeNullOrEmpty
    }

    It 'adversarial: returns $null for an unrecognised mode rather than throwing' {
        $config = @{ computer_name_mode = 'something-unexpected' }
        { Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' } | Should -Not -Throw
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' | Should -BeNullOrEmpty
    }

    It 'is case-insensitive on computer_name_mode' {
        $config = @{ computer_name_mode = 'SERIAL' }
        Get-RehearsalExpectedComputerName -MergedConfig $config -SerialNumber 'ABC12345' | Should -Be 'ABC12345'
    }
}

Describe 'Get-RehearsalExpectedLocalUsernames' {

    It 'defaults the OSIT username to OSIT when osit_local_admin_username is blank' {
        $config = @{ osit_local_admin_username = ''; additional_local_users = @() }
        Get-RehearsalExpectedLocalUsernames -MergedConfig $config | Should -Be @('OSIT')
    }

    It 'uses a custom osit_local_admin_username when supplied' {
        $config = @{ osit_local_admin_username = 'LocalAdmin'; additional_local_users = @() }
        Get-RehearsalExpectedLocalUsernames -MergedConfig $config | Should -Be @('LocalAdmin')
    }

    It 'includes enabled additional_local_users entries' {
        $config = @{
            osit_local_admin_username = 'OSIT'
            additional_local_users    = @(
                @{ username = 'TechUser'; enabled = $true },
                @{ username = 'DisabledUser'; enabled = $false }
            )
        }
        $expected = Get-RehearsalExpectedLocalUsernames -MergedConfig $config
        $expected | Should -Contain 'OSIT'
        $expected | Should -Contain 'TechUser'
        $expected | Should -Not -Contain 'DisabledUser'
    }

    It 'treats an additional_local_users entry with no enabled key as enabled' {
        $config = @{
            osit_local_admin_username = 'OSIT'
            additional_local_users    = @(@{ username = 'TechUser' })
        }
        Get-RehearsalExpectedLocalUsernames -MergedConfig $config | Should -Contain 'TechUser'
    }

    It 'never duplicates the OSIT account even if it also appears in additional_local_users' {
        $config = @{
            osit_local_admin_username = 'OSIT'
            additional_local_users    = @(@{ username = 'OSIT'; enabled = $true })
        }
        @(Get-RehearsalExpectedLocalUsernames -MergedConfig $config) | Should -HaveCount 1
    }

    It 'adversarial: tolerates a missing additional_local_users key' {
        $config = @{ osit_local_admin_username = 'OSIT' }
        { Get-RehearsalExpectedLocalUsernames -MergedConfig $config } | Should -Not -Throw
        Get-RehearsalExpectedLocalUsernames -MergedConfig $config | Should -Be @('OSIT')
    }

    It 'adversarial: skips non-hashtable entries in additional_local_users rather than throwing' {
        $config = @{
            osit_local_admin_username = 'OSIT'
            additional_local_users    = @('not-a-hashtable', @{ username = 'TechUser'; enabled = $true })
        }
        { Get-RehearsalExpectedLocalUsernames -MergedConfig $config } | Should -Not -Throw
        Get-RehearsalExpectedLocalUsernames -MergedConfig $config | Should -Contain 'TechUser'
    }
}

Describe 'Get-RehearsalUnexpectedLocalUsernames' {

    It 'returns actual usernames not present in expected or built-in lists' {
        $unexpected = Get-RehearsalUnexpectedLocalUsernames -ActualUsernames @('OSIT', 'Administrator', 'RogueUser') -ExpectedUsernames @('OSIT')
        $unexpected | Should -Be @('RogueUser')
    }

    It 'never flags a known Windows built-in account' {
        $unexpected = Get-RehearsalUnexpectedLocalUsernames -ActualUsernames @('Guest', 'DefaultAccount', 'WDAGUtilityAccount') -ExpectedUsernames @('OSIT')
        $unexpected | Should -BeNullOrEmpty
    }

    It 'returns an empty array when every actual username is expected' {
        Get-RehearsalUnexpectedLocalUsernames -ActualUsernames @('OSIT') -ExpectedUsernames @('OSIT') | Should -BeNullOrEmpty
    }

    It 'honours a custom -KnownBuiltInUsernames list' {
        $unexpected = Get-RehearsalUnexpectedLocalUsernames -ActualUsernames @('CustomBuiltIn') -ExpectedUsernames @() -KnownBuiltInUsernames @('CustomBuiltIn')
        $unexpected | Should -BeNullOrEmpty
    }
}

Describe 'Get-RehearsalArtifactFacts and Get-RehearsalArtifactFileAssertions (real temp files)' {

    BeforeEach {
        $script:ArtifactFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("rehearsal-assert-test-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:ArtifactFolder -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:ArtifactFolder) {
            Remove-Item -LiteralPath $script:ArtifactFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports every path as $null when the artifact folder does not exist' {
        $missingFolder = Join-Path ([System.IO.Path]::GetTempPath()) "rehearsal-assert-missing-$([guid]::NewGuid().ToString('N'))"
        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $missingFolder
        $facts.report_json_path | Should -BeNullOrEmpty
        $facts.summary_md_path | Should -BeNullOrEmpty
        $facts.inventory_json_path | Should -BeNullOrEmpty
    }

    It 'finds and parses a well-formed deployment report, summary, and inventory' {
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'deployment-report-run1.json') -Value '{"dry_run": false, "status": "Ready for customer onboarding"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'deployment-summary-run1.md') -Value '# Summary' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'asset-inventory-run1.json') -Value '{"computer": {"computer_name": "TEST01"}}' -Encoding UTF8

        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $script:ArtifactFolder
        $facts.report_json_path | Should -Not -BeNullOrEmpty
        $facts.report_json.status | Should -Be 'Ready for customer onboarding'
        $facts.report_json_error | Should -BeNullOrEmpty
        $facts.summary_md_content | Should -Match '# Summary'
        $facts.inventory_json.computer.computer_name | Should -Be 'TEST01'
        $facts.inventory_json_error | Should -BeNullOrEmpty
    }

    It 'finds files nested under a preserved directory structure (Copy-RehearsalArtifacts layout)' {
        $nested = Join-Path $script:ArtifactFolder 'Deployment_Reports\SomeDevice'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'deployment-report-run1.json') -Value '{"dry_run": false}' -Encoding UTF8

        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $script:ArtifactFolder
        $facts.report_json_path | Should -Match 'deployment-report-run1\.json$'
    }

    It 'records a parse error rather than throwing when a JSON file is malformed' {
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'deployment-report-run1.json') -Value '{ not valid json ' -Encoding UTF8

        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $script:ArtifactFolder
        $facts.report_json_path | Should -Not -BeNullOrEmpty
        $facts.report_json_error | Should -Not -BeNullOrEmpty
        $facts.report_json | Should -BeNullOrEmpty
    }

    It 'Get-RehearsalArtifactFileAssertions fails all four checks when the folder is empty' {
        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $script:ArtifactFolder
        $results = Get-RehearsalArtifactFileAssertions -Facts $facts
        $results | Should -HaveCount 4
        ($results | Where-Object { $_.Status -eq 'Fail' }) | Should -HaveCount 4
    }

    It 'Get-RehearsalArtifactFileAssertions passes all four checks for a well-formed, non-dry-run artifact set' {
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'deployment-report-run1.json') -Value '{"dry_run": false}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'deployment-summary-run1.md') -Value '# Summary' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'asset-inventory-run1.json') -Value '{}' -Encoding UTF8

        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $script:ArtifactFolder
        $results = Get-RehearsalArtifactFileAssertions -Facts $facts
        ($results | Where-Object { $_.Status -eq 'Fail' }) | Should -BeNullOrEmpty
    }

    It "fails the dry_run assertion when the harvested report's dry_run flag is true" {
        Set-Content -LiteralPath (Join-Path $script:ArtifactFolder 'deployment-report-run1.json') -Value '{"dry_run": true}' -Encoding UTF8

        $facts = Get-RehearsalArtifactFacts -ArtifactFolder $script:ArtifactFolder
        $results = Get-RehearsalArtifactFileAssertions -Facts $facts
        $dryRunResult = $results | Where-Object { $_.Name -match 'dry_run flag' }
        $dryRunResult.Status | Should -Be 'Fail'
    }
}

Describe 'Get-RehearsalAdditionalUsersAssertions and Get-RehearsalScenarioExtraAssertions (T14, real temp files)' {

    BeforeEach {
        $script:ArtifactFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("rehearsal-extra-assert-test-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $script:ArtifactFolder -Force | Out-Null
        $script:MergedConfig = @{
            additional_local_users = @(
                @{ username = 'RehearsalTech'; enabled = $true; password_mode = 'random'; groups = @('Users') }
            )
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:ArtifactFolder) {
            Remove-Item -LiteralPath $script:ArtifactFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns two assertions per random-password additional_local_users entry' {
        $results = Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig
        $results | Should -HaveCount 2
    }

    It 'fails the "exists on media" check when no password report file was harvested' {
        $results = Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig
        $existsResult = $results | Where-Object { $_.Name -match 'exists on media' }
        $existsResult.Status | Should -Be 'Fail'
    }

    It 'passes the "exists on media" check once the password report file is present anywhere under the artifact folder' {
        $nested = Join-Path $script:ArtifactFolder 'Deployment_Reports\SomeDevice'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'local-user-password-RehearsalTech-run001.txt') -Value 'Sup3rSecret!' -Encoding UTF8

        $results = Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig
        $existsResult = $results | Where-Object { $_.Name -match 'exists on media' }
        $existsResult.Status | Should -Be 'Pass'
    }

    It 'passes the "not emailed" check when no harvested log references the password file at all (the vacuous case: SMTP disabled)' {
        $results = Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig
        $notEmailedResult = $results | Where-Object { $_.Name -match 'not emailed' }
        $notEmailedResult.Status | Should -Be 'Pass'
    }

    It 'fails the "not emailed" check when a harvested log line references the password file alongside the word "attach"' {
        $logDir = Join-Path $script:ArtifactFolder 'Deployment_Logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $logDir 'deploy.log') -Value 'Deployment email sent with attach: local-user-password-RehearsalTech-run001.txt' -Encoding UTF8

        $results = Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig
        $notEmailedResult = $results | Where-Object { $_.Name -match 'not emailed' }
        $notEmailedResult.Status | Should -Be 'Fail'
    }

    It 'ignores a disabled additional_local_users entry (no assertions for it)' {
        $config = @{ additional_local_users = @(@{ username = 'Disabled'; enabled = $false; password_mode = 'random' }) }
        @(Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $config) | Should -HaveCount 0
    }

    It 'ignores a non-random password_mode entry (osit_secret/prompt have no generated report file to check)' {
        $config = @{ additional_local_users = @(@{ username = 'Prompted'; enabled = $true; password_mode = 'prompt' }) }
        @(Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig $config) | Should -HaveCount 0
    }

    It 'adversarial: an empty additional_local_users list produces no assertions' {
        @(Get-RehearsalAdditionalUsersAssertions -ArtifactFolder $script:ArtifactFolder -MergedConfig @{ additional_local_users = @() }) | Should -HaveCount 0
    }

    It 'Get-RehearsalScenarioExtraAssertions dispatches to the AdditionalUsers set only for that scenario name' {
        @(Get-RehearsalScenarioExtraAssertions -Scenario 'AdditionalUsers' -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig) | Should -HaveCount 2
    }

    It 'Get-RehearsalScenarioExtraAssertions returns nothing for every other scenario name' {
        foreach ($scenario in @('Standard', 'NoWipe', 'Handover', 'ResumeKill')) {
            @(Get-RehearsalScenarioExtraAssertions -Scenario $scenario -ArtifactFolder $script:ArtifactFolder -MergedConfig $script:MergedConfig) | Should -HaveCount 0
        }
    }
}
