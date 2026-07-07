$ErrorActionPreference = 'Stop'
. "C:\projects\Win11-USB\Test\Rehearsal\RehearsalCommon.ps1"
. "C:\projects\Win11-USB\Test\Rehearsal\RehearsalMonitoring.ps1"
if (-not (Test-RehearsalCommandAvailable -Name 'ConvertTo-PlainHashtable')) {
    . "C:\projects\Win11-USB\Deployment\Scripts\Common.ps1"
}

$workingDir = "$env:TEMP\DeploymentRehearsal"
$vmName = 'Rehearsal-SecureBootDiag'
$isoPath = 'E:\iso\Win11_25H2_English_x64_all_versions.iso'

Write-Output 'Building rehearsal media...'
$media = New-RehearsalMedia -WorkingDirectory $workingDir -Scenario 'Standard'
Write-Output "Media built: $($media.VhdxPath)"

if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    Remove-RehearsalVm -VmName $vmName
}

Write-Output 'Creating VM...'
$vm = New-RehearsalVm -VmName $vmName -IsoPath $isoPath -MediaVhdxPath $media.VhdxPath -WorkingDirectory $workingDir -MemoryGB 8 -CpuCount 4 -OsDiskGB 80
Write-Output "VM created: $($vm.VmName)"

Write-Output 'Disabling Secure Boot for this diagnostic...'
Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

Write-Output 'Starting VM...'
Start-VM -Name $vmName

Start-Sleep -Seconds 20
Send-RehearsalKeystroke -VmName $vmName -Text ' ' | Out-Null
Start-Sleep -Seconds 10
Send-RehearsalKeystroke -VmName $vmName -Text ' ' | Out-Null
Start-Sleep -Seconds 20

$screenshotPath = 'C:\projects\Win11-USB\.diag-secureboot-off.png'
Save-RehearsalVmScreenshot -VmName $vmName -OutputPath $screenshotPath
Write-Output "Screenshot saved: $screenshotPath"

$vmState = Get-VM -Name $vmName | Select-Object Name, State, Uptime
Write-Output "VM state: $($vmState.State), Uptime: $($vmState.Uptime)"
