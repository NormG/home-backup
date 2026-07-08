#!/usr/bin/env bash
#
# install-home-backup.sh — one-shot, mostly-automated installer for the
# rsync home-backup system. It only asks the user one thing (and only if it
# has to): where the backup drive is. Everything else is automatic, and a
# graphical summary is shown at the end.
#
set -euo pipefail
export EDITOR="${EDITOR:-vim}" VISUAL="${VISUAL:-vim}"   # honour vim for any crontab editing

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SRC_ENGINE="$SCRIPT_DIR/home-backup.sh"
SRC_EXCLUDES="$SCRIPT_DIR/home-backup.excludes"
SRC_WRAPPER="$SCRIPT_DIR/backup-now.sh"
SRC_ICON="$SCRIPT_DIR/home-backup.png"

# ---- Install locations & policy -------------------------------------------
BIN_DIR="$HOME/.local/bin"
CFG_DIR="$HOME/.config/home-backup"
STATE_DIR="$HOME/.local/state/home-backup"
BIN_PATH="$BIN_DIR/home-backup.sh"
CFG_PATH="$CFG_DIR/config"
EXCLUDES_PATH="$CFG_DIR/excludes"
WRAPPER_PATH="$BIN_DIR/backup-now.sh"
ICON_PATH="$HOME/.local/share/icons/home-backup.png"
DESKTOP_PATH="$HOME/.local/share/applications/home-backup.desktop"

CRON_MARK="# HOME-BACKUP"
CRON_HOUR=2
CRON_MIN=0
FULL_DOW=1                 # 1 = Monday
RETENTION_DAYS=30
BACKUP_SUBDIR=""          # empty: snapshots live directly at the backup mountpoint

