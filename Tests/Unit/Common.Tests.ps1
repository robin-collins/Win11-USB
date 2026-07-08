#
# Pester v5 unit tests for the platform-independent pure functions in
# Deployment\Scripts\Common.ps1.
#
# Scope: only functions that do not depend on Windows-only functionality
# (CIM/WMI, scheduled tasks, toast notifications, the registry) are covered
# here. Get-DeviceIdentity itself IS Windows-only (Get-CimInstance) and is not
# tested directly; where a covered function calls it internally
# (New-DeploymentState), it is mocked so the round-trip test exercises only
# the pure JSON state plumbing. See Tests\README.md for how to run this
# suite and for the full list of what is intentionally out of scope.
#
# Write code in this file the same way Common.ps1 is written: no ternary
# operator, no null-coalescing operator, no other PowerShell-7-only syntax.
# Common.ps1 runs under Windows PowerShell 5.1 in production
# (Set-StrictMode -Version 2.0), and although this suite can currently only
# be executed with pwsh 7 on Linux, it must not rely on anything that would
# break on 5.1.

BeforeAll {
    # Common.ps1 only sets script-scoped variables and defines functions at
    # dot-source time -- it has no side effects when loaded -- so it is safe
    # to dot-source directly here. This was verified by hand before writing
    # this suite: dot-sourcing it standalone on pwsh 7/Linux completes
    # without error and without touching the filesystem, registry, or any
    # external command. No guard was added to Common.ps1 for this suite.
    . "$PSScriptRoot/../../Deployment/Scripts/Common.ps1"

    # Re-declared here (identical body to the top-level copy above): a function defined only at
    # Discovery time does not carry over into the Run-phase session either -- an It body calling
    # it would throw CommandNotFoundException, the same cross-phase-session hazard as the
    # $script: variable this replaced. BeforeAll bodies, unlike loose script statements, ARE
    # re-run during Run, so this copy is what makes the function available inside It bodies
    # (e.g. the "records why..." test below); the top-level copy is what makes -Skip work.
    function Test-CanGenerateRandomPassword {
        try {
            Add-Type -AssemblyName System.Web -ErrorAction Stop
            [System.Web.Security.Membership].GetMethod('GeneratePassword', [type[]]@([int], [int])) | Out-Null
            return $true
        } catch {
            return $false
        }
    }

    # GetInvalidFileNameChars() differs by platform (Windows: many punctuation
    # characters; Linux/macOS on .NET: just '/' and NUL). Several tests below
    # need at least one character guaranteed invalid on every platform this
    # suite might run on -- '/' is invalid everywhere .NET runs, so it is used
    # for the portable "illegal filesystem character" cases. Other tests use
    # the live platform list itself so they remain correct no matter which set
    # of characters the current OS reports.
    # Wrapped in @(...): Where-Object emitting exactly one match would otherwise
    # unwrap to a bare [char] instead of a one-element array, breaking .Count below.
    $script:PrintableInvalidFileNameChars = @([System.IO.Path]::GetInvalidFileNameChars() | Where-Object { [int]$_ -ge 32 })
}

