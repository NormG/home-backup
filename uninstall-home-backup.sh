#!/usr/bin/env bash
#
# uninstall-home-backup.sh — The "Clean Slate" uninstaller.
# This script removes scripts, configurations, and system automounts.
# It is hard-coded to NEVER delete directories containing 'inc-' or 'full-'.
#
set -euo pipefail

# --- Configuration ---
INSTALL_DIR="$HOME/Projects/home-backup"
CONFIG_DIR="$HOME/.config/home-backup"
STATE_DIR="$HOME/.local/state/home-backup"
BIN_LINK="$HOME/.local/bin/home-backup.sh"
UNINSTALL_LOG="$HOME/uninstall_home_backup.log"
FSTAB_MARKER="# home-backup-automount"
CRON_MARKER="# HOME-BACKUP"
MOUNTPOINT="/mnt/home_backups"
WRAPPER="$HOME/.local/bin/backup-now.sh"
ICON="$HOME/.local/share/icons/home-backup.png"
DESKTOP="$HOME/.local/share/applications/home-backup.desktop"
BOOKMARKS="$HOME/.config/gtk-3.0/bookmarks"

# --- Logging Function ---
log_action() {
    local status="$1"
    local message="$2"
    printf "[%-7s] %s\n" "$status" "$message" | tee -a "$UNINSTALL_LOG"
}

# --- Safety Check ---
# Prevent accidental execution if the user is currently inside their backup drive
if [[ "$PWD" == *"/inc-"* || "$PWD" == *"/full-"* ]]; then
    echo "❌ ERROR: You appear to be inside a backup directory ($PWD)."
    echo "Please move to a different directory before uninstalling."
    exit 1
fi

echo "========================================================"
echo "⚠️  WARNING: UNINSTALLING HOME-BACKUP"
echo "This will remove all settings and the backup engine."
echo "Your actual backup data will NOT be touched."
echo "========================================================"
read -p "Are you sure you want to proceed? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Initialize Log
echo "--- Uninstall Log: $(date) ---" > "$UNINSTALL_LOG"
log_action "START" "Beginning uninstallation process."

# 1. System-Level Cleanup (Requires Sudo)
echo "--- ⚙️  Cleaning System-Level Hooks ---"
# Stop/disable the automount unit before touching fstab.
autounit="$(systemd-escape -p --suffix=automount "$MOUNTPOINT" 2>/dev/null || true)"
if [[ -n "$autounit" ]]; then
    sudo systemctl disable --now "$autounit" >/dev/null 2>&1 || true
    log_action "INFO" "Stopped automount unit ($autounit)."
fi
if grep -q "$FSTAB_MARKER" /etc/fstab; then
    log_action "INFO" "Removing fstab automount entry (backing up /etc/fstab first)..."
    sudo cp -a /etc/fstab "/etc/fstab.home-backup-uninstall.bak.$(date +%Y%m%d%H%M%S)"
    sudo sed -i "\|$FSTAB_MARKER|d" /etc/fstab
    log_action "SUCCESS" "fstab cleaned."
else
    log_action "SKIP" "No fstab automount entry found."
fi

# Reload systemd to clear the automount unit
echo "--- 🔄 Reloading Systemd ---"
sudo systemctl daemon-reload
log_action "SUCCESS" "Systemd reloaded."

# 2. User-Level Cleanup (No Sudo)
echo "--- 🧹 Cleaning User-Level Files ---"

# Remove Configs
if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    log_action "SUCCESS" "Removed config directory: $CONFIG_DIR"
else
    log_action "SKIP" "Config directory not found."
fi

# Remove State/Logs
if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR"
    log_action "SUCCESS" "Removed state/log directory: $STATE_DIR"
else
    log_action "SKIP" "State directory not found."
fi

# Remove installed binaries (engine + GUI wrapper) — these are COPIES, not symlinks.
for f in "$BIN_LINK" "$WRAPPER"; do
    if [ -e "$f" ]; then
        rm -f "$f"; log_action "SUCCESS" "Removed: $f"
    else
        log_action "SKIP" "Not found: $f"
    fi
done

# Remove the "Back Up Now" launcher (desktop entry + icon).
for f in "$DESKTOP" "$ICON"; do
    if [ -e "$f" ]; then
        rm -f "$f"; log_action "SUCCESS" "Removed: $f"
    else
        log_action "SKIP" "Not found: $f"
    fi
done
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
fi

# Remove the Nautilus bookmark (line labelled "Home Backups").
if [ -f "$BOOKMARKS" ] && grep -q ' Home Backups$' "$BOOKMARKS"; then
    sed -i '/ Home Backups$/d' "$BOOKMARKS"
    log_action "SUCCESS" "Removed Nautilus bookmark."
else
    log_action "SKIP" "No Nautilus bookmark found."
fi

# Remove the nightly cron entry (idempotent, by marker).
if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    ( crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" ) | crontab -
    log_action "SUCCESS" "Removed cron entry."
else
    log_action "SKIP" "No cron entry found."
fi

# Remove the Source Directory (The current directory)
if [ "$INSTALL_DIR" != "/" ]; then
    echo "--- 📂 Removing Source Code Directory ---"
    # We use 'cd ..' to ensure we aren't trying to delete the directory we are standing in
    cd ..
    rm -rf "$INSTALL_DIR"
    log_action "SUCCESS" "Removed source directory: $INSTALL_DIR"
fi

# 3. Final Report
echo "========================================================"
echo "✅ UNINSTALL COMPLETE"
echo "Summary of actions recorded in: $UNINSTALL_LOG"
echo "Your backup data remains safe on your external drive."
echo "========================================================"
