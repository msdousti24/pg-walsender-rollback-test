-- Phase D: MANY read-only transactions. These count in pg_stat_database.xact_commit
-- but write no WAL, so the walsender never sees them.
-- This explains why the jump can be far smaller than xact_commit on a real
-- workload: xact_commit counts reads too, and the walsender never sees them.
\set id random(1, 100000)
SELECT count(*) FROM unpub_small WHERE id = :id;
