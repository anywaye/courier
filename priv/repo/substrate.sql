-- kit template — the ACCOUNT boundary inside one service's database.
--
--     psql "$MIGRATIONS_DATABASE_URL" -f substrate.sql
--
-- WHAT THIS IS. One schema, one GUC, one setter, one function that protects a
-- table, and one sweep that says whether the service is still isolated. Postgres
-- enforces the account boundary; the application does not have to remember to.
--
-- WHY IT EXISTS HERE AND NOT IN EACH SERVICE. Across the nine account-scoped
-- services there is not one `ROW LEVEL SECURITY`, not one `CREATE POLICY` and not
-- one non-owner login role. Tenancy is enforced entirely by hand-written
-- `WHERE account_id = ?` in six languages, which means it is one forgotten
-- predicate per query per service and the whole suite stays green. A boundary
-- that lives in application code is only as strong as the least recently
-- reviewed query. This is the same trade kit already makes with the database
-- itself, where the boundary is `REVOKE` and not good intentions.
--
-- THE TWO ROLES, AND WHY ONE OF THEM IS THE POINT.
--
--   <service>       the owner. LOGIN, owns the database and every table, runs
--                   migrations. This is the role kit's cluster already
--                   provisions and a service already uses, so adopting this
--                   changes nothing about how a service builds its schema.
--   <service>_app   the LOGIN the application uses. It owns nothing, so it
--                   cannot `ALTER TABLE ... DISABLE ROW LEVEL SECURITY`, drop a
--                   policy, or truncate around one. It is granted DML and
--                   nothing else.
--
-- FORCE ROW LEVEL SECURITY is still required, and it is required for the OWNER.
-- Postgres exempts a table's owner from its own policies; `FORCE` is what removes
-- that exemption. Without it a table whose policies are all in place still reads
-- as fully protected while the role that owns it reads every account's rows, and
-- nothing reports that: the policies are there, `relrowsecurity` is true, and
-- the owner walks straight past them. It is the one setting on this page that
-- Supabase's row-level-security guide does not document and that no lint in this
-- fleet checks for, which is why `templates/database/tenancy/isolation.sql`
-- asserts it by RUNNING the denials as the owner rather than by grepping for it.
--
-- THE CONSEQUENCE, STATED HERE BECAUSE IT WILL SURPRISE SOMEONE. Once a table is
-- protected, the OWNER reads zero rows from it too — no policy names the owner,
-- and FORCE removed the exemption that used to let it through. That is the
-- correct posture and it is also the adoption cost: a migration that has to read
-- or backfill rows either sets the identity (`set local role <service>_app` plus
-- `begin_account`) or goes through a `SECURITY DEFINER` function. A migration
-- that silently reads zero rows fails immediately, which is the good direction,
-- but it is a change to how a service writes backfills and it is worth knowing
-- before the first one runs rather than after.
--
-- THE `(select ...)` WRAPPING IS NOT STYLE.
--
--   using (      cafaye.current_account_id() = account_id )      -- per ROW
--   using ( (select cafaye.current_account_id()) = account_id )  -- per STATEMENT
--
-- Postgres evaluates a bare function call in a policy qualifier once per
-- candidate row and hoists an uncorrelated scalar subquery into an InitPlan that
-- runs once per statement. Measured on this kit, five rows, one call:
--
--     using (account_id = (select probe_id()))   ->  1 call
--     using (account_id = probe_id())            ->  5 calls
--
-- and `tests/tenancy_test.sh` re-measures it on every run, because a comment
-- saying so is not a measurement and this is the sort of difference that is
-- invisible until the table is large, which is the worst time to find it.
-- `protect_table` only ever writes the wrapped form. A hand-written policy that
-- writes the bare form is correct and slow, and nothing in a normal run will
-- ever notice.
--
-- WHAT IS NOT HERE. No JWT parsing, no token format, no session store, and no
-- `auth.uid()`. How a service turns the credential in its hand into an account
-- is that service's own business — identity issues opaque session tokens and
-- gateway verifies JWKS bearer JWTs, and a template that picked one of those would
-- be wrong for the other. The seam is `cafaye.begin_account/1`, and a service
-- calls it once per request from whatever it already authenticates.
--
-- Idempotent, deliberately: this is a migration, migrations get re-run by
-- `down`/`up` and by `bin/dev down -v`, and `protect_table` drops and recreates
-- its policies so a re-run converges rather than failing on a duplicate name.

-- Its own schema, and not `public`, so `cafaye` is never part of a sweep over
-- the service's tables and never collides with a name the service chose.
create schema if not exists cafaye;

-- THE ONE SEAM.
--
--   returns NULL when no account has been set  ->  every policy reads zero rows
--   raises      when the value is not a uuid   ->  a plumbing bug, loudly
--
-- The NULL is the load-bearing half and it is deliberate. "No identity" and "an
-- identity that owns none of these rows" are indistinguishable by construction,
-- which is core's `docs/tenancy.md` D33 arriving from the other end: a policy that
-- raised on an absent identity would tell a caller its request was not
-- authenticated, and a caller can be made to believe that about somebody else's
-- request.
--
-- The raise is the other half, and it is not a contradiction. An ABSENT identity
-- is a legitimate state that must read as nothing. A MALFORMED one is a bug in
-- the service's own plumbing, and reading nothing would report it as a service
-- with no data, which is the worst possible way to find out.
create or replace function cafaye.current_account_id()
returns uuid
language plpgsql
stable
as $caf$
declare
  raw text;
begin
  -- `missing_ok = true` is what makes an unset GUC NULL rather than an error.
  -- A dotted custom GUC needs no CREATE to be read: Postgres treats the
  -- placeholder as set-to-empty, which is the second case below.
  raw := current_setting('cafaye.account_id', true);
  if raw is null or raw = '' then
    return null;
  end if;
  return raw::uuid;
exception
  when invalid_text_representation then
    raise exception 'cafaye.account_id is set to % which is not a uuid', raw
      using errcode = '22023',
            hint = 'cafaye.begin_account/1 takes a uuid. A request that reaches the '
                   'database with a malformed account has a bug in whatever '
                   'authenticated it, and this is the cheapest place to find it.';
end
$caf$;

-- SET THE IDENTITY, ONCE PER REQUEST, TRANSACTION-LOCAL.
--
-- `is_local = true` is the whole design. Every one of kit's six drivers holds a
-- POOL, and a session-level account variable on a pooled connection is the worst
-- shape this thing can take: the connection goes back to the pool still carrying
-- tenant A's identity, tenant B is handed it, and tenant B reads tenant A's rows.
-- Transaction-local cannot outlive the request, so a leak needs the caller to
-- forget to open a transaction, which is a different bug with a different
-- symptom.
--
-- A NULL argument CLEARS rather than failing, because "this worker has no
-- account" is a legitimate call and it goes through here rather than through a
-- raw `set_config`, so there is exactly one place in a service's codebase that
-- writes this GUC.
--
-- THE AUTOCOMMIT CONSEQUENCE, STATED RATHER THAN HIDDEN. Outside an explicit
-- transaction, `is_local = true` expires at the end of the statement that set it,
-- so a caller reaching the database in autocommit reads zero rows. That cannot
-- leak and it is loud rather than silent — a service that suddenly sees none of
-- its own data fails its first integration test — and `isolation.sql` runs every
-- case inside an explicit transaction for exactly this reason.
create or replace function cafaye.begin_account(p_account uuid)
returns void
language plpgsql
as $caf$
begin
  if p_account is null then
    perform set_config('cafaye.account_id', '', true);
    return;
  end if;
  perform set_config('cafaye.account_id', p_account::text, true);