# ---- GUI helpers (zenity, with terminal fallback) -------------------------
HAVE_GUI=0
have_display() { [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; }
refresh_gui() { if command -v zenity >/dev/null 2>&1 && have_display; then HAVE_GUI=1; else HAVE_GUI=0; fi; }

ensure_zenity() {
    if ! command -v zenity >/dev/null 2>&1 && have_display && command -v dnf >/dev/null 2>&1; then
        echo "Installing 'zenity' for graphical dialogs (sudo required)..."
        sudo dnf install -y zenity || true
    fi
    refresh_gui
}

msg_info() {   # title, text
    if [[ $HAVE_GUI -eq 1 ]]; then
        zenity --info --no-markup --width=480 --title="$1" --text="$2" || true
    else
        printf '\n=== %s ===\n%s\n' "$1" "$2"
    fi
}
msg_error() {  # title, text
    if [[ $HAVE_GUI -eq 1 ]]; then
        zenity --error --no-markup --width=480 --title="$1" --text="$2" || true
    else
        printf '\n!!! %s !!!\n%s\n' "$1" "$2" >&2
    fi
}
ask_yesno() {  # title, text -> 0 yes / 1 no
    if [[ $HAVE_GUI -eq 1 ]]; then
        zenity --question --no-markup --width=480 --title="$1" --text="$2"
    else
        local a=""
        [ -r /dev/tty ] && { read -r -p "$2 [y/N] " a </dev/tty || true; }
        [[ "$a" =~ ^[Yy] ]]
    fi
}
ask_directory() {  # title -> prints chosen dir
    if [[ $HAVE_GUI -eq 1 ]]; then
        zenity --file-selection --directory --title="$1" 2>/dev/null
    else
        local d=""
        [ -r /dev/tty ] && { read -r -p "$1: " d </dev/tty || true; }
        printf '%s' "$d"
    fi
}
choose_from_list() {  # title; TAB rows "mp\tdev\tlabel\tsize\tfstype" on stdin -> prints chosen mountpoint
    local -a rows=(); local line
    while IFS= read -r line; do [[ -n "$line" ]] && rows+=("$line"); done
    [[ ${#rows[@]} -gt 0 ]] || return 1
    local mp dev label size fstype row
    if [[ $HAVE_GUI -eq 1 ]]; then
        local -a args=(); local first=1
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r mp dev label size fstype <<< "$row"
            if [[ $first -eq 1 ]]; then args+=("TRUE"); first=0; else args+=("FALSE"); fi
            args+=("$mp" "$label" "$size" "$fstype" "$dev")
        done
        zenity --list --radiolist --width=660 --height=360 \
            --title="$1" --text="Select your backup drive:" --print-column=2 \
            --column="Pick" --column="Mounted at" --column="Label" \
            --column="Size" --column="Filesystem" --column="Device" \
            "${args[@]}" 2>/dev/null
    else
        [ -r /dev/tty ] || return 1
        local idx=1 n=""
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r mp dev label size fstype <<< "$row"
            printf '  %d) %s  [label=%s, size=%s, fs=%s, dev=%s]\n' "$idx" "$mp" "$label" "$size" "$fstype" "$dev" >&2
            idx=$((idx+1))
        done
        read -r -p "Choose number: " n </dev/tty || true
        [ -n "$n" ] || return 1
        IFS=$'\t' read -r mp dev label size fstype <<< "${rows[$((n-1))]:-}"
        printf '%s' "$mp"
    fi
}

# ---- Detect mounted external / removable drives ---------------------------
# Prints one mountpoint per line. Internal SATA/NVMe disks (RM=0,HOTPLUG=0,
# TRAN!=usb) are excluded, so the user's system disks never show up.
list_removable_mounts() {
    local mp src fstype opts rm hp tran pk dtype label size
    findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | while read -r mp src fstype opts; do
        [[ -n "$mp" && -n "$src" && -b "$src" ]] || continue
        case "$mp" in
            /|/boot|/boot/efi|/home|/usr|/var|/tmp) continue ;;
        esac
        # Never offer optical / read-only / pseudo filesystems as a backup target.
        case "$fstype" in iso9660|udf|squashfs) continue ;; esac
        case ",$opts," in *,ro,*) continue ;; esac
        dtype="$(lsblk -no TYPE "$src" 2>/dev/null | head -n1 || true)"
        [[ "$dtype" == "rom" ]] && continue
        # Must be writable by the current user.
        [[ -w "$mp" ]] || continue
        # Never use Fedora system/data partitions as a backup target (label like "fedora", "fedora00").
        label="$(lsblk -no LABEL "$src" 2>/dev/null | head -n1 || true)"
        case "${label,,}" in fedora*) continue ;; esac
        read -r rm hp < <(lsblk -no RM,HOTPLUG "$src" 2>/dev/null | head -n1 || true) || true
        pk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true)"
        tran=""
        [[ -n "$pk" ]] && tran="$(lsblk -no TRAN "/dev/$pk" 2>/dev/null | head -n1 || true)"
        if [[ "$tran" == "usb" || "${rm:-0}" == "1" || "${hp:-0}" == "1" ]]; then
            size="$(lsblk -no SIZE "$src" 2>/dev/null | head -n1 || true)"
            printf '%s\t%s\t%s\t%s\t%s\n' "$mp" "$src" "${label:-(no label)}" "${size:-?}" "${fstype:-?}"
        fi
    done | sort -u
}