Describe 'ConvertTo-PlainHashtable' {
    It 'returns $null unchanged for $null input' {
        $result = ConvertTo-PlainHashtable $null
        $result | Should -BeNullOrEmpty
    }

    It 'passes a plain string through unchanged (strings are IEnumerable but must not be exploded into characters)' {
        $result = ConvertTo-PlainHashtable 'hello'
        $result | Should -BeOfType [string]
        $result | Should -Be 'hello'
    }

    It 'recursively converts a PSCustomObject, including nested objects and arrays, into plain Hashtables/arrays' {
        $nested = [pscustomobject]@{
            Name   = 'Test'
            Nested = [pscustomobject]@{ A = 1; B = @(1, 2, [pscustomobject]@{ C = 3 }) }
            Arr    = @('x', 'y')
        }

        $plain = ConvertTo-PlainHashtable $nested

        $plain | Should -BeOfType [System.Collections.Hashtable]
        $plain.Name | Should -Be 'Test'
        $plain.Nested | Should -BeOfType [System.Collections.Hashtable]
        $plain.Nested.A | Should -Be 1
        # Note: not piped -- piping an array into Should -BeOfType checks the type
        # of each element rather than the array as a whole, which is not what is
        # being asserted here.
        $plain.Nested.B.GetType().FullName | Should -Be 'System.Object[]'
        $plain.Nested.B[2] | Should -BeOfType [System.Collections.Hashtable]
        $plain.Nested.B[2].C | Should -Be 3
        $plain.Arr | Should -Be @('x', 'y')
    }

    It 'recursively converts a plain Hashtable (IDictionary) input, not only PSCustomObject input' {
        $hashIn = @{ A = @{ B = 1; C = @(1, 2) }; D = 'plain' }

        $plain = ConvertTo-PlainHashtable $hashIn

        $plain | Should -BeOfType [System.Collections.Hashtable]
        $plain.A | Should -BeOfType [System.Collections.Hashtable]
        $plain.A.B | Should -Be 1
        $plain.A.C | Should -Be @(1, 2)
        $plain.D | Should -Be 'plain'
    }

    It 'adversarial: converts nested arrays-of-arrays, preserving the nested array shape' {
        $arr = @(@(1, 2), @(3, 4))

        # No @(...) wrap needed: the function's array branch now emits the whole array as one
        # pipeline object (see the empty-array regression test below), so wrapping the call
        # site here would double-wrap it into a 1-element array containing the real array.
        $plain = ConvertTo-PlainHashtable $arr

        $plain.Count | Should -Be 2
        $plain[0].GetType().FullName | Should -Be 'System.Object[]'
        $plain[0] | Should -Be @(1, 2)
        $plain[1] | Should -Be @(3, 4)
    }

    It 'adversarial: an empty array input round-trips to an empty array, not $null, even without @(...) at the call site' {
        # Regression test: ConvertTo-PlainHashtable's array branch used to `return $items`
        # unwrapped, which PowerShell enumerates element-by-element when writing to the output
        # stream -- for a zero-element array that means zero objects are emitted, so an
        # unwrapped call site (exactly how Get-DesktopItemConfig in Configure-DesktopItems.ps1
        # calls it: `ConvertTo-PlainHashtable $Config.desktop_items`, no @(...)) silently
        # received $null instead of @(). That turned the shipped default config's
        # `"common_desktop_items": []` into $null, which then crashed
        # Sync-DesktopItems' `.ContainsKey()` call on a null element. The fix wraps the return
        # in a unary comma (`return , $items`) so the array itself -- however many elements it
        # has -- is always emitted as a single pipeline object.
        $plain = ConvertTo-PlainHashtable @()
        # Piping $plain into `Should` here would itself enumerate it -- for a genuinely empty
        # array that sends zero objects downstream, which is indistinguishable from $null at
        # the assertion. Comparing the variable directly (no pipe) avoids that trap.
        ($null -eq $plain) | Should -BeFalse -Because 'an empty array must round-trip as @(), not collapse to $null'
        $plain.GetType().FullName | Should -Be 'System.Object[]'
        $plain.Count | Should -Be 0
    }

    It 'adversarial: a hashtable with a nested empty-array property preserves that property as an empty array, not $null' {
        # Mirrors the real production shape (deployment_config.json's desktop_items object with
        # common_desktop_items/final_user_desktop_items: []) parsed by ConvertFrom-Json, then
        # converted via the recursive `$hash[$key] = ConvertTo-PlainHashtable $InputObject[$key]`
        # call site inside the function itself -- the exact path that silently produced $null
        # before this was fixed.
        $json = '{"desktop_items":{"common_desktop_items":[],"final_user_desktop_items":["a"]}}'
        $plain = ConvertTo-PlainHashtable ($json | ConvertFrom-Json)

        ($null -eq $plain.desktop_items.common_desktop_items) | Should -BeFalse
        $plain.desktop_items.common_desktop_items.GetType().FullName | Should -Be 'System.Object[]'
        $plain.desktop_items.common_desktop_items.Count | Should -Be 0
        $plain.desktop_items.final_user_desktop_items.Count | Should -Be 1
    }

    It 'adversarial: preserves $null elements found inside an array' {
        $plain = ConvertTo-PlainHashtable @(1, $null, 3)
        $plain.Count | Should -Be 3
        $plain[1] | Should -BeNullOrEmpty
    }
}

