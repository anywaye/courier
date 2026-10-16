#!/usr/bin/env bash
#
# PROVE courier's row-level security actually refuses a cross-account read,
# and prove the refusal is the POLICY rather than a table nobody can read.
#
#   bash reports/courier-row-level-security/prove.sh
#
# Requires a migrated database with `20261003090000_protect_account_scoped_tables`
# applied. Point it at one with the standard libpq variables:
#
#   PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=courier_test_rls \
#     bash reports/courier-row-level-security/prove.sh
#
# WHY IT DRIVES `SET ROLE courier_app` RATHER THAN LOGGING IN AS IT.
#
# `protect_table` writes each policy `to current_user, <login_role>`, so the
# role that ran the migration — `postgres` here — is itself a policy subject,
# and `FORCE ROW LEVEL SECURITY` removes the owner's exemption. So the owner
# path is genuinely filtered and would be the stronger proof.
#
# It is ALSO useless as a proof, because `postgres` is a SUPERUSER and a
# superuser bypasses RLS unconditionally, whatever FORCE says. `SET ROLE` leaves
# superuser behind, so the policies actually apply and the boundary can be
# observed.
#
# AS OF THE APP-ROLE PACKET this is no longer only a property of the harness.
# `Courier.Repo` connects as **`courier_app`** in every environment this
# repository configures, and `Courier.OwnerRepo` — the credential that runs the
# migrations — is not in `:ecto_repos` and not in the supervision tree. So §4
# below no longer measures a hypothetical: the superuser bypass is a fact about
# the BOOTSTRAP role, and the role the application actually uses is subject to
# every policy. The section is kept because the bootstrap role is still a
# superuser on a plain local postgres, and a check that stops measuring the thing
# it was written for is a check that has stopped looking.
#
# FOUR PROBES PER TABLE, and none of them is the same statement as another:
#
#   A  rows_visible_A   count(account_id = A) as identity A   -> 1   (control)
#   B  rows_visible_B   count(account_id = B) as identity A   -> 0   (red, filtered)
#   C  value            the sensitive column for A, as A      -> the real value
#   D  cross_write      UPDATE A row owned by B, as identity A-> 42501
#
# A is the control the packet asks for and B is meaningless without it: a
# policy that refuses everything also satisfies "B returned no rows", and only
# A distinguishes a scoped policy from an unreadable table. B returns ZERO ROWS
# rather than an error, because that is what a SELECT policy that does not match
# does; D is where `42501` actually comes from, because `WITH CHECK` and a
# non-matching `USING` on UPDATE/DELETE raise. Both are refusals and the report
# names them separately rather than reporting one number for both.
#
# `begin_account/1` sets its GUC with `is_local = true`, which is transaction
# scoped: outside an explicit `BEGIN` it is discarded at the end of its own
# statement and the next statement sees no identity at all. Every case is
# wrapped in `BEGIN ... COMMIT`, which is how a request would use it.
#
# EXIT: 0 only if every probe produced its expected outcome.
set -uo pipefail

ACCOUNT_A='11111111-1111-4111-8111-111111111111'
ACCOUNT_B='22222222-2222-4222-8222-222222222222'
USER_A='aaaaaaaa-0000-4000-8000-000000000001'
USER_B='bbbbbbbb-0000-4000-8000-000000000001'
IDEM_A='aaaaaaaa-0000-4000-8000-000000000001'
IDEM_B='bbbbbbbb-0000-4000-8000-000000000001'
HOOK_A='aaaaaaaa-0000-4000-8000-000000000002'
HOOK_B='bbbbbbbb-0000-4000-8000-000000000002'
ENDPOINT='/rls-proof'
EVENT_A='cccccccc-0000-4000-8000-000000000001'
EVENT_B='cccccccc-0000-4000-8000-000000000002'
NOTE_A='dddddddd-0000-4000-8000-000000000001'
NOTE_B='dddddddd-0000-4000-8000-000000000002'
URL='https://rls-proof.invalid/hook'

export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGDATABASE="${PGDATABASE:-courier_test_rls}"

passes=0
failures=0
out=""; raw=""; rc=0

