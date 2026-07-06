[CmdletBinding()]
param(
    [string]$UsbRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-DeploymentRoot }
& (Join-Path $PSScriptRoot 'Start-Deployment.ps1') -UsbRoot $UsbRoot -NonInteractive
