#!/usr/bin/env bash
# backup-world.sh — crash-consistent, immutable Minecraft world backups.
#
# Why not `cp -r world`, and why not hardlink snapshots:
#   * copying region files while the server writes them gives a corrupt backup;
#   * hardlinking "unchanged" files into a snapshot is silently unsafe, because
#     Minecraft truncates and rewrites region files in place — the old snapshot
#     would mutate along with the live world.
# So: quiesce the server over RCON, stream the world into a compressed archive,
# verify it, and rotate. Every snapshot is immutable and restorable with one
# command (printed at the end of each run).
#
# Usage (as the minecraft user, from cron/timer):
#   */30 * * * * /opt/minecraft/scripts/backup-world.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="${MC_DIR:-/opt/minecraft}"
WORLD="${WORLD:-world}"
DEST="${DEST:-/mnt/backups/minecraft}"
RCON_PY="${RCON_PY:-$SCRIPT_DIR/rcon.py}"
FLUSH_WAIT="${FLUSH_WAIT:-10}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if command -v zstd >/dev/null 2>&1; then
  COMP="zstd -T4 -3 -q"; EXT="tar.zst"; TEST="zstd -t -q"
else
  COMP="gzip -1"; EXT="tar.gz"; TEST="gzip -t"
fi

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

[[ -d "$MC_DIR/$WORLD" ]] || { log "FATAL: world not found at $MC_DIR/$WORLD"; exit 1; }
mkdir -p "$DEST"
ARCHIVE="$DEST/world-$STAMP.$EXT"
PARTIAL="$ARCHIVE.part"

# Send one console command; non-zero exit means the server is unreachable.
send() { python3 "$RCON_PY" "$1" >/dev/null 2>&1; }

SERVER_UP=0
if send "save-off"; then
  SERVER_UP=1
  send "save-all flush" || true
  log "server quiesced; waiting ${FLUSH_WAIT}s for region files to reach disk"
  sleep "$FLUSH_WAIT"
else
  log "WARN: RCON unreachable (server stopped?) - archiving live files anyway"
fi

abort() {
  local rc=$?
  if [[ "$SERVER_UP" -eq 1 ]]; then send "save-on" || true; fi
  [[ -f "$PARTIAL" ]] && rm -f "$PARTIAL"
  [[ $rc -ne 0 ]] && log "archive failed (rc=$rc); partial file removed"
  exit $rc
}
trap abort EXIT

log "archiving $WORLD -> $(basename "$ARCHIVE") ($COMP)"
tar -C "$MC_DIR" -cf - "$WORLD" | $COMP > "$PARTIAL"
$TEST "$PARTIAL"
mv "$PARTIAL" "$ARCHIVE"
sha256sum "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"

# Back to normal saving as soon as the data is on disk.
if [[ "$SERVER_UP" -eq 1 ]]; then send "save-on" || true; fi
trap - EXIT

log "verified: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
log "restore with: $TEST <archive> && tar -C $MC_DIR -xf <archive>"

# Retention: 24 hourly, 7 daily, 4 weekly (see rotate-backups.py).
log "rotating ($(find "$DEST" -maxdepth 1 -name 'world-*.tar.*' | wc -l) archives before)"
python3 "$SCRIPT_DIR/rotate-backups.py" "$DEST" || log "WARN: rotation failed - archives kept"

# Optional off-site copy:
#   restic -r sftp:backup@host:/srv/mc backup "$DEST" --tag minecraft
#   rclone copy "$DEST" remote:mc-backups --include 'world-*.tar.*'