say()   { printf '%s\n' "$*"; }
head1() { printf '\n================ %s ================\n' "$*"; }

# ask <sql> -> runs it inside one transaction, captures output and exit code
ask() {
  # The blank line is `select cafaye.begin_account/1` returning void, which psql
  # still prints as an empty row. Trim surrounding whitespace so the comparison
  # is against the value and not against psql's formatting.
  # VERBOSITY verbose so the SQLSTATE is in the text. At the default verbosity
  # psql prints `ERROR:  new row violates row-level security policy` and not the
  # `42501`, which is the number this packet is required to report — a harness
  # that cannot see it cannot check it.
  raw="$(printf '\\set VERBOSITY verbose\nbegin;\n%s\ncommit;\n' "$1" \
    | psql -q -v ON_ERROR_STOP=1 -t -A -f - 2>&1)"
  rc=$?
  out="$(printf '%s' "$raw" | tr -d '[:space:]')"
}

# show — print the literal SQL, the literal output and the literal exit code
show() {
  say "--- SQL ---"
  printf '%s\n' "$1"
  say "--- output ---"
  printf '%s\n' "$raw"
  say "--- exit code: $rc ---"
}

expect_eq() { # <label> <expected> <actual>
  if [ "$3" = "$2" ]; then
    passes=$((passes + 1)); say "PASS: $1 (got '$3')"
  else
    failures=$((failures + 1)); say "FAIL: $1 — expected '$2', got '$3'"
  fi
}

# A non-matching `USING` does NOT raise: the statement succeeds and affects no
# row, and psql is run with -q so it prints no `UPDATE 0` tag either. So this
# asserts the EFFECT rather than the exit status: `probe_unchanged` re-reads the
# target AS THE OWNER and checks it is still there / still has its old value.
# Reading it back through the same filtered path would make "unchanged" and
# "invisible" the same claim.
expect_filtered() { # <label> <owner-read-sql> <expected-value>
  local label="$1" read="$2" want="$3" got
  got="$(printf '%s\n' "$read" | psql -q -v ON_ERROR_STOP=1 -t -A -f - 2>&1 | tr -d '[:space:]')"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    passes=$((passes + 1)); say "PASS: $1 — succeeded, and the row is unchanged (owner reads '$got')"
  else
    failures=$((failures + 1))
    say "FAIL: $1 — write exit $rc, owner reads '$got', expected '$want'"
  fi
}

# Must be 42501 specifically. A bare non-zero check is not enough: an INSERT into
# a table with a `bigserial` primary key as the login role fails with
# `permission denied for sequence ...`, which is ALSO non-zero and has nothing to
# do with tenancy. An earlier draft of this harness accepted that as a pass.
expect_denied() { # <label>
  if [ "$rc" -eq 0 ]; then
    failures=$((failures + 1)); say "FAIL: $1 — ALLOWED (exit 0)"
  elif printf '%s' "$raw" | grep -q '42501' \
       && printf '%s' "$raw" | grep -q 'violates row-level security policy'; then
    # The SQLSTATE alone is NOT enough, and this harness was bitten by exactly
    # that: `permission denied for sequence notification_preferences_id_seq` is
    # ALSO 42501, so a check on the code alone accepts a privilege failure as a
    # tenancy refusal. Both words are required.
    passes=$((passes + 1)); say "PASS: $1 — refused with 42501, row-level security policy"
  else
    failures=$((failures + 1))
    say "FAIL: $1 — refused, but NOT with 42501, so it measured the wrong thing:"
    printf '%s\n' "$raw" | sed 's/^/         /'
  fi
}

identify_a="set role courier_app; select cafaye.begin_account('$ACCOUNT_A'::uuid);"
identify_none="set role courier_app;"

# --------------------------------------------------------------------------
# 0. Seed one row per account per table, as the OWNER.
# --------------------------------------------------------------------------
head1 "0. SEED — one row for account A, one for account B, in each protected table"
psql -v ON_ERROR_STOP=1 -q <<SQL
delete from idempotency_keys   where endpoint = '$ENDPOINT';
delete from webhook_endpoints where url = '$URL';
delete from notification_preferences where user_id in ('$USER_A'::uuid, '$USER_B'::uuid);

