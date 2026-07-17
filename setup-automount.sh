#!/usr/bin/env bash
#
# setup-automount.sh — prepare the backup drive for headless (cron) use:
#   * find the backup partition and REFUSE anything that isn't removable/USB
#   * optionally format it ext4 (only on explicit confirmation) if it isn't a
#     Linux, hard-link-capable filesystem
#   * give the backup user ownership so the unprivileged engine can write
#   * add a systemd automount (via /etc/fstab, by UUID) at /mnt/home_backups
#   * ensure the backup directory exists and add a Nautilus bookmark to it
#   * point the backup config at the mountpoint + UUID
#
# Run as root:   sudo ./setup-automount.sh
#
set -euo pipefail

MOUNTPOINT="/mnt/home_backups"
SUBDIR=""                                   # empty: snapshots live at the mountpoint
BACKUP_DIR="$MOUNTPOINT${SUBDIR:+/$SUBDIR}"
FSTAB="/etc/fstab"
MARKER="# home-backup-automount"

if [[ $EUID -ne 0 ]]; then
    echo "This script must run as root. Try:  sudo $0" >&2
    exit 1
fi

USER_NAME="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
CONFIG="$USER_HOME/.config/home-backup/config"

confirm_yes() {  # $1 = prompt; returns 0 only if the user types exactly YES
    local ans=""
    printf '%s ' "$1" >&2
    if [[ -r /dev/tty ]]; then read -r ans </dev/tty || true; else read -r ans || true; fi
    [[ "$ans" == "YES" ]]
}

# --- Find the backup partition ------------------------------------------------
# Prefer the config's UUID (unless it points at optical media), else 'Backup'.
DEVICE=""
if [[ -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    cfg_uuid="$(. "$CONFIG" 2>/dev/null; printf '%s' "${BACKUP_UUID:-}")"
    if [[ -n "$cfg_uuid" ]]; then
        d="$(blkid -U "$cfg_uuid" 2>/dev/null || true)"
        if [[ -n "$d" ]]; then
            ft="$(lsblk -no FSTYPE "$d" 2>/dev/null | head -n1 || true)"
            case "$ft" in iso9660|udf|squashfs|"") : ;; *) DEVICE="$d" ;; esac
        fi
    fi
fi
[[ -n "$DEVICE" ]] || DEVICE="$(blkid -L Backup 2>/dev/null || true)"
[[ -n "$DEVICE" && -b "$DEVICE" ]] || {
    echo "Could not find the backup partition. Plug the drive in and/or run the installer first." >&2
    exit 1
}

# --- Gather details + SAFETY: must be removable/USB (never a system disk) -----
PK="$(lsblk -no PKNAME "$DEVICE" 2>/dev/null | head -n1 || true)"
RM_FLAG="$(lsblk -dno RM "$DEVICE" 2>/dev/null | head -n1 || echo 0)"
HP_FLAG="$(lsblk -dno HOTPLUG "$DEVICE" 2>/dev/null | head -n1 || echo 0)"
TRAN=""; [[ -n "$PK" ]] && TRAN="$(lsblk -dno TRAN "/dev/$PK" 2>/dev/null | head -n1 || true)"
FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null | head -n1 || true)"
LABEL="$(lsblk -no LABEL "$DEVICE" 2>/dev/null | head -n1 || true)"
SIZE="$(lsblk -dno SIZE "$DEVICE" 2>/dev/null | head -n1 || true)"

echo "Backup partition : $DEVICE  (label='${LABEL:-}', fs='${FSTYPE:-none}', size=${SIZE:-?})"
echo "Parent disk      : /dev/${PK:-?}  (removable=$RM_FLAG hotplug=$HP_FLAG tran=${TRAN:-?})"

if [[ "$TRAN" != "usb" && "$RM_FLAG" != "1" && "$HP_FLAG" != "1" ]]; then
    echo "Refusing to operate on '$DEVICE': it is not a removable/USB drive (safety guard)." >&2
    exit 1
fi

# --- Format to ext4 if it isn't a Linux (hard-link capable) filesystem --------
case "$FSTYPE" in
    ext2|ext3|ext4|btrfs|xfs)
        echo "Filesystem '$FSTYPE' already supports hard links; no format needed."
        ;;
    *)
        echo
        echo "*** '$DEVICE' is '${FSTYPE:-unformatted}', which cannot do hard-linked incrementals"
        echo "*** or Linux permissions. Formatting it ext4 will ERASE ALL DATA on it."
        if confirm_yes "Type YES to format $DEVICE (label='${LABEL:-backup}', ${SIZE:-?}) as ext4:"; then
            while read -r tgt; do
                [[ -z "$tgt" ]] && continue
                umount "$tgt" 2>/dev/null || true
            done < <(findmnt -rn -S "$DEVICE" -o TARGET 2>/dev/null)
            mkfs.ext4 -F -L "${LABEL:-backup}" "$DEVICE"
            FSTYPE="ext4"
            echo "Formatted $DEVICE as ext4."
        else
            echo "Not confirmed; aborting (an ext4 drive is required)." >&2
            exit 1
        fi
        ;;
