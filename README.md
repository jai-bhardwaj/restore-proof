# restore-proof

**A backup you have not restored is not a backup. It is a claim.**

Most backup tooling reports the claim as if it were the fact: the dump exited 0,
the file is on disk, the dashboard is green. None of that establishes that the
data can come back.

`restore-proof` runs PostgreSQL with streaming replication and WAL archiving,
then continuously tries to disprove its own backups by restoring them into a
throwaway instance and querying the result. A backup is `UNVERIFIED` until that
restore succeeds, and the word `OK` does not appear in the state machine.

## Why this exists

A hiring manager at a company that had just rejected me told me exactly what
their platform team screens for: running databases on Linux including
replication and upgrades, backup and disaster recovery with **restore testing**
and point-in-time recovery, and infrastructure automation. He was right that I
did not have it. This is that project.

## The failure it is built around

While building this, the restore check caught a real instance of the exact
failure it exists to detect — and it is worth stating because it is so easy to
ship:

> The first version bind-mounted the backup directory into the verification
> container. The files were owned by the host user, so the container's
> `postgres` (uid 70) could not read them. The image entrypoint concluded
> `PGDATA` was empty, ran `initdb`, and produced **a pristine empty cluster
> that started perfectly**. `pg_isready` passed. The container was healthy. The
> data was gone.

A check that confirmed "the restored server came up" would have called that a
success. The query step is the whole point:

```
state -> FAILED (restored instance started but the ledger table is unreadable)
```

## What it actually does

```
primary ──── streaming replication ───▶ standby
   │
   └─ WAL archive ──▶ base backup ──▶ throwaway restore ──▶ SELECT ──▶ VERIFIED
```

### Measured on this machine

Every number below is from a real run, not a target.

| | |
|---|---|
| Replication | `172.18.0.3/32 \| streaming \| async` on `pg_stat_replication` |
| Base backup | 39,824 KiB |
| Restore result | **VERIFIED — 5,000 rows, sum 2,512,153.06** |
| PITR drill | deleted 100 rows (5,000 → 4,900), recovered **all 5,000** |

The PITR drill is not a simulation. It deletes real rows on the primary, which
stays at 4,900 afterwards, and recovers them into a separate instance.

## Three states, and no fourth

| state | meaning |
|---|---|
| `VERIFIED` | restored into a throwaway instance and successfully queried |
| `UNVERIFIED` | a backup exists and **has never been restored** |
| `FAILED` | a restore was attempted and the data did not come back |

`take-basebackup.sh` writes `UNVERIFIED` on success, deliberately. The backup
command exiting 0 is not evidence of anything, and only `verify-restore.sh` can
move the state forward.

"No backup at all" exits `2`, not `1` — absence of a backup and a backup that
will not restore are different emergencies and should not share an exit code.

## Run it

```sh
docker compose -f compose/docker-compose.yml up -d
./scripts/take-basebackup.sh      # -> UNVERIFIED
./scripts/verify-restore.sh       # -> VERIFIED, or FAILED with a reason

./scripts/pitr-drill.sh           # deletes rows, prints a recovery target
RECOVERY_TARGET_TIME='<target>' ./scripts/verify-restore.sh
```

Or the whole thing under Ansible, which **fails the play** unless the backup
reaches `VERIFIED`:

```sh
ansible-playbook ansible/site.yml
```

That ordering is deliberate. Automation that takes a backup and reports green
without restoring it is the thing this replaces; it would be incoherent for the
playbook to do exactly that.

## Two things the automation asserts that health checks miss

**A standby that is up is not a standby that is replicating.** The playbook
queries `pg_stat_replication` on the *primary* and fails if nothing is in
`streaming` state. A container health check cannot see this, and the gap is a
silent data-loss window.

**The official Postgres image ships no `replication` line in `pg_hba.conf`.**
Without it `pg_basebackup` fails in a retry loop while the standby container
looks fine. `compose/pg_hba.conf` is mounted explicitly so the grant is visible
in the repository rather than patched in at runtime.

## Monitoring

Prometheus (`:59090`), Grafana (`:53000`, anonymous viewer), and
postgres_exporter (`:59187`).

**No alerting rules are included.** Thresholds are a property of a specific
service's tolerance for lag and downtime; inventing them for a demo would be
the same mistake as inventing a latency number.

## Tests

```sh
./tests/test_state_machine.sh
```

Five assertions on the one invariant that matters: nothing reaches `VERIFIED`
without a successful restore, "no backup" is distinct from "backup failed", and
the status is never the word `OK`.

## Runbook

[`docs/RUNBOOK.md`](docs/RUNBOOK.md) — written to be followed at 3am by someone
who did not build this. Includes promoting the standby, and the warning that
matters afterwards: the old primary must be rebuilt as a standby before it
comes back, because two nodes that both believe they are writable is worse than
an outage.

## What this is not

- **Single machine.** The disaster here is a dropped table or a corrupt data
  directory, not a lost datacentre.
- **No encryption at rest, no off-host backup copy.** Both are necessary in
  production; neither is demonstrated here.
- **Postgres only.** The shape applies to MongoDB and ClickHouse. The commands
  do not.

## Licence

MIT.