Describe 'Merge-Config' {
    It 'keeps a Base-only key that Override does not mention' {
        $merged = Merge-Config -Base @{ a = 1; b = 2 } -Override @{ b = 99 }
        $merged.a | Should -Be 1
    }

    It 'lets an Override value win over a matching Base key' {
        $merged = Merge-Config -Base @{ a = 1; b = 2 } -Override @{ b = 99 }
        $merged.b | Should -Be 99
    }

    It 'adds an Override-only key that Base does not have' {
        $merged = Merge-Config -Base @{ a = 1 } -Override @{ c = 3 }
        $merged.c | Should -Be 3
        $merged.Keys.Count | Should -Be 2
    }

    It 'adversarial: nested hashtables are replaced wholesale, not deep-merged' {
        # Merge-Config is a shallow merge: an Override value for a key entirely
        # replaces the Base value for that key, even when both are hashtables.
        $base = @{ nested = @{ x = 1; keep = 'base-only' } }
        $override = @{ nested = @{ y = 2 } }

        $merged = Merge-Config -Base $base -Override $override

        $merged.nested.Keys.Count | Should -Be 1
        $merged.nested.y | Should -Be 2
        $merged.nested.ContainsKey('x') | Should -BeFalse
        $merged.nested.ContainsKey('keep') | Should -BeFalse
    }

    It 'adversarial: array values are replaced wholesale (not concatenated) the same way nested hashtables are' {
        $merged = Merge-Config -Base @{ list = @(1, 2, 3) } -Override @{ list = @(9) }
        $merged.list.Count | Should -Be 1
        $merged.list[0] | Should -Be 9
    }

    It 'returns an empty hashtable when both Base and Override are empty' {
        $merged = Merge-Config -Base @{} -Override @{}
        $merged | Should -BeOfType [System.Collections.Hashtable]
        $merged.Keys.Count | Should -Be 0
    }
}

Describe 'Get-BloatwareSelectors' {
    It 'returns an entry for every id Set-SystemTweaks.ps1''s default system_tweaks.remove_bloatware lists' {
        $catalog = Get-BloatwareSelectors
        foreach ($id in @('RemoveBingSearch', 'RemoveCortana', 'RemoveZuneVideo', 'RemoveStepsRecorder', 'RemoveGetStarted', 'RemoveWordPad', 'RemoveXboxApps')) {
            $catalog.ContainsKey($id) | Should -BeTrue
        }
    }

    It 'gives every Package-type entry at least one selector' {
        $catalog = Get-BloatwareSelectors
        foreach ($id in @('RemoveBingSearch', 'RemoveCortana', 'RemoveZuneVideo', 'RemoveGetStarted', 'RemoveXboxApps')) {
            @($catalog[$id].Packages).Count | Should -BeGreaterThan 0
        }
    }

    It 'gives every Capability-type entry at least one selector' {
        $catalog = Get-BloatwareSelectors
        foreach ($id in @('RemoveStepsRecorder', 'RemoveWordPad')) {
            @($catalog[$id].Capabilities).Count | Should -BeGreaterThan 0
        }
    }

    It 'attaches the GameDVR DefaultUserRegistry special-case only to RemoveXboxApps' {
        $catalog = Get-BloatwareSelectors
        $catalog['RemoveXboxApps'].DefaultUserRegistry.Name | Should -Be 'AppCaptureEnabled'
        $catalog['RemoveBingSearch'].ContainsKey('DefaultUserRegistry') | Should -BeFalse
    }
}

