defmodule Courier.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  @moduledoc """
  The in-app notification record: **an event**, and that event **addressed to
  exactly one recipient**.

  ## WHY TWO TABLES AND NOT ONE

  A notification is a statement about one person, and the thing that happened is
  a statement about the world. One table would make the second one carry a
  recipient it does not have — a row per (event, recipient) pair where the
  event's own facts are repeated N times and cannot be stated once. Two tables
  say what is true: the event happened, and here it is for these people. The
  reference implementation (`anywaye/notes/reference/jumpstart-inventory.md` §1.1) stores it
  the same way, and this migration is the port of the **shape**, not of the
  rendering.

  ## `account_id` ON BOTH TABLES, IN THIS FIRST MIGRATION

  Both columns are `NOT NULL` and both are here. The reference's `noticed_events`
  and `noticed_notifications` carry **no** `account_id` at all and cannot be
  retrofitted cheaply, because every row-level-security policy in this repository
  is written against that column:

      account_id = (select anywaye.current_account_id())

  A policy written against a column added later is a policy whose predicate is
  `NULL` for every existing row — which `protect_table` resolves as "not true",
  so every pre-existing row becomes invisible to its own account rather than
  visible to another one. Adding the column later is not a small migration; it
  is a backfill, a policy rewrite, and a re-proof. Adding it here costs one
  `null: false`.

  The consequence is recorded rather than assumed: **there is no way to hold one
  of these tables without its boundary**, because the boundary is a column the
  insert cannot omit.

  ## THE RECIPIENT IS `NOT NULL`, AND THAT IS THE WHOLE ARGUMENT

  An event with no recipient is a fan-out that has not happened yet. Storing it
  as a notification would put a row in the recipient's inbox that is addressed to
  nobody, and every question asked of that inbox — "how many unread?" "what is
  new?" — would count it. So `recipient_type` and `recipient_id` are both
  `NOT NULL`, and `Courier.Notifications.record/2` writes the event and the
  notification **in one transaction**, which is what makes "an event with no
  notification" a state the transaction cannot reach rather than one a caller has
  to remember not to create.

  `recipient_type` is courier's **kind** of recipient, spelled as a string, and
  the vocabulary is closed in the changeset rather than by a CHECK constraint —
  `status` on `webhook_endpoints` has a CHECK, so the inconsistency is visible
  rather than inherited. The reason is different: `recipient_id` has no foreign
  key (see below), so nothing else in the schema knows what a recipient *is*, and
  a column that can only hold two values in Elixir and five in the database is
  the column `create_webhook_endpoints` says nobody can reason about.

  ## NO FOREIGN KEY ON `record_type`/`record_id` OR ON THE RECIPIENT

  Both are references to rows courier does not own. There is no `users` table in
  this database and no `accounts` table either, so a `references/2` here would be
  a constraint against **another service's schema** — which is how two services
  come to share one by accident. This is the same reasoning
  `Courier.NotificationPreference` records for `user_id` and
  `create_webhook_endpoints` records for `account_id`.

  The one reference that IS courier's own is `notifications.notification_event_id`,
  and it is a real foreign key with `on_delete: :delete_all`. It is also the only
  one, which is why the ordering is the other way round from the usual advice:
  the child is the referrer, so the thing that could be dropped out from under it
  is its parent.

  ## `READ` IMPLIES `SEEN`, AND IT IS A CONSTRAINT RATHER THAN A CONVENTION

  `seen_at` is "this appeared in a list". `read_at` is "this person opened it".
  They are different facts and both are nullable, because a row nobody has looked
  at has neither.

  But a row that has been **read and not seen** is not a state this service can
  produce honestly. `Courier.Notifications.mark_read/2` writes both, because
  opening something is a stronger statement than seeing it, and a deep link can
  open a notification that was never in a list — which is exactly the case that
  would otherwise leave `read_at` set and `seen_at` `NULL` forever. So the
  database refuses that row:

      check (read_at is null or seen_at is not null)

  and `seen_at` alone is fine, which is the ordinary state of an unread row in a
  list the person scrolled past.

  The constraint is in the migration rather than in the changeset because the
  table is also written by `Repo.insert!/2` in a console and by a future
  migration, and a rule three places have to remember is a rule two of them will
  not.

  ## THE TWO INDEXES, AND WHICH QUERY EACH IS FOR

  * `(account_id, recipient_type, recipient_id, inserted_at DESC)` — the list,
    newest first, which is what `list/4` runs and what an inbox renders.
  * the same four columns, **partial on `read_at is null`** — the unread filter,
    which is the query an unread badge runs on every page load. Partial because
    unread is the small set: a full composite index would put every read row in
    the index the badge reads.

  `protect_table` adds its own `notifications_account_id_idx` and
  `notification_events_account_id_idx`, because a policy is a filter evaluated
  per row. That is a third index on `account_id` alone and it is not redundant:
  the policy is applied to a primary-key lookup too, where neither composite
  above leads.

  ## NO SEQUENCE, AND THEREFORE NO GRANT TO FIX

  Both tables key on a **uuid** rather than Ecto's default `bigserial`, for the
  reason `create_webhook_endpoints` gives: this id appears in a URL a customer
  pastes into a dashboard, and a sequential integer there tells every other
  customer how many notifications exist.

  That choice has a second consequence worth writing down, because the sibling
  migration `20261005120000_grant_app_role_runtime_dml` exists to work around
  the opposite one: kit's `anywaye.protect_table/2` at the `@substrate_sha` this
  repository pins grants DML on the **table** and no `USAGE` on the **sequence**,
  so a protected table with a `bigserial` column is uninsertable by the login
  role (`42501`, `permission denied for sequence …`). `protect_table` grants the
  DML these two tables need and there is no sequence behind either of them, so
  **the workaround does not apply here** — and a reader checking whether it does
  should be able to find that out from this paragraph rather than by inserting a
  row and reading a permission error.
  """

  @login_role "courier_app"

  # `up/0` and `down/0` rather than `change/0`, for the reason
  # `add_account_to_notification_preferences` sets out at length: a `change/0`
  # cannot reverse a bare `execute/1`, and Ecto raises **after** it has already
  # run the statements it could reverse. `Courier.Release.rollback/2` is a real
  # entrypoint, and the version it is called with during an incident is somebody's
  # decision made under time pressure.
  def up do
    create table(:notification_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :uuid, null: false

      # WHAT HAPPENED. A closed vocabulary courier does not yet enforce — the
      # catalog is `Courier.Events.types/0` and the two are not the same list,
      # because an in-app event is not necessarily something courier emits on the
      # bus. It is validated in the changeset and named here so the two can be
      # compared by a reader rather than discovered.
      add :type, :string, null: false

      # THE THING IT HAPPENED TO, polymorphically and optionally. Both columns
      # are nullable because plenty of events are about nothing: "your trial
      # ends tomorrow" has no record behind it. The reference calls this
      # `noticeable_type`/`noticeable_id`; it is spelled `record_*` here because
      # "noticeable" names the notification, not the record.
      add :record_type, :string
      add :record_id, :string

      # The structured facts, as jsonb and not as a rendered string. **This is
      # the decision that makes the rendering somebody else's problem**: the
      # reference ships notification bodies as ERB fragments rendered through
      # `ApplicationController.render`, which is the thing most worth not porting
      # into an API-only service. A consumer reads these keys and renders them.
      add :params, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :uuid, null: false

      # The one foreign key in this migration, and the reason the child holds it
      # rather than the parent: the event is the thing that could be dropped out
      # from under the notification, and `delete_all` says what happens to a
      # notification whose event is retracted.
      # **THE `type:` BELONGS TO `references/2` AND NOT TO `add/3`.** `add/3`
      # takes `:null`, `:default`, `:precision`, `:size` and `:check`; a `type:`
      # among them is not an option it knows, so the column keeps
      # `references/2`'s own default of `:bigserial` and Postgres answers
      #       datatype_mismatch: foreign key constraint … cannot be implemented
      #       Key columns "notification_event_id" and "id" are of incompatible
      #       types: bigint and uuid.
      # which names the constraint, the two columns and both types, and does not
      # mention the option that caused it. Measured on this migration.
      add :notification_event_id,
          references(:notification_events, on_delete: :delete_all, type: :binary_id),
          null: false

      add :recipient_type, :string, null: false
      add :recipient_id, :string, null: false

      add :seen_at, :utc_datetime_usec
      add :read_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # ONE EVENT, ONE ROW PER PERSON. Without this a retry — and the same event
    # addressed twice by two callers who both believed they were first — writes
    # two rows and the unread count is wrong by one. It is not `nulls_distinct`
    # trickery and it is not a partial index: `(event, type, id)` is the
    # notification's identity, and the account is the row's owner rather than
    # part of it, for the same reason `notification_preferences` is keyed by
    # `(user_id, notification_type)` alone.
    create unique_index(:notifications, [:notification_event_id, :recipient_type, :recipient_id],
             name: :notifications_one_per_recipient_index
           )

    # THE LIST, newest first — `Courier.Notifications.list/4` with no options.
    create index(:notifications, [:account_id, :recipient_type, :recipient_id, :inserted_at],
             name: :notifications_inbox_index
           )

    # THE UNREAD FILTER, and it is partial for the reason the same migration's
    # `unsubscribe_tokens` index is: `read_at IS NULL` is the small set, and an
    # unread badge runs this query on every page load. A full composite index
    # would put every read row in the index the badge reads.
    create index(:notifications, [:account_id, :recipient_type, :recipient_id, :inserted_at],
             where: "read_at is null",
             name: :notifications_unread_index
           )

    create constraint(:notifications, :notifications_read_implies_seen_check,
             check: "read_at is null or seen_at is not null"
           )

    # THE SUBSTRATE, NOT HAND-WRITTEN POLICIES. `anywaye.protect_table/2` is kit's,
    # copied verbatim by `20261003090000_protect_account_scoped_tables.exs`, and
    # this is the second file to call it — which is the point of having it. It
    # writes the `FORCE ROW LEVEL SECURITY` bit, the four per-command policies
    # naming both roles, and the DML grant to `courier_app`, so a table that
    # ships without this line ships with no boundary at all.
    #
    # **A NEW MIGRATION RATHER THAN TWO MORE CALLS IN THE PROTECTION MIGRATION**,
    # because that migration has run everywhere and editing an applied migration
    # makes the schema depend on which branch ran it.
    execute("select anywaye.protect_table('notification_events', '#{@login_role}')")
    execute("select anywaye.protect_table('notifications', '#{@login_role}')")
  end

  def down do
    # `disable` BEFORE `drop policy`, for the reason
    # `protect_account_scoped_tables.down/0` gives: a table with policies and RLS
    # already dropped cannot be read by anybody between the two statements.
    for table <- ~w(notifications notification_events) do
      execute("alter table #{table} disable row level security")

      for command <- ~w(select insert update delete) do
        execute("drop policy if exists #{table}_anywaye_#{command} on #{table}")
      end

      execute("drop index if exists #{table}_anywaye_account_id_idx")
    end

    # The child first: `notifications` holds the foreign key.
    drop table(:notifications)
    drop table(:notification_events)
  end
end