end
$caf$;

-- ===========================================================================
-- CREDENTIAL RESOLUTION — the one query whose subject the boundary does not
-- know yet. Read this before changing anything below; MD24 is the decision and
-- its cost, and DECISIONS.md is where the alternatives are recorded as dead.
-- ===========================================================================
--
-- THE PROBLEM, IN ONE SENTENCE. A scoped token, an invitation token and a
-- client id all resolve by "find the row by an unguessable value and learn the
-- account from it", and the account is WHAT THE QUERY IS FOR — so a query with
-- no identity cannot be scoped by an identity it has not computed yet. Measured
-- by `identity` against its real protected `api_keys` table, as the OWNER:
--
--     no identity (the state a token request is in)      0 rows
--     identity = the credential's own account            1 row
--     identity = another tenant's identity               0 rows
--
-- The first line is the finding, and it is the quietest one available: the token
-- does not resolve, `ErrNoRows` becomes "not found", and the HTTP layer answers
-- 401. Every machine credential, refused as though it did not exist.
--
-- WHY NOT THE OTHER THREE ANSWERS. Each is measured or read rather than
-- assumed, and each is written down in `DECISIONS.md` (MD24):
--
--   * A `BYPASSRLS` role — Supabase's answer, and right for Supabase's
--     topology: `service_role` is `nologin noinherit bypassrls` granted only to
--     `authenticator`, and what bounds it is who may assume it plus its object
--     grants. kit has one per-request role and no separate service layer, so a
--     bypass role here is a bypass over the WHOLE DATABASE held by the role
--     every request already authenticates as.
--   * A `SECURITY DEFINER` function — does not work under FORCE. FORCE applies
--     to the definer, and only BYPASSRLS skips RLS; no service role has one.
--   * Dropping FORCE — MD23's measurement: 1 row with, 3 without, on the one
--     table holding every machine credential.
--
-- WHAT IS HERE INSTEAD. One extra `for select` policy, whose qualifier is the
-- value the CALLER PRESENTED, read from a transaction-local GUC:
--
--     using (token_digest = (select cafaye.current_credential_digest()))
--
-- The predicate is in the POLICY and not only in the caller's query, and that is
-- the whole design rather than a detail. RLS policies combine permissively, so a
-- policy that said merely "a credential session may select this table" would hand
-- the caller a table-wide SELECT and let it browse every key in the database
-- with the one query this mechanism exists to prevent. Because the policy
-- carries the same predicate the query carries, the honest semantics are:
--
--     A resolution session may read exactly the credential row whose digest it
--     presented, and nothing else in the database.
--
-- `select * from api_keys` inside one of these sessions returns THAT row, not
-- the table. `isolation.sql` asserts it as `credential/resolution-cannot-browse`
-- and asserts the other half — that the mechanism did not become a general
-- bypass — as `credential/resolution-does-not-open-another-table`.
--
-- WHAT IT CANNOT DO, all five, so nobody has to find them:
--
--   1. It cannot tell a secret from a label. It widens a read to the row whose
--      value you presented, and whether that value is unguessable is the
--      SERVICE's knowledge. `oidc_clients.client_id` is an identifier, not a
--      secret, and this is the wrong mechanism for it. The invariant that keeps
--      the mechanism from becoming a general bypass is exactly that one: you can
--      only widen a read to a row you could already name.
--   2. It cannot write. `for select`, so every write policy still demands an
--      account identity: a resolution session cannot mint a credential.
--   3. It does not open any other table. It is a policy on a named table, and
--      `account_users` still reads zero rows in a resolution session.
--   4. It is transaction-local, like `begin_account/1`, and that is not tidiness
--      — the six drivers hold pools, and a session-level digest survives the
--      pool and hands one resolution's credential to the next connection.
--   5. It is not audited at runtime. The GUC leaves nothing behind; what IS
--      auditable is the SCOPE, and `credential_tables()` below is the one query
--      that answers "which tables in this database can be read with no account".
--      A claim this file cannot honour would be a comment pretending to be a
--      control, so it is not made.
--
-- TWO SEAMS, NOT ONE. `begin_credential/1` is a second transaction-local GUC and
-- the cost of that is real and is why the substrate has no third. It is set in
-- exactly one function, so a service has exactly one place that writes it.

-- The digest the session is resolving. NULL when none is set, and the NULL is
-- load-bearing for the same reason `current_account_id()`'s is: with no digest
-- set, `token_digest = NULL` is never true, so a table carrying only a resolve
-- policy plus an account policy reads nothing at all rather than raising. A
-- credential table is still fully protected without a digest — this policy only
-- ever ADDS the one row whose digest is present.
create or replace function cafaye.current_credential_digest()
returns text
language plpgsql
stable
as $caf$
declare
  raw text;
begin
  -- `missing_ok = true` makes an unset GUC NULL rather than an error; the second
  -- case is Postgres treating an unregistered dotted placeholder as set-to-empty.
  raw := current_setting('cafaye.credential_digest', true);
  if raw is null or raw = '' then
    return null;
  end if;
  return raw;
end
$caf$;

-- OPEN THE RESOLUTION, ONCE, TRANSACTION-LOCAL. The twin of `begin_account/1`,
-- and a NULL argument clears rather than failing, for the same reason.
--
-- THE CALLER PASSES THE VALUE IT ALREADY COMPUTED. A service hashes the token it
-- was handed — that hash is how it was going to query the table anyway — and
-- hands the digest to Postgres as the statement that scopes the read. Postgres
-- does not learn the secret, does not learn how it was derived, and gains no
-- ability to compute one: it is given a string it will compare against a column.
create or replace function cafaye.begin_credential(p_digest text)
returns void
language plpgsql
as $caf$
begin
  if p_digest is null then
    perform set_config('cafaye.credential_digest', '', true);
    return;
  end if;
  perform set_config('cafaye.credential_digest', p_digest, true);
end
$caf$;