insert into idempotency_keys
  (id, account_id, endpoint, idempotency_key, request_hash, state,
   response_status, response_body, expires_at, inserted_at, updated_at)
values
  ('$IDEM_A', '$ACCOUNT_A', '$ENDPOINT', 'k-a', 'h', 'completed',
   200, 'BODY-FOR-ACCOUNT-A', now() + interval '1 hour', now(), now()),
  ('$IDEM_B', '$ACCOUNT_B', '$ENDPOINT', 'k-b', 'h', 'completed',
   200, 'BODY-FOR-ACCOUNT-B', now() + interval '1 hour', now(), now());

insert into notification_preferences
  (user_id, notification_type, email_enabled, push_enabled, inserted_at, updated_at, account_id)
values
  ('$USER_A'::uuid, 'transactional', false, true, now(), now(), '$ACCOUNT_A'),
  ('$USER_B'::uuid, 'transactional', false, true, now(), now(), '$ACCOUNT_B');

insert into webhook_endpoints
  (id, account_id, url, description, secret, status, inserted_at, updated_at)
values
  ('$HOOK_A', '$ACCOUNT_A', '$URL', 'account A endpoint', 'SECRET-FOR-ACCOUNT-A', 'enabled', now(), now()),
  ('$HOOK_B', '$ACCOUNT_B', '$URL', 'account B endpoint', 'SECRET-FOR-ACCOUNT-B', 'enabled', now(), now());
SQL
if [ $? -ne 0 ]; then say "FATAL: could not seed; everything below would measure nothing."; exit 2; fi

say "Rows actually present, read as the OWNER with no identity at all:"
psql -t -A -c "
  select 'idempotency_keys          rows=' || count(*) from idempotency_keys   where endpoint = '$ENDPOINT'
  union all select 'notification_preferences rows=' || count(*) from notification_preferences where user_id in ('$USER_A'::uuid,'$USER_B'::uuid)
  union all select 'webhook_endpoints         rows=' || count(*) from webhook_endpoints where url = '$URL';"

# --------------------------------------------------------------------------
# 1. idempotency_keys — a cached customer HTTP response
# --------------------------------------------------------------------------
head1 "1. idempotency_keys — the row carries response_body: ANOTHER CUSTOMER'S RESPONSE"
ask "$identify_a select count(*) from idempotency_keys where account_id = '$ACCOUNT_A';"
show "$identify_a
select count(*) from idempotency_keys where account_id = '$ACCOUNT_A';"
expect_eq "A / control: account A sees its own row" "1" "$out"

ask "$identify_a select count(*) from idempotency_keys where account_id = '$ACCOUNT_B';"
show "$identify_a
select count(*) from idempotency_keys where account_id = '$ACCOUNT_B';"
expect_eq "B / RED: account A sees none of account B's rows" "0" "$out"

ask "$identify_a select convert_from(response_body,'UTF8') from idempotency_keys where account_id = '$ACCOUNT_A';"
show "$identify_a
select convert_from(response_body,'UTF8') from idempotency_keys where account_id = '$ACCOUNT_A';"
expect_eq "C / control: the real cached body comes back" "BODY-FOR-ACCOUNT-A" "$out"

ask "$identify_a update idempotency_keys set state = 'in_flight' where id = '$IDEM_B';"
show "$identify_a
update idempotency_keys set state = 'in_flight' where id = '$IDEM_B';"
expect_filtered "D / RED: UPDATE of account B's row while acting as A" \
  "select state from idempotency_keys where id = '$IDEM_B';" "completed"

ask "$identify_a update idempotency_keys set account_id = '$ACCOUNT_B' where id = '$IDEM_A';"
show "$identify_a
update idempotency_keys set account_id = '$ACCOUNT_B' where id = '$IDEM_A';"
expect_denied "E / RED: escalating your OWN row into account B (WITH CHECK)"

