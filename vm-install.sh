#!/usr/bin/env bash
#
# vm-bootstrap.sh — The "Day Zero" installer for a new Fedora VM.
# Uses SSH for cloning to avoid interactive password prompts.
#
set -euo pipefail

# --- Configuration ---
# Using SSH URL to bypass HTTPS password prompts
REPO_URL="git@github.com:NormG/home-backup.git"
INSTALL_DIR="$HOME/Projects/home-backup"
AUTOMOUNT_TARGET="/mnt/home_backups"

echo "--- 🛠️  Starting Home-Backup Bootstrap for Fedora ---"

# 1. Install System Dependencies
echo "--- 📦 Installing system dependencies (zenity, rsync, findutils, etc.) ---"
sudo dnf install -y git rsync findutils zenity util-linux

# 2. Clone the Repository (Shallow Clone for speed)
if [ -d "$INSTALL_DIR" ]; then
    echo "--- 📂 Repository exists. Pulling latest changes... ---"
    cd "$INSTALL_DIR" && git pull
else
    echo "--- 📥 Cloning repository via SSH (Shallow Clone) ---"
    # If this fails, ensure your SSH keys are added to GitHub!
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Configure the System-Level Automount
echo "--- ⚙️  Configuring Systemd Automount (fstab) ---"
echo "Target: $AUTOMOUNT_TARGET"

# Ensure the mount point exists before running the automount setup
sudo mkdir -p "$AUTOMOUNT_TARGET"
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
