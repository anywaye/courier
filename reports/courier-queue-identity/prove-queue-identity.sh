#!/usr/bin/env bash
#
# PROVE what REPORT-courier-queue-identity-01.md claims about the Oban queue's
# database identity.
#
#   bash reports/courier-queue-identity/prove-queue-identity.sh
#
# THE CLAIM.
#
# `webhook_endpoints` carries FORCE ROW LEVEL SECURITY. `DispatchWebhooksWorker`
# reads it through `WebhookEndpoints.enabled(event.account_id)`, and a policy
# subject holding no `cafaye.account_id` reads ZERO ROWS — not every row, and
# not an error.
#
# THE PART THAT CANNOT BE READ OFF THE SQL, AND IS THE REASON THIS FILE EXISTS.
#
# `config/test.exs` connects as `postgres`. On the machine this was measured on
# that role is `rolsuper=t rolbypassrls=t`, so it bypasses RLS whatever FORCE
# says and the whole suite is green with the boundary inert. kit's cluster does
# NOT create the service owner that way — `kit/templates/compose/postgres/
# initdb/10-cluster.sh:219` creates it `NOSUPERUSER`, and courier connects as it
# (`docker-compose.yml`: `ecto://courier:…@postgres:5432/courier`). So the only
# way to know what courier does on the stack it deploys to is to BUILD that role
# and run courier's own code as it.
#
# So this harness:
#
#   1. builds a NOSUPERUSER owner, exactly as kit's cluster does, and a database
#      it owns — `courier_queue_probe` / `courier_queue_probe_role`;
#   2. runs courier's OWN migration set as that owner, so the policies name that
#      owner (`protect_table` writes them `TO current_user, courier_app`) and
#      FORCE takes the owner's exemption away;
#   3. seeds two accounts, one endpoint and one outbox event each, under an
#      identity — an insert with no identity is refused by the policy's WITH
#      CHECK, which is the substrate working rather than a broken fixture;
#   4. runs `DispatchWebhooksWorker.perform/1` THREE ways and asserts the row
#      counts for each.
#
# THE THREE ARMS, and what each one is for.
#
#   without    the owner role, bare perform/1, nothing around it. THE MEASUREMENT.
#   with       the same call inside `Tenancy.with_account/3`. THE CONTROL: the only
#              difference from `without` is the identity, so a difference in the
#              numbers is a measurement of the identity rather than of the
#              fixture, the seed or the clock.
#   superuser  the same bare call as `postgres`. THE EXPLANATION: identical code
#              and identical rows, so a green suite here is the harness proving
#              nothing, said as a number.
#
# EXIT: 0 only if every arm matched its expectation. **The expectations are
# written against the FIXED tree**: on the unfixed tree this harness is red, with
# `without` returning 0 deliveries where it demands 2. That is not a bug in the
# harness — it is the falsification, and the report prints the run.
#
# ONE DELIBERATE OMISSION. `DeliverWebhookWorker` is MEASURED here and asserted
# NOWHERE. It reads the same protected table from the same queue, it is live in
# the same way, and it is not fixed by this packet — see the report §4 for why
# its fix is a different shape and not a `with_account/3` call. Its numbers are
# printed under a heading that says they are measurements and not passes, and
# they are deliberately outside `$passes`/`$failures`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="$ROOT/reports/courier-queue-identity/driver.exs"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"

ROLE=courier_queue_probe_role
DB=courier_queue_probe
OWNER_URL="ecto://$ROLE:postgres@127.0.0.1:$PGPORT/$DB"
SUPERUSER_URL="ecto://postgres:postgres@127.0.0.1:$PGPORT/$DB"

passes=0
failures=0
say()   { printf '%s\n' "$*"; }
head1() { printf '\n================ %s ================\n' "$*"; }

