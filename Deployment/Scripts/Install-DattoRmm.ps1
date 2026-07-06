[CmdletBinding()]
param(
    [string]$UsbRoot,
    [string]$StatePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

if ([string]::IsNullOrWhiteSpace($UsbRoot)) { $UsbRoot = Get-UsbRoot }
$paths = Get-DeploymentPaths -UsbRoot $UsbRoot
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = $paths.StateFile }
$config = Get-DeploymentConfig -UsbRoot $UsbRoot
$state = Read-DeploymentState -StatePath $StatePath

function Test-DattoSiteUuid {
    param([AllowEmptyString()][string]$SiteId)

    if ([string]::IsNullOrWhiteSpace($SiteId)) { return $false }
    if ($SiteId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $false }
    try {
        [guid]$SiteId | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-DattoRmmInstalled {
    $services = @('CagService', 'CentraStage')
    foreach ($serviceName in $services) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) { return $true }
    }

    if (Test-ProgramInstalled -Pattern 'Datto.*RMM') { return $true }
    if (Test-ProgramInstalled -Pattern 'CentraStage') { return $true }
    return $false
}

$siteId = ([string]$config.datto_rmm_site_id_uuid).Trim()
if ([string]::IsNullOrWhiteSpace($siteId)) {
    Write-Log -Level Info -Message 'Datto RMM site ID is not configured; skipping Datto RMM install.'
    return
}

if (-not (Test-DattoSiteUuid -SiteId $siteId)) {
    throw "datto_rmm_site_id_uuid is not a valid UUID: '$siteId'"
}

if (Test-DattoRmmInstalled) {
    Write-Log -Level Success -Message 'Datto RMM agent already appears to be installed.'
    if ($state) {
        $state.datto_rmm = [ordered]@{
            site_id_uuid = $siteId
            status       = 'AlreadyInstalled'
            timestamp    = (Get-Date).ToString('o')
        }
        Write-DeploymentState -State $state -StatePath $StatePath
    }
    return
}

$downloadUrl = "https://syrah.rmm.datto.com/download-agent/windows/$siteId"
$installerPath = Join-Path $env:TEMP ("DattoRmm-AgentInstall-{0}.exe" -f $siteId)
$downloadLog = if ($script:DeploymentLogContext) { Join-Path $script:DeploymentLogContext.LogDir 'datto-rmm-download.log' } else { Join-Path $env:TEMP 'datto-rmm-download.log' }

if (Test-DeploymentDryRun) {
    # UUID validation and the already-installed detection above both ran for real (the
    # genuine value of a dry run here); no download, signature check, or install happens below.
    $installArgumentLine = ConvertTo-ProcessArgumentString -Arguments (Split-CommandLineArguments -ArgumentString ([string]$config.datto_rmm_install_arguments))
    Write-DryRunAction -State $state -Step 'DattoRmm' -Action "would download agent from $downloadUrl and run: <installer> $installArgumentLine" -Data ([ordered]@{
            site_id_uuid = $siteId
            download_url = $downloadUrl
            install_arguments = $config.datto_rmm_install_arguments
        })
    if ($state) {
        $state.datto_rmm = [ordered]@{
            site_id_uuid = $siteId
            status       = 'DryRun'
            timestamp    = (Get-Date).ToString('o')
        }
        Write-DeploymentState -State $state -StatePath $StatePath
    }
    Write-Log -Level Success -Message "Dry run: Datto RMM agent would be downloaded from $downloadUrl and installed for site $siteId."
    return
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
    Write-Log -Level Info -Message "Downloading Datto RMM agent for site $siteId."
    Invoke-WithRetry -OperationName 'Datto RMM agent download' -MaxAttempts 3 -DelaySeconds 15 -ScriptBlock {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
    } | Out-Null
    Set-Content -LiteralPath $downloadLog -Value @(
        "Downloaded: $((Get-Date).ToString('o'))",
        "URL: $downloadUrl",
        "Path: $installerPath",
        "SizeBytes: $((Get-Item -LiteralPath $installerPath).Length)"
    ) -Encoding UTF8 -Force
} catch {
    throw "Failed to download Datto RMM agent from $downloadUrl`: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Datto RMM installer was not downloaded: $installerPath"
}

# The installer runs elevated, so refuse anything that is not validly signed.
$signature = Get-AuthenticodeSignature -FilePath $installerPath
if ($signature.Status -ne 'Valid') {
    throw "Datto RMM installer Authenticode signature status is '$($signature.Status)'; refusing to run it. Verify the site UUID and download URL."
}
Write-Log -Level Info -Message "Datto RMM installer signature is valid: $($signature.SignerCertificate.Subject)"

$arguments = Split-CommandLineArguments -ArgumentString ([string]$config.datto_rmm_install_arguments)
try {
    $install = Invoke-ExternalCommand -FilePath $installerPath -Arguments $arguments -AllowedExitCodes @(0, 3010) -LogName 'datto-rmm-install.log'
} finally {
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
}

$installedAfter = Test-DattoRmmInstalled
if (-not $installedAfter -and [bool]$config.datto_rmm_required) {
    throw 'Datto RMM installer completed but the Datto/CentraStage service or installed program was not detected.'
}

$result = [ordered]@{
    site_id_uuid = $siteId
    status       = if ($installedAfter) { 'Installed' } else { 'InstallerCompletedNotDetected' }
    installer    = $installerPath
    exit_code    = $install.exit_code
    timestamp    = (Get-Date).ToString('o')
}

if ($state) {
    $state.datto_rmm = $result
    Write-DeploymentState -State $state -StatePath $StatePath
}

Write-StructuredLog -Level Info -Message 'Datto RMM installation completed' -Data $result
Write-Log -Level Success -Message "Datto RMM install step completed with status $($result.status)."
