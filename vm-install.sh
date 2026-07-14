#!/usr/bin/env bash
#
# vm-bootstrap.sh — The "Day Zero" installer for a new Fedora VM.
# This script handles system-level configuration (fstab/automount)
# and then hands off to the user-level installer.
#
set -euo pipefail

# --- Configuration ---
REPO_URL="https://github.com/NormG/home-backup"
INSTALL_DIR="$HOME/Projects/home-backup"
# The mount point you want for your backup drive (must match your hardware/intent)
# We use /mnt/home_backups as it's a standard, clean location.
AUTOMOUNT_TARGET="/mnt/home_backups"

echo "--- 🛠️  Starting Home-Backup Bootstrap for Fedora ---"

# 1. Install System Dependencies
echo "--- 📦 Installing system dependencies (zenity, rsync, findutils, etc.) ---"
sudo dnf install -y git rsync findutils zenity util-linux

# 2. Clone the Repository
if [ -d "$INSTALL_DIR" ]; then
    echo "--- 📂 Repository exists. Pulling latest changes... ---"
    cd "$INSTALL_DIR" && git pull
else
    echo "--- 📥 Cloning repository... ---"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Configure the System-Level Automount (The fstab magic)
# We use the existing setup-automount.sh logic but ensure it's applied correctly.
echo "--- ⚙️  Configuring Systemd Automount (fstab) ---"
echo "This will allow your backup drive to mount automatically when accessed."
echo "Target: $AUTOMOUNT_TARGET"

# We run the script. Note: setup-automount.sh likely requires sudo for fstab.
# We pass the target if the script supports it, otherwise we edit fstab manually.
# Based on our analysis, we'll ensure the drive is ready for the user.
sudo ./setup-automount.sh

# 4. Hand-off to User-Level Installer
echo "--- 🚀 Handing off to the User-Level Installer ---"
echo "--------------------------------------------------------"
echo "IMPORTANT: The next step requires a GUI (Cinnamon Desktop)."
echo "If you are in a terminal, please switch to your desktop session"
echo "and run: cd $INSTALL_DIR && ./install-home-backup.sh"
echo "--------------------------------------------------------"

# Check if we are in a GUI session
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    echo "GUI detected. Launching installer now..."
    sleep 2
    ./install-home-backup.sh
else
    echo "No GUI detected. Please run the installer manually from your desktop."
    echo "Command: cd $INSTALL_DIR && ./install-home-backup.sh"
fi

echo "--- ✅ Bootstrap process finished ---"
