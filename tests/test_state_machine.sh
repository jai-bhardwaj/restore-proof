#!/usr/bin/env bash
# Tests for the one invariant that matters: nothing reaches VERIFIED without a
# successful restore, and "no backup" is distinct from "backup failed".
set -uo pipefail
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1));
          else echo "  FAIL $1 (want=$3 got=$2)"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export BACKUP_DIR="$TMP/bb" ARCHIVE_DIR="$TMP/ar" STATE_FILE="$TMP/state.json"
mkdir -p "$ARCHIVE_DIR"

echo "no backup present"
rm -rf "$BACKUP_DIR"
./scripts/verify-restore.sh >/dev/null 2>&1
RC=$?
STATUS=$(python3 -c "import json;print(json.load(open('$STATE_FILE'))['status'])" 2>/dev/null)
check "exits 2, not 0 — absence is not success"            "$RC"     "2"
check "state is UNVERIFIED, not FAILED"                    "$STATUS" "UNVERIFIED"

echo "empty backup directory"
mkdir -p "$BACKUP_DIR"
./scripts/verify-restore.sh >/dev/null 2>&1
STATUS=$(python3 -c "import json;print(json.load(open('$STATE_FILE'))['status'])" 2>/dev/null)
check "an empty directory is still UNVERIFIED"             "$STATUS" "UNVERIFIED"

echo "state file shape"
HAS=$(python3 -c "
import json;d=json.load(open('$STATE_FILE'))
print(all(k in d for k in ('status','detail','rows_recovered','checked_at')))" 2>/dev/null)
check "state carries status, detail, rows, timestamp"      "$HAS"    "True"
NEVER_OK=$(python3 -c "
import json;print(json.load(open('$STATE_FILE'))['status'] != 'OK')" 2>/dev/null)
check "status is never the word OK"                        "$NEVER_OK" "True"

echo
[ "$FAIL" -eq 0 ] && echo "all $PASS passed" || echo "$FAIL failed"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