# Resolve the backup mountpoint, asking the user only when undetermined.
get_backup_mount() {
    local -a rows=(); local mp
    mapfile -t rows < <(list_removable_mounts)

    if [[ ${#rows[@]} -eq 1 ]]; then IFS=$'\t' read -r mp _ <<< "${rows[0]}"; printf '%s' "$mp"; return 0; fi
    if [[ ${#rows[@]} -gt 1 ]]; then
        printf '%s\n' "${rows[@]}" | choose_from_list "Backup drive"; return 0
    fi

    # None detected: prompt to plug in, then retry, then fall back to a chooser.
    msg_info "Backup drive" "No external drive was detected.\n\nPlease plug in your backup drive, wait a few seconds, then click OK."
    sleep 2
    mapfile -t rows < <(list_removable_mounts)
    if [[ ${#rows[@]} -eq 1 ]]; then IFS=$'\t' read -r mp _ <<< "${rows[0]}"; printf '%s' "$mp"; return 0; fi
    if [[ ${#rows[@]} -gt 1 ]]; then
        printf '%s\n' "${rows[@]}" | choose_from_list "Backup drive"; return 0
    fi
    ask_directory "Select your backup drive (its mounted folder)"
}

# ---------------------------------------------------------------------------
main() {
    [[ -r "$SRC_ENGINE" ]]   || { echo "Cannot find engine script next to installer: $SRC_ENGINE" >&2; exit 1; }
    refresh_gui
    ensure_zenity

    local BACKUP_SOURCE="$HOME"

    # --- Determine destination ---
    local BACKUP_MOUNT
    BACKUP_MOUNT="$(get_backup_mount || true)"
    BACKUP_MOUNT="${BACKUP_MOUNT%/}"
    if [[ -z "$BACKUP_MOUNT" || ! -d "$BACKUP_MOUNT" ]]; then
        msg_error "Install cancelled" "No valid backup destination was selected. Nothing has been changed."
        exit 1
    fi
    if [[ ! -w "$BACKUP_MOUNT" ]]; then
        msg_error "Install cancelled" "The selected destination is not writable:\n$BACKUP_MOUNT\n\nChoose a writable drive (e.g. an ext4 USB drive), not read-only media."
        exit 1
    fi
    local BACKUP_DIR="$BACKUP_MOUNT${BACKUP_SUBDIR:+/$BACKUP_SUBDIR}"

    # --- Identify the drive (UUID + filesystem) ---
    local SRC_DEV BACKUP_UUID FSTYPE
    SRC_DEV="$(findmnt -fnro SOURCE --target "$BACKUP_MOUNT" 2>/dev/null || true)"
    BACKUP_UUID="$(findmnt -fnro UUID --target "$BACKUP_MOUNT" 2>/dev/null || true)"
    [[ -z "$BACKUP_UUID" && -n "$SRC_DEV" ]] && BACKUP_UUID="$(lsblk -no UUID "$SRC_DEV" 2>/dev/null | head -n1 || true)"
    FSTYPE="$(findmnt -fnro FSTYPE --target "$BACKUP_MOUNT" 2>/dev/null || true)"

    # --- Warn if the filesystem can't do hardlinks / Unix permissions ---
    case "$FSTYPE" in
        ext2|ext3|ext4|btrfs|xfs|zfs|jfs|reiserfs|f2fs) : ;;
        *)
            if ! ask_yesno "Filesystem warning" \
                "The backup drive is formatted as '${FSTYPE:-unknown}'.\n\nIncremental (hard-link) backups and Linux file permissions need a POSIX filesystem such as ext4. On '${FSTYPE:-unknown}' the incrementals may fail or waste space.\n\nContinue anyway?"; then
                msg_error "Install cancelled" "Re-run after formatting the drive as ext4. Nothing has been changed."
                exit 1
            fi
            ;;
    esac

    # --- Lay down files ---
    mkdir -p "$BIN_DIR" "$CFG_DIR" "$STATE_DIR"
    install -m 0755 "$SRC_ENGINE" "$BIN_PATH"

    if [[ -e "$EXCLUDES_PATH" ]]; then
        :                                   # keep the user's existing edits
    elif [[ -r "$SRC_EXCLUDES" ]]; then
        install -m 0644 "$SRC_EXCLUDES" "$EXCLUDES_PATH"
    else
        printf '# add rsync exclude patterns here\n' > "$EXCLUDES_PATH"
    fi

    cat > "$CFG_PATH" <<EOF
# home-backup configuration (managed by install-home-backup.sh; safe to edit)
BACKUP_SOURCE="$BACKUP_SOURCE"
BACKUP_MOUNT="$BACKUP_MOUNT"
BACKUP_UUID="$BACKUP_UUID"
BACKUP_SUBDIR="$BACKUP_SUBDIR"
EXCLUDES_FILE="$EXCLUDES_PATH"
RETENTION_DAYS="$RETENTION_DAYS"
LOG_DIR="$STATE_DIR"
RSYNC_OPTS="-aHAX --numeric-ids"
FULL_DOW="$FULL_DOW"
EOF
    chmod 0644 "$CFG_PATH"

    # --- Install the "Back Up Now" launcher (wrapper + icon + desktop entry) ---
    if [[ -r "$SRC_WRAPPER" ]]; then
        install -m 0755 "$SRC_WRAPPER" "$WRAPPER_PATH"
    fi
    if [[ -r "$SRC_ICON" ]]; then
        mkdir -p "$(dirname "$ICON_PATH")"
        install -m 0644 "$SRC_ICON" "$ICON_PATH"
    fi
    if [[ -x "$WRAPPER_PATH" ]]; then
        mkdir -p "$(dirname "$DESKTOP_PATH")"
        cat > "$DESKTOP_PATH" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Back Up Now
Comment=Run a home-backup snapshot of your home directory now
Exec=$WRAPPER_PATH
Icon=$ICON_PATH
Terminal=false
Categories=Utility;System;Archiving;
DESKTOP
        chmod 0644 "$DESKTOP_PATH"
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$(dirname "$DESKTOP_PATH")" >/dev/null 2>&1 || true
        fi
    fi

    # --- Install/refresh the cron entry (idempotent via marker comment) ---
    local CRON_LINE tmpcron
    CRON_LINE="$CRON_MIN $CRON_HOUR * * * \"$BIN_PATH\" >> \"$STATE_DIR/cron.log\" 2>&1 $CRON_MARK"
    tmpcron="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$CRON_MARK" > "$tmpcron" || true
    printf '%s\n' "$CRON_LINE" >> "$tmpcron"
    crontab "$tmpcron"
    rm -f "$tmpcron"

    # --- Offer to run the first FULL backup now ---
    local INITIAL="not run (cron will take the first full backup automatically)"
    if ask_yesno "Initial backup" \
        "Setup is complete.\n\nRun the FIRST FULL backup now? (recommended)\n\nSource: $BACKUP_SOURCE\nDestination: $BACKUP_DIR"; then
        if [[ $HAVE_GUI -eq 1 ]]; then
            ( "$BIN_PATH" ) | zenity --progress --pulsate --auto-close --no-cancel \
                --title="Home Backup" \
                --text="Running the initial full backup — this can take a while..." 2>/dev/null || true
        else
            "$BIN_PATH" || true
        fi
        INITIAL="attempted — see log: $STATE_DIR/backup.log"
    fi

    # --- Build the recap ---
    local TIMESTR; TIMESTR="$(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MIN")"
    local recap
    recap="$(cat <<EOF
HOME BACKUP — INSTALLATION COMPLETE
====================================

WHAT WAS INSTALLED
  Backup engine : $BIN_PATH
  Configuration : $CFG_PATH
  Exclude list  : $EXCLUDES_PATH
  Logs          : $STATE_DIR/backup.log  (+ cron.log)
  Cron entry    : nightly at $TIMESTR   (tagged "$CRON_MARK")
  Launcher      : "Back Up Now" app icon (search your apps) -> $WRAPPER_PATH

WHAT GETS BACKED UP
  Source        : $BACKUP_SOURCE   (your entire home directory)
  Destination   : $BACKUP_DIR
  Drive         : UUID=${BACKUP_UUID:-unknown}   filesystem=${FSTYPE:-unknown}
  Excluded      : caches, *.iso, .extras/, Trash  (edit $EXCLUDES_PATH)

BACKUP ROUTINE
  - Runs automatically every night at $TIMESTR.
  - Monday      -> FULL backup (an independent, complete copy).
  - Tue.-Sun.   -> INCREMENTAL (6 per week). Only changed files are copied;
                   unchanged files are hard-linked from the previous night,
                   so every snapshot is still a complete, browsable tree.
  - The very first run is always a FULL ("full backup first").
  - Retention   -> incremental snapshots older than $RETENTION_DAYS days are
                   deleted automatically; full backups are kept.
  - If the drive is not connected at $TIMESTR, that night is skipped safely
    and logged (you also get a desktop notification).

INITIAL FULL BACKUP: $INITIAL

HANDY COMMANDS
  Back up now (GUI)  :  launch "Back Up Now" from your apps (or run $WRAPPER_PATH)
  Run a backup now   :  $BIN_PATH
  Watch the log      :  tail -f $STATE_DIR/backup.log
  Change the schedule:  crontab -e
  Edit exclusions    :  \$EDITOR $EXCLUDES_PATH
  Restore files      :  copy them out of any snapshot folder under
                        $BACKUP_DIR  (e.g. .../latest)
EOF
)"

    if [[ $HAVE_GUI -eq 1 ]]; then
        printf '%s' "$recap" | zenity --text-info --width=740 --height=640 \
            --title="Home Backup — Setup Summary" 2>/dev/null || true
    fi
    printf '%s\n' "$recap"
}

main "$@"
