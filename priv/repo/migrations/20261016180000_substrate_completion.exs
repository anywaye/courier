defmodule Courier.Repo.Migrations.SubstrateCompletion do
  use Ecto.Migration

  @moduledoc """
  Converges a database that installed the substrate before the copy moved to the
  substrate this repository carries now.

  ## WHAT WAS DIVERGENT, MEASURED

  `20261003090000_protect_account_scoped_tables` reads `priv/repo/substrate.sql`
  at migrate time. A database that ran it before 2026-10-16 therefore holds the
  file as it was then — kit `15cee0e1`: **eight** functions, and a
  `cafaye.protect_table` that predates kit `63663f8` ("kit-31"), which added the
  `pg_depend` loop granting the login role USAGE on the protected table's own
  sequences. A database created after the copy moved to kit `537441e` gets
  **twelve** functions and the current `protect_table`.

  `mix test` creates its database fresh, so the suite exercises the
  twelve-function path while an existing deployment keeps the eight: two
  schemas, one repository, and nothing that fails.

  Nothing in this repository calls the four added functions today. `begin_user`,
  `current_user_id`, `membership_tables` and `protect_membership_table` have zero
  references in `lib/`, `priv/` and `test/`, so the divergence is inert — until
  something does, at which point the behaviour depends on when the database was
  created. That is the shape this file removes.

  ## WHY A NEW MIGRATION AND NOT AN EDIT TO 20261003090000

  That migration has run everywhere, and editing an applied migration makes the
  schema depend on which branch ran it. This file is the correction. Every
  statement in `up` is `create or replace`, so applying it to a database from
  either path converges to the same twelve functions, and applying it twice is a
  no-op that succeeds.

  ## WHY `down` IS A DEFINITION AND NOT A RECONSTRUCTION

  `down` returns the database to the substrate this repository carried before the
  copy moved: the previous `protect_table` body and none of the four additions.
  A database from either path round-trips through down and up, which is the
  property that makes it a definition rather than a guess about which path this
  database took. The previous body is embedded below ONLY as that inverse — it is
  not the copy to read or copy from (the copy is `priv/repo/substrate.sql`, and
  kit's checker compares that file). The full teardown of the substrate remains
  `20261003090000`'s own `down`, which drops the `cafaye` schema cascade.

  ## THIS FILE AND THE DIGEST CHECK, NAMED

  It does not read `priv/repo/substrate.sql`, so `20261003090000`'s sha256 guard
  is neither bypassed nor duplicated: fresh databases install the file through
  that migration and this one re-states five of its definitions; databases that
  already ran it get the five from here. Both paths were measured to end with the
  same twelve `pg_proc` entries and identical `pg_get_functiondef` digests.
  """

  # `protect_table` FIRST: it is the one definition whose BODY changed
  # (kit 63663f8 added the pg_depend sequence loop), and
  # `protect_membership_table` calls it. The four additions follow in
  # kit's template order. Order is readability here, not dependency:
  # a plpgsql body is parsed, not resolved, at `create or replace` time.
  def up do
    execute(sql_protect_table())
    execute(sql_current_user_id())
    execute(sql_begin_user())
    execute(sql_protect_membership_table())
    execute(sql_membership_tables())
  end

  def down do
    # Restore the previous `protect_table` body first, then remove the four
    # additions in reverse of their definition. `if exists` because a
    # database from the fresh path installed them through 20261003090000
    # and a rollback here must not fail on a function this migration did not
    # add. No table in this repository carries a `_cafaye_members` policy,
    # so dropping `protect_membership_table` cannot strand one.
    execute(sql_protect_table_previous())
    execute("drop function if exists cafaye.membership_tables()")
    execute("drop function if exists cafaye.protect_membership_table(regclass, text, text)")
    execute("drop function if exists cafaye.begin_user(uuid)")
    execute("drop function if exists cafaye.current_user_id()")
  end

  # kit 537441e, verbatim: the bytes of priv/repo/substrate.sql. A heredoc
  # evaluates to the block plus its closing newline; every byte inside a
  # body is the template bytes.
  defp sql_protect_table do
    """
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
    """
  end

  defp sql_current_user_id do
    """
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
    """
  end

  defp sql_begin_user do
    """
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
    """
  end

  defp sql_protect_membership_table do
    """
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
    """
  end

  defp sql_membership_tables do
    """
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
    """
  end

  # kit 15cee0e1, verbatim (same trailing-newline note), used only by `down`.
  defp sql_protect_table_previous do
    """
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
      execute format('grant usage on schema public to %I', login_role);
      if to_regnamespace('cafaye') is not null then
        execute format('grant usage on schema cafaye to %I', login_role);
      end if;
      execute format('grant select, insert, update, delete on table %s to %I', p_table, login_role);
    end
    $caf$;
    """
  end
end
