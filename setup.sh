#!/usr/bin/env bash
set -e

# Install PowerShell if not already installed
if command -v pwsh >/dev/null 2>&1; then
    echo "PowerShell is already installed"
    exit 0
fi

# Install dependencies
sudo apt-get update
sudo apt-get install -y wget apt-transport-https software-properties-common

# Add Microsoft package repository
wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb

# Install PowerShell
sudo apt-get update
sudo apt-get install -y powershell