esac

# --- Final UUID (it changes after mkfs) ---------------------------------------
UUID="$(blkid -s UUID -o value "$DEVICE" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "Could not read UUID of $DEVICE." >&2; exit 1; }
echo "Using UUID=$UUID  ->  $MOUNTPOINT"

mkdir -p "$MOUNTPOINT"

# --- /etc/fstab automount entry (idempotent, with backup + safety check) ------
backup="${FSTAB}.home-backup.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$FSTAB" "$backup"
newline="UUID=$UUID $MOUNTPOINT $FSTYPE noauto,nofail,x-systemd.automount,x-systemd.idle-timeout=120 0 0 $MARKER"
tmp="$(mktemp)"
awk -v mp="$MOUNTPOINT" -v mark="$MARKER" '
    index($0, mark) { next }
    $2 == mp        { next }
    { print }
' "$FSTAB" > "$tmp"
printf '%s\n' "$newline" >> "$tmp"
if [[ ! -s "$tmp" ]] || ! awk '$2=="/"{f=1} END{exit !f}' "$tmp"; then
    echo "Safety check failed (new fstab missing root entry); leaving $FSTAB unchanged." >&2
    echo "Backup at $backup" >&2
    rm -f "$tmp"; exit 1
fi
install -m 0644 "$tmp" "$FSTAB"; rm -f "$tmp"
echo "Updated $FSTAB (backup: $backup)"

# --- Activate the automount and trigger it now --------------------------------
systemctl daemon-reload
autounit="$(systemd-escape -p --suffix=automount "$MOUNTPOINT")"
systemctl enable --now "$autounit" >/dev/null 2>&1 || systemctl restart "$autounit" >/dev/null 2>&1 || true
ls -a "$MOUNTPOINT" >/dev/null 2>&1 || true

# --- Ownership + backup dir + Nautilus bookmark -------------------------------
if findmnt "$MOUNTPOINT" >/dev/null 2>&1; then
    # Give the backup user ownership of the drive root (fresh ext4 is root-owned).
    chown "$USER_NAME":"$USER_NAME" "$MOUNTPOINT"
    if [[ -n "$SUBDIR" ]]; then
        runuser -u "$USER_NAME" -- mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    fi
    echo "Ownership of $MOUNTPOINT set to $USER_NAME."
else
    echo "WARNING: $MOUNTPOINT not mounted; ownership not set. Re-run with the drive attached." >&2
fi

# Nautilus bookmark to the backup directory (clicking it triggers the automount).
# Remove any previous managed "Home Backups" bookmark(s) first — including stale
# ones pointing at an old path — so we never leave a duplicate, then add current.
BM_DIR="$USER_HOME/.config/gtk-3.0"
BM_FILE="$BM_DIR/bookmarks"
BM_LINE="file://$BACKUP_DIR Home Backups"
runuser -u "$USER_NAME" -- mkdir -p "$BM_DIR" 2>/dev/null || true
if [[ -f "$BM_FILE" ]]; then
    runuser -u "$USER_NAME" -- sed -i '/ Home Backups$/d' "$BM_FILE" 2>/dev/null || true
fi
runuser -u "$USER_NAME" -- bash -c 'printf "%s\n" "$1" >> "$2"' _ "$BM_LINE" "$BM_FILE" 2>/dev/null || true
echo "Set Nautilus bookmark 'Home Backups' -> $BACKUP_DIR (any stale duplicate removed)."

# --- Point the backup config at the mountpoint + UUID (keep user ownership) ---
if [[ -f "$CONFIG" ]]; then
    runuser -u "$USER_NAME" -- sed -i \
        -e "s|^BACKUP_MOUNT=.*|BACKUP_MOUNT=\"$MOUNTPOINT\"|" \
        -e "s|^BACKUP_UUID=.*|BACKUP_UUID=\"$UUID\"|" \
        -e "s|^BACKUP_SUBDIR=.*|BACKUP_SUBDIR=\"$SUBDIR\"|" \
        "$CONFIG" 2>/dev/null || true
    echo "Updated $CONFIG (BACKUP_MOUNT=$MOUNTPOINT, BACKUP_SUBDIR='$SUBDIR', BACKUP_UUID=$UUID)"
else
    echo "Note: $CONFIG not found — run the installer to create it (BACKUP_MOUNT should be $MOUNTPOINT)."
fi

echo "--- fstab entry ---"; grep -- "$MARKER" "$FSTAB" || true
echo "--- mount ---"; findmnt "$MOUNTPOINT" || echo "(will mount on first access)"
echo "Done."
