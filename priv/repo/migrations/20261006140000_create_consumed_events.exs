defmodule Courier.Repo.Migrations.CreateConsumedEvents do
  use Ecto.Migration

  @moduledoc """
  courier's first **inbound** queue: the events it consumes off the bus.

  Everything else in this schema is courier's own outbox — the rows courier
  *publishes*. This table is the other direction, and it exists because of one
  sentence in core:

  > `core/docs/event-outbox.md` §"At-least-once, so idempotent": "**Dedupe on
  > `id`.** Store the envelope `id` in a table with a unique constraint and
  > insert it in the same transaction as the handler's own work. […] an
  > in-memory 'have I seen this?' set is wrong the moment there are two
  > replicas."

  The packet asked whether a schema change could be avoided. It cannot, and this
  migration is the reason rather than the preference: an at-least-once bus makes
  duplicate delivery **ordinary operation**, and the only duplicate-proof a
  second replica honours is a row both replicas can see.

  ## THE PRIMARY KEY IS THE DEDUPE

  `id` is the **envelope's own `id`**, not a generated uuid. That is the whole
  mechanism and it is why there is no separate "seen" index to keep in step: the
  unique constraint *is* the check, so a redelivery cannot insert and
  `Courier.Consumers.record/2` answers `{:error, :already_consumed}` rather than
  handing the handler the same envelope twice.

  A generated primary key with a unique index on `envelope_id` beside it would be
  the same guarantee with a second column to keep honest, and the way it goes
  wrong is a migration that adds the index in a later packet and forgets the
  insert. The envelope id is already a uuid, already unique, and already what
  every other service's dedupe will use.

  ## WHAT THE CONSUMER MARKS, AND WHEN — THE COLUMNS ANSWER IT

  `consumed_at` is written **from the handler's answer, never from the ack**.
  The relay's `published_at` is marked when the broker acknowledges because at
  that moment nobody has acted on the message; a consumer's ack arrives *after*
  the handler ran, the provider was dialled, and a person may already have the
  mail. Marking on the ack would record "handled" for a handler that then
  failed, and the next pass would skip an invitation that was never sent.

  So the three columns are three separate facts, and conflating any two of them
  is the bug this layout exists to prevent:

  | column         | the fact                                            |
  | -------------- | --------------------------------------------------- |
  | `attempt_count`| this has been tried N times, successfully or not      |
  | `last_error`   | the most recent failure's reason, or `NULL`           |
  | `consumed_at`  | **the handler succeeded** — and only that             |

  A failed attempt leaves `consumed_at` NULL and the row claimable. A
  *refused* envelope — malformed, or a type courier does not subscribe to — is
  written with `consumed_at` set and a `last_error`, because a payload missing
  `email` will be missing `email` on every redelivery, forever. Retrying a
  poison message is a denial of service on the subject.

  ## `ORDERED BY THE ENVELOPE'S TIME`, AND `time` IS NOT NULL

  `claim/0` orders on `time` because that is the order the facts happened; a
  publisher's backlog delivers out of insert order, and ordering on `inserted_at`
  would deliver a redelivered old event last. That ordering is the contract, so
  `time` is `NOT NULL` here rather than nullable: a row with no time sorts to
  the end of every batch on PostgreSQL's default for NULL, which is an event
  arriving now being handled after every backlogged one — silently. An
  envelope courier cannot parse a time from is refused by
  `Courier.Consumers.record/2` and never reaches this table.

  ## NO `account_id`, AND NO RLS — THE SAME POSTURE AS `outbox_events`

  A consumed event is courier's own bookkeeping about a message **from another
  service**, not a tenant's data. The event carries an `account_id` in its
  payload, and it is deliberately **not** promoted to a column here: courier
  reads the row on a background sweep with no principal and no account context,
  so a policy keyed on `current_account_id()` would filter out every row the
  consumer exists to read.

  This is the same argument `create_outbox_events` makes and for the same
  reason, and `tenancy.yml`'s `rls.tables` records it: `outbox_events`,
  `email_suppressions` and `webhook_deliveries` have no `account_id` by design,
  and this table is the fourth. What is on the row is readable by courier and by
  nobody else, which is the correct boundary for a queue courier owns — not a
  missing one.

  ## A UUID KEY, SO THERE IS NO SEQUENCE TO GRANT

  `id` is the envelope's uuid, so there is no `bigserial` behind this table and
  the `grant_app_role_runtime_dml` workaround (`42501`, `permission denied for
  sequence …`) does not apply. It is written down because a reader checking
  whether that migration should have covered this table deserves an answer in
  this file rather than by attempting an insert and reading a permission error.

  ## NO FOREIGN KEY, BECAUSE THE ENVELOPE'S SUBJECT IS NOT A ROW HERE

  `subject` is the account the event is about, per core's catalog
  (`identity.member.invited | the account`). It is a bare uuid string because
  `account_invitations` is **identity's** table and this database has no
  reference to it — the same reasoning
  `20261006120000_create_notifications` gives for its recipient columns.
  """

  @login_role "courier_app"

  # `up/0`/`down/0` rather than `change/0`, for the reason
  # `20261006120000_create_notifications` sets out: a `change/0` cannot reverse
  # a bare `execute/1`, and Ecto raises **after** it has already run the
  # statements it could reverse. `Courier.Release.rollback/2` is a real
  # entrypoint.
  def up do
    create table(:consumed_events, primary_key: false) do
      # THE ENVELOPE'S ID, and the dedupe. See the moduledoc: the primary key is
      # the unique constraint, so there is no separate index to drift from it.
      add :id, :string, primary_key: true

      # The envelope's own three identifying attributes, kept as written so a row
      # is readable — by an operator staring at a stuck event — without joining
      # anything or decoding `data`. `data` is below and is the payload verbatim,
      # because a consumer that re-rendered the payload to decide what to do
      # could act on a shape the publisher never sent.
      add :type, :string, null: false
      add :source, :string, null: false
      add :subject, :string

      add :data, :map, null: false, default: %{}

      # The order the facts happened, and `NOT NULL` because `claim/0` orders on
      # it. See the moduledoc on why a nullable one would be silent.
      add :time, :utc_datetime_usec, null: false

      # The three facts, kept apart on purpose. See the table in the moduledoc.
      add :consumed_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 0

      # **`text` and not `:string`, and that is a deliberate divergence from
      # `outbox_events.last_error`.** `:string` is `varchar(255)`, and a handler's
      # refusal can be a provider error carrying a whole HTML page — so a 255
      # column turns "the provider was unwell" into a `22001` raised from inside
      # `record_failure/3`, which kills the consumer mid-batch. That is the exact
      # denial of service the packet forbids, reached by the column being too
      # narrow.
      #
      # The relay has the same latent defect: `ProcessOutboxWorker.mark_refused/2`
      # writes `to_string(reason)` into its own `varchar(255)` with no bound. It
      # is not fixed here — this packet does not touch the relay — and it is
      # reported in `REPORT-courier-consumer-invite-01` rather than fixed in a
      # packet about the other direction of the bus.
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    # The claim query's predicate: unhandled, not yet exhausted, oldest first.
    # Partial on `consumed_at is null` because a table of spent rows is the
    # large set and the sweep reads only the live one — the same reason
    # `create_notifications`' unread index is partial.
    create index(:consumed_events, [:time, :inserted_at],
             where: "consumed_at is null",
             name: :consumed_events_unconsumed_index
           )

    # The stuck-event query an operator runs: what is failing, and since when.
    # A `last_error is not null` filter with no partial index reads the whole
    # table, and the whole table is every event courier has ever consumed.
    create index(:consumed_events, [:type, :time],
             where: "last_error is not null",
             name: :consumed_events_failed_index
           )

    # THE GRANT TO `courier_app`, HERE AND NOT IN
    # `20261005120000_grant_app_role_runtime_dml`.
    #
    # That migration is the single list of what the runtime role can do, and the
    # obvious move is to add a row to it. **That would be wrong, and the reason is
    # the same one `create_notifications` gives for not adding two more calls to
    # `protect_account_scoped_tables`: that migration has run everywhere, and
    # editing an applied migration makes the schema depend on which branch ran
    # it.** A deployment that applied it before this commit would keep the old
    # file; one that applies fresh would get the new list. Two schemas, one
    # repository, and no error anywhere.
    #
    # So the grant is a new migration, and the cost is stated rather than hidden:
    # the list is now in two files, and a reader of the 20261005 one will not see
    # this table in it. `test/courier/consumers/grant_test.exs` reads **both** and
    # asserts every table courier's code writes has a grant somewhere, so the
    # split cannot become a missing one.
    #
    # **No `delete`, and no `TRUNCATE` anywhere.** A consumed event is deduped by
    # its primary key, so deleting a row does not "clear" it — it re-opens the
    # event for a second handler run on the next delivery. Retention is a
    # separate, age-based sweep run as the owner (core's retention rule: keep
    # past the slowest consumer's redelivery window), and `TRUNCATE` is the one
    # DML privilege with no row filter at all.
    execute("grant select, insert, update on table consumed_events to #{@login_role}")
  end

  def down do
    drop table(:consumed_events)
  end
end