-- THE CALLER, AS A TRANSACTION-LOCAL IDENTITY. The third scope, and the reason
-- this file grew one.
--
-- WHAT WAS MISSING, MEASURED. An account boundary answers "which account is this
-- request standing in". It does not answer "which accounts is this PERSON a
-- member of" — and that is not a rare question, it is the first question a
-- product asks. `identity` answered it with `GET /v1/accounts`, and the query was
-- a two-table join on the membership table keyed by the caller's user id. The
-- policy on that table filters on `account_id = current_account_id()`, the caller
-- is not standing in an account yet — that is what makes them a caller rather
-- than a tenant — so the predicate is NULL, and the query that exists to
-- DISCOVER the caller's accounts returned none of them. The row was in the
-- database the whole time; `identity` answered `[]` and its product rendered
-- "you are not a member of any account" to a user who owned one.
--
-- WHY A THIRD SCOPE AND NOT A LOOSER POLICY. Every alternative was a way of
-- saying something false:
--
--   * drop the FORCE, or exempt the login role — that is not an account
--     boundary any more, it is a convention.
--   * let a caller read their own memberships without an account identity —
--     the policy still cannot tell WHICH caller is asking, so this reads every
--     membership in the fleet.
--   * a SECURITY DEFINER function that bypasses RLS — the mechanism kit's
--     MD24 already rejected for credentials, for the same reason.
--
-- So the substrate needed to be able to NAME THE CALLER, and naming a caller is
-- exactly what a GUC is for. This is `begin_account`'s twin: same
-- transaction-local lifetime, same NULL-clears, same "the service passes the
-- value it already computed" property.
--
-- WHAT IT IS NOT. It is not a session, not an authorisation and not an
-- identity claim: it says who the database is currently answering, and nothing
-- else. A service that set it from a request body would be handing the
-- database a caller's identity chosen by the caller — which is why the value is
-- the same `users.id` the service resolved the session to, and why this file's
-- twin for accounts warns at the same length.
create or replace function cafaye.current_user_id()
returns uuid
language plpgsql
stable
as $caf$
declare
  raw text;
begin
  -- `missing_ok = true` and the empty check are the two cases `begin_account`'s
  -- reader handles, copied rather than re-derived: an unset dotted GUC reads as
  -- set-to-empty, and a caller with no identity is a legitimate state.
  raw := current_setting('cafaye.user_id', true);
  if raw is null or raw = '' then
    return null;
  end if;
  return raw::uuid;
exception
  when invalid_text_representation then
    raise exception 'cafaye.user_id is set to % which is not a uuid', raw
      using errcode = '22023',
            hint = 'cafaye.begin_user/1 takes a uuid. A request that reaches the '
                   'database with a malformed user has a bug in whatever '
                   'authenticated it, and this is the cheapest place to find it.';
end
$caf$;

-- OPEN THE CALLER SCOPE, ONCE, TRANSACTION-LOCAL. Every word of
-- `begin_credential`'s contract applies here and is not restated: `is_local`
-- because every driver holds a pool, NULL clears rather than fails, and outside
-- an explicit transaction the setting expires at the end of the statement that
-- set it — so a caller that forgets the transaction reads zero rows rather than
-- somebody else's.
create or replace function cafaye.begin_user(p_user uuid)
returns void
language plpgsql
as $caf$
begin
  if p_user is null then
    perform set_config('cafaye.user_id', '', true);
    return;
  end if;
  perform set_config('cafaye.user_id', p_user::text, true);
end
$caf$;

-- PROTECT ONE CREDENTIAL TABLE. The one call a credential table's migration
-- makes, and it is ONE call: it protects the table exactly as `protect_table`
-- does — same four policies, same ENABLE, same FORCE, same index on
-- `account_id` — and then adds the fifth. There is no `protect_credential_table`
-- that only adds the resolve policy to a table somebody forgot to protect,
-- because a substrate with two entry points for one table is a substrate where
-- the one nobody reads is the one that ships.
--
--   select cafaye.protect_credential_table('api_keys', 'token_digest');
--
-- The digest column is named in the migration and nowhere else, and naming it
-- IS the declaration: it is the column whose value a caller must already hold to
-- resolve a credential on this table, and the README says what makes a value
-- suitable (it has to be unguessable, or this mechanism is the wrong one).
create or replace function cafaye.protect_credential_table(
  p_table regclass,
  p_digest_column text,
  p_login_role text default null
)
returns void
language plpgsql
as $caf$
declare
  login_role text := coalesce(p_login_role, current_user || '_app');
  base text;
  qual text;
begin
  -- 0. THE COLUMN NAME IS A BARE IDENTIFIER. `%I` quotes it, so this is not
  --    about injection; it is about a typo becoming a policy nobody notices,
  --    which is the failure a database-boundary file exists to make loud.
  if p_digest_column is null
     or p_digest_column !~ '^[A-Za-z_][A-Za-z0-9_$]*$' then
    raise exception 'cafaye.protect_credential_table(%, %): the digest column must be one bare column name, and % is not one.', p_table, coalesce(p_digest_column, '<null>'), coalesce(p_digest_column, 'null')
      using errcode = 'undefined_column',
            hint = 'The second argument is the column a caller presents to resolve a credential on this table — `token_digest` for a hashed API key, `token` for a hashed invitation. It is a column of this table and nothing else.';
  end if;

  -- 1. AND IT EXISTS, before `protect_table` runs, so a misspelt column does not
  --    half-install a table.
  if not exists (
    select 1 from pg_attribute
    where attrelid = p_table and attname = p_digest_column and not attisdropped
  ) then
    raise exception 'cafaye.protect_credential_table(%, %): the table has no % column.', p_table, login_role, p_digest_column
      using errcode = 'undefined_column',
            hint = 'A credential table resolves by the column a caller presents. Name the one this table has; if it has none, this table is not resolved by an unguessable value and does not want this mechanism.';
  end if;

  -- 2. THE SAME PROTECTION AS EVERY OTHER ACCOUNT-SCOPED TABLE. This calls the
  --    other function rather than repeating it, so a fix to one is a fix to both
  --    and there is no second copy of ENABLE/FORCE to drift.
  perform cafaye.protect_table(p_table, p_login_role);

  base := (select c.relname from pg_class c where c.oid = p_table::regclass::oid);

  -- 3. THE INDEX ON THE DIGEST COLUMN, for the reason `protect_table` creates one
  --    on `account_id`: a policy is a filter on every candidate row, and this one
  --    filters on the column the resolution query is keyed by.
  execute format('create index if not exists %I on %s (%I)',
                 base || '_cafaye_' || p_digest_column || '_idx', p_table, p_digest_column);

  -- 4. ONE POLICY, FOR ONE COMMAND, FOR THE TWO NAMED ROLES, WITH THE PREDICATE
  --    THE CALLER'S OWN QUERY CARRIES.
  --
  --    `for select` and nothing else is what makes item 2 of "what it cannot do"
  --    true: there is no `insert`/`update`/`delete` counterpart, so a resolution
  --    session meets the ordinary account policies on the write side and a NULL
  --    identity there is `42501`.
  --
  --    The `(select ...)` wrapping is the same InitPlan discipline as every other
  --    policy in this file, for the same measured reason: `tests/tenancy_test.sh`
  --    measures 1 call wrapped against 5 bare on five rows, on every run.
  qual := format('%I = (select cafaye.current_credential_digest())', p_digest_column);

  --    DROP before CREATE, so a re-run converges and a corrected qualifier cannot
  --    survive one.
  execute format('drop policy if exists %I on %s', base || '_cafaye_resolve', p_table);
  execute format('create policy %I on %s for select to %I, %I using (%s)',
                 base || '_cafaye_resolve', p_table, current_user, login_role, qual);

  -- 5. USAGE on `cafaye`, for the same reason `protect_table` grants it: without
  --    it the login role cannot resolve `cafaye.begin_credential/1` and every
  --    resolution fails with `permission denied for schema cafaye`.
  if to_regnamespace('cafaye') is not null then
    execute format('grant usage on schema cafaye to %I', login_role);
  end if;
end
$caf$;

