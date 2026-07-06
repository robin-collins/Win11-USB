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

GIT_SIGNING_KEY="""
-----BEGIN PGP PUBLIC KEY BLOCK-----

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
+N+fSOzDfTfvohbmZsxdElreT+FYqW2KWQ==
=NUNv
-----END PGP PUBLIC KEY BLOCK-----

"""
echo "variable GIT_SIGINING_KEY is the GPG key to use to sign the commits"