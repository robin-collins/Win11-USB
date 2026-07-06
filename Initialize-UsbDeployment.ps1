[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$VolumeLabel = '1S-WIN11',
    [switch]$SkipCopy
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $sourceRoot 'Deployment\Scripts\Common.ps1')

if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
    $UsbRoot = Get-UsbRoot -VolumeLabel $VolumeLabel
}

$paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
Write-Host "Deployment folder structure ensured under $UsbRoot" -ForegroundColor Green

if (-not $SkipCopy) {
    $sourceDeployment = Join-Path $sourceRoot 'Deployment'
    $targetDeployment = Join-Path $UsbRoot 'Deployment'
    if ((Resolve-Path -LiteralPath $sourceDeployment).Path -ne (Resolve-Path -LiteralPath $targetDeployment -ErrorAction SilentlyContinue).Path) {
        Copy-Item -LiteralPath (Join-Path $sourceDeployment '*') -Destination $targetDeployment -Recurse -Force -ErrorAction Stop
        Write-Host "Deployment files copied to $targetDeployment" -ForegroundColor Green
    }

    $sourceAutounattend = Join-Path $sourceRoot 'Autounattend.xml'
    $targetAutounattend = Join-Path $UsbRoot 'Autounattend.xml'
    if (Test-Path -LiteralPath $sourceAutounattend -PathType Leaf) {
        Copy-Item -LiteralPath $sourceAutounattend -Destination $targetAutounattend -Force -ErrorAction Stop
        Write-Host "Autounattend.xml copied to $targetAutounattend" -ForegroundColor Green
    }
}

foreach ($vendor in @('Dell', 'HP', 'Lenovo', 'Generic')) {
    $vendorPath = Join-Path $paths.Drivers $vendor
    if (-not (Test-Path -LiteralPath $vendorPath -PathType Container)) {
        New-Item -ItemType Directory -Path $vendorPath -Force | Out-Null
    }
}

Write-Host 'USB deployment toolkit initialisation complete.' -ForegroundColor Green