-- PROTECT ONE MEMBERSHIP TABLE. The third member of this family, and it is the
-- first one whose job is to let a read THROUGH the account boundary rather than
-- to resolve something inside it.
--
-- A membership table is an ordinary account-scoped table with one extra fact to
-- carry: it is also the map FROM a person TO accounts. Those are different reads
-- and the ordinary policy can only do one of them. `protect_table`'s predicate
-- answers "which rows of this table belong to the account I am standing in" —
-- true, useless, and exactly wrong for the query that asks a signed-in person
-- which accounts they are in, because that query happens BEFORE any account is
-- being stood in. Without this function that query returns an empty list and
-- nothing anywhere says the rows are being withheld: the policy is present, the
-- columns are right, the join is correct, and the answer is `[]`.
--
-- So this function calls `protect_table` first — the write side, the `for select`
-- account read, ENABLE, FORCE, the `account_id` index and the role check all
-- come from there, not from a copy — and then adds ONE policy:
--
--   select cafaye.protect_membership_table('account_users', 'user_id');
--
-- `for select` only, for the same reason the credential policy is: a caller with
-- no account identity still meets the ordinary account policies on insert,
-- update and delete, so this grants DISCOVERY and not AUTHORSHIP. Being able to
-- see that you are a member of an account is not the ability to change it,
-- invite to it, or read a row in it.
--
-- The predicate is `<user_column> = (select cafaye.current_user_id())`, wrapped
-- in a scalar subquery for the InitPlan reason every other policy in this file
-- is, and it is NULL rather than true when the caller has no user identity — so
-- a worker that forgot `begin_user` reads zero memberships instead of all of
-- them. That is the whole safety property, and it is the same property the
-- account boundary has: absent an identity, nothing.
create or replace function cafaye.protect_membership_table(
  p_table regclass,
  p_user_column text,
  p_login_role text default null
)
returns void
language plpgsql
as $caf$
declare
  login_role text := coalesce(p_login_role, current_user || '_app');
  base text;
  qual text;
begin
  -- 0. THE COLUMN NAME IS A BARE IDENTIFIER, for the reason
  --    `protect_credential_table`'s check 0 gives: `%I` makes this not about
  --    injection, it is about a typo becoming a policy that quietly admits
  --    nothing instead of a migration that stops.
  if p_user_column is null
     or p_user_column !~ '^[A-Za-z_][A-Za-z0-9_$]*$' then
    raise exception 'cafaye.protect_membership_table(%, %): the user column must be one bare column name, and % is not one.', p_table, coalesce(p_user_column, '<null>'), coalesce(p_user_column, 'null')
      using errcode = 'undefined_column',
            hint = 'The second argument is the column on this table holding the member''s `users.id` — `user_id` in every service kit has shipped. It is a column of this table and nothing else.';
  end if;

  -- 1. AND IT EXISTS, before `protect_table` runs, so a misspelt column cannot
  --    half-install a table. The message quotes the COLUMN rather than the
  --    table, which `protect_credential_table`'s check 1 gets right for a
  --    credential and would get wrong here: `protect_credential_table(%, %)`
  --    interpolates the login role into the second `%` and the table into the
  --    third, which reads as though the role were the missing column. That is a
  --    pre-existing bug in the credential function's message, not something this
  --    one copies.
  if not exists (
    select 1 from pg_attribute
    where attrelid = p_table and attname = p_user_column and not attisdropped
  ) then
    raise exception 'cafaye.protect_membership_table(%, %): the table has no % column.', p_table, p_user_column, p_user_column
      using errcode = 'undefined_column',
            hint = 'A membership table is read by the column that names the member. Name the one this table has; if it has none, this table is not a membership table and does not want this mechanism.';
  end if;

  -- 2. THE SAME PROTECTION AS EVERY OTHER ACCOUNT-SCOPED TABLE, from the same
  --    function, so there is no second copy of ENABLE/FORCE to drift. This call
  --    also raises if the table has no `account_id`, which a membership table
  --    must have: it is the edge of the account graph, not a user-scoped
  --    resource that happens to mention accounts.
  perform cafaye.protect_table(p_table, p_login_role);

  base := (select c.relname from pg_class c where c.oid = p_table::regclass::oid);

  -- 3. THE INDEX ON THE USER COLUMN, for the reason `protect_table` indexes
  --    `account_id`: the policy is evaluated against every candidate row, and
  --    the query this exists for is a scan of the whole table looking for this
  --    caller's memberships. Without the index that scan is sequential however
  --    few rows it returns.
  execute format('create index if not exists %I on %s (%I)',
                 base || '_cafaye_' || p_user_column || '_idx', p_table, p_user_column);

  -- 4. ONE POLICY, FOR ONE COMMAND, FOR THE TWO NAMED ROLES, PREDICATED ON THE
  --    CALLER rather than on an account.
  qual := format('%I = (select cafaye.current_user_id())', p_user_column);

  --    DROP before CREATE, so a re-run converges and a corrected qualifier cannot
  --    survive one.
  execute format('drop policy if exists %I on %s', base || '_cafaye_members', p_table);
  execute format('create policy %I on %s for select to %I, %I using (%s)',
                 base || '_cafaye_members', p_table, current_user, login_role, qual);

  -- 5. USAGE on `cafaye`, for the reason the other two functions grant it:
  --    without it the login role cannot call `cafaye.begin_user/1` and every
  --    membership read fails with `permission denied for schema cafaye` — which
  --    reads as a permissions bug rather than as the missing GRANT that it is.
  if to_regnamespace('cafaye') is not null then
    execute format('grant usage on schema cafaye to %I', login_role);
  end if;
end
$caf$;

