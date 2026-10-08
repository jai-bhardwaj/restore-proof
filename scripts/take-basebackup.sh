#!/usr/bin/env bash
#
# Take a base backup from the primary.
#
# Note what this script deliberately does NOT do: it does not report success.
# It writes the backup and then marks state UNVERIFIED, because at this point
# that is all that is known. Only verify-restore.sh can move it to VERIFIED.
# Treating "the backup command exited 0" as success is the exact failure this
# project is about.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./data/basebackup}"
STATE_FILE="${STATE_FILE:-./data/backup-state.json}"
PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-rp-primary}"

log() { printf '[basebackup] %s\n' "$*" >&2; }

rm -rf "${BACKUP_DIR:?}"/*
mkdir -p "$BACKUP_DIR"

log "running pg_basebackup against $PRIMARY_CONTAINER"
docker exec "$PRIMARY_CONTAINER" rm -rf /tmp/bb
docker exec "$PRIMARY_CONTAINER" \
  pg_basebackup -U postgres -D /tmp/bb -Fp -Xs -c fast
docker cp "$PRIMARY_CONTAINER":/tmp/bb/. "$BACKUP_DIR"/
docker exec "$PRIMARY_CONTAINER" rm -rf /tmp/bb

BYTES=$(du -sk "$BACKUP_DIR" | cut -f1)
mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" <<JSON
{
  "status": "UNVERIFIED",
  "detail": "base backup written (${BYTES} KiB) but never restored",
  "rows_recovered": null,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

log "backup written: ${BYTES} KiB"
log "status is UNVERIFIED. It stays that way until verify-restore.sh restores it."
