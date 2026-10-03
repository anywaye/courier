#!/usr/bin/env bash
#
# PROVE what REPORT-courier-outbox-enqueue-01.md claims about courier's queue
# having no producer.
#
#   bash reports/courier-outbox-enqueue/prove-outbox-enqueue.sh
#
# THE CLAIM.
#
# `Courier.Deliver` writes an `outbox_events` row in the same transaction as the
# send, and `Courier.Workers.ProcessOutboxWorker` is the only thing that publishes
# those rows. Before this packet NOTHING ever put a job in the queue: `Oban.insert`
# appeared zero times in `lib/`, there was no cron plugin, and the supervision tree
# started Oban and left it empty. So a send left a durable row that nothing would
# ever read.
#
#   grep -rn "Oban.insert" lib/ priv/ config/ | wc -l     -> 0
#   grep -rniE "cron|periodic|sweeper" lib/              -> nothing
#
# WHY A HARNESS AND NOT A LEMMA. 1301 green tests never saw it, because every one
# of them drives `perform/1` directly. The gap is not inside the consumer, it is
# one layer out from it: a test that drives the consumer proves the consumer works
# and says nothing about who calls it. So this harness asserts on the QUEUE: after
# a real send, what does `oban_jobs` hold?
#
# THE TWO ARMS.
#
#   enqueue   `Courier.Deliver.welcome/1` end to end, then read `oban_jobs`, then
#             run the job the queue HOLDS. The fast path and its whole claim.
#   sweep     a row written with a plain `Repo.insert/1` — no enqueue anywhere —
#             published by a job shaped exactly the way the crontab builds one.
#             The floor under it, for a row written by a path that forgot.
#
# EXIT: 0 only if the tree enqueues. `COURIER_OUTBOX_EXPECT=none` inverts the
# expectation, which is how the falsification is run — the SAME script, the SAME
# commands, against the tree with the enqueue deleted. Nothing here is a mock and
# no SQL is hand-written for the write under test.
#
# ITS OWN DATABASE, and why: `config/test.exs` hard-codes the database name, and
# the suite's `courier_test` must not be written to by a harness. This creates
# `courier_outbox_probe`, migrates courier's own migration set into it, and drops
# it on the way out.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="$ROOT/reports/courier-outbox-enqueue/driver.exs"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"

DB=courier_outbox_probe
EXPECT="${COURIER_OUTBOX_EXPECT:-enqueue}"
export COURIER_OUTBOX_PROBE_URL="ecto://postgres:postgres@127.0.0.1:$PGPORT/$DB"

passes=0
failures=0
measurements=0
say()   { printf '%s\n' "$*"; }
head1() { printf '\n================ %s ================\n' "$*"; }

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    passes=$((passes + 1))
    say "  ok    $label = $actual"
  else
    failures=$((failures + 1))
    say "  FAIL  $label = $actual (expected $expected)"
  fi
}

note() {
  measurements=$((measurements + 1))
  say "  measured  $*"
}

cleanup() {
  dropdb --if-exists "$DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
createdb "$DB" || exit 1
say "created $DB"
say "expectation: a job in the queue = $EXPECT"

# ---------------------------------------------------------------- the source
head1 "the source: who calls Oban.insert"
inserts="$(grep -rn "Oban.insert" "$ROOT/lib" | wc -l | tr -d ' ')"
say "  Oban.insert in lib/: $inserts"
cron_hits="$(grep -rniE "Oban.Cron|crontab" "$ROOT/lib" "$ROOT/config" | wc -l | tr -d ' ')"
say "  cron configuration in lib/ and config/: $cron_hits"

# ---------------------------------------------------------------- the enqueue arm
head1 "arm: enqueue — Courier.Deliver end to end, then read oban_jobs"
out="$(cd "$ROOT" && MIX_ENV=test mix run --no-start "$DRIVER" enqueue 2>&1)"
printf '%s\n' "$out" | sed 's/^/  | /'

if [ "$EXPECT" = "enqueue" ]; then
  check "oban jobs after one send" "1" \
    "$(printf '%s\n' "$out" | sed -n 's/^oban jobs after one send:  *//p')"
  check "the job's args name the row" "true" \
    "$(printf '%s\n' "$out" | sed -n 's/^args name the row: //p')"
  check "the row is published by the queued job" "true" \
    "$(printf '%s\n' "$out" | sed -n 's/^row published: //p' | head -1)"
  check "envelopes handed to the publisher" "1" \
    "$(printf '%s\n' "$out" | sed -n 's/^published envelopes handed back: //p')"
else
  check "oban jobs after one send" "0" \
    "$(printf '%s\n' "$out" | sed -n 's/^oban jobs after one send:  *//p')"
fi
note "the send wrote $(printf '%s\n' "$out" | sed -n 's/^outbox rows after one send: //p') row(s) and the queue holds $(printf '%s\n' "$out" | sed -n 's/^oban jobs after one send:  *//p') job(s)"

# ---------------------------------------------------------------- the sweep arm
head1 "arm: sweep — a row nobody enqueued, published by the crontab's job"
out="$(cd "$ROOT" && MIX_ENV=test mix run --no-start "$DRIVER" sweep 2>&1)"
printf '%s\n' "$out" | sed 's/^/  | /'

check "oban jobs before the sweep" "0" \
  "$(printf '%s\n' "$out" | sed -n 's/^oban jobs before the sweep: *//p')"
check "the sweep's job publishes the stranded row" "true" \
  "$(printf '%s\n' "$out" | sed -n 's/^row published: *//p' | head -1)"
check "envelopes handed to the publisher" "1" \
  "$(printf '%s\n' "$out" | sed -n 's/^published envelopes handed back: //p')"

head1 "tally"
say "  passes:        $passes"
say "  failures:      $failures"
say "  measurements:  $measurements (printed, deliberately not asserted on)"
if [ "$failures" -ne 0 ]; then
  say "  RESULT: RED"
  exit 1
fi
say "  RESULT: GREEN"
exit 0