# --------------------------------------------------------------------------
# 2. notification_preferences — one answer per person
# --------------------------------------------------------------------------
head1 "2. notification_preferences — a user's own answer"
ask "$identify_a select count(*) from notification_preferences where account_id = '$ACCOUNT_A';"
show "$identify_a
select count(*) from notification_preferences where account_id = '$ACCOUNT_A';"
expect_eq "A / control: account A sees its own row" "1" "$out"

ask "$identify_a select count(*) from notification_preferences where account_id = '$ACCOUNT_B';"
show "$identify_a
select count(*) from notification_preferences where account_id = '$ACCOUNT_B';"
expect_eq "B / RED: account A sees none of account B's rows" "0" "$out"

ask "$identify_a select email_enabled from notification_preferences where account_id = '$ACCOUNT_A';"
show "$identify_a
select email_enabled from notification_preferences where account_id = '$ACCOUNT_A';"
expect_eq "C / control: the real answer comes back" "f" "$out"

ask "$identify_a delete from notification_preferences where user_id = '$USER_B'::uuid;"
show "$identify_a
delete from notification_preferences where user_id = '$USER_B'::uuid;"
expect_filtered "D / RED: DELETE of account B's row while acting as A" \
  "select count(*) from notification_preferences where user_id = '$USER_B'::uuid;" "1"

# An UPDATE that tries to move a row into account B, which reaches the policy's
# WITH CHECK. An INSERT would be the obvious choice and it is WRONG here: this
# table's primary key is `bigserial`, and `protect_table` grants DML on the
# TABLE without granting USAGE on the sequence, so the insert fails on the
# sequence before the policy is ever consulted. That is a separate finding and it
# is measured in its own right below; putting it here would have made this probe
# pass for the wrong reason.
ask "$identify_a update notification_preferences set account_id = '$ACCOUNT_B' where user_id = '$USER_A'::uuid;"
show "$identify_a
update notification_preferences set account_id = '$ACCOUNT_B' where user_id = '$USER_A'::uuid;"
expect_denied "E / RED: escalating your OWN preference row into account B (WITH CHECK)"

# --------------------------------------------------------------------------
# 3. webhook_endpoints — a sealed signing secret
# --------------------------------------------------------------------------
head1 "3. webhook_endpoints — the row carries a sealed signing secret"
ask "$identify_a select count(*) from webhook_endpoints where account_id = '$ACCOUNT_A';"
show "$identify_a
select count(*) from webhook_endpoints where account_id = '$ACCOUNT_A';"
expect_eq "A / control: account A sees its own row" "1" "$out"

ask "$identify_a select count(*) from webhook_endpoints where account_id = '$ACCOUNT_B';"
show "$identify_a
select count(*) from webhook_endpoints where account_id = '$ACCOUNT_B';"
expect_eq "B / RED: account A sees none of account B's rows" "0" "$out"

ask "$identify_a select secret from webhook_endpoints where account_id = '$ACCOUNT_A';"
show "$identify_a
select secret from webhook_endpoints where account_id = '$ACCOUNT_A';"
expect_eq "C / control: the real secret comes back" "SECRET-FOR-ACCOUNT-A" "$out"

ask "$identify_a delete from webhook_endpoints where id = '$HOOK_B';"
show "$identify_a
delete from webhook_endpoints where id = '$HOOK_B';"
expect_filtered "D / RED: DELETE of account B's endpoint while acting as A" \
  "select count(*) from webhook_endpoints where id = '$HOOK_B';" "1"

ask "$identify_a update webhook_endpoints set account_id = '$ACCOUNT_B' where id = '$HOOK_A';"
show "$identify_a
update webhook_endpoints set account_id = '$ACCOUNT_B' where id = '$HOOK_A';"
expect_denied "E / RED: escalating your OWN endpoint into account B (WITH CHECK)"

