#!/bin/bash
set -euo pipefail

# Only needed in Claude Code on the web — this repo's PowerShell scripts
# (Deployment/Scripts/*.ps1, Initialize-UsbDeployment.ps1, Validate-Unattend.ps1)
# need `pwsh` available to be linted/tested during a session.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "Installing PowerShell (pwsh) via the Microsoft APT repository..."
  # Deliberately NOT using Deployment/Scripts/install_pwsh.sh here: that
  # script resolves the latest release via api.github.com and downloads the
  # .deb from github.com, both of which this sandbox's network policy
  # blocks for repos outside this session's scope. packages.microsoft.com
  # is reachable, so use Microsoft's documented APT-based install instead.
  curl -fsSL -o /tmp/packages-microsoft-prod.deb \
    "https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb"
  sudo dpkg -i /tmp/packages-microsoft-prod.deb
  rm -f /tmp/packages-microsoft-prod.deb
  sudo apt-get update || true
  sudo apt-get install -y powershell
fi

pwsh --version

# PSScriptAnalyzer ships from the PowerShell Gallery, which this sandbox's
# network policy also blocks. Try anyway (in case the policy differs
# elsewhere), but don't fail the session if it's unreachable.
if ! pwsh -NoLogo -NoProfile -Command "if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) { exit 1 }" 2>/dev/null; then
  echo "Installing PSScriptAnalyzer from the PowerShell Gallery..."
  pwsh -NoLogo -NoProfile -Command "
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop && Import-Module -Name PSScriptAnalyzer -Scope Local -Force -ErrorAction Stop && Write-Host (Get-Module -ListAvailable -Name 'PSScriptAnalyzer' | Select-Object -First 1).Version.ToString(3);
  " || echo "WARNING: could not install PSScriptAnalyzer (PowerShell Gallery is unreachable from this environment's network policy)." >&2
else
  PSScriptAnalyzerVersion=$(pwsh -NoLogo -NoProfile -Command "
  (Get-Module -ListAvailable -Name 'PSScriptAnalyzer' | Select-Object -First 1).Version.ToString(3)");
  echo "PSScriptAnalyzer already Installed and version $PSScriptAnalyzerVersion";
fi

# Pester ships from the PowerShell Gallery, which this sandbox's
# network policy also blocks. Try anyway (in case the policy differs
# elsewhere), but don't fail the session if it's unreachable.
if ! pwsh -NoLogo -NoProfile -Command "if (-not (Get-Module -ListAvailable -Name Pester)) { exit 1 }" 2>/dev/null; then
  echo "Installing Pester from the PowerShell Gallery..."
  pwsh -NoLogo -NoProfile -Command "
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
    Install-Module -Name Pester -Scope CurrentUser -Force -ErrorAction Stop && Import-Module -Name Pester -Scope Local -Force -ErrorAction Stop && Write-Host (Get-Module -ListAvailable -Name 'Pester' | Select-Object -First 1).Version.ToString(3);
  " || echo "WARNING: could not install Pester (PowerShell Gallery is unreachable from this environment's network policy)." >&2
else
  PesterVersion=$(pwsh -NoLogo -NoProfile -Command "
  (Get-Module -ListAvailable -Name 'Pester' | Select-Object -First 1).Version.ToString(3)");
  echo "Pester already Installed and version $PesterVersion";
fi

