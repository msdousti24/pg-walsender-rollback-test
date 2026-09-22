#!/usr/bin/env bash
# Does a logical walsender exiting dump a large bogus increment into
# pg_stat_database.xact_rollback on the publisher?  And what is the count
# proportional to: transactions, WAL volume, or published-table changes?
#
# Usage: ./run-experiment.sh
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh

OUT=out/results.tsv
LOG=out/run.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

banner() { echo; echo "=============== $* ==============="; }

banner "1. Reset stack"
$DC down -v --remove-orphans >/dev/null 2>&1
$DC up -d --wait
sleep 2

banner "2. Create subscription"
psql_sub "CREATE SUBSCRIPTION sub_one
          CONNECTION 'host=pub port=5432 user=postgres password=pw dbname=appdb'
          PUBLICATION pub_one;"
wait_streaming 90 && echo "  walsender is streaming"
psql_pub "SELECT 'slot: '||slot_name||' plugin='||plugin||' active='||active FROM pg_replication_slots;"
psql_pub "SELECT 'published tables: '||string_agg(tablename,',') FROM pg_publication_tables WHERE pubname='pub_one';"

printf 'phase\tclients\ttxns\tcommits_during_load\twal_MB_during_load\trollback_during_load\tFLUSH_at_walsender_exit\tbytes_per_count\tcommits_per_count\n' > "$OUT"

cycle() { # cycle <name> <benchfile|-> <clients> <txns_per_client>
  local name="$1" bench="$2" c="${3:-0}" t="${4:-0}"
  banner "CYCLE: $name"

  read -r c0 r0 w0 ws0 sa0 <<<"$(snap)"
  echo "  before load : commits=$c0 rollback=$r0 wal=$w0 walsenders=$ws0 slot_active=$sa0"

  if [ "$bench" != "-" ]; then
    echo "  running load: pgbench -c $c -t $t -f $bench"
    $DC exec -T pub pgbench -n -c "$c" -j "$(( c < 4 ? c : 4 ))" -t "$t" -f "/bench/$bench" -U postgres appdb 2>&1 \
      | grep -E 'number of transactions actually processed|latency average|tps' | sed 's/^/    /'
  else
    echo "  (no load - idle baseline)"; sleep 3
  fi

  echo "  waiting for decoding to catch up..."
  wait_for "slot caught up" "SELECT count(*)=0 FROM pg_replication_slots WHERE slot_name='sub_one' AND pg_current_wal_lsn() - confirmed_flush_lsn > 1000000" 180

  read -r c1 r1 w1 ws1 sa1 <<<"$(snap)"
  echo "  after load  : commits=$c1 rollback=$r1 wal=$w1 walsenders=$ws1 slot_active=$sa1"
  echo "    -> rollback moved DURING load by: $((r1-r0))"

  echo "  >> DISRUPTING subscriber (docker compose stop sub)"
  $DC stop sub >/dev/null 2>&1
  wait_no_walsender 60 && echo "     walsender process is gone (pg_stat_replication empty)"
  sleep 3

  read -r c2 r2 w2 ws2 sa2 <<<"$(snap)"
  echo "  after exit  : commits=$c2 rollback=$r2 wal=$w2 walsenders=$ws2 slot_active=$sa2"
  echo "    -> FLUSH at walsender exit: $((r2-r1))"

  local dc=$((c1-c0)) dw=$((w1-w0)) fl=$((r2-r1))
  local bpc="n/a" cpc="n/a"
  [ "$fl" -gt 0 ] && bpc=$(python3 -c "print(f'{$dw/$fl:.1f}')") && cpc=$(python3 -c "print(f'{$dc/$fl:.3f}')")
  printf '%s\t%s\t%s\t%d\t%.1f\t%d\t%d\t%s\t%s\n' \
    "$name" "$c" "$((c*t))" "$dc" "$(python3 -c "print($dw/1048576)")" "$((r1-r0))" "$fl" "$bpc" "$cpc" >> "$OUT"

  echo "  restarting subscriber"
  $DC start sub >/dev/null 2>&1
  $DC exec -T sub sh -c 'until pg_isready -U postgres -d appdb >/dev/null 2>&1; do sleep 1; done'
  wait_streaming 120 && echo "     walsender streaming again"
}

cycle "0-idle-baseline"      -                        0 0
cycle "A-many-tiny-unpub"    a-many-tiny-unpub.sql   8 25000
cycle "B-few-huge-unpub"     b-few-huge-unpub.sql    4 75
cycle "C-many-tiny-pub"      c-many-tiny-pub.sql     8 5000
cycle "D-readonly-only"      d-readonly.sql          8 25000
cycle "E-repeat-idle"        -                        0 0

banner "RESULTS"
column -t -s $'\t' "$OUT"
echo
echo "publisher log around the disruptions:"
$DC logs pub 2>&1 | grep -iE 'logical decoding|START_REPLICATION|terminating|disconnection' | tail -30
