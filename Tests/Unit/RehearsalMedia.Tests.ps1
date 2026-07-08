#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for the T10 (FABLE_TASKS.md) pure helpers backing New-RehearsalMedia in
    Test\Rehearsal\RehearsalCommon.ps1:
      - Get-RehearsalStandardScenarioOverlay
      - Get-RehearsalStandardWingetPackages
      - Merge-RehearsalScenarioConfig
      - New-RehearsalDotEnvContent
    Plus a smoke test of New-RehearsalMedia's own up-front platform guard.

    New-RehearsalMedia itself is NOT tested beyond that guard: building a real VHDX requires
    New-VHD/Mount-VHD/Initialize-Disk/New-Partition/Format-Volume/Dismount-VHD (Hyper-V/Storage
    cmdlets that only exist on a Windows host with Hyper-V), and running the real
    Initialize-UsbDeployment.ps1 against a mounted volume needs an actual Windows filesystem and
    the whole Deployment\ tree behind it. None of that is exercisable in this toolkit's Linux
    CI/dev sandbox -- see Tests\README.md's "what's intentionally out of scope" note.
    FABLE_TASKS.md T10's full acceptance criteria (byte-for-byte Validate-Unattend.ps1
    -Generated pass against the mounted media, idempotent re-run producing a fresh VHDX each
    time, exact volume label 1S-WIN11) require a real Windows/Hyper-V host to verify.

    Convention: matches Tests\Unit\Common.Tests.ps1 / DryRun.Tests.ps1 -- dot-source directly (no
    module manifest), PowerShell 5.1-compatible syntax only (no ternary/null-coalescing), and
    Pester v5 Describe/It/BeforeAll structure.
#>

BeforeAll {
    # Common.ps1 for Merge-Config (used by Merge-RehearsalScenarioConfig) and Get-DotEnvValue
    # (used by the .env round-trip test below) -- confirmed side-effect-free at dot-source time
    # by the existing Common.Tests.ps1 suite.
    . "$PSScriptRoot/../../Deployment/Scripts/Common.ps1"
    # RehearsalCommon.ps1 itself has no side effects at dot-source time either: it only sets
    # script-scoped variables (including the new $script:RehearsalRepoRoot, computed from
    # $PSScriptRoot) and defines functions.
    . "$PSScriptRoot/../../Test/Rehearsal/RehearsalCommon.ps1"
}

Describe 'Get-RehearsalStandardScenarioOverlay' {
    It 'returns the exact T10 Standard baseline described in FABLE_TASKS.md' {
        $overlay = Get-RehearsalStandardScenarioOverlay
        $overlay.wipe_repartition_drive | Should -BeTrue
        $overlay.wipe_minimum_target_disk_gb | Should -Be 60
        $overlay.require_ac_power | Should -BeFalse
        $overlay.msp_wifi_setup.enabled | Should -BeFalse
        $overlay.computer_name_mode | Should -Be 'serial'
        $overlay.install_winget_apps | Should -BeTrue
        $overlay.datto_rmm_site_id_uuid | Should -Be ''
    }

    It 'returns a fresh hashtable on every call (no shared mutable state between callers)' {
        $first = Get-RehearsalStandardScenarioOverlay
        $first.computer_name_mode = 'mutated'
        $second = Get-RehearsalStandardScenarioOverlay
        $second.computer_name_mode | Should -Be 'serial'
    }
}

Describe 'Get-RehearsalStandardWingetPackages' {
    It 'returns exactly one placeholder package' {
        @(Get-RehearsalStandardWingetPackages).Count | Should -Be 1
    }

    It 'the placeholder package has the shape winget_packages.json expects' {
        $package = @(Get-RehearsalStandardWingetPackages)[0]
        $package.id | Should -Not -BeNullOrEmpty
        $package.display_name | Should -Not -BeNullOrEmpty
        $package.ContainsKey('required') | Should -BeTrue
        $package.ContainsKey('install_arguments') | Should -BeTrue
    }
}