cleanup() {
  psql -q -c "drop database if exists $DB;" >/dev/null 2>&1
  psql -q -c "drop role if exists $ROLE;"      >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

probe() { # probe <url> <mode...>
  local url="$1"; shift
  COURIER_QUEUE_PROBE_URL="$url" MIX_ENV=test mix run --no-start "$DRIVER" "$@" 2>&1 |
    grep -E '^PROBE ' || true
}

# field <probe-output> <KEY> — the LAST value for KEY, so the `reset` a mode
# prints before an arm cannot be mistaken for the arm's own number.
field() {
  printf '%s\n' "$1" | grep -E "^PROBE $2=" | tail -1 | cut -d= -f2-
}

expect() { # expect <label> <got> <want>
  if [ "$2" = "$3" ]; then
    passes=$((passes + 1)); say "PASS: $1 = $2"
  else
    failures=$((failures + 1)); say "FAIL: $1 = '$2', expected '$3'"
  fi
}

# --------------------------------------------------------------------------
head1 "0. A NOSUPERUSER owner, exactly as kit's cluster creates one"
psql -v ON_ERROR_STOP=1 -q <<SQL
create role $ROLE login nosuperuser nobypassrls nocreatedb nocreaterole
  noreplication password 'postgres';
create database $DB owner $ROLE;
SQL
psql -t -A -c "select rolname || '  rolsuper=' || rolsuper || '  rolbypassrls=' || rolbypassrls
               from pg_roles where rolname = '$ROLE';"
psql -t -A -c "select 'database ' || datname || ' owned by ' || pg_get_userbyid(datdba)
               from pg_database where datname = '$DB';"

# --------------------------------------------------------------------------
head1 "1. courier's OWN migration set, run AS THAT OWNER"
migrated="$(probe "$OWNER_URL" migrate)"
printf '%s\n' "$migrated"
expect "the migration ran as the NOSUPERUSER owner" \
  "$(field "$migrated" CURRENT_ROLE | cut -d' ' -f1)" "$ROLE"

head1 "2. the catalog the migration left, read from pg_class and pg_policies"
psql -q -d "$DB" -t -A -c "
  select relname || '  relrowsecurity=' || relrowsecurity
                || '  relforcerowsecurity=' || relforcerowsecurity
  from pg_class where relname in ('idempotency_keys','notification_preferences','webhook_endpoints')
  order by relname;"
psql -q -d "$DB" -t -A -c "
  select tablename || '  SELECT-policy -> ' || array_to_string(roles, ',')
        || '  USING ' || coalesce(qual, '-')
  from pg_policies where schemaname = 'public' and cmd = 'SELECT' order by tablename;"
expect "webhook_endpoints is FORCE ROW LEVEL SECURITY" \
  "$(psql -q -d "$DB" -t -A -c "select relforcerowsecurity from pg_class where relname='webhook_endpoints'")" \
  "t"
# `pg_policies.cmd` holds the UPPERCASE word — a `cmd = 'select'` predicate
# matches nothing and returns an empty string rather than an error, which is the
# sort of quietly-wrong check that reads as "the policy is absent" when it means
# "the query was". `roles` is a `name[]`, so `array_to_string` joins it with bare
# commas and NO braces (the braces in the table output are psql's rendering), and
# it comes back sorted, hence courier_app first.
expect "the SELECT policy names courier_app AND the owner role that ran it" \
  "$(psql -q -d "$DB" -t -A -c "select array_to_string(roles,',') from pg_policies where tablename='webhook_endpoints' and cmd='SELECT'")" \
  "courier_app,$ROLE"

# --------------------------------------------------------------------------
head1 "3. The fixture: two accounts, one endpoint and one outbox event each"
probe "$OWNER_URL" seed
# Counted as the SUPERUSER, because the owner with no identity reads zero — that
# is the finding, and a fixture counted by the thing under test is a fixture that
# can report itself missing.
expect "webhook_endpoints holds two rows" \
  "$(psql -q -d "$DB" -t -A -c 'select count(*) from webhook_endpoints;')" "2"
expect "outbox_events holds two rows" \
  "$(psql -q -d "$DB" -t -A -c 'select count(*) from outbox_events;')" "2"

# --------------------------------------------------------------------------
head1 "4. THE MEASUREMENT — DispatchWebhooksWorker.perform/1, three ways"
for arm in without with superuser; do
  head1 "--- arm: $arm ---"
  if [ "$arm" = superuser ]; then url="$SUPERUSER_URL"; else url="$OWNER_URL"; fi

  out="$(probe "$url" arm "$arm")"
  printf '%s\n' "$out"

  role="$(field "$out" CURRENT_ROLE)"
  ident="$(field "$out" IDENTITY_BEFORE)"
  visible="$(field "$out" ENDPOINT_ROWS_VISIBLE)"

  say ""
  say "role:                              $role"
  say "identity before perform/1:         $ident"
  say "webhook_endpoints visible to it:   $visible of 2"
  say "perform/1 called:                  $(field "$out" DISPATCH_CALL)"
  say "perform/1 returned:                $(field "$out" DISPATCH_RETURN)"
  say "log lines emitted by perform/1:    $(field "$out" DISPATCH_LOG_LINES)"
  say "webhook_deliveries created:        $(field "$out" DISPATCH_DELIVERY_ROWS)"
  say ""

  # THE CLAIM. Two deliveries is what a fan-out that reached both accounts'
  # endpoints looks like; zero is what one that reached nothing looks like, and
  # the two are the same exit code and the same empty log.
  expect "[$arm] perform/1 returned" "$(field "$out" DISPATCH_CALL)" "returned"
  expect "[$arm] the fan-out created 2 deliveries" "$(field "$out" DISPATCH_DELIVERY_ROWS)" "2"

  if [ "$arm" = without ]; then
    # Two assertions about the ROLE, because "0 deliveries" has three possible
    # causes and only the role distinguishes the one under test from a fixture
    # that was never seeded and a worker that found no events to claim.
    expect "[without] the role is the NOSUPERUSER owner" "$(printf '%s' "$role" | cut -d' ' -f1)" "$ROLE"
    expect "[without] the role does NOT bypass RLS" \
      "$(printf '%s' "$role" | grep -o 'rolbypassrls=t' || echo absent)" "absent"
    expect "[without] the owner read 0 of 2 endpoint rows with no identity" "$visible" "0"
    expect "[without] perform/1 logged nothing" "$(field "$out" DISPATCH_LOG_LINES)" "0"
  fi
done

# --------------------------------------------------------------------------
head1 "5. THE SIBLING WORKER — MEASURED, NOT ASSERTED, NOT FIXED HERE"
say "DeliverWebhookWorker reads the same protected table from the same queue."
say "These numbers are NOT in the tally above and assert nothing: the worker is"
say "outside this packet's fix, and the report says why its fix is a different"
say "shape rather than another with_account/3 call. Read them as the finding."
say ""
for arm in without with superuser; do
  if [ "$arm" = superuser ]; then url="$SUPERUSER_URL"; else url="$OWNER_URL"; fi
  out="$(probe "$url" arm "$arm")"
  say "arm $arm:"
  say "  deliver/1 returned:               $(field "$out" DELIVER_RETURN)"
  say "  deliveries succeeded:             $(field "$out" DELIVER_DELIVERY_ROWS_SUCCEEDED)"
  say "  deliveries exhausted:             $(field "$out" DELIVER_DELIVERY_ROWS_EXHAUSTED)"
  say "  log lines emitted by deliver/1:   $(field "$out" DELIVER_LOG_LINES)"
done

# --------------------------------------------------------------------------
head1 "RESULT"
say "passed: $passes"
say "failed: $failures"
[ "$failures" -eq 0 ] || exit 1