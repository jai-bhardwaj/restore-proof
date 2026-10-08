#!/usr/bin/env bash
#
# Point-in-time recovery drill: cause the disaster, then recover from it.
#
# A DR plan that has never been executed is a document, not a capability. This
# deletes real rows and recovers them, so the runbook is something that has
# been done rather than something that has been written.
set -euo pipefail
PRIMARY="${PRIMARY_CONTAINER:-rp-primary}"
psql_p() { docker exec "$PRIMARY" psql -U postgres -tAc "$1"; }
log() { printf '[pitr-drill] %s\n' "$*" >&2; }

BEFORE=$(psql_p 'SELECT count(*) FROM ledger;')
log "rows before: $BEFORE"

# A recovery target needs a timestamp that is unambiguously before the damage.
sleep 1
TARGET=$(psql_p 'SELECT now();')
log "recovery target: $TARGET"
sleep 1

log "*** causing the disaster: deleting every row for acct-7 ***"
DELETED=$(psql_p "WITH d AS (DELETE FROM ledger WHERE account = 'acct-7' RETURNING 1) SELECT count(*) FROM d;")
AFTER=$(psql_p 'SELECT count(*) FROM ledger;')
log "deleted $DELETED rows; now $AFTER"

# Force the WAL containing the delete to be archived, otherwise recovery has
# nothing to replay past and the drill proves nothing.
psql_p 'SELECT pg_switch_wal();' >/dev/null
sleep 2

printf '%s\n' "$TARGET" > ./data/pitr-target.txt
log "target written to data/pitr-target.txt"
log "now run: RECOVERY_TARGET_TIME='$TARGET' ./scripts/verify-restore.sh"
log "expected: $BEFORE rows, not $AFTER."
