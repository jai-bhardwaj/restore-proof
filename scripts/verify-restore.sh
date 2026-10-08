#!/usr/bin/env bash
#
# The only script here that matters.
#
# A backup is a claim. Until it has been restored and queried, it is an
# UNVERIFIED claim, and most backup tooling reports the claim as if it were the
# fact: the dump exited 0, the file is on disk, the dashboard is green. None of
# that establishes that the data can come back.
#
# This restores the latest base backup into a throwaway Postgres instance,
# replays WAL, runs verification queries against it, and only then marks the
# backup VERIFIED. Anything else - including "the backup file exists and looks
# fine" - leaves it UNVERIFIED, which is a different and more honest state than
# FAILED.
set -euo pipefail

ARCHIVE_DIR="${ARCHIVE_DIR:-./data/archive}"
BACKUP_DIR="${BACKUP_DIR:-./data/basebackup}"
STATE_FILE="${STATE_FILE:-./data/backup-state.json}"
VERIFY_PORT="${VERIFY_PORT:-55433}"
VERIFY_CONTAINER="restore-proof-verify"
PGIMAGE="${PGIMAGE:-postgres:16-alpine}"

log() { printf '[verify-restore] %s\n' "$*" >&2; }

write_state() {
  # status is one of VERIFIED | UNVERIFIED | FAILED. Never "OK".
  local status="$1" detail="$2" rows="${3:-null}"
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" <<JSON
{
  "status": "$status",
  "detail": "$detail",
  "rows_recovered": $rows,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  log "state -> $status ($detail)"
}

cleanup() {
  docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm -f restore-proof-verify-data >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 0. is there anything to verify at all? -------------------------------
if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
  write_state UNVERIFIED "no base backup present" 
  log "nothing to restore. This is UNVERIFIED, not FAILED - absence of a"
  log "backup is not the same as a backup that did not restore."
  exit 2
fi

# --- 1. restore into a throwaway instance ---------------------------------
#
# A BIND MOUNT DOES NOT WORK HERE, and the way it fails is worth knowing: the
# backup files are owned by the host user, so the container's postgres (uid 70)
# cannot read them, the image entrypoint concludes PGDATA is empty, runs initdb,
# and you get a pristine empty cluster that starts perfectly. Every health check
# passes and the data is gone. A restore check that reported "server came up" and
# stopped there would have called that a success.
#
# So: a named volume, populated with docker cp, chowned to the postgres uid.
VOLUME="restore-proof-verify-data"
docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
docker volume create "$VOLUME" >/dev/null

log "copying backup into volume $VOLUME"
docker run --rm -v "$VOLUME":/pgdata -v "$(cd "$BACKUP_DIR" && pwd)":/src:ro "$PGIMAGE" \
  sh -c 'cp -a /src/. /pgdata/ && chown -R postgres:postgres /pgdata && chmod 700 /pgdata'

log "arming recovery"
docker run --rm -v "$VOLUME":/pgdata "$PGIMAGE" sh -c '
  touch /pgdata/recovery.signal
  {
    echo "restore_command = '"'"'cp /archive/%f %p'"'"'"
    echo "recovery_target_action = '"'"'promote'"'"'"
    if [ -n "'"${RECOVERY_TARGET_TIME:-}"'" ]; then
      echo "recovery_target_time = '"'"'"'"${RECOVERY_TARGET_TIME:-}"'"'"'"'"
    fi
  } >> /pgdata/postgresql.conf
  chown postgres:postgres /pgdata/recovery.signal /pgdata/postgresql.conf'

docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$VERIFY_CONTAINER" \
  -e POSTGRES_PASSWORD=verify \
  -v "$VOLUME":/var/lib/postgresql/data \
  -v "$(cd "$ARCHIVE_DIR" && pwd)":/archive:ro \
  -p "${VERIFY_PORT}:5432" \
  "$PGIMAGE" >/dev/null

# --- 2. wait for recovery to finish and the server to accept queries ------
log "waiting for recovery to complete"
ready=0
for _ in $(seq 1 60); do
  if docker exec "$VERIFY_CONTAINER" pg_isready -U postgres -q 2>/dev/null; then ready=1; break; fi
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  write_state FAILED "restored instance never became ready"
  log "the backup did not come back. THIS is the case the whole project exists to catch."
  docker logs --tail 30 "$VERIFY_CONTAINER" >&2 || true
  exit 1
fi

# --- 3. query it. A server that starts is not a backup that worked. -------
log "running verification queries"
ROWS="$(docker exec "$VERIFY_CONTAINER" psql -U postgres -tAc \
        'SELECT count(*) FROM ledger;' 2>/dev/null || echo "")"
SUM="$(docker exec "$VERIFY_CONTAINER" psql -U postgres -tAc \
        'SELECT COALESCE(sum(amount),0) FROM ledger;' 2>/dev/null || echo "")"

if [ -z "$ROWS" ]; then
  write_state FAILED "restored instance started but the ledger table is unreadable"
  exit 1
fi
if [ "$ROWS" -lt 1 ]; then
  write_state FAILED "restored instance has an empty ledger" 0
  exit 1
fi

write_state VERIFIED "restored and queried successfully; checksum sum=$SUM" "$ROWS"
log "VERIFIED - $ROWS rows recovered, sum=$SUM"
