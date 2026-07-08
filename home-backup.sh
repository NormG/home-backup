#!/usr/bin/env bash
#
# home-backup.sh — rsync snapshot backup engine.
#
#   * Monday        -> FULL backup (independent complete copy)
#   * Other days    -> INCREMENTAL (rsync --link-dest hardlinks unchanged
#                      files against the previous snapshot, so each snapshot
#                      still looks like a complete, browsable tree)
#   * First ever run is always a FULL ("full backup first").
#   * Incrementals older than RETENTION_DAYS are pruned; FULLs are kept.
#
# Configuration is read from ~/.config/home-backup/config (written by the
# installer). This script is normally launched by cron once per night.
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CONFIG="${HOME}/.config/home-backup/config"
if [[ ! -r "$CONFIG" ]]; then
    echo "home-backup: missing config file: $CONFIG" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$CONFIG"

# ---- Required / defaulted settings -----------------------------------------
: "${BACKUP_SOURCE:?config is missing BACKUP_SOURCE}"
: "${BACKUP_SUBDIR=home-backups}"   # unset -> default; empty "" means the mount root
: "${EXCLUDES_FILE:=${HOME}/.config/home-backup/excludes}"
: "${RETENTION_DAYS:=30}"
: "${LOG_DIR:=${HOME}/.local/state/home-backup}"
: "${RSYNC_OPTS:=-aHAX --numeric-ids}"
: "${FULL_DOW:=1}"            # 1 = Monday (see `date +%u`)

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup.log"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

# Best-effort desktop notification (works from cron by pointing at the
# user's session bus; silently does nothing if unavailable).
notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    local uid; uid="$(id -u)"
    [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && \
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus"
    [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]] && export DISPLAY=":0"
    notify-send -a "Home Backup" -- "$1" "${2:-}" >/dev/null 2>&1 || true
}

# ---- Single-instance lock --------------------------------------------------
exec 9>"$LOG_DIR/.lock"
if ! flock -n 9; then
    log "Another backup run is already in progress; exiting."
    exit 0
fi

# ---- Resolve the backup drive (prefer UUID, fall back to stored path) ------
resolve_dest_mount() {
    local mp="" dev
    # Prefer the configured mountpoint; accessing it triggers a systemd
    # automount (x-systemd.automount) if set up, and keeps the backup location
    # consistent whether mounted by the desktop or by automount.
    if [[ -n "${BACKUP_MOUNT:-}" ]]; then
        ls "${BACKUP_MOUNT}/" >/dev/null 2>&1 || true
        mountpoint -q "${BACKUP_MOUNT}" 2>/dev/null && mp="$BACKUP_MOUNT"
    fi
    # Otherwise resolve by UUID, mounting removable media if necessary.
    if [[ -z "$mp" && -n "${BACKUP_UUID:-}" ]]; then
        mp="$(findmnt -rn -S "UUID=${BACKUP_UUID}" -o TARGET 2>/dev/null | head -n1 || true)"
        if [[ -z "$mp" ]]; then
            dev="$(blkid -U "${BACKUP_UUID}" 2>/dev/null || true)"
            if [[ -n "$dev" ]] && command -v udisksctl >/dev/null 2>&1; then
                udisksctl mount -b "$dev" >/dev/null 2>&1 || true
                mp="$(findmnt -rn -S "UUID=${BACKUP_UUID}" -o TARGET 2>/dev/null | head -n1 || true)"
            fi
        fi
    fi
    printf '%s' "$mp"
}

DEST_MOUNT="$(resolve_dest_mount)"
if [[ -z "$DEST_MOUNT" || ! -d "$DEST_MOUNT" ]]; then
    log "Backup drive not available (UUID=${BACKUP_UUID:-none}, path=${BACKUP_MOUNT:-none}); skipping this run."
    notify "Backup skipped" "The backup drive is not connected."
    exit 0
fi

# Refuse to write unless the destination is a real, writable mountpoint.
# Guards against a misconfigured target such as a read-only install ISO.
if ! mountpoint -q "$DEST_MOUNT" 2>/dev/null; then
    log "Destination '$DEST_MOUNT' is not a mounted filesystem; skipping this run."
    notify "Backup skipped" "Destination is not a mounted drive."
    exit 0
fi
_writetest="$DEST_MOUNT/.home-backup-writetest.$$"
if ! ( : > "$_writetest" ) 2>/dev/null; then
    log "Destination '$DEST_MOUNT' is not writable by $(id -un) (read-only media, or the drive root is not owned by this user); skipping this run."
    notify "Backup skipped" "Backup drive is not writable."
    exit 0
fi
rm -f "$_writetest"

