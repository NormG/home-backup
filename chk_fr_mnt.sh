#!/usr/bin/env bash
#
# chk_fr_mnt.sh — Phase 1: Destination Readiness Test
# 
# Purpose:
#   1. Locate device with label "Backup".
#   2. Ensure it is mounted to /mnt/backup.
#   3. Verify the mount is writable via a canary test.
#
# Exit Codes:
#   0 - Success: Device found, mounted, and writable.
#   1 - Error: Device with label "Backup" not found.
#   2 - Error: Mount attempt failed.
#   3 - Error: Write test failed (Read-only filesystem).
#

set -u

LABEL="Backup"
TARGET="/mnt/backup"
CANARY_FILE="${TARGET}/.canary_test"

# Helper for reporting
report() {
    local status="$1"
    local msg="$2"
    echo "--------------------------------------------------------"
    echo "STATE: $status"
    echo "MSG:   $msg"
    echo "--------------------------------------------------------"
}

# 1. Find the device by label
# We use lsblk to get the device path for the label
DEV=$(lsblk -no NAME,LABEL | grep -w "$LABEL" | awk '{print "/dev/"$1}' | head -n1 || true)

if [[ -z "$DEV" ]]; then
    report "FAILURE" "Device with label '$LABEL' not found."
    exit 1
fi

# 2. Check if it is already mounted
# We check if the device path is currently associated with a mountpoint
CURRENT_MOUNT=$(findmnt -n -o TARGET "$DEV" || true)

if [[ -z "$CURRENT_MOUNT" ]]; then
    echo "Device '$DEV' found but not mounted. Attempting to mount to $TARGET..."
    
    # Create target directory if it doesn't exist
    sudo mkdir -p "$TARGET"
    
    # Attempt to mount
    if sudo mount "$DEV" "$TARGET"; then
        echo "Mount successful."
    else
        report "FAILURE" "Failed to mount $DEV to $TARGET."
        exit 2
    fi
else
    echo "Device '$DEV' is already mounted at '$CURRENT_MOUNT'."
    # If it's mounted somewhere else, we'll use that as our target for the write test
    TARGET="$CURRENT_MOUNT"
fi

# 3. Verify Writability (Canary Test)
echo "Performing write integrity test on $TARGET..."
if sudo touch "$CANARY_FILE" 2>/dev/null; then
    sudo rm "$CANARY_FILE"
    report "SUCCESS" "Device is ready. Mounted at $TARGET and writable."
    exit 0
else
    report "FAILURE" "Mount is read-only or write permission denied at $TARGET."
    exit 3
fi