Describe 'Merge-RehearsalScenarioConfig' {
    BeforeEach {
        $script:BaseConfig = @{
            wipe_repartition_drive = $false
            computer_name_mode     = 'prompt'
            msp_wifi_setup          = @{
                enabled                 = $true
                ssid                    = 'OneSolution'
                password_env_var        = 'OSIT_WIFI_PASSWORD'
                authentication          = 'WPA2PSK'
                encryption              = 'AES'
                connect_timeout_seconds = 60
            }
        }
    }

    It 'overrides top-level scalar keys present in the overlay' {
        $merged = Merge-RehearsalScenarioConfig -BaseConfig $script:BaseConfig -Overlay @{ wipe_repartition_drive = $true }
        $merged.wipe_repartition_drive | Should -BeTrue
    }

    It 'leaves top-level keys not present in the overlay untouched' {
        $merged = Merge-RehearsalScenarioConfig -BaseConfig $script:BaseConfig -Overlay @{ wipe_repartition_drive = $true }
        $merged.computer_name_mode | Should -Be 'prompt'
    }

    It 'deep-merges msp_wifi_setup: the overlay''s enabled flag applies without clobbering sibling keys' {
        $merged = Merge-RehearsalScenarioConfig -BaseConfig $script:BaseConfig -Overlay @{ msp_wifi_setup = @{ enabled = $false } }
        $merged.msp_wifi_setup.enabled | Should -BeFalse
        $merged.msp_wifi_setup.ssid | Should -Be 'OneSolution'
        $merged.msp_wifi_setup.password_env_var | Should -Be 'OSIT_WIFI_PASSWORD'
        $merged.msp_wifi_setup.connect_timeout_seconds | Should -Be 60
    }

    It 'adversarial: a base config missing msp_wifi_setup entirely still applies the overlay''s keys' {
        $baseWithoutWifi = @{ wipe_repartition_drive = $false }
        $merged = Merge-RehearsalScenarioConfig -BaseConfig $baseWithoutWifi -Overlay @{ msp_wifi_setup = @{ enabled = $false } }
        $merged.msp_wifi_setup.enabled | Should -BeFalse
    }

    It 'the real T10 Standard overlay merges cleanly over a production-shaped config' {
        $realShapedBase = @{
            wipe_repartition_drive = $false
            require_ac_power       = $true
            computer_name_mode     = 'prompt'
            install_winget_apps    = $false
            datto_rmm_site_id_uuid = '1193f864-66b2-49fd-bafe-950ba1e803e5'
            msp_wifi_setup          = @{
                enabled                 = $true
                ssid                    = 'OneSolution'
                password_env_var        = 'OSIT_WIFI_PASSWORD'
                authentication          = 'WPA2PSK'
                encryption              = 'AES'
                connect_timeout_seconds = 60
            }
        }
        $merged = Merge-RehearsalScenarioConfig -BaseConfig $realShapedBase -Overlay (Get-RehearsalStandardScenarioOverlay)
        $merged.wipe_repartition_drive | Should -BeTrue
        $merged.require_ac_power | Should -BeFalse
        $merged.computer_name_mode | Should -Be 'serial'
        $merged.install_winget_apps | Should -BeTrue
        $merged.datto_rmm_site_id_uuid | Should -Be ''
        $merged.msp_wifi_setup.enabled | Should -BeFalse
        $merged.msp_wifi_setup.ssid | Should -Be 'OneSolution'
    }

    It 'does not mutate the caller''s BaseConfig hashtable' {
        $originalWifiEnabled = $script:BaseConfig.msp_wifi_setup.enabled
        Merge-RehearsalScenarioConfig -BaseConfig $script:BaseConfig -Overlay @{ msp_wifi_setup = @{ enabled = $false } } | Out-Null
        $script:BaseConfig.msp_wifi_setup.enabled | Should -Be $originalWifiEnabled
    }

    It 'adversarial: an overlay with no msp_wifi_setup key leaves the base''s wifi config completely untouched' {
        $merged = Merge-RehearsalScenarioConfig -BaseConfig $script:BaseConfig -Overlay @{ computer_name_mode = 'serial' }
        $merged.msp_wifi_setup.enabled | Should -BeTrue
        $merged.msp_wifi_setup.ssid | Should -Be 'OneSolution'
    }
}