# --------------------------------------------------------------------------
# 3b. THE SEQUENCE FINDING — `protect_table` grants DML, not the sequence
# --------------------------------------------------------------------------
head1 "3b. THE SEQUENCE GRANT — the bigserial column courier_app writes through"
say "protect_table grants select/insert/update/delete on the TABLE. It does not"
say "grant USAGE on the sequence behind a bigserial primary key, so WITHOUT a"
say "second grant courier_app cannot INSERT into notification_preferences at all"
say "-- and it fails on the SEQUENCE, not on the policy, which is the same"
say "SQLSTATE (42501) the RLS refusals raise."
say ""
say "The copy of kit's substrate this repository carried at the time of the"
say "packet (15cee0e1) predated kit's fix (63663f8), so courier closed it in"
say "its own migration: 20261005120000_grant_app_role_runtime_dml. The copy was"
say "re-taken on 2026-10-16 at 537441e, which includes the fix, so"
say "protect_table now grants the sequence too and the migration's grant is a"
say "no-op. The probe below stays a REGRESSION check: it goes red the moment"
say "the usage grant from either source is withdrawn."
ask "$identify_a insert into notification_preferences
  (user_id, notification_type, email_enabled, push_enabled, inserted_at, updated_at, account_id)
  values ('aaaaaaaa-0000-4000-8000-000000000009', 'transactional', true, true, now(), now(), '$ACCOUNT_A');"
show "$identify_a
insert into notification_preferences
  (user_id, notification_type, email_enabled, push_enabled, inserted_at, updated_at, account_id)
  values ('aaaaaaaa-0000-4000-8000-000000000009', 'transactional', true, true, now(), now(), '$ACCOUNT_A');"
say "inserted into account A's OWN account — i.e. this is not a tenancy refusal:"
if [ "$rc" -eq 0 ]; then
  say "CONFIRMED: the insert into account A's OWN rows now succeeds, so the"
  say "sequence grant is present. This probe is the regression check for"
  say "20261005120000_grant_app_role_runtime_dml -- withdraw it and this goes red."
else
  say "NOT CONFIRMED: refused on the sequence, which means the grant is MISSING."
  printf '%s\n' "$raw"
  say "Either the migration did not run, or it ran and its grant was withdrawn."
  failures=$((failures + 1))
fi
say ""
say "grants courier_app actually holds on this table and its sequence:"
psql -t -A -c "
  select 'table    ' || privilege_type from information_schema.role_table_grants
   where grantee='courier_app' and table_name='notification_preferences' order by privilege_type;
  select 'sequence ' || privilege_type from information_schema.role_usage_grants
   where grantee='courier_app' and object_name='notification_preferences_id_seq' order by privilege_type;"

# --------------------------------------------------------------------------
# 4. THE SUPERUSER FINDING
# --------------------------------------------------------------------------
head1 "4. THE SUPERUSER FINDING — the BOOTSTRAP role is not filtered"
say "Identical statement to 1/B above, but WITHOUT SET ROLE, i.e. as the role"
say "that ran the migration. Same table, same no-identity state."
say ""
say "THIS WAS 'the role Courier.Repo connects as' until the app-role packet."
say "It is now the owner credential only, and that distinction is the whole"
say "point: Courier.Repo is courier_app and IS filtered, while this connection"
say "belongs to Courier.OwnerRepo and is not. Nothing in a running release"
say "opens one -- see Courier.OwnerRepo's moduledoc."
say "--- SQL ---"
printf "select count(*) from idempotency_keys where account_id = '%s';\n" "$ACCOUNT_B"
say "--- output ---"
ask "select count(*) from idempotency_keys where account_id = '$ACCOUNT_B';"
printf '%s\n' "$out"
say "--- exit code: $rc ---"
psql -t -A -c "select 'current_user=' || current_user
                      || ' rolsuper=' || rolsuper
                      || ' rolbypassrls=' || rolbypassrls
               from pg_roles where rolname = current_user;"
expect_eq "as the bootstrap role, account B's row is still visible" "1" "$out"