Describe 'Get-StartFolderBlob' {
    It 'returns 16 bytes per requested folder' {
        $blob = Get-StartFolderBlob -Names @('Documents', 'Downloads')
        $blob.Length | Should -Be 32
    }

    It 'returns bytes in a fixed alphabetical-by-Id order, independent of input order' {
        $forward = Get-StartFolderBlob -Names @('Documents', 'Downloads')
        $reversed = Get-StartFolderBlob -Names @('Downloads', 'Documents')
        [System.Convert]::ToBase64String($forward) | Should -Be ([System.Convert]::ToBase64String($reversed))
    }

    It 'normalizes names with spaces the same as the equivalent Id' {
        $spaced = Get-StartFolderBlob -Names @('File Explorer')
        $noSpace = Get-StartFolderBlob -Names @('FileExplorer')
        [System.Convert]::ToBase64String($spaced) | Should -Be ([System.Convert]::ToBase64String($noSpace))
    }

    It 'is case-insensitive on folder names' {
        $lower = Get-StartFolderBlob -Names @('documents')
        $mixed = Get-StartFolderBlob -Names @('Documents')
        [System.Convert]::ToBase64String($lower) | Should -Be ([System.Convert]::ToBase64String($mixed))
    }

    It 'returns an empty array for an empty Names list' {
        $blob = Get-StartFolderBlob -Names @()
        $blob.Length | Should -Be 0
    }

    It 'adversarial: throws a clear error naming the unknown folder, not a generic key-not-found error' {
        { Get-StartFolderBlob -Names @('NotARealFolder') } | Should -Throw '*NotARealFolder*'
    }

    It 'adversarial: does not silently drop a duplicate name (still returns one copy''s worth of bytes)' {
        $blob = Get-StartFolderBlob -Names @('Documents', 'Documents')
        $blob.Length | Should -Be 16
    }
}

Describe 'Get-WlanProfileSsid' {
    It 'reads the SSID from the standard exported-profile shape (SSIDConfig/SSID/name)' {
        $path = Join-Path $TestDrive 'standard.xml'
        Set-Content -LiteralPath $path -Value @'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>OfficeWiFi</name>
  <SSIDConfig>
    <SSID>
      <hex>4F6666696365576946 69</hex>
      <name>OfficeWiFi</name>
    </SSID>
  </SSIDConfig>
</WLANProfile>
'@
        Get-WlanProfileSsid -ProfileXmlPath $path | Should -Be 'OfficeWiFi'
    }

    It 'falls back to the top-level name element when SSIDConfig/SSID/name is absent' {
        $path = Join-Path $TestDrive 'minimal.xml'
        Set-Content -LiteralPath $path -Value @'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>HomeNetwork</name>
</WLANProfile>
'@
        Get-WlanProfileSsid -ProfileXmlPath $path | Should -Be 'HomeNetwork'
    }

    It 'adversarial: throws naming the file path when neither shape of a name element is present' {
        $path = Join-Path $TestDrive 'broken.xml'
        Set-Content -LiteralPath $path -Value @'
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <connectionType>ESS</connectionType>
</WLANProfile>
'@
        { Get-WlanProfileSsid -ProfileXmlPath $path } | Should -Throw "*$path*"
    }
}

