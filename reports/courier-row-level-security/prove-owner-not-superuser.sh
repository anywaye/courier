#!/usr/bin/env bash
#
# PROVE the thing REPORT-courier-row-level-security.md §4 claims: that this
# migration makes the OWNER read zero rows, and that nothing on the machine used
# to develop it would have said so.
#
#   bash reports/courier-row-level-security/prove-owner-not-superuser.sh
#
# THE CLAIM.
#
# `protect_table` writes each policy `to current_user, <login_role>` and applies
# `FORCE ROW LEVEL SECURITY`. So the role that RAN the migration is a policy
# subject, and FORCE is exactly the setting that removes the owner's exemption
# from its own policies. kit's substrate says so in its own header.
#
# A superuser bypasses RLS whatever FORCE says, so on a development machine
# where `postgres` is superuser this is invisible: the owner reads everything
# and every test passes. kit's cluster does NOT create the owner that way.
# Measured, `kit/templates/compose/postgres/initdb/10-cluster.sh:219`:
#
#     CREATE ROLE :"svc" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
#
# and courier's own stack connects as that role — `docker-compose.yml:253`:
#
#     DATABASE_URL: ecto://courier:…@postgres:5432/courier
#
# So the claim is testable without deploying anything: give a database a
# NOSUPERUSER owner, run the substrate against it as that owner, and read.
#
# EXIT: 0 only if the owner read zero rows (the claim holds) and the superuser
# comparison read them (the reason nobody noticed).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUBSTRATE="$ROOT/priv/repo/substrate.sql"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"

OWNER=rls_probe_owner
DB=courier_rls_owner_probe
A='11111111-1111-4111-8111-111111111111'
B='22222222-2222-4222-8222-222222222222'

passes=0; failures=0
say()   { printf '%s\n' "$*"; }
head1() { printf '\n================ %s ================\n' "$*"; }