-- WHICH TABLES CAN BE READ WITHOUT AN ACCOUNT. The audit for item 5 above: one
-- query, and not a code search.
--
-- It reads the POLICIES rather than a list, for the reason the sweep reads
-- `pg_class`: a table this function could only know about because
-- `protect_credential_table` created it would be satisfied by a mechanism that
-- records nothing. The policy name and the digest reference are both required,
-- so a hand-written policy that merely mentions the digest does not appear here
-- and a policy named like this one with a different qualifier does not either.
--
-- It answers the SCOPE question and only that one. It cannot answer "who
-- resolved what", and this file does not pretend otherwise: the digest is
-- transaction-local and gone by the time anything could look at it.
--
-- NOTHING HERE READS A DEPARSED EXPRESSION, AND THE REASON IS THE READER.
-- `pg_get_expr` is a pretty-printer, and it drops the schema from a name the
-- READER can resolve — which is that reader's `search_path`, and `"$user"` is a
-- search_path entry. So the policy this file writes deparses as
--
--     (token_digest = ( SELECT cafaye.current_credential_digest() AS …))
--
-- for a role with no schema of its own, and as
--
--     (token_digest = ( SELECT current_credential_digest() AS …))
--
-- for the role named after this platform, whose `"$user"` schema IS `cafaye`.
-- An audit written against that text therefore returned NOTHING in that session
-- and the whole answer in every other one — same database, same policy — and
-- "no table here can be resolved without an account" is exactly what an operator
-- auditing credentials as the cluster's own admin role would then be told.
-- `tests/tenancy_test.sh` measures both roles on every run and requires the
-- answers to be equal.
--
-- The paragraph this one replaces warned that "an audit query that returns an
-- empty column forever looks exactly like an audit query that found nothing". The
-- trap was never the regexp's strictness; it was reading a spelling at all. So
-- the two facts this query needs are read from DEPENDENCIES, which are OIDs:
--
--   * `cafaye.current_credential_digest()` is called by the policy's own `using`
--     expression, and `CREATE POLICY` records that in `pg_depend` with
--     `classid = pg_policy` and `refclassid = pg_proc`. Matching it through
--     `pg_proc` JOIN `pg_namespace` ON `proname` is by OID rather than by
--     spelling, so the answer is the same for every role and every `search_path`.
--   * the COLUMN it is compared against is a reference to a column of the
--     policy's OWN table, recorded as a `pg_depend` row onto that table with the
--     column's `attnum` in `refobjsubid`. Measured on 16.15 and 17: one `pg_proc`
--     row with `deptype = 'n'`, one `pg_class` row with `refobjsubid > 0`, and
--     one `pg_class` row with `refobjsubid = 0` and `deptype = 'a'` — the last
--     is the whole relation, which is why the column join requires
--     `refobjsubid > 0` rather than joining the table.
--
-- WHAT THAT COSTS, all of it, so none of it is a surprise:
--
--   1. Two catalogs more (`pg_proc`, `pg_depend`) and one dependency join. This
--      is a query a human runs once; it is sub-millisecond per row over a whole
--      database and nothing calls it per request.
--   2. It depends on `CREATE POLICY` recording dependencies — which is what
--      stops a policy outliving the function it calls, so the fact is the
--      catalog's rather than a convention of this file. Measured on 16.15 and
--      17.x; NOT measured on 15, kit's floor, because no 15 image was available
--      on this machine and an unmeasured version is not a verified one.
--   3. `pronargs = 0` is part of the match. The substrate's digest function takes
--      no arguments, and an overload of the same name is not that function.
--   4. A qualifier naming MORE THAN ONE column of its own table cannot be
--      narrowed to one, because nothing structural says which of them the digest
--      is compared to. That row is still reported, with `'(unresolved)'` in the
--      column: a table named with an unresolved column is an audit finding, and a
--      table absent from the audit is the silence this function exists to
--      prevent. The deparsing version reported the same policy with a NULL
--      column, which is neither an answer nor a complaint.
create or replace function cafaye.credential_tables()
returns table (table_schema text, table_name text, digest_column text)
language sql
stable
as $caf$
  -- (1) The digest function, by OID. `pronargs = 0` is part of the identity and
  --     not decoration — see cost 3 above.
  with digest_fn as (
    select fn.oid
      from pg_proc fn
      join pg_namespace fns on fns.oid = fn.pronamespace
     where fns.nspname = 'cafaye'
       and fn.proname = 'current_credential_digest'
       and fn.pronargs = 0
  ),

  -- (2) The policies in the substrate's own naming that call it, with the columns
  --     of THEIR OWN table that the call sits beside. `cd.refobjid = pol.polrelid`
  --     is what keeps a qualifier that reads another table's column out: the
  --     audit is about what THIS table resolves by.
  resolve as (
    select pol.oid as policy_oid,
           pol.polrelid,
           att.attname as column_name
      from pg_policy pol
      join pg_depend fd
        on fd.classid = 'pg_policy'::regclass
       and fd.objid = pol.oid
       and fd.refclassid = 'pg_proc'::regclass
       and fd.deptype = 'n'
      join digest_fn df on df.oid = fd.refobjid
      left join pg_depend cd
        on cd.classid = 'pg_policy'::regclass
       and cd.objid = pol.oid
       and cd.refclassid = 'pg_class'::regclass
       and cd.refobjid = pol.polrelid
       and cd.refobjsubid > 0
      left join pg_attribute att
        on att.attrelid = pol.polrelid
       and att.attnum = cd.refobjsubid
       and not att.attisdropped
     where pol.polname like '%!_cafaye!_resolve' escape '!'
       and pol.polcmd = 'r'
  )

  -- (3) One row per policy. The column is reported only when the qualifier names
  --     exactly one of the table's own columns, and `'(unresolved)'` otherwise —
  --     cost 4 above. `min()` is never the answer; it is what a single-column
  --     qualifier reduces to.
  select n.nspname::text,
         c.relname::text,
         case when g.columns_named = 1 then g.column_name
              else '(unresolved)' end
    from (select policy_oid,
                 polrelid,
                 count(distinct column_name) as columns_named,
                 min(column_name)            as column_name
            from resolve
           group by policy_oid, polrelid) g
    join pg_class c on c.oid = g.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   order by n.nspname, c.relname
$caf$;

-- WHICH TABLES CAN BE READ WITHOUT AN ACCOUNT BECAUSE OF WHO IS ASKING. The
-- second kind of exemption, and the audit for it is here for the reason the first
-- one is: an exemption nobody can list is an exemption nobody notices has been
-- widened.
--
-- `credential_tables` exists because "no table here can be resolved without an
-- account" is a sentence an operator has to be able to check. Before
-- `protect_membership_table` there was exactly one way for a policy to stop
-- requiring an account, so one query covered the question. Now there are two, and
-- the honest form of that sentence is two queries — or one sweep that reports a
-- table readable under either rule, which is what an operator actually wants to
-- read on a fleet they did not write.
--
-- IT IS NOT `credential_tables` RENAMED. The two are different claims and
-- conflating them would be the same error this file keeps refusing: a membership
-- table resolved by a caller is not a table that can be resolved by anybody who
-- guesses a digest, and a credential table is not a table whose rows a signed-in
-- person may enumerate. So this reads the `_cafaye_members` policy and calls
-- `current_user_id`, and reports the USER column, which is the column whose value
-- the caller must already hold.
--
-- Everything else is `credential_tables`' query with two names changed, and that
-- is deliberate rather than lazy: the `pg_depend` reading is the part that took
-- the work. Deparse-and-regexp would have been five lines, and `credential_tables`
-- carries 40 lines of measured explanation of why it does not work — an audit
-- that spells a function name returns NOTHING as the cluster's own admin role and
-- the whole answer in every other session, so the same query and the same
-- substring rules are what make the two functions agree with each other.
create or replace function cafaye.membership_tables()
returns table (table_schema text, table_name text, user_column text)
language sql
stable
as $caf$
  -- (1) The caller function, by OID, with `pronargs = 0` as part of its identity.
  with user_fn as (
    select fn.oid
      from pg_proc fn
      join pg_namespace fns on fns.oid = fn.pronamespace
     where fns.nspname = 'cafaye'
       and fn.proname = 'current_user_id'
       and fn.pronargs = 0
  ),

  -- (2) The policies in the substrate's own naming that call it, with the columns
  --     of THEIR OWN table the call sits beside. Same two dependency joins, same
  --     `deptype`, same `refobjsubid > 0` narrowing of the column match.
  discover as (
    select pol.oid as policy_oid,
           pol.polrelid,
           att.attname as column_name
      from pg_policy pol
      join pg_depend fd
        on fd.classid = 'pg_policy'::regclass
       and fd.objid = pol.oid
       and fd.refclassid = 'pg_proc'::regclass
       and fd.deptype = 'n'
      join user_fn uf on uf.oid = fd.refobjid
      left join pg_depend ud
        on ud.classid = 'pg_policy'::regclass
       and ud.objid = pol.oid
       and ud.refclassid = 'pg_class'::regclass
       and ud.refobjid = pol.polrelid
       and ud.refobjsubid > 0
      left join pg_attribute att
        on att.attrelid = pol.polrelid
       and att.attnum = ud.refobjsubid
       and not att.attisdropped
     where pol.polname like '%!_cafaye!_members' escape '!'
       and pol.polcmd = 'r'
  )

  -- (3) One row per policy, with `'(unresolved)'` when the qualifier names more
  --     than one of the table's own columns — reported, not dropped, for the
  --     reason cost 4 of `credential_tables` above gives.
  select n.nspname::text,
         c.relname::text,
         case when g.columns_named = 1 then g.column_name
              else '(unresolved)' end
    from (select policy_oid,
                 polrelid,
                 count(distinct column_name) as columns_named,
                 min(column_name)            as column_name
            from discover
           group by policy_oid, polrelid) g
    join pg_class c on c.oid = g.polrelid
    join pg_namespace n on n.oid = c.relnamespace
   order by n.nspname, c.relname