Describe 'New-RehearsalDotEnvContent' {
    It 'renders one NAME=value line per non-blank secret' {
        $lines = @(New-RehearsalDotEnvContent -Secrets @{ OSIT_LOCAL_ADMIN_PASSWORD = 'Sup3rSecret!' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'OSIT_LOCAL_ADMIN_PASSWORD=Sup3rSecret!'
    }

    It 'sorts multiple secrets by name for deterministic output' {
        $lines = @(New-RehearsalDotEnvContent -Secrets @{
                OSIT_WIFI_PASSWORD        = 'wifi-pass'
                OSIT_LOCAL_ADMIN_PASSWORD = 'admin-pass'
            })
        $lines[0] | Should -Be 'OSIT_LOCAL_ADMIN_PASSWORD=admin-pass'
        $lines[1] | Should -Be 'OSIT_WIFI_PASSWORD=wifi-pass'
    }

    It 'adversarial: omits a null, empty, or whitespace-only secret entirely rather than writing NAME=' {
        $lines = @(New-RehearsalDotEnvContent -Secrets @{
                OSIT_LOCAL_ADMIN_PASSWORD = 'admin-pass'
                OSIT_WIFI_PASSWORD        = ''
                OSIT_SMTP_PASSWORD        = $null
            })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'OSIT_LOCAL_ADMIN_PASSWORD=admin-pass'
    }

    It 'adversarial: an empty secrets map produces no lines' {
        @(New-RehearsalDotEnvContent -Secrets @{}).Count | Should -Be 0
    }

    It 'round-trips through Get-DotEnvValue (Common.ps1), the reader this content is written for' {
        $envPath = Join-Path $TestDrive '.env'
        Set-Content -LiteralPath $envPath -Value @(New-RehearsalDotEnvContent -Secrets @{ OSIT_LOCAL_ADMIN_PASSWORD = 'round-trip-pass' }) -Encoding UTF8
        Get-DotEnvValue -Path $envPath -Name 'OSIT_LOCAL_ADMIN_PASSWORD' | Should -Be 'round-trip-pass'
    }
}

Describe 'Get-RehearsalKnownScenarioNames (T14)' {
    It 'always includes Standard' {
        Get-RehearsalKnownScenarioNames | Should -Contain 'Standard'
    }

    It 'includes every real scenario folder under Test\Rehearsal\Scenarios' {
        $names = Get-RehearsalKnownScenarioNames
        foreach ($expected in @('NoWipe', 'Handover', 'ResumeKill', 'AdditionalUsers')) {
            $names | Should -Contain $expected
        }
    }
}

Describe 'Assert-RehearsalScenarioKnown (T14)' {
    It 'does not throw for Standard' {
        { Assert-RehearsalScenarioKnown -Scenario 'Standard' } | Should -Not -Throw
    }

    It 'does not throw for a real on-disk scenario, case-insensitively' {
        { Assert-RehearsalScenarioKnown -Scenario 'nowipe' } | Should -Not -Throw
    }

    It 'throws with a ''not recognised'' message for an unknown scenario' {
        { Assert-RehearsalScenarioKnown -Scenario 'DoesNotExist' } | Should -Throw '*not recognised*'
    }
}

Describe 'Resolve-RehearsalScenarioOverlay (T14)' {
    It 'returns the same overlay as Get-RehearsalStandardScenarioOverlay for Standard' {
        $resolved = Resolve-RehearsalScenarioOverlay -Scenario 'Standard'
        $literal = Get-RehearsalStandardScenarioOverlay
        $resolved.wipe_repartition_drive | Should -Be $literal.wipe_repartition_drive
        $resolved.computer_name_mode | Should -Be $literal.computer_name_mode
    }

    It 'loads NoWipe from disk with wipe_repartition_drive flipped false' {
        $overlay = Resolve-RehearsalScenarioOverlay -Scenario 'NoWipe'
        $overlay.wipe_repartition_drive | Should -BeFalse
        $overlay.computer_name_mode | Should -Be 'serial'
    }

    It 'loads Handover from disk with local_deployment_handover.enabled true' {
        $overlay = Resolve-RehearsalScenarioOverlay -Scenario 'Handover'
        $overlay.local_deployment_handover.enabled | Should -BeTrue
        $overlay.local_deployment_handover.local_path | Should -Be 'C:\1S-WIN11'
    }

    It 'loads AdditionalUsers from disk with one random-password additional_local_users entry' {
        $overlay = Resolve-RehearsalScenarioOverlay -Scenario 'AdditionalUsers'
        $overlay.allow_random_password_export | Should -BeTrue
        @($overlay.additional_local_users).Count | Should -Be 1
        $overlay.additional_local_users[0].username | Should -Be 'RehearsalTech'
        $overlay.additional_local_users[0].password_mode | Should -Be 'random'
    }

    It 'loads ResumeKill from disk with the same config baseline as Standard (only the harness injects a failure, not the config)' {
        $overlay = Resolve-RehearsalScenarioOverlay -Scenario 'ResumeKill'
        $overlay.wipe_repartition_drive | Should -BeTrue
        $overlay.computer_name_mode | Should -Be 'serial'
    }

    It 'is case-insensitive to the scenario name' {
        { Resolve-RehearsalScenarioOverlay -Scenario 'nowipe' } | Should -Not -Throw
    }

    It 'adversarial: throws a clear error for an unrecognised scenario' {
        { Resolve-RehearsalScenarioOverlay -Scenario 'DoesNotExist' } | Should -Throw '*not recognised*'
    }
}

Describe 'Get-RehearsalScenarioWingetPackages (T14)' {
    It 'falls back to the Standard placeholder package for every named scenario (none override it)' {
        foreach ($scenario in @('Standard', 'NoWipe', 'Handover', 'ResumeKill', 'AdditionalUsers')) {
            @(Get-RehearsalScenarioWingetPackages -Scenario $scenario).Count | Should -Be 1
        }
    }
}

Describe 'Get-RehearsalScenarioFailureInjection (T14)' {
    It 'returns $null for scenarios with no failure injection' {
        foreach ($scenario in @('Standard', 'NoWipe', 'AdditionalUsers')) {
            Get-RehearsalScenarioFailureInjection -Scenario $scenario | Should -BeNullOrEmpty
        }
    }

    It 'resolves ResumeKill''s injection: force-stop/restart, triggered when WindowsUpdates starts' {
        $injection = Get-RehearsalScenarioFailureInjection -Scenario 'ResumeKill'
        $injection.Action | Should -Be 'ForceStopRestartVm'
        $injection.TriggerStep | Should -Be 'WindowsUpdates'
        $injection.TriggerWhen | Should -Be 'Started'
    }

    It 'resolves Handover''s injection: hot-remove the media disk, triggered once LocalHandover completes' {
        $injection = Get-RehearsalScenarioFailureInjection -Scenario 'Handover'
        $injection.Action | Should -Be 'HotRemoveMediaDisk'
        $injection.TriggerStep | Should -Be 'LocalHandover'
        $injection.TriggerWhen | Should -Be 'Completed'
    }
}

Describe 'Test-RehearsalFailureInjectionTriggered (T14)' {
    BeforeEach {
        $script:StartedInjection = @{ TriggerStep = 'WindowsUpdates'; TriggerWhen = 'Started' }
        $script:CompletedInjection = @{ TriggerStep = 'LocalHandover'; TriggerWhen = 'Completed' }
    }

    It '''Started'' fires as soon as CurrentStep matches, even before the step completes' {
        Test-RehearsalFailureInjectionTriggered -Injection $script:StartedInjection -CurrentStep 'WindowsUpdates' -CompletedSteps @('Preflight') | Should -BeTrue
    }

    It '''Started'' also fires if the trigger step is already in CompletedSteps (a fast poll cycle could miss it mid-run)' {
        Test-RehearsalFailureInjectionTriggered -Injection $script:StartedInjection -CurrentStep 'WingetApps' -CompletedSteps @('WindowsUpdates') | Should -BeTrue
    }

    It '''Started'' does not fire while a different step is current and the trigger step has not completed' {
        Test-RehearsalFailureInjectionTriggered -Injection $script:StartedInjection -CurrentStep 'Preflight' -CompletedSteps @() | Should -BeFalse
    }

    It '''Completed'' does NOT fire merely because CurrentStep matches -- only once it is in CompletedSteps' {
        Test-RehearsalFailureInjectionTriggered -Injection $script:CompletedInjection -CurrentStep 'LocalHandover' -CompletedSteps @() | Should -BeFalse
    }

    It '''Completed'' fires once the trigger step is in CompletedSteps' {
        Test-RehearsalFailureInjectionTriggered -Injection $script:CompletedInjection -CurrentStep 'WindowsUpdates' -CompletedSteps @('LocalHandover') | Should -BeTrue
    }
}

Describe 'New-RehearsalMedia platform guard' {
    It 'fails with one clear, actionable message when Hyper-V cmdlets are unavailable, instead of a cryptic error partway through' {
        # This sandbox has no Hyper-V module (Linux), so New-VHD etc. are genuinely absent --
        # this exercises the SAME guard clause a Windows host without the Hyper-V feature
        # enabled would hit, following the Get-Command -ErrorAction SilentlyContinue convention
        # already used by Test-RehearsalDefaultSwitch / Test-RehearsalVmNameAvailable elsewhere
        # in RehearsalCommon.ps1.
        { New-RehearsalMedia -WorkingDirectory (Join-Path $TestDrive 'media') } | Should -Throw '*Hyper-V*'
    }

    It 'rejects an unrecognised -Scenario before touching any Hyper-V cmdlet or the filesystem' {
        { New-RehearsalMedia -WorkingDirectory (Join-Path $TestDrive 'media') -Scenario 'DoesNotExist' } | Should -Throw '*not recognised*'
    }
}