cleanup() {
  PGPASSWORD=postgres psql -q -c "drop database if exists $DB;" >/dev/null 2>&1
  PGPASSWORD=postgres psql -q -c "drop role if exists $OWNER;"      >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

# --------------------------------------------------------------------------
head1 "0. A NOSUPERUSER owner, exactly as kit's cluster creates one"
psql -v ON_ERROR_STOP=1 -q <<SQL
create role $OWNER login nosuperuser nobypassrls nocreatedb nocreaterole
  noreplication password 'postgres';
create database $DB owner $OWNER;
SQL
say "--- the role, read from pg_roles ---"
psql -t -A -c "select rolname || ' rolsuper=' || rolsuper || ' rolbypassrls=' || rolbypassrls
               from pg_roles where rolname = '$OWNER';"

# --------------------------------------------------------------------------
head1 "1. The three protected tables, shaped as courier's are, OWNED by that role"
psql -v ON_ERROR_STOP=1 -d "$DB" -q <<SQL
grant all on schema public to $OWNER;
create table idempotency_keys (
  id uuid primary key, account_id uuid not null, endpoint text not null,
  response_body bytea);
create table notification_preferences (
  id bigserial primary key, account_id uuid not null, user_id uuid not null);
create table webhook_endpoints (
  id uuid primary key, account_id uuid not null, secret text not null);
alter table idempotency_keys          owner to $OWNER;
alter table notification_preferences owner to $OWNER;
alter table webhook_endpoints         owner to $OWNER;
SQL

# --------------------------------------------------------------------------
head1 "2. Seed one row per account, as the owner (before RLS exists)"
psql -v ON_ERROR_STOP=1 -d "$DB" -q <<SQL
set role $OWNER;
insert into idempotency_keys values
  ('aaaaaaaa-0000-4000-8000-000000000001','$A','/p','BODY-A'),
  ('bbbbbbbb-0000-4000-8000-000000000001','$B','/p','BODY-B');
insert into notification_preferences (account_id, user_id) values
  ('$A','aaaaaaaa-0000-4000-8000-000000000001'),
  ('$B','bbbbbbbb-0000-4000-8000-000000000001');
insert into webhook_endpoints values
  ('aaaaaaaa-0000-4000-8000-000000000002','$A','SECRET-A'),
  ('bbbbbbbb-0000-4000-8000-000000000002','$B','SECRET-B');
SQL
say "rows visible to the owner BEFORE the migration:"
psql -q -d "$DB" -t -A -c "set role $OWNER; select 'before migration, owner sees ' || count(*) from idempotency_keys;" 2>/dev/null

# --------------------------------------------------------------------------
head1 "3. The substrate and the three protect_table calls, run AS THE OWNER"
say "current_user inside protect_table is \$OWNER, so the policies name it."
psql -v ON_ERROR_STOP=1 -d "$DB" -q <<SQL
set role $OWNER;
\i $SUBSTRATE
select cafaye.protect_table('idempotency_keys', 'courier_app');
select cafaye.protect_table('notification_preferences', 'courier_app');
select cafaye.protect_table('webhook_endpoints', 'courier_app');
SQL
say "substrate + 3 protect_table calls: exit $?"

say ""
say "--- who the policies name ---"
psql -d "$DB" -t -A -c "
  select tablename || '  ->  ' || array_to_string(roles, ',')
  from pg_policies where schemaname='public' and cmd='select' order by tablename;"
psql -d "$DB" -t -A -c "
  select relname || '  relrowsecurity=' || relrowsecurity
                || ' relforcerowsecurity=' || relforcerowsecurity
  from pg_class where relname in ('idempotency_keys','notification_preferences','webhook_endpoints')
  order by relname;"

# --------------------------------------------------------------------------
head1 "4. THE CLAIM: as the owner, with NO identity set, courier reads nothing"
for t in idempotency_keys notification_preferences webhook_endpoints; do
  say ""
  say "--- SQL ---"
  printf 'set role %s;\nselect count(*) from %s;\n' "$OWNER" "$t"
  say "--- output ---"
  got="$(psql -d "$DB" -t -A -c "set role $OWNER; select count(*) from $t;" 2>&1 | tr -d '[:space:]' | sed 's/^SET//')"
  printf '%s\n' "$got"
  if [ "$got" = "0" ]; then
    passes=$((passes + 1)); say "PASS: the owner reads 0 of 2 rows — the boundary is LIVE on the owner path"
  else
    failures=$((failures + 1)); say "FAIL: the owner read '$got' rows, so the claim is WRONG"
  fi
done

# --------------------------------------------------------------------------
head1 "5. WHY NOBODY NOTICED: the same read as a SUPERUSER"
got="$(psql -q -d "$DB" -t -A -c "select count(*) from idempotency_keys;" 2>&1 | tr -d '[:space:]')"
say "--- SQL: select count(*) from idempotency_keys;   (as postgres)"
say "--- output: $got"
if [ "$got" = "2" ]; then
  passes=$((passes + 1))
  say "PASS: the superuser reads all 2 — which is why 219 green tests did not see this"
else
  failures=$((failures + 1)); say "FAIL: superuser read '$got', expected 2"
fi

head1 "6. AND WITH begin_account/1, the owner reads its own account"
say "--- SQL ---"
printf 'set role %s;\nselect cafaye.begin_account(%s);\nselect count(*) from idempotency_keys;\n' "$OWNER" "'$A'"
say "--- output ---"
psql -q -d "$DB" -t -A -c "begin; set role $OWNER; select cafaye.begin_account('$A'::uuid); select count(*) from idempotency_keys; commit;" 2>&1
got="$(psql -q -d "$DB" -t -A -c "begin; set role $OWNER; select cafaye.begin_account('$A'::uuid); select count(*) from idempotency_keys; commit;" 2>&1 | tr -d '[:space:]')"
if [ "$got" = "1" ]; then
  passes=$((passes + 1)); say "PASS: with an identity the owner reads its own row (1, not 2)"
else
  failures=$((failures + 1)); say "FAIL: expected 1, got '$got'"
fi

head1 "RESULT"
say "passed: $passes"
say "failed: $failures"
[ "$failures" -eq 0 ] || exit 1