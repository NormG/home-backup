#!/usr/bin/env bash
#
# backup-now.sh — manual "Back Up Now" trigger with a graphical progress dialog.
# Launched from the Home Backup desktop entry; runs the very same engine that
# cron uses (~/.local/bin/home-backup.sh).
#
set -u

ENGINE="$HOME/.local/bin/home-backup.sh"
LOG="$HOME/.local/state/home-backup/backup.log"

gui() { command -v zenity >/dev/null 2>&1 && { [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; }; }

if [[ ! -x "$ENGINE" ]]; then
    if gui; then
        zenity --error --title="Home Backup" \
            --text="Backup engine not found:\n$ENGINE\n\nRun the installer first." 2>/dev/null || true
    else
        echo "Backup engine not found: $ENGINE" >&2
    fi
    exit 1
fi

if gui; then
    # We run the engine in the background and let zenity pulsate.
    # We redirect the engine's stdout/stderr to the log file so it doesn't clog the pipe.
    "$ENGINE" >> "$LOG" 2>&1 &
    ENGINE_PID=$!

    zenity --progress --pulsate --auto-close --no-cancel \
        --title="Home Backup" --text="Backing up your home directory…" 2>/dev/null

    # Wait for the background engine to finish
    wait $ENGINE_PID
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
        zenity --info --title="Home Backup" \
            --text="Backup run finished.\n\nSee the notification for the result." 2>/dev/null || true
    else
        zenity --error --title="Home Backup" \
            --text="Backup reported a problem (exit $rc).\n\nLog: $LOG" 2>/dev/null || true
    fi
else
    "$ENGINE"
fi