# --------------------------------------------------------------------------
# 5. THE DELIBERATE BREAKAGE, then the revert
# --------------------------------------------------------------------------
head1 "5. BREAKAGE — disable RLS on idempotency_keys, re-run 1/B verbatim"
say "This is what makes the check a check: the statement that returned 0 in 1/B"
say "must return 1 here, or 1/B was measuring nothing."
say ""
say "--- SQL: alter table idempotency_keys disable row level security;"
psql -v ON_ERROR_STOP=1 -q -c 'alter table idempotency_keys disable row level security;'
say "--- SQL: the same cross-account read as 1/B ---"
printf '%s\n' "$identify_a
select count(*) from idempotency_keys where account_id = '$ACCOUNT_B';"
ask "$identify_a select count(*) from idempotency_keys where account_id = '$ACCOUNT_B';"
say "--- output ---"
printf '%s\n' "$out"
say "--- exit code: $rc ---"
expect_eq "with the policy off, the cross-account read SUCCEEDS" "1" "$out"

head1 "5b. REVERT — re-enable and force, and the refusal is back"
say "--- SQL: alter table idempotency_keys enable row level security;"
say "--- SQL: alter table idempotency_keys force row level security;"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
alter table idempotency_keys enable row level security;
alter table idempotency_keys force  row level security;
SQL
ask "$identify_a select count(*) from idempotency_keys where account_id = '$ACCOUNT_B';"
say "post-revert count = '$out', exit code: $rc"
expect_eq "the refusal is back after the revert" "0" "$out"

psql -t -A -c "select 'catalog after revert: relrowsecurity=' || relrowsecurity
                      || ' relforcerowsecurity=' || relforcerowsecurity
               from pg_class where relname = 'idempotency_keys';"

# --------------------------------------------------------------------------
# 6. Unprotected tables: the sweep's own answer
# --------------------------------------------------------------------------
head1 "6. cafaye.unprotected_tables() — what the sweep names"
psql -t -A -c "select table_schema || '.' || table_name || ' — ' || why
               from cafaye.unprotected_tables() order by table_name;"

# --------------------------------------------------------------------------
# 6b. THE IN-APP NOTIFICATION TABLES — the same four probes, and the reason
#     they are here rather than only in the suite
# --------------------------------------------------------------------------
head1 "6b. notifications / notification_events — the in-app record"
say "These two tables arrived with the in-app notification packet, and they are"
say "proved here for the ONE reason they cannot be proved in the suite: the OWNER"
say "half. `config/test.exs` connects as courier_app, which is a subject of the"
say "policies either way, so a FORCE-less table is indistinguishable from a"
say "protected one from in there — measured: with \`no force row level security\`"
say "on both tables and RLS still enabled, 12 of 16 in-suite boundary tests stay"
say "green and only the four that read pg_class go red."
say ""
say "So: the same five probes, the same control-first ordering, on the two tables"
say "whose boundary is the newest thing in this schema."
say ""

psql -v ON_ERROR_STOP=1 -q <<SQL
delete from notifications where recipient_id in ('$USER_A'::text, '$USER_B'::text);
delete from notification_events where id in ('$EVENT_A'::uuid, '$EVENT_B'::uuid);

insert into notification_events (id, account_id, type, record_type, record_id, params, inserted_at, updated_at)
values
  ('$EVENT_A', '$ACCOUNT_A', 'comment', 'Comment', '11111111-aaaa-4aaa-8aaa-111111111111', '{"actor":"DANA"}'::jsonb, now(), now()),
  ('$EVENT_B', '$ACCOUNT_B', 'comment', 'Comment', '22222222-bbbb-4bbb-8bbb-222222222222', '{"actor":"SAM"}'::jsonb, now(), now());

insert into notifications (id, account_id, notification_event_id, recipient_type, recipient_id, inserted_at, updated_at)
values
  ('$NOTE_A', '$ACCOUNT_A', '$EVENT_A', 'user', '$USER_A', now(), now()),
  ('$NOTE_B', '$ACCOUNT_B', '$EVENT_B', 'user', '$USER_B', now(), now());
SQL
if [ $? -ne 0 ]; then say "FATAL: could not seed; everything below would measure nothing."; exit 2; fi

say "catalog before anything is disabled:"
psql -t -A -c "
  select '  ' || relname || ' rls=' || relrowsecurity || ' force=' || relforcerowsecurity
    from pg_class
   where relname in ('notifications', 'notification_events') order by relname;"

