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
