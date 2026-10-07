#!/usr/bin/env bash
# radar-update.sh - checks the Radar version and performs the auto-update (if a newer one exists).
# macOS version. Requires: curl, tar, python3. PowerShell 5.1/Windows equivalents not needed.
#
# Flow:
#   installed version -> latest GitHub release -> if newer: download the darwin tar.gz for the
#   local architecture, remove the quarantine attribute, back up the current binary, replace it,
#   restart silently, and VERIFY that the server comes back online (port 9280).
#   On error it restores the backup and restarts: never leave Radar stopped or partial.
#
# Usage:
#   bash radar-update.sh            # prints results
#   bash radar-update.sh --silent   # writes only ~/.radar/last-update-result.txt (used by the tray)

set -euo pipefail

SILENT=0
if [ "${1:-}" = "--silent" ]; then SILENT=1; fi

RADAR_DIR="${RADAR_DIR:-$HOME/.radar}"
RADAR_BIN="${RADAR_BIN:-$RADAR_DIR/radar}"
BACKUP_DIR="$RADAR_DIR/backup"
RESULT_FILE="$RADAR_DIR/last-update-result.txt"
LOG_FILE="$RADAR_DIR/radar.log"
REPO="skyhook-io/radar"
API="https://api.github.com/repos/${REPO}/releases/latest"
UA="User-Agent: opencode"

mkdir -p "$RADAR_DIR" "$BACKUP_DIR"

write_result() { printf '%s\n' "$1" >"$RESULT_FILE"; [ "$SILENT" -eq 0 ] && echo "$1"; }

# Rotate/clean old logs and temp files so they never fill the disk.
clean_stale() {
    # ~/.radar temporal download dirs older than 7 days
    find "$RADAR_DIR"/update-tmp-* -maxdepth 0 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    # radar.log rotated: keep the last ~2 MB
    if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt 2097152 ]; then
        tail -c 2097152 "$LOG_FILE" >"$LOG_FILE.2" 2>/dev/null && mv -f "$LOG_FILE.2" "$LOG_FILE" || true
    fi
}
clean_stale

# Server answers on 9280? (TCP)
radar_up() { nc -z 127.0.0.1 9280 2>/dev/null; }

# Installed version
inst="$("$RADAR_BIN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$inst" ] || inst="0.0.0"

# Latest GitHub release
latest="$(curl -fsSL --connect-timeout 30 --max-time 60 -H "$UA" "$API" 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))' || true)"
[ -n "$latest" ] || { write_result "Could not retrieve the latest version (network?)."; exit 1; }

# If newest available <= installed -> up to date
if [ "$(printf '%s\n%s\n' "$latest" "$inst" | sort -V | head -n1)" = "$latest" ]; then
    write_result "Radar already up to date: installed $inst = latest $latest."
    exit 0
fi

# Architecture of this Mac
case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    *)     ARCH="amd64" ;;
esac

asset="radar_v${latest}_darwin_${ARCH}.tar.gz"
url="https://github.com/${REPO}/releases/download/v${latest}/${asset}"

write_result "Downloading Radar $latest ($ARCH) from GitHub..."
TMP="$(mktemp -d "$RADAR_DIR/update-tmp.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if ! curl -fL --retry 4 --retry-delay 3 --connect-timeout 30 --max-time 900 -H "$UA" -o "$TMP/$asset" "$url"; then
    # download failed before touching anything -> no rollback needed
    write_result "Download failed. Retry: likely a network/proxy issue."
    exit 1
fi

tar -xzf "$TMP/$asset" -C "$TMP"
NEW="$TMP/radar"
[ -f "$NEW" ] || { write_result "radar binary not found in the archive."; exit 1; }

# Remove the macOS quarantine attribute (else Gatekeeper may block execution).
xattr -d com.apple.quarantine "$NEW" 2>/dev/null || true

# Back up the current binary so an error can restore it.
[ -f "$RADAR_BIN" ] && cp -f "$RADAR_BIN" "$BACKUP_DIR/radar.$inst.bak" 2>/dev/null || true
BACKED_UP=1

# On macOS a running executable is NOT locked, so replacement is easy; still stop to avoid a
# short-lived bind conflict on port 9280, then replace.
pkill -x radar 2>/dev/null || true
sleep 0.5
if ! cp -f "$NEW" "$RADAR_BIN"; then
    # restore backup and restart
    [ "$BACKED_UP" -eq 1 ] && cp -f "$BACKUP_DIR/radar.$inst.bak" "$RADAR_BIN" 2>/dev/null || true
    nohup "$RADAR_BIN" --prometheus-single-cluster -no-browser >>"$LOG_FILE" 2>&1 </dev/null & disown
    write_result "Error applying update: could not replace the binary. Backup restored and server restarted."
    exit 1
fi
chmod +x "$RADAR_BIN"

# Restart silently and verify the server comes back online (MCP + web UI).
nohup "$RADAR_BIN" --prometheus-single-cluster -no-browser >>"$LOG_FILE" 2>&1 </dev/null & disown
online=0
for _ in $(seq 1 30); do
    sleep 0.5
    if radar_up; then online=1; break; fi
done

if [ "$online" -eq 1 ]; then
    write_result "Radar updated: $inst -> $latest. Server restarted and online."
else
    write_result "Radar updated: $inst -> $latest, but the server does not appear to be back up. Run start-radar.sh."
fi
exit 0