Describe 'Get-SafeName' {
    It 'falls back to the default "Unknown" for an empty string' {
        Get-SafeName -Value '' | Should -Be 'Unknown'
    }

    It 'falls back to the default "Unknown" for a whitespace-only string' {
        Get-SafeName -Value '   ' | Should -Be 'Unknown'
    }

    It 'uses a caller-supplied fallback instead of the default' {
        Get-SafeName -Value '' -Fallback 'CustomFallback' | Should -Be 'CustomFallback'
    }

    It 'collapses whitespace and hyphen runs into a single underscore and trims stray underscores' {
        Get-SafeName -Value 'My  Cool---Name' | Should -Be 'My_Cool_Name'
        Get-SafeName -Value '  --test--  ' | Should -Be 'test'
    }

    It 'adversarial: replaces the illegal filesystem character "/" with an underscore' {
        # '/' is rejected by [System.IO.Path]::GetInvalidFileNameChars() on every
        # platform this suite runs on (Windows, Linux, macOS), unlike most other
        # punctuation which Windows alone rejects -- so it is the one character
        # safe to hardcode an exact expected replacement for.
        Get-SafeName -Value 'abc/def' | Should -Be 'abc_def'
    }

    It 'adversarial: falls back entirely when every character is illegal and strips to nothing' {
        Get-SafeName -Value '///' -Fallback 'AllInvalid' | Should -Be 'AllInvalid'
    }

    It 'adversarial: strips every platform-reported invalid filename character, whatever that set is' {
        # Uses the live platform character set instead of a hardcoded list so the
        # assertion holds on both Windows (many punctuation characters invalid)
        # and Linux/macOS (only '/' and NUL invalid).
        if ($script:PrintableInvalidFileNameChars.Count -eq 0) {
            Set-ItResult -Skipped -Because 'this platform reports no printable invalid filename characters'
            return
        }
        $raw = 'My' + ($script:PrintableInvalidFileNameChars -join '') + 'File'
        $result = Get-SafeName -Value $raw
        foreach ($invalidChar in $script:PrintableInvalidFileNameChars) {
            $result | Should -Not -Match ([regex]::Escape([string]$invalidChar))
        }
    }

    It 'leaves ordinary mixed-case alphanumeric content unchanged' {
        Get-SafeName -Value 'MixedCase123' | Should -Be 'MixedCase123'
    }
}

Describe 'Get-SafeComputerName' {
    It 'uppercases the input and preserves hyphens' {
        Get-SafeComputerName -Name 'my-laptop' | Should -Be 'MY-LAPTOP'
    }

    It 'replaces disallowed symbols with a hyphen and trims leading/trailing hyphens' {
        Get-SafeComputerName -Name 'lap@top#01!' | Should -Be 'LAP-TOP-01'
    }

    It 'truncates a long name to 15 characters' {
        $result = Get-SafeComputerName -Name 'ThisIsAVeryLongComputerNameThatExceeds15'
        $result.Length | Should -BeLessOrEqual 15
        $result | Should -Be 'THISISAVERYLONG'
    }

    It 'adversarial: trims a trailing hyphen left dangling exactly at the 15-character truncation point' {
        # Character 15 of "ABCDEFGHIJKLMN-XYZ" is the hyphen itself, so truncating
        # to 15 chars would otherwise leave a trailing hyphen in the result.
        Get-SafeComputerName -Name 'ABCDEFGHIJKLMN-XYZ' | Should -Be 'ABCDEFGHIJKLMN'
    }

    It 'adversarial: rejects an empty string at parameter binding because Name has no AllowEmptyString attribute' {
        { Get-SafeComputerName -Name '' } | Should -Throw
    }

    It 'adversarial: throws a specific error when normalisation strips the name to nothing' {
        { Get-SafeComputerName -Name '***' } | Should -Throw 'Computer name cannot be empty after normalisation.'
    }
}

Describe 'ConvertTo-NormalizedManufacturer' {
    It 'recognises HP spellings and aliases them to "HP"' {
        ConvertTo-NormalizedManufacturer -Manufacturer 'HP' | Should -Be 'HP'
        ConvertTo-NormalizedManufacturer -Manufacturer 'HP Inc.' | Should -Be 'HP'
        ConvertTo-NormalizedManufacturer -Manufacturer 'Hewlett-Packard' | Should -Be 'HP'
    }

    It 'recognises Dell spellings and aliases them to "Dell"' {
        ConvertTo-NormalizedManufacturer -Manufacturer 'Dell' | Should -Be 'Dell'
        ConvertTo-NormalizedManufacturer -Manufacturer 'Dell Inc.' | Should -Be 'Dell'
    }

    It 'recognises Lenovo spellings and aliases them to "Lenovo"' {
        ConvertTo-NormalizedManufacturer -Manufacturer 'LENOVO' | Should -Be 'Lenovo'
        ConvertTo-NormalizedManufacturer -Manufacturer 'Lenovo' | Should -Be 'Lenovo'
    }

    It 'matches vendor aliases case-insensitively' {
        ConvertTo-NormalizedManufacturer -Manufacturer 'hp' | Should -Be 'HP'
        ConvertTo-NormalizedManufacturer -Manufacturer 'lenovo' | Should -Be 'Lenovo'
    }

    It 'adversarial: falls back to "Generic" for an empty string' {
        ConvertTo-NormalizedManufacturer -Manufacturer '' | Should -Be 'Generic'
    }

    It 'adversarial: sanitises an unrecognised vendor name containing an illegal filesystem character' {
        ConvertTo-NormalizedManufacturer -Manufacturer 'Weird/VendorName' | Should -Be 'Weird_VendorName'
    }
}