$caf$;

-- PROTECT ONE ACCOUNT-SCOPED TABLE. The only thing a migration calls.
--
--   select cafaye.protect_table('assets');                 -- the owner's role
--   select cafaye.protect_table('assets', 'darkroom_app'); -- explicit login role
--
-- Everything it does is required and everything it does is idempotent. There is
-- no `protect_table_lite`, and there is no way to ask it for a policy without
-- FORCE, because a template that offers the weaker version is a template the
-- weaker version gets chosen from.
create or replace function cafaye.protect_table(
  p_table regclass,
  p_login_role text default null
)
returns void
language plpgsql
as $caf$
declare
  login_role text := coalesce(p_login_role, current_user || '_app');
  qual text := 'account_id = (select cafaye.current_account_id())';
  base text;
  seq_name text;
begin
  -- 0. THE LOGIN ROLE HAS TO EXIST, and saying so by name is the difference
  --    between a diagnosable failure and a confusing one. Postgres reports a
  --    missing role in `create policy` as `role "courier_app" does not exist`,
  --    six lines into a function, with the table named by the context and the
  --    fix not. This is the check that turns that into one sentence.
  if not exists (select 1 from pg_roles where rolname = login_role and rolcanlogin) then
    raise exception 'cafaye.protect_table(%, %): % is not a LOGIN role on this cluster.', p_table, login_role, login_role
      using errcode = 'undefined_object',
            hint = 'kit''s cluster provisions <service> and <service>_app. Either the _app role has not been provisioned — this service was added to KIT_POSTGRES_DATABASES before it existed, and the init script only runs on a fresh volume — or pass the login role explicitly as the second argument.';
  end if;

  -- 1. THE COLUMN, OR STOP. A table with no `account_id` cannot be scoped by
  --    account, and protecting it anyway would create policies whose predicate
  --    cannot be evaluated — which Postgres resolves as "not true", i.e. a table
  --    nobody can read, which is a much harder failure to diagnose than this one.
  if not exists (
    select 1 from pg_attribute
    where attrelid = p_table and attname = 'account_id' and not attisdropped
  ) then
    raise exception 'cafaye.protect_table(%, %): the table has no account_id column, so there is nothing to scope it by.', p_table, login_role
      using errcode = 'undefined_column',
            hint = 'Either the column is spelled something else — write the policy yourself and name the fleet''s key — or this table is not account-scoped and should not be protected. A service holding no customer rows is core''s honest zero and needs none of this.';
  end if;

  base := (select c.relname from pg_class c where c.oid = p_table::regclass::oid);

  -- 2. THE INDEX, IN THE SAME FUNCTION, BECAUSE A POLICY IS A FILTER ON EVERY
  --    ROW AND AN UNINDEXED ONE IS A SEQUENTIAL SCAN. Postgres evaluates the
  --    policy against each candidate row, so an account-scoped table read
  --    through its primary key still has to filter on `account_id`, and without
  --    this index that is a full scan behind a primary-key lookup. Named
  --    deterministically so a re-run converges rather than making a second one.
  execute format('create index if not exists %I on %s (account_id)', base || '_cafaye_account_id_idx', p_table);

  -- 3. REVOKE FROM PUBLIC BEFORE ENABLING. A table's default privileges come
  --    from its owner and from whatever has been granted on it; PUBLIC is not
  --    among them unless somebody granted it. Revoking is one statement, and it
  --    means the answer to "who can read this" is not "whoever the last
  --    migration remembered".
  execute format('revoke all on table %s from public', p_table);

  -- 4. ENABLE, THEN FORCE. Two statements, and the second is the one that is in
  --    nobody's blog post.
  --
  --    Without FORCE a table's OWNER is exempt from its policies. Every service
  --    in this fleet runs its migrations as its own role, so without FORCE the
  --    role that owns the table reads every account's rows while the policies
  --    read as though they were in place. `pg_class.relforcerowsecurity` is the
  --    only catalog that says otherwise, and `isolation.sql` asserts it by
  --    running the denials AS THE OWNER — which is the only assertion that
  --    cannot be satisfied by a policy that exists.
  execute format('alter table %s enable row level security', p_table);
  execute format('alter table %s force row level security', p_table);

  -- 5. FOUR POLICIES, ONE PER COMMAND, ALL NAMED, FOR TWO NAMED ROLES.
  --
  --    Naming the roles with `to <owner>, <login>` rather than leaving it to PUBLIC
  --    is not tidiness: an unnamed policy is evaluated for every role including the
  --    ones that should never reach the table, and the role filter is what stops
  --    the evaluation early. It is also the first thing Supabase's guide tells you
  --    to do and the first thing everybody skips.
  --
  --    The OWNER is in the list, and that is not a convenience. FORCE removes the
  --    owner's exemption, so without an owner policy the owner reads NOTHING from
  --    a protected table — no rows, including its own — and a service that runs
  --    background work and migrations as that role discovers it by seeing empty
  --    result sets. Naming it means the owner's reads are ACCOUNT-SCOPED rather
  --    than absent: a migration sets an identity and reads exactly one account's
  --    rows, which is the same rule every other request obeys and the only version
  --    of "the owner may read" that is not "the owner may read everything".
  --
  --    One policy per command rather than one `for all` is what keeps a later
  --    grant additive — a policy added for one command cannot widen another. The
  --    `for all` shape with `using (true)` and `with check (...)` is the one that
  --    silently permits an INSERT nobody meant to permit, and it is the shape
  --    every "permissive RLS policy" lint is written to flag.
  --
  --    `insert` has no `using` — an INSERT has no existing row to filter — and
  --    its `with check` is what stops a row being created in somebody else's
  --    account, which is the write-side twin of the read denial.
  --
  --    DROP before CREATE so the function is re-runnable, and so a policy whose
  --    definition has been corrected here cannot survive a re-run.
  execute format('drop policy if exists %I on %s', base || '_cafaye_select', p_table);
  execute format('drop policy if exists %I on %s', base || '_cafaye_insert', p_table);
  execute format('drop policy if exists %I on %s', base || '_cafaye_update', p_table);
  execute format('drop policy if exists %I on %s', base || '_cafaye_delete', p_table);

  execute format('create policy %I on %s for select to %I, %I using (%s)', base || '_cafaye_select', p_table, current_user, login_role, qual);
  execute format('create policy %I on %s for insert to %I, %I with check (%s)', base || '_cafaye_insert', p_table, current_user, login_role, qual);
  execute format('create policy %I on %s for update to %I, %I using (%s) with check (%s)', base || '_cafaye_update', p_table, current_user, login_role, qual, qual);
  execute format('create policy %I on %s for delete to %I, %I using (%s)', base || '_cafaye_delete', p_table, current_user, login_role, qual);

  -- 6. AND THE LOGIN ROLE GETS DML AND NOTHING ELSE. No ownership, no DDL, no
  --    CREATE on the schema, no ability to change a policy. A grant that gives a
  --    login role more than it needs is a grant that has to be re-examined every
  --    time somebody adds a privilege, and this is the one place that list lives.
  --
  --    USAGE on `cafaye` is in the list and is not optional: without it the login
  --    role cannot resolve `cafaye.begin_account/1` at all, so the first thing a
  --    service does after adopting this is a `permission denied for schema
  --    cafaye` on every request.
  --
  --    USAGE ON A SEQUENCE is in the list for the same reason and it is the one
  --    that is INVISIBLE until a service writes a row. A table's INSERT reads its
  --    sequence before it writes the row, and a sequence is a separate object with
  --    its own grants — the table grant above does not carry it. Without this line
  --    a protected table with a `bigserial` column is UNINSERTABLE by the login
  --    role:
  --
  --        ERROR:  permission denied for sequence notification_preferences_id_seq
  --
  --    which is SQLSTATE 42501 — the code the policies themselves raise. An
  --    assertion that checks the code alone cannot tell a working boundary from a
  --    table nobody can write to. `templates/database/tenancy/isolation.sql`'s
  --    `cafaye_observed` returns `sqlstate` and nothing else, so it is exposed to
  --    exactly that; what has kept it out of reach is that its probe table is
  --    `id uuid … default gen_random_uuid()`, which is why 39 assertions have been
  --    green through this defect. `reports/substrate-sequence-grant/` is where the
  --    message is required, and it is where the two are told apart.
  execute format('grant usage on schema public to %I', login_role);
  if to_regnamespace('cafaye') is not null then
    execute format('grant usage on schema cafaye to %I', login_role);
  end if;
  execute format('grant select, insert, update, delete on table %s to %I', p_table, login_role);

  -- 7. AND USAGE ON EVERY SEQUENCE THIS TABLE'S OWN COLUMNS OWNED, AND NO OTHER.
  --
  --    `USAGE` is the whole grant and it is the whole need: it is what `nextval`
  --    and `currval` check, so it is the minimum that makes an INSERT into a
  --    serial column work. It is deliberately NOT `select` (which would let the
  --    login role read `last_value` and reason about how many rows other tables
  --    hold) and NOT `update` (which would let it `setval` and forge ids). A
  --    blanket `grant all on all sequences in schema public` also makes the
  --    insert work, and hands the same role control of every sequence in the
  --    database — including the ones behind tables it must not touch. The
  --    narrowing is the point of the loop.
  --
  --    FOUND IN THE CATALOG, NOT BY NAME. `<column>_id_seq` is this migration's
  --    convention and is not the next service's; a table with two serial columns
  --    has two sequences and neither is the table's; `serial4`, `bigserial`,
  --    `identity` and a hand-written `DEFAULT nextval(…)` differ in spelling and
  --    in nothing else. `pg_depend` is the edge Postgres itself records for all of
  --    them — `deptype` `a` for `serial` and `i` for `identity` — so reading it
  --    covers every spelling rather than the one this migration happened to use.
  --    The loop deliberately does NOT filter on `deptype`.
  --
  --    MEASURED, because it was the premise this line was written under and the
  --    measurement says otherwise: on PostgreSQL 17.11 and 18.6 a protected table
  --    whose id is `generated always as identity` IS insertable by a role holding
  --    no privilege on the sequence at all, while that same role's explicit
  --    `nextval()` on the sequence is refused — the identity value is fetched on a
  --    path with no ACL check. So the `bigserial` case was the lockout and this one
  --    was not, and the grant is here anyway for two reasons that do not depend on
  --    that: it is `USAGE` on the table's OWN sequence and nothing wider, and a
  --    substrate whose correctness rests on an undocumented executor detail is one
  --    minor version from the same lockout. Do not read this loop as a claim that
  --    `identity` was broken; read it as a claim that this file does not have to
  --    be re-derived per spelling.
  --
  --    `FOR … IN SELECT` rather than `SELECT … INTO`, so an empty result set is a
  --    loop that does not run rather than a `no rows` exception. Most tables in
  --    any service have no serial column at all, and `protect_table` already
  --    refuses a table it cannot scope by name — a sequence loop that RAISED on
  --    the tables that need no loop would be a quieter bug than the one it fixes.
  --
  --    Schema-qualified, because a bare relation name in a `GRANT` is resolved
  --    through the CALLER's `search_path` — and the caller of a migration is a
  --    role whose `search_path` this function does not control.
  for seq_name in
    select format('%I.%I', n.nspname, s.relname)
      from pg_class s
      join pg_namespace n on n.oid = s.relnamespace
      join pg_depend d on d.classid = 'pg_class'::regclass
                       and d.refclassid = 'pg_class'::regclass
                       and d.objid = s.oid
                       and d.refobjid = p_table::regclass
      join pg_attribute a on a.attrelid = d.refobjid
                         and a.attnum = d.refobjsubid
     where s.relkind = 'S'
  loop
    execute format('grant usage on sequence %s to %I', seq_name, login_role);
  end loop;
