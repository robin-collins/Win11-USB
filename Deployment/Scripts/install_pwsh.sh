#!/bin/bash
set -euo pipefail

###################################
# Resolve the latest PowerShell release from GitHub

echo "Querying GitHub for the latest PowerShell release..."

# Fetch the latest release tag (e.g. "v7.5.8") from the GitHub API
LATEST_TAG=$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
  | grep '"tag_name"' \
  | head -1 \
  | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
  echo "ERROR: Could not determine the latest PowerShell release." >&2
  exit 1
fi

# Strip the leading "v" to get the numeric version (e.g. "7.5.8")
VERSION="${LATEST_TAG#v}"

echo "Latest PowerShell version: ${VERSION} (${LATEST_TAG})"

# Detect architecture
ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
echo "Detected architecture: ${ARCH}"

# Build the download URL and filename
DEB_FILE="powershell_${VERSION}-1.deb_${ARCH}.deb"
DOWNLOAD_URL="https://github.com/PowerShell/PowerShell/releases/download/${LATEST_TAG}/${DEB_FILE}"

###################################
# Prerequisites

# Update the list of packages
sudo apt-get update

# Install pre-requisite packages.
sudo apt-get install -y wget

# Download the PowerShell package file
echo "Downloading ${DOWNLOAD_URL} ..."
wget -q --show-progress "$DOWNLOAD_URL"

if [ ! -f "$DEB_FILE" ]; then
  echo "ERROR: Download failed — ${DEB_FILE} not found." >&2
  exit 1
fi

###################################
# Install the PowerShell package
sudo dpkg -i "$DEB_FILE"

# Resolve missing dependencies and finish the install (if necessary)
sudo apt-get install -f

# Delete the downloaded package file
rm "$DEB_FILE"

# Verify the installation
if INSTALLED_VERSION=$(pwsh --version 2>/dev/null); then
  echo "✅ ${INSTALLED_VERSION} installed successfully."
else
  echo "ERROR: PowerShell installation failed — 'pwsh' is not working." >&2
  exit 1
fi

# Install PSScriptAnalyzer for all users so it's available in every session,
# without the interactive "untrusted repository" prompt
pwsh -NoLogo -NoProfile -Command "
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted 
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
    Import-Module PSScriptAnalyzer
    Get-Module PSScriptAnalyzer
"