Describe 'ConvertTo-NormalizedModel' {
    It 'strips a leading manufacturer prefix and descriptive suffix words' {
        ConvertTo-NormalizedModel -Model 'HP EliteBook 840 G8 Notebook PC' | Should -Be 'EliteBook_840_G8'
        ConvertTo-NormalizedModel -Model 'Dell Latitude 5420 Laptop' | Should -Be 'Latitude_5420'
    }

    It 'strips the "(R)" marker and a trailing "System" word' {
        ConvertTo-NormalizedModel -Model 'Lenovo ThinkPad T14 (R) System' | Should -Be 'ThinkPad_T14'
    }

    It 'converts commas and semicolons to spaces before collapsing' {
        ConvertTo-NormalizedModel -Model 'Model X, Rev; 2' | Should -Be 'Model_X_Rev_2'
    }

    It 'adversarial: falls back to "Unknown_Model" for an empty string' {
        ConvertTo-NormalizedModel -Model '' | Should -Be 'Unknown_Model'
    }

    It 'adversarial: falls back to "Unknown_Model" when the input is entirely stripped-out descriptive words' {
        ConvertTo-NormalizedModel -Model 'Notebook PC' | Should -Be 'Unknown_Model'
    }

    It 'adversarial: sanitises an illegal filesystem character alongside normal word-stripping' {
        ConvertTo-NormalizedModel -Model 'Weird/Model Name Notebook' | Should -Be 'Weird_Model_Name'
    }
}

Describe 'Split-CommandLineArguments' {
    It 'adversarial: returns an empty result for an empty or whitespace-only string' {
        Split-CommandLineArguments -ArgumentString '' | Should -BeNullOrEmpty
        Split-CommandLineArguments -ArgumentString '   ' | Should -BeNullOrEmpty
    }

    It 'splits simple space-separated tokens' {
        $result = @(Split-CommandLineArguments -ArgumentString 'foo bar baz')
        $result | Should -Be @('foo', 'bar', 'baz')
    }

    It 'keeps a double-quoted token with embedded spaces as a single argument and strips the quotes' {
        $result = @(Split-CommandLineArguments -ArgumentString '"C:\Program Files\App\app.exe" --flag value')
        $result.Count | Should -Be 3
        $result[0] | Should -Be 'C:\Program Files\App\app.exe'
        $result[1] | Should -Be '--flag'
        $result[2] | Should -Be 'value'
    }

    It 'keeps a single-quoted token with embedded spaces as a single argument and strips the quotes' {
        $result = @(Split-CommandLineArguments -ArgumentString "'hello world' second")
        $result | Should -Be @('hello world', 'second')
    }

    It 'adversarial: a quote embedded mid-token (not at the very start) is not treated as a quoted group, so an internal space still splits it' {
        # This documents a real, current limitation of the tokenizer rather than
        # an assumed "shell-correct" behaviour: the quote-detection only applies
        # when the token match itself begins with a quote character.
        $result = @(Split-CommandLineArguments -ArgumentString '/silent /log:"C:\some path\log.txt" -x')
        $result.Count | Should -Be 4
        $result[0] | Should -Be '/silent'
        $result[1] | Should -Be '/log:"C:\some'
        $result[2] | Should -Be 'path\log.txt"'
        $result[3] | Should -Be '-x'
    }
}