end
$caf$;

-- SWEEP: every account-scoped table in the schemas THIS SUBSTRATE OWNS,
-- protected or not.
--
-- Returns one row per table that is NOT, so a caller can report all of them
-- rather than the first. It returns rather than raising because a caller that
-- gets rows can print them, and a caller that gets an exception has to parse the
-- message. This is the query that answers "is this service isolated?".
--
-- THE COLUMN IS THE DEFINITION OF ACCOUNT-SCOPED, and it is a definition rather
-- than a list because a list is a thing to remember. A table that grows an
-- `account_id` column and no policies appears here on the next run, which is the
-- moment before it matters.
--
-- THE SCOPE IS THE SCHEMAS THE SUBSTRATE WAS APPLIED IN, and that is the whole
-- difference between this function and a scan of every table in the database.
-- The property being asserted is "every account-scoped table THE SERVICE
-- INSTALLED is protected", and its input is the set of tables the substrate was
-- applied to — a whole-database scan is one way to compute that set, and it is
-- the way that breaks every adopter.
--
-- MEASURED, on identity: its test helper builds a private fixture schema per
-- test by cloning tables with `LIKE … INCLUDING ALL`, and `LIKE` does not copy
-- row-level security. Each fixture therefore carries an `account_id` column and
-- no policies. A whole-database sweep named every one of them, so a correct
-- database produced a red proof — and the count moved with how many neighbouring
-- tests were mid-flight (5 on one run, 21 on the next), which is what says it
-- was a reach rather than a defect. A sweep that cannot stay green on a correct
-- database is a sweep nobody reads, and one that goes red for somebody else's
-- fixtures is a sweep an adopter has to work around, which is worse.
--
-- THE SCOPE IS DERIVED, NOT RECORDED, and the difference is the reason an
-- adopter needs no migration to get the fix. There is no registry table, because
-- a registry would have to be created by the NEW substrate and every database
-- that has applied the OLD one does not have it — so the fix would only arrive
-- with a migration, and the proofs it is meant to repair are the thing that
-- decides whether the migration is needed. Instead the scope is read back out of
-- what the substrate ALREADY wrote: `protect_table` names its policies
-- `<table>_cafaye_<command>` and creates an index beside them, so every schema
-- the substrate was applied in is discoverable from the catalog, with nothing
-- new to install and nothing to remember to update.
--
-- Extension-owned tables are excluded (`pg_depend.deptype = 'e'`): pgvector,
-- PostGIS and friends ship their own tables with their own grants, and reporting
-- a table this substrate cannot protect would train the reader to ignore the
-- sweep.
--
-- TEMPORARY TABLES ARE NOT EXCLUDED, and that is deliberate. A temp table with an
-- `account_id` column and no policies is genuinely unprotected, it is exactly
-- the shape a service's test fixture has, and `isolation.sql` plants one on
-- purpose as its sweep's control. It is safe to INCLUDE this file's own session's
-- temporary schema for the reason a fixture schema is not: temporary objects are
-- per-session, so no other session — not another test, not another service — can
-- put a table in scope by creating one. `pg_temp` is the alias; the real schema
-- is named `pg_temp_N`, which is why this is a prefix test and not an equality.
create or replace function cafaye.unprotected_tables()
returns table (table_schema text, table_name text, why text)
language sql
stable
as $caf$
  with scoped(nspname) as (
    -- (1) The substrate's own schema. It holds functions rather than rows, so
    --     this contributes nothing today; it is here so that a table added to
    --     `cafaye` later cannot be quietly unowned by the exclusion this query
    --     used to carry.
    select 'cafaye'::name
    -- (2) This session's temporary schema, where `isolation.sql` plants its
    --     control table. Per-session, so it can never carry another session's.
    union
    select n.nspname
      from pg_namespace n
     where n.nspname = 'pg_temp' or left(n.nspname, 8) = 'pg_temp_'
    -- (3) Every schema the substrate was applied IN, read back from the policies
    --     `protect_table` wrote. A schema qualifies when it holds at least one
    --     table this substrate protected, which is what makes the scope the
    --     service's own tables rather than a list somebody maintains: a new
    --     account-scoped table added NEXT MONTH to a schema already in scope is
    --     named on the next run, with nothing having been updated anywhere.
    union
    select n.nspname
      from pg_namespace n
      join pg_class c on c.relnamespace = n.oid
      join pg_policy p on p.polrelid = c.oid
     where c.relkind = 'r'
       and p.polname ~ '_cafaye_(select|insert|update|delete)$'
  )
  select n.nspname::text,
         c.relname::text,
         case
           when not c.relrowsecurity then 'row level security is not enabled'
           when not c.relforcerowsecurity then 'row level security is not FORCED, so the table owner bypasses it'
           when not exists (select 1 from pg_policy p where p.polrelid = c.oid) then 'row level security is enabled with no policy, so every row is hidden'
           else ''
         end
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_depend d on d.objid = c.oid and d.deptype = 'e'
  where c.relkind = 'r'
    and d.objid is null
    and n.nspname in (select s.nspname from scoped s)
    and exists (
      select 1 from pg_attribute a
      where a.attrelid = c.oid and a.attname = 'account_id' and not a.attisdropped
    )
    and (
      not c.relrowsecurity
      or not c.relforcerowsecurity
      or not exists (select 1 from pg_policy p where p.polrelid = c.oid)
    )
  order by n.nspname, c.relname
