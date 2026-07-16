[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }

Write-Log -Level Info -Message 'Asset inventory capture started (CIM hardware/OS queries, TPM, Secure Boot, BitLocker, activation, installed programs).'

function Get-TpmSummary {
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        [ordered]@{
            present = $tpm.TpmPresent
            ready   = $tpm.TpmReady
            enabled = $tpm.TpmEnabled
            activated = $tpm.TpmActivated
            manufacturer_id = $tpm.ManufacturerId
            manufacturer_version = $tpm.ManufacturerVersion
        }
    } catch {
        # Best-effort: recorded as an error in the inventory instead of failing the capture.
        Write-Log -Level Warn -Message "TPM inventory query failed: $($_.Exception.Message). Recording the error in the inventory and continuing."
        [ordered]@{ error = $_.Exception.Message }
    }
}

function Get-SecureBootSummary {
    try {
        [ordered]@{ enabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
    } catch {
        # Best-effort: Confirm-SecureBootUEFI throws on legacy-BIOS/unsupported firmware.
        Write-Log -Level Warn -Message "Secure Boot inventory query failed (expected on legacy BIOS / unsupported firmware): $($_.Exception.Message). Recording the error in the inventory and continuing."
        [ordered]@{ enabled = $null; error = $_.Exception.Message }
    }
}

function Get-ActivationSummary {
    try {
        Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
            Where-Object { $_.PartialProductKey -and $null -ne $_.LicenseStatus } |
            Select-Object Name, Description, LicenseStatus, PartialProductKey
    } catch {
        # Best-effort: recorded as an error in the inventory instead of failing the capture.
        Write-Log -Level Warn -Message "Windows activation inventory query failed: $($_.Exception.Message). Recording the error in the inventory and continuing."
        @([ordered]@{ error = $_.Exception.Message })
    }
}

$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$product = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$memory = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
$disks = Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue
$netAdapters = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalAdapter }
$drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue
$programs = Get-InstalledProgramNames

$inventory = [ordered]@{
    captured_at = (Get-Date).ToString('o')
    computer = [ordered]@{
        computer_name = $env:COMPUTERNAME
        serial_number = if ($bios) { $bios.SerialNumber } else { '' }
        uuid = if ($product) { $product.UUID } else { '' }
        manufacturer = if ($system) { $system.Manufacturer } else { '' }
        model = if ($system) { $system.Model } else { '' }
        sku = if ($product) { $product.SKUNumber } else { '' }
    }
    bios = [ordered]@{
        # Picks whichever of SMBIOSBIOSVersion/Version is non-null, preferring SMBIOSBIOSVersion.
        # Uses Where-Object (rather than the array -ne $null idiom) so $null can be on the left
        # of the comparison without losing the array's element-filtering behavior.
        version = if ($bios) { (@($bios.SMBIOSBIOSVersion, $bios.Version) | Where-Object { $null -ne $_ } | Select-Object -First 1) } else { '' }
        release_date = if ($bios -and $bios.ReleaseDate) { $bios.ReleaseDate.ToString('o') } else { '' }
    }
    security = [ordered]@{
        tpm = Get-TpmSummary
        secure_boot = Get-SecureBootSummary
        bitlocker = try { Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop | Select-Object MountPoint, VolumeStatus, ProtectionStatus, EncryptionPercentage } catch { Write-Log -Level Warn -Message "BitLocker inventory query failed: $($_.Exception.Message). Recording the error in the inventory and continuing."; @([ordered]@{ error = $_.Exception.Message }) }
    }
    hardware = [ordered]@{
        cpu = if ($cpu) { $cpu.Name } else { '' }
        ram_gb = [math]::Round((($memory | Measure-Object -Property Capacity -Sum).Sum / 1GB), 2)
        disks = @($disks | Select-Object Model, SerialNumber, InterfaceType, MediaType, @{ Name = 'SizeGB'; Expression = { [math]::Round($_.Size / 1GB, 2) } }, Status)
        network_adapters = @($netAdapters | Select-Object Name, NetConnectionID, MACAddress, Speed, Manufacturer)
    }
    windows = [ordered]@{
        caption = if ($os) { $os.Caption } else { '' }
        version = if ($os) { $os.Version } else { '' }
        build = if ($os) { $os.BuildNumber } else { '' }
        install_date = if ($os -and $os.InstallDate) { $os.InstallDate.ToString('o') } else { '' }
        architecture = if ($os) { $os.OSArchitecture } else { '' }
        activation = @(Get-ActivationSummary)
    }
    installed_apps = @($programs)
    driver_summary = [ordered]@{
        count = @($drivers).Count
        vendors = @($drivers | Group-Object Manufacturer | Sort-Object Count -Descending | Select-Object -First 20 Name, Count)
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Write-JsonFile -Path $OutputPath -InputObject $inventory
    Write-Log -Level Info -Message "Asset inventory written to $OutputPath."
}

Write-StructuredLog -Level Info -Message 'Asset inventory captured' -Data $inventory
Write-Log -Level Success -Message "Asset inventory captured for $($inventory.computer.computer_name) (serial $($inventory.computer.serial_number)): $(@($inventory.hardware.disks).Count) disk(s), $(@($inventory.hardware.network_adapters).Count) network adapter(s), $(@($programs).Count) installed program(s), $($inventory.driver_summary.count) signed driver(s)."
$inventory