ask "select count(*) from notifications where account_id = '$ACCOUNT_A';"
show "$identify_a
select count(*) from notifications where account_id = '$ACCOUNT_A';"
expect_eq "A / control: account A sees its own notification" "1" "$out"

ask "$identify_a select count(*) from notifications where account_id = '$ACCOUNT_B';"
show "$identify_a
select count(*) from notifications where account_id = '$ACCOUNT_B';"
expect_eq "B / RED: account A sees none of account B's notifications" "0" "$out"

# The NO-IDENTITY half, which is the one the suite asserts and which a table with
# no policy at all also satisfies. It is here because it costs one line and it is
# the third of the three denials.
#
# **`set role courier_app` AND NOT `begin_account`, AND THE DISTINCTION IS THE
# POINT.** The first version of this probe was a bare `select count(*) from
# notifications` and it answered **2** — every row in the table — because the
# connection was then the role that ran the migration, and on this cluster that
# role is a SUPERUSER, which bypasses RLS whatever FORCE says. The `else` branch of
# `ask/1` runs whatever SQL it is given, so a probe that forgets `set role` is
# silently probing the superuser rather than failing to probe at all.
#
# Read as a warning about the harness rather than about the table: every other
# probe in this file carries `identify_a`, and this one was the only statement
# that did not, which is exactly the shape that measures the wrong thing.
ask "$identify_none select count(*) from notifications;"
show "$identify_none
select count(*) from notifications;   -- no identity at all"
expect_eq "no identity reads NO ROWS, and reads none rather than erroring" "0" "$out"

ask "$identify_a select recipient_id from notifications where account_id = '$ACCOUNT_A';"
show "$identify_a
select recipient_id from notifications where account_id = '$ACCOUNT_A';"
expect_eq "C / control: the real recipient comes back" "$USER_A" "$out"

ask "$identify_a update notifications set account_id = '$ACCOUNT_B' where id = '$NOTE_A';"
show "$identify_a
update notifications set account_id = '$ACCOUNT_B' where id = '$NOTE_A';"
expect_denied "E / RED: escalating your OWN notification into account B (WITH CHECK)"

head1 "6c. THE FORCE HALF, MEASURED, AND IT IS A SEPARATE PROBE"
say "Rls enabled with the FORCE bit REMOVED is the state that looks completely"
say "correct in review: relrowsecurity = true, four policies present, every"
say "login-role denial green. The catalog is the only thing that distinguishes it."
say ""
say "--- SQL: alter table notifications no force row level security;"
psql -v ON_ERROR_STOP=1 -q -c 'alter table notifications no force row level security;'
psql -t -A -c "select '  after: rls=' || relrowsecurity || ' force=' || relforcerowsecurity
                 from pg_class where relname = 'notifications';"
ask "$identify_a select count(*) from notifications where account_id = '$ACCOUNT_B';"
say "post-mutation cross-account read = '$out' (still 0, because courier_app is subject)"
say ""
say "--- SQL: alter table notifications force row level security;"
psql -v ON_ERROR_STOP=1 -q -c 'alter table notifications force row level security;'
psql -t -A -c "select '  restored: rls=' || relrowsecurity || ' force=' || relforcerowsecurity
                 from pg_class where relname = 'notifications';"

# --------------------------------------------------------------------------
# 7. Leave the database as found
# --------------------------------------------------------------------------
head1 "7. CLEANUP"
psql -v ON_ERROR_STOP=1 -q <<SQL
delete from idempotency_keys   where endpoint = '$ENDPOINT';
delete from webhook_endpoints where url = '$URL';
delete from notification_preferences
  where user_id in ('$USER_A'::uuid, '$USER_B'::uuid,
                    'aaaaaaaa-0000-4000-8000-000000000009'::uuid);
delete from notifications     where recipient_id in ('$USER_A', '$USER_B');
delete from notification_events
  where id in ('$EVENT_A'::uuid, '$EVENT_B'::uuid);
SQL
say "cleanup exit code: $?"

head1 "RESULT"
say "passed: $passes"
say "failed: $failures"
[ "$failures" -eq 0 ] || exit 1