$caf$;

-- ---------------------------------------------------------------------------
-- A login role that OWNS an account-scoped table can switch that table's
-- policies off, and no amount of FORCE stops it: FORCE is about the owner being
-- SUBJECT to policies, not about the owner being unable to REMOVE them. So the
-- second half of the design is a role that owns nothing, and that claim has
-- nothing to sweep — it is a fact about one role and one table, so it is asserted
-- about the role the application actually logs in as rather than generalised into
-- a query that would have to guess which role that is. `isolation.sql` asserts
-- it three ways, and the two that matter are the ones no catalog reports: the
-- login role is refused `ALTER TABLE ... DISABLE ROW LEVEL SECURITY`, and it is
-- refused `DROP POLICY`.
--
-- WHAT THIS FILE DOES NOT PROVE, because every item below is a way the boundary
-- can be right in the database and absent from the service.
--
--   * That the service SETS the identity. `begin_account/1` is one call in one
--     place, and nothing here can tell a service that never calls it from one
--     that calls it in every request. A service that forgets reads zero rows,
--     which is safe and extremely visible, so this is a diagnosis rather than a
--     leak.
--
--     `begin_user/1` has the same property with one difference in the WRONG
--     DIRECTION, and it is worth stating because the difference is invisible from
--     the service's side. Forgetting `begin_account` makes reads EMPTY. Forgetting
--     `begin_user` makes one specific query empty — "which accounts am I in" —
--     while every other query on the same connection keeps working, because the
--     account scope is unaffected by the caller scope. A service can therefore
--     run for a long time with a caller scope nobody sets, and the only symptom
--     is a list that is always empty in exactly one screen. That is the same
--     shape as a permission that was never granted, and it looks the same in a
--     log: nothing failed.
--
--   * That the service's QUERIES still carry their own `where account_id = ?`.
--     They should. RLS is defence in depth, not a licence to delete the
--     predicate: the predicate is what makes the query indexable, and it is what
--     a mistake in the policy expression gets caught by. core's
--     `schemas/tenant-isolation.schema.json` still requires the predicate and this
--     file does not change that.
--
--   * That the login role is not a MEMBER of the owner role. The cluster grants
--     `<service>_app` TO `<service>` so a migration and `tests/isolation_test.sh`
--     can impersonate the weaker role; the reverse membership would undo the
--     entire design and is worth asserting in the services that adopt this.
--
--   * That a TABLE is account-scoped. The sweep defines that as "has an
--     `account_id` column", which is the fleet's own vocabulary (D7), and it
--     misses a service that spells it `tenant_id` and protects it by hand. A
--     service with no account-scoped tables at all is the honest zero, and
--     core's `tenancy.honest-zero` finding is what says so out loud.
--
--   * That a SCHEMA the substrate was never applied to holds no account-scoped
--     table. The sweep's scope is the schemas it protected, plus its own and
--     `pg_temp`, so customer rows kept in a schema no `protect_table` call ever
--     named are outside it. That is the trade, and it is a deliberate one: the
--     alternative reports every other session's test fixture, which is how a
--     correct database ends up with a red proof and how an adopter ends up
--     carrying a workaround for a bug that was upstream. A service whose account
--     tables span schemas the substrate has not met is a service that has not
--     protected them, and `protect_table` is one call per table.
-- ---------------------------------------------------------------------------