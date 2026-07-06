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

function Set-DotEnvSecret {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        $found = $false
        $lines = @($lines | ForEach-Object {
                if ($_ -match "^\s*$([regex]::Escape($Name))\s*=") {
                    $found = $true
                    "$Name=$Value"
                } else {
                    $_
                }
            })
        if (-not $found) { $lines += "$Name=$Value" }
    } else {
        $lines = @("$Name=$Value")
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8 -Force -ErrorAction Stop
}

function Resolve-OsitPasswordForInitialisation {
    param(
        [string]$SourceRoot,
        [string]$UsbRoot
    )

    $password = Get-OsitLocalAdminPassword -SearchRoots @($SourceRoot, $UsbRoot)
    if (-not [string]::IsNullOrWhiteSpace($password)) { return $password }

    Write-Host ''
    Write-Host 'OSIT_LOCAL_ADMIN_PASSWORD was not found in the environment or a .env file.' -ForegroundColor Yellow
    Write-Host 'The generated USB Autounattend.xml needs this password for the OSIT auto-logon account.' -ForegroundColor Yellow
    Write-Host 'D) Create or update .env in this toolkit folder'
    Write-Host 'E) Create or update the current user environment variable'
    Write-Host 'Q) Quit without writing Autounattend.xml'

    do {
        $choice = (Read-Host 'Choose D, E, or Q').Trim().ToUpperInvariant()
    } until ($choice -in @('D', 'E', 'Q'))

    if ($choice -eq 'Q') { throw 'OSIT password initialisation cancelled.' }

    $secure = Read-Host 'Enter the OSIT local admin password' -AsSecureString
    $plain = ConvertFrom-SecureStringToPlainText -SecureString $secure
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'OSIT local admin password cannot be empty.' }

    if ($choice -eq 'D') {
        $envPath = Join-Path $SourceRoot '.env'
        Set-DotEnvSecret -Path $envPath -Name 'OSIT_LOCAL_ADMIN_PASSWORD' -Value $plain
        Write-Host ".env updated at $envPath" -ForegroundColor Green
    } else {
        [Environment]::SetEnvironmentVariable('OSIT_LOCAL_ADMIN_PASSWORD', $plain, 'User')
        [Environment]::SetEnvironmentVariable('OSIT_LOCAL_ADMIN_PASSWORD', $plain, 'Process')
        Write-Host 'User environment variable OSIT_LOCAL_ADMIN_PASSWORD has been set.' -ForegroundColor Green
    }

    return $plain
}

function Write-PreparedAutounattend {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Password
    )

    $content = Get-Content -LiteralPath $SourcePath -Raw -ErrorAction Stop
    if ($content -notmatch '__OSIT_LOCAL_ADMIN_PASSWORD__') {
        throw "Autounattend template does not contain the __OSIT_LOCAL_ADMIN_PASSWORD__ placeholder: $SourcePath"
    }

    $escapedPassword = [System.Security.SecurityElement]::Escape($Password)
    $content = $content.Replace('__OSIT_LOCAL_ADMIN_PASSWORD__', $escapedPassword)
    Set-Content -LiteralPath $TargetPath -Value $content -Encoding UTF8 -Force -ErrorAction Stop

    $xmlValidation = [xml]$content
    if (-not $xmlValidation.unattend) { throw 'Generated Autounattend.xml did not validate as an unattend document.' }
}

if ([string]::IsNullOrWhiteSpace($UsbRoot)) {
    $UsbRoot = Get-UsbRoot -VolumeLabel $VolumeLabel
}

$paths = Initialize-DeploymentDirectories -UsbRoot $UsbRoot
Write-Host "Deployment folder structure ensured under $UsbRoot" -ForegroundColor Green
$ositPassword = Resolve-OsitPasswordForInitialisation -SourceRoot $sourceRoot -UsbRoot $UsbRoot

if (-not $SkipCopy) {
    $sourceDeployment = Join-Path $sourceRoot 'Deployment'
    $targetDeployment = Join-Path $UsbRoot 'Deployment'
    if ((Resolve-Path -LiteralPath $sourceDeployment).Path -ne (Resolve-Path -LiteralPath $targetDeployment -ErrorAction SilentlyContinue).Path) {
        Copy-Item -Path (Join-Path $sourceDeployment '*') -Destination $targetDeployment -Recurse -Force -ErrorAction Stop
        Write-Host "Deployment files copied to $targetDeployment" -ForegroundColor Green
    }

    $sourceAutounattend = Join-Path $sourceRoot 'Autounattend.xml'
    $targetAutounattend = Join-Path $UsbRoot 'Autounattend.xml'
    if (Test-Path -LiteralPath $sourceAutounattend -PathType Leaf) {
        Write-PreparedAutounattend -SourcePath $sourceAutounattend -TargetPath $targetAutounattend -Password $ositPassword
        Write-Host "Autounattend.xml prepared for OSIT and written to $targetAutounattend" -ForegroundColor Green
    }
} else {
    Write-Host 'SkipCopy was specified; deployment files and Autounattend.xml were not copied.' -ForegroundColor Yellow
}

foreach ($vendor in @('Dell', 'HP', 'Lenovo', 'Generic')) {
    $vendorPath = Join-Path $paths.Drivers $vendor
    if (-not (Test-Path -LiteralPath $vendorPath -PathType Container)) {
        New-Item -ItemType Directory -Path $vendorPath -Force | Out-Null
    }
}

Write-Host 'USB deployment toolkit initialisation complete.' -ForegroundColor Green