Describe 'ConvertTo-ProcessArgumentString' {
    It 'joins plain arguments with spaces and adds no quoting when none is needed' {
        ConvertTo-ProcessArgumentString -Arguments @('foo', 'bar') | Should -Be 'foo bar'
    }

    It 'quotes an argument that contains a space' {
        $result = ConvertTo-ProcessArgumentString -Arguments @('C:\Program Files\App\app.exe', '--flag', 'value with space')
        $result | Should -Be '"C:\Program Files\App\app.exe" --flag "value with space"'
    }

    It 'adversarial: escapes an embedded double quote inside an argument' {
        $result = ConvertTo-ProcessArgumentString -Arguments @('say "hi"')
        $result | Should -Be '"say \"hi\""'
    }

    It 'adversarial: doubles a trailing backslash when quoting is required, per Win32 CommandLineToArgvW rules' {
        # A trailing backslash immediately before the closing quote must become
        # two backslashes so the consuming process does not see it as escaping
        # the closing quote itself.
        $result = ConvertTo-ProcessArgumentString -Arguments @('C:\Program Files\dir\')
        $result | Should -Be '"C:\Program Files\dir\\"'
    }

    It 'leaves a trailing backslash alone when the argument needs no quoting at all' {
        $result = ConvertTo-ProcessArgumentString -Arguments @('C:\path\to\dir\')
        $result | Should -Be 'C:\path\to\dir\'
    }

    It 'adversarial: an empty arguments array returns an empty string' {
        ConvertTo-ProcessArgumentString -Arguments @() | Should -Be ''
    }

    It 'adversarial: a single empty-string argument is still emitted as an explicit empty quoted pair' {
        ConvertTo-ProcessArgumentString -Arguments @('') | Should -Be '""'
    }
}

Describe 'New-RandomPassword' {
    It 'generates a password of the default length (20)' {
        (New-RandomPassword).Length | Should -Be 20
    }

    It 'generates a password of a caller-supplied custom length' {
        (New-RandomPassword -Length 32).Length | Should -Be 32
    }

    It 'generates different values across successive calls' {
        $first = New-RandomPassword -Length 24
        $second = New-RandomPassword -Length 24
        $first | Should -Not -Be $second
    }

    It 'adversarial: throws for a length too small to fit one character from each required class' {
        { New-RandomPassword -Length 2 } | Should -Throw
    }
}

Describe 'Get-DotEnvValue' {
    BeforeEach {
        $script:EnvFilePath = Join-Path $TestDrive 'probe.env'
        @'
# comment line
FOO=bar
QUOTED="hello world"
SINGLEQUOTED='single value'

SPACED = spaced value
'@ | Set-Content -LiteralPath $script:EnvFilePath -Encoding UTF8
    }

    It 'reads a plain unquoted value' {
        Get-DotEnvValue -Path $script:EnvFilePath -Name 'FOO' | Should -Be 'bar'
    }

    It 'strips surrounding double quotes from a value' {
        Get-DotEnvValue -Path $script:EnvFilePath -Name 'QUOTED' | Should -Be 'hello world'
    }

    It 'strips surrounding single quotes from a value' {
        Get-DotEnvValue -Path $script:EnvFilePath -Name 'SINGLEQUOTED' | Should -Be 'single value'
    }

    It 'tolerates spaces around the equals sign' {
        Get-DotEnvValue -Path $script:EnvFilePath -Name 'SPACED' | Should -Be 'spaced value'
    }

    It 'adversarial: returns $null for a key that is not present (comments and blank lines are skipped, not matched)' {
        Get-DotEnvValue -Path $script:EnvFilePath -Name 'MISSING' | Should -BeNullOrEmpty
    }

    It 'adversarial: returns $null when the file itself does not exist' {
        $missingPath = Join-Path $TestDrive 'does-not-exist.env'
        Get-DotEnvValue -Path $missingPath -Name 'FOO' | Should -BeNullOrEmpty
    }
}

Describe 'Deployment state round-trip: New-DeploymentState -> Write-DeploymentState -> Read-DeploymentState' {
    BeforeEach {
        # New-DeploymentState calls Get-DeviceIdentity internally, which is the
        # Windows-only (Get-CimInstance) function explicitly out of scope for this
        # suite. Mocking it here isolates the pure JSON state read/write/round-trip
        # logic under test from that Windows-only dependency, without touching
        # Common.ps1 itself.
        Mock Get-DeviceIdentity {
            @{
                serial_number   = 'TEST-SERIAL-001'
                uuid            = '11111111-1111-1111-1111-111111111111'
                computer_name   = 'TESTPC'
                manufacturer    = 'Dell'
                model           = 'Latitude'
                windows_caption = 'Windows 11 Pro'
                windows_version = '10.0.22621'
                windows_build   = '22621'
            }
        }

        # Per-test temp directory using Pester's TestDrive convention; Pester
        # tears TestDrive down automatically after the run, so no manual
        # cleanup is required here.
        $script:StateDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
        $script:StatePath = Join-Path $script:StateDir 'deployment_state.json'
    }

    It 'creates state with the expected identity and default fields' {
        $state = New-DeploymentState -RunId 'run-001'
        $state.deployment_run_id | Should -Be 'run-001'
        $state.device_serial_number | Should -Be 'TEST-SERIAL-001'
        $state.computer_name | Should -Be 'TESTPC'
        $state.current_step | Should -Be ''
        $state.completed_steps | Should -BeNullOrEmpty
        $state.last_error | Should -BeNullOrEmpty
        $state.reboot_pending | Should -BeFalse
    }

    It 'round-trips a freshly created state unchanged through Write-DeploymentState and Read-DeploymentState' {
        $state = New-DeploymentState -RunId 'run-002'

        Write-DeploymentState -State $state -StatePath $script:StatePath
        $read = Read-DeploymentState -StatePath $script:StatePath

        $read | Should -Not -BeNullOrEmpty
        $read.deployment_run_id | Should -Be 'run-002'
        $read.device_serial_number | Should -Be 'TEST-SERIAL-001'
        $read.device_uuid | Should -Be '11111111-1111-1111-1111-111111111111'
        $read.manufacturer | Should -Be 'Dell'
        $read.model | Should -Be 'Latitude'
    }

    It 'round-trips step history and completed_steps growth added via the Set-State* helpers' {
        $state = New-DeploymentState -RunId 'run-003'
        Set-StateStepStarted -State $state -Step 'Preflight' -StatePath $script:StatePath
        Set-StateStepCompleted -State $state -Step 'Preflight' -StatePath $script:StatePath

        $read = Read-DeploymentState -StatePath $script:StatePath

        @($read.completed_steps) | Should -Contain 'Preflight'
        $read.last_successful_step | Should -Be 'Preflight'
        $read.current_step | Should -Be ''
        @($read.history).Count | Should -Be 2
    }

    It 'adversarial: Read-DeploymentState returns $null when the state file does not exist' {
        $missingPath = Join-Path $script:StateDir 'never-written.json'
        Read-DeploymentState -StatePath $missingPath | Should -BeNullOrEmpty
    }

    It 'adversarial: falls back to the .bak backup when the primary state file is corrupted JSON' {
        $state = New-DeploymentState -RunId 'run-v1'
        Write-DeploymentState -State $state -StatePath $script:StatePath
        # A second write is required before a .bak exists at all: Write-DeploymentState
        # only backs up a *pre-existing* file, so the very first write has nothing to
        # back up yet.
        $state.deployment_run_id = 'run-v2'
        Write-DeploymentState -State $state -StatePath $script:StatePath

        Test-Path -LiteralPath "$($script:StatePath).bak" -PathType Leaf | Should -BeTrue

        Set-Content -LiteralPath $script:StatePath -Value '{ not valid json' -Encoding UTF8

        $read = Read-DeploymentState -StatePath $script:StatePath
        $read.deployment_run_id | Should -Be 'run-v1'
    }
}
