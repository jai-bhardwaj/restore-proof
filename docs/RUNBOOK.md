# Recovery runbook

Written to be followed at 3am by someone who did not build this, which is the
only test a runbook has to pass.

Every command below has been run. The numbers in "expected" are what this
project actually produced, not what it ought to produce.

---

## 0. First question: is there a verified backup?

```sh
cat data/backup-state.json
```

| `status` | meaning | what to do |
|---|---|---|
| `VERIFIED` | restored into a throwaway instance and queried successfully | proceed |
| `UNVERIFIED` | a backup exists but **has never been restored** | run step 1 before trusting it |
| `FAILED` | a restore was attempted and did not come back | **do not plan around this backup** |

There is no `OK`. "The backup job exited 0" is not a status anyone should be
able to act on.

## 1. Prove the backup before you need it

```sh
./scripts/verify-restore.sh
```

Restores the latest base backup into a disposable container on port 55433,
replays WAL from `data/archive`, and runs `SELECT count(*)` and `SELECT
sum(amount)` against the recovered `ledger`. Only a successful query moves the
state to `VERIFIED`.

**Exit codes:** `0` verified · `1` restore failed · `2` nothing to restore.
`2` is deliberately not `1` — absence of a backup and a backup that will not
restore are different emergencies.

## 2. Is the standby actually streaming?

```sh
docker exec rp-primary psql -U postgres -tAc \
  "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
```

Expected: one row, `state = streaming`.

**A standby container that is "healthy" tells you nothing.** It can be up,
accepting connections, and silently not replicating. Check
`pg_stat_replication` on the *primary*, not the standby's health check.

Replication lag:

```sh
docker exec rp-primary psql -U postgres -tAc \
  "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
     FROM pg_stat_replication;"
```

## 3. Point-in-time recovery

Cause and recover from a real deletion:

```sh
./scripts/pitr-drill.sh          # deletes every acct-7 row, prints a target time
RECOVERY_TARGET_TIME='<target>' ./scripts/verify-restore.sh
```

The drill forces `pg_switch_wal()` after the delete. Without that the WAL
segment containing the damage may not be archived yet, and the recovery would
"succeed" while proving nothing.

## 4. Promote the standby (primary is gone)

```sh
docker exec rp-standby pg_ctl promote -D /var/lib/postgresql/data
docker exec rp-standby psql -U postgres -tAc "SELECT pg_is_in_recovery();"  # expect f
```

**After promotion the old primary must not come back as a primary.** Two
writable nodes that both believe they are authoritative is worse than an
outage, because it is silent. Rebuild the old primary as a standby
(`pg_basebackup` from the promoted node) before restarting it.

## 5. Monitoring

- Prometheus: http://localhost:59090
- Grafana: http://localhost:53000 (anonymous viewer enabled)
- postgres_exporter: http://localhost:59187/metrics

Useful starting queries:

```promql
pg_stat_replication_pg_wal_lsn_diff     # replication lag in bytes
pg_up                                    # exporter can reach the database
```

**What is deliberately not here:** alerting rules. Alert thresholds are a
property of a specific service's tolerance for lag and downtime, and inventing
them for a demo would be the same mistake as inventing a latency number.

---

## Known limits

- Single-machine. The "disaster" is a dropped table or a corrupt data
  directory, not a lost datacentre.
- No encryption at rest and no off-host backup copy. Both are necessary in
  production and neither is demonstrated here.
- Postgres only. The shape applies to MongoDB and ClickHouse; the commands do
  not.
