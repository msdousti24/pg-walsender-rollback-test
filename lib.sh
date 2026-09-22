#!/usr/bin/env bash
# Shared helpers for the walsender / xact_rollback experiment.
set -uo pipefail
DC="docker compose"
PSQL_PUB=( $DC exec -T pub psql -U postgres -d appdb -At -F $'\t' )
PSQL_SUB=( $DC exec -T sub psql -U postgres -d appdb -At -F $'\t' )

psql_pub() { "${PSQL_PUB[@]}" -c "$1"; }
psql_sub() { "${PSQL_SUB[@]}" -c "$1"; }

# One snapshot of everything we care about, on the PUBLISHER.
#   commits  rollbacks  wal_bytes  walsender_procs  slot_active
snap() {
  psql_pub "SELECT
      (SELECT xact_commit   FROM pg_stat_database WHERE datname='appdb'),
      (SELECT xact_rollback FROM pg_stat_database WHERE datname='appdb'),
      (SELECT pg_current_wal_lsn() - '0/0'::pg_lsn)::bigint,
      (SELECT count(*) FROM pg_stat_replication),
      (SELECT coalesce(bool_or(active),false)::int FROM pg_replication_slots WHERE slot_name='sub_one');"
}

wait_for() {  # wait_for <desc> <sql returning t/f> <timeout_s>
  local desc="$1" sql="$2" t="${3:-60}" i=0
  while [ $i -lt "$t" ]; do
    [ "$(psql_pub "SELECT ($sql)::int;" 2>/dev/null | tr -d '[:space:]')" = "1" ] && return 0
    sleep 1; i=$((i+1))
  done
  echo "    !! timeout waiting for: $desc" >&2; return 1
}

wait_streaming()   { wait_for "walsender streaming" "SELECT count(*)>0 FROM pg_stat_replication WHERE state='streaming'" "${1:-90}"; }
wait_no_walsender(){ wait_for "walsender gone"      "SELECT count(*)=0 FROM pg_stat_replication" "${1:-60}"; }
