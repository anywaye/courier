defmodule Courier.Repo.Migrations.GrantAppRoleRuntimeDml do
  use Ecto.Migration

  @moduledoc """
  The grants `courier_app` needs to be courier's application, and nothing more.

  ## WHY THIS FILE EXISTS

  `config/test.exs` and `docker-compose.yml` moved courier's runtime connection
  to **`courier_app`**, kit's app login role: it owns nothing, and it is a subject
  of every row-level-security policy
  `20261003090000_protect_account_scoped_tables.exs` installed. That is the whole
  point — an owner is exempt from its own policies, so a courier running as the
  owner has no account boundary at all.

  Being the application means touching **every table courier writes**, and
  `protect_table/2` grants DML on **the three tables it was asked about**. Six
  more tables in this schema have no grant at all, and the measured result of
  moving the connection without this file is:

      ERROR:  permission denied for table oban_jobs
      ERROR:  permission denied for table outbox_events

  Which is a refusal to start, not a subtle leak — the good shape for a missing
  grant. `mix test` fails on the first outbox write; the dev container never
  becomes healthy. The alternative failure, a role quietly holding more than it
  needs, is the one this file is written to avoid.

  ## WHAT IS GRANTED, TABLE BY TABLE, AND WHY THAT IS THE MINIMUM

  | table | granted | why |
  | --- | --- | --- |
  | `outbox_events` | select, insert, update | `Courier.Outbox.insert/1` inserts; `ProcessOutboxWorker` claims and marks published. **No delete**: nothing in `lib/` calls `Repo.delete` on it, and `DispatchWebhooksWorker` writes `webhooks_dispatched_at` rather than removing a row. |
  | `email_suppressions` | select, insert, update | `Courier.Suppressions` reads by address, inserts a bounce, and `update/2` promotes a soft bounce to a hard one. **No delete**: a suppression is durable by design. |
  | `unsubscribe_tokens` | select, insert, update | `Courier.UnsubscribeToken.issue/2` and `.find/1`. |
  | `webhook_deliveries` | select, insert, update | `Courier.WebhookDeliveries` records an attempt and advances `next_attempt_at`; the retry budget is arithmetic on the row, so an update is not optional. |
  | `oban_jobs`, `oban_peers` | select, insert, update, delete | Oban's engine, not courier's. `deps/oban/lib/oban/engines/basic.ex` calls `Repo.delete_all/2` in **three** places — `prune/1`, `cancel_job/1` and `delete_all_jobs/2` — so delete is Oban's requirement rather than a widening for courier's convenience. |

  **NO `TRUNCATE` ANYWHERE.** It is the one DML privilege with no row filter, so
  on a shared cluster it reaches rows the role cannot otherwise read. Nothing
  courier runs truncates anything.

  ## THE TWO SEQUENCES, AND THE FIRST ONE IS A KNOWN KIT DEFECT

  `grant usage on sequence` and nothing else. `USAGE` is what `nextval` and
  `currval` check, so it is the minimum that lets an INSERT into a `bigserial`
  column work. Not `select` (which would let the role read `last_value` and count
  another table's rows) and not `update` (which would let it `setval` and forge
  ids). **No blanket `grant all on all sequences in schema public`** — that hands
  the same role control of every sequence in the database, including ones behind
  tables it must not touch.

  `notification_preferences_id_seq` was here because of a **defect in the copy
  of kit's substrate this repository carried when this migration was written**:
  `cafaye.protect_table/2` at `15cee0e1` granted table DML and no sequence
  privilege, so a protected table with a `bigserial` column was uninsertable by
  the login role:

      ERROR:  permission denied for sequence notification_preferences_id_seq

  kit fixed exactly this in `63663f8` ("kit-31: protect_table granted DML and left
  the login role unable to insert"), which added the `pg_depend` loop, and the
  copy was re-taken on 2026-10-16 at `537441e`, which includes it — so
  `protect_table('notification_preferences', 'courier_app')` now grants USAGE on
  the table's own sequence, and the notification_preferences grant below is a
  no-op. It is kept rather than removed for two reasons: a re-grant of a held
  privilege changes nothing, and this file is the record of the state it was
  written for. `oban_jobs_id_seq` is **not** redundant — `oban_jobs` has no
  `account_id`, `protect_table` refuses a table it cannot scope, and no substrate
  call ever reaches that sequence, so this migration is the only thing that
  grants it. It surfaces as `42501`, the same SQLSTATE the RLS policies raise, so
  an assertion that checks the code alone cannot tell a working boundary from a
  table nobody can write to.

  ## WHY NOT `GRANT courier_app TO courier` OR ANY OWNERSHIP

  kit's cluster grants `<service>_app` **to** `<service>` and never the reverse,
  so the owner can impersonate the weaker role to prove the boundary from outside
  it. That is the whole of the impersonation arrangement and this migration
  relies on it: the denials are run `SET ROLE courier_app` from the owner, which
  is only possible because the membership runs that way. Nothing here changes a role's attributes — no
  `BYPASSRLS`, no `SUPERUSER`, no ownership, no `CREATE` on the schema.

  ## DOWN IS A REVOKE, NOT A `DROP ROLE`

  `down` withdraws exactly what `up` granted and leaves the role itself alone.
  Dropping `courier_app` would fail anyway while the policies name it, and
  revoking is the honest inverse: the boundary this packet installs is the
  connection, and `down` returns the schema to a state where connecting as
  `courier_app` does not work.
  """

  @login_role "courier_app"

  # Read out of `pg_depend` rather than named: `notification_preferences_id_seq` is
  # THIS repository's convention and not the next service's, and `serial4`,
  # `bigserial`, `identity` and a hand-written `DEFAULT nextval(…)` differ in
  # spelling and in nothing else. `deptype` is deliberately not filtered, for the
  # reason kit's own comment gives: the grant is wanted in every spelling.
  # `for … in <query> loop` and NOT a bare `select …` followed by `loop`, which is
  # a plpgsql syntax error: an unbound SELECT has nowhere to put its rows.
  # Measured, and the message names the wrong thing, which is why it is written
  # down here rather than left to be rediscovered:
  #
  #     ** (Postgrex.Error) ERROR 42601 (syntax_error) syntax error at or near "loop"
  #
  @sequences """
  select format('%I.%I', n.nspname, s.relname)
    from pg_class s
    join pg_namespace n on n.oid = s.relnamespace
    join pg_depend d on d.classid = 'pg_class'::regclass
                     and d.refclassid = 'pg_class'::regclass
                     and d.objid = s.oid
    where s.relkind = 'S'
      and n.nspname = 'public'
      and s.relname in ('notification_preferences_id_seq', 'oban_jobs_id_seq')
  """

  def sequence_loop(command) do
    """
    do $$
    declare
      seq_name text;
    begin
      for seq_name in #{@sequences}
      loop
        execute format('#{command} %s to #{@login_role}', seq_name);
      end loop;
    end
    $$;
    """
  end

  @app_tables [
    # (table, the four DML privileges, whether courier deletes rows in it)
    {"outbox_events", ~w(select insert update), false},
    {"email_suppressions", ~w(select insert update), false},
    {"unsubscribe_tokens", ~w(select insert update), false},
    {"webhook_deliveries", ~w(select insert update), false},
    # Oban's engine, and its delete requirement is Oban's — see the moduledoc.
    {"oban_jobs", ~w(select insert update delete), true},
    {"oban_peers", ~w(select insert update delete), true}
  ]

  def up do
    for {table, privileges, _deletes?} <- @app_tables do
      execute("grant #{Enum.join(privileges, ", ")} on table #{table} to #{@login_role}")
    end

    # `usage`, never `select` and never `update` — see the moduledoc.
    execute(sequence_loop("grant usage on sequence"))

    # The migrator's own bookkeeping table. `Courier.OwnerRepo` runs every
    # migration, so this is not strictly needed for that — and granting it anyway
    # would be a grant nothing reads. Named here so the omission is a decision
    # somebody can see rather than an oversight: **`schema_migrations` is not
    # granted, and nothing at runtime reads it.**
  end

  def down do
    for {table, privileges, _deletes?} <- @app_tables do
      execute("revoke #{Enum.join(privileges, ", ")} on table #{table} from #{@login_role}")
    end

    execute(sequence_loop("revoke usage on sequence"))
  end
end