if [[ -n "${BACKUP_SUBDIR:-}" ]]; then
    DEST_ROOT="${DEST_MOUNT%/}/${BACKUP_SUBDIR}"
else
    DEST_ROOT="${DEST_MOUNT%/}"     # empty subdir -> snapshots live at the mount root
fi
mkdir -p "$DEST_ROOT"
LATEST="$DEST_ROOT/latest"

# ---- Warn if the destination doesn't support hard links --------------------
# Incrementals rely on hard links for space-efficient snapshots. Test the
# capability directly on the destination instead of guessing from the FS name.
_hl_src="$DEST_ROOT/.hltest.$$"
_hl_dst="$DEST_ROOT/.hltest.$$.link"
if : > "$_hl_src" 2>/dev/null && ln "$_hl_src" "$_hl_dst" 2>/dev/null; then
    :   # hard links supported
else
    log "WARNING: destination filesystem does not support hard links; incrementals will not save space."
    notify "Backup warning" "Backup drive doesn't support hard links; incrementals won't save space."
fi
rm -f "$_hl_src" "$_hl_dst" 2>/dev/null || true

# ---- Decide backup type ----------------------------------------------------
DOW="$(date +%u)"
TYPE="inc"
[[ "$DOW" == "$FULL_DOW" ]] && TYPE="full"
# Force a full if none exists yet (very first run).
if ! compgen -G "$DEST_ROOT/full-*" >/dev/null; then
    TYPE="full"
fi

STAMP="$(date +%Y-%m-%d_%H%M%S)"
NEW="$DEST_ROOT/${TYPE}-${STAMP}"
TMP="$DEST_ROOT/.inprogress-${TYPE}-${STAMP}"

# Clean up stale half-finished runs (older than a day).
find "$DEST_ROOT" -maxdepth 1 -type d -name '.inprogress-*' -mtime +1 \
    -exec rm -rf {} + 2>/dev/null || true

# ---- Build the rsync command ----------------------------------------------
read -r -a RS_OPTS <<< "$RSYNC_OPTS"
RSYNC_CMD=(rsync "${RS_OPTS[@]}" --delete --stats)
[[ -r "$EXCLUDES_FILE" ]] && RSYNC_CMD+=(--exclude-from="$EXCLUDES_FILE")
RSYNC_CMD+=(--exclude="${DEST_ROOT}/")    # never recurse into the backup store itself

if [[ "$TYPE" == "inc" ]]; then
    link_target="$(readlink -f "$LATEST" 2>/dev/null || true)"
    if [[ -n "$link_target" && -d "$link_target" ]]; then
        RSYNC_CMD+=(--link-dest="$link_target")
    else
        log "No previous snapshot to link against; promoting this run to a FULL."
        TYPE="full"
        NEW="$DEST_ROOT/${TYPE}-${STAMP}"
    fi
fi

# Human-readable backup type for user-facing (GUI) notifications.
if [[ "$TYPE" == "inc" ]]; then TYPE_LABEL="incremental"; else TYPE_LABEL="full"; fi

mkdir -p "$TMP"
log "Starting ${TYPE} backup: ${BACKUP_SOURCE%/}/ -> ${NEW}"

set +e
"${RSYNC_CMD[@]}" "${BACKUP_SOURCE%/}/" "$TMP/" >>"$LOG_FILE" 2>&1
rc=$?
set -e

# rsync 24 = "some source files vanished during transfer" — harmless for a
# live home directory, treat as success.
if [[ $rc -eq 0 || $rc -eq 24 ]]; then
    [[ $rc -eq 24 ]] && log "Note: some files vanished mid-backup (rsync rc=24); continuing."
    mv "$TMP" "$NEW"
    ln -sfn "$NEW" "$LATEST"
    log "Completed ${TYPE} backup: ${NEW}"
    notify "Backup complete (${TYPE_LABEL})" "Snapshot: $(basename "$NEW")"
else
    log "ERROR: rsync failed (exit ${rc}). Partial data left at ${TMP} for inspection."
    notify "Backup FAILED (${TYPE_LABEL})" "See ${LOG_FILE}"
    exit "$rc"
fi

# ---- Retention: delete incrementals older than RETENTION_DAYS --------------
if [[ "$RETENTION_DAYS" =~ ^[0-9]+$ && "$RETENTION_DAYS" -gt 0 ]]; then
    log "Pruning incremental snapshots older than ${RETENTION_DAYS} days..."
    while IFS= read -r -d '' d; do
        log "  removing old incremental: $(basename "$d")"
        rm -rf "$d"
    done < <(find "$DEST_ROOT" -maxdepth 1 -type d -name 'inc-*' -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)
fi

log "Done."
