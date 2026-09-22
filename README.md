# `pg_stat_database.xact_rollback` jumps when a logical walsender exits

A self-contained reproduction of a PostgreSQL behaviour that is easy to mistake for a
database problem:

> **A logical decoding walsender increments `pg_stat_database.xact_rollback` once for every
> WAL-writing transaction it decodes. The counts accumulate in the walsender's private memory
> for its entire lifetime and are flushed into the shared `pg_stat_database` row only when the
> process exits — producing one enormous step in a single sample.**

Nothing actually rolls back. The contents of the publication are irrelevant. It is not
specific to any CDC tool: this harness uses plain native logical replication.

This is a known issue, reported on pgsql-hackers by Nikolay Samokhvalov as
["xact_rollback spikes when logical walsender exits"](http://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg226992.html).

## Why it matters

If you alert on transaction health with something like

```
error_ratio = xact_rollback / (xact_rollback + xact_commit)
```

and you also run logical replication, then every walsender restart — a subscriber restart, a
connector redeploy, a node moving, a network blip — injects a large spike into that ratio with
no corresponding application error. Depending on how long the walsender had been alive, the
spike can be large enough to blow through every burn-rate window you have.

## Setup

| | |
|---|---|
| Publisher | PostgreSQL, `wal_level=logical` |
| Subscriber | PostgreSQL, native logical replication (no CDC tooling involved) |
| Tables | 4 on the publisher: `published_tbl`, `unpub_small`, `unpub_wide`, `unpub_other` |
| Publication | `pub_one FOR TABLE published_tbl` — **one table of four** |
| Slot | `sub_one`, plugin `pgoutput` |
| Disruption | `docker compose stop sub` → apply worker disconnects → walsender exits |

```
./run-experiment.sh
```

Takes about four minutes. Results land in `out/results.tsv` and `out/run.log`.

## Experiment design

Each cycle is: snapshot → load → snapshot → **disrupt subscriber** → snapshot → restore.
Snapshots record `xact_commit`, `xact_rollback`, the current WAL position, the number of rows
in `pg_stat_replication`, and whether the slot is active.

The four workloads exist to pull apart three variables that move together on real traffic —
transaction count, WAL volume, and published-table changes:

| script | shape | isolates |
|---|---|---|
| `a-many-tiny-unpub.sql` | many tiny txns → **unpublished** table | high txn count, low WAL |
| `b-few-huge-unpub.sql` | few large txns → **unpublished** table | low txn count, high WAL |
| `c-many-tiny-pub.sql` | many tiny txns → **published** table | published vs unpublished |
| `d-readonly.sql` | many read-only txns | commits with no WAL at all |

Phase **B** is the decisive one. "One count per transaction" predicts a tiny number there;
"one count per N bytes of WAL" predicts a huge one.

## Results

| phase | load | commits during load | WAL during load | rollback **during** load | **JUMP at walsender exit** |
|---|---|---|---|---|---|
| 0-idle-baseline | none | 6 | 0.0 MB | 0 | **0** |
| A-many-tiny-unpub | 200,000 tiny txns → unpublished | 200,015 | 36.2 MB | 0 | **200,000** |
| B-few-huge-unpub | 300 large txns → unpublished | 311 | 489.7 MB | 0 | **300** |
| C-many-tiny-pub | 40,000 tiny txns → published | 40,016 | 7.3 MB | 0 | **40,000** |
| D-readonly-only | 200,000 read-only txns | 200,015 | 1.3 MB | 0 | **2** |
| E-repeat-idle | none | 6 | 0.0 MB | 0 | **1** |

Reproduced identically across runs.

## What the table shows

**1. Exactly one count per write transaction.** 200,000 → 200,000. 300 → 300. 40,000 → 40,000.

**2. Not proportional to WAL volume.** Phase B pushed 490 MB of WAL through the decoder in 300
transactions and produced a jump of 300 — not the ~1.4 million a WAL-proportional model predicts.
Bytes-per-count across phases spans a factor of ~9,000, so WAL volume is not the driver.

**3. The publication is irrelevant.** Phases A and B wrote *only* to unpublished tables and still
produced a full 1:1 count. Since PostgreSQL 15 the walsender filters changes to unpublished
tables before buffering them, but the per-transaction begin/abort cycle still happens. This is why
a consumer reporting only a few thousand captured events can be associated with millions of
counted "rollbacks".

**4. Read-only transactions contribute nothing.** Phase D: 200,015 commits, a jump of 2. They
write no WAL, so the walsender never sees them. This is also why the jump can be far smaller than
`xact_commit` on a real workload — the ratio between them is just your write fraction.

**5. Nothing accumulates visibly during the load.** The `rollback during load` column is zero in
every phase. The counter is flat while the work happens, then moves all at once at process exit.

## Mechanism

Two things combine to produce the shape.

**Where the count comes from.** Logical decoding reads the catalog under a historic snapshot
inside a transaction that is never committed — `ReorderBufferProcessTXN()` ends each decoded
transaction with `AbortCurrentTransaction()`. In a walsender that is a *top-level* abort, so
`AtEOXact_PgStat_Database(isCommit=false)` increments the backend-local rollback counter.

**Why it arrives in one lump.** Backends hold cumulative statistics privately and flush them to
shared memory periodically. A walsender in streaming mode does not reach that flush path, so its
counts accumulate for the process's whole lifetime and are written out only at exit.

Samokhvalov's thread proposes a backend-local `pgStatXactSkipCounters` flag so
`AtEOXact_PgStat_Database()` can skip these implicit walsender rollbacks. Fujii Masao raised the
design question of whether `xact_rollback` should count background processes at all. Unresolved
at time of writing — so plan around the behaviour rather than waiting for a fix.

## Practical advice

- **Do not alert on raw `xact_rollback` if you run logical replication.** Neither as a rate nor
  as a ratio. Any threshold is either deaf to real problems or deafened by walsender restarts.
- **Alert on application-level errors instead** — failed requests, constraint violations. That is
  what an "aborted transactions" metric was a proxy for anyway.
- **Watch walsender restarts directly.** `pg_stat_replication` going empty is a clean signal, and
  every restart is also a gap in change capture, which is worth knowing about on its own.
- **Restarting less often does not help proportionally.** Because the count accrues over the
  walsender's whole life, halving the restart rate roughly doubles each spike.

## A gotcha worth knowing

`pg_stat_database.xact_commit` counts **every** committed transaction, including read-only ones.
Phase D demonstrates it: 200,015 commits from pure `SELECT`s. If you build a "transactions per
second" dashboard on that counter for a read-heavy database, you are mostly graphing reads.

## Distinguishing a real walsender exit from a failed scrape

If you monitor this, note that `pg_replication_slots.active` tells you the slot is being streamed,
not that a process is alive. `pg_stat_replication` is the process-level view — the docs define it
as "one row per WAL sender process".

- **Real exit:** `pg_stat_replication` empty **and** the `pg_replication_slots` row present with
  `active = false`.
- **Failed scrape:** both views missing.

## Files

```
docker-compose.yml            publisher + subscriber
sql/01-publisher-init.sql     4 tables, publication on 1 of them
sql/02-subscriber-init.sql    replica table
bench/a-many-tiny-unpub.sql   many small txns, unpublished table
bench/b-few-huge-unpub.sql    few large txns, unpublished table  (decisive phase)
bench/c-many-tiny-pub.sql     many small txns, published table
bench/d-readonly.sql          read-only txns
lib.sh                        psql helpers, snapshot + wait functions
run-experiment.sh             orchestrates all cycles
out/results.tsv               machine-readable results
out/run.log                   full transcript
```
