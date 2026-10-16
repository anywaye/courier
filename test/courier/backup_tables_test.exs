defmodule Courier.BackupTablesTest do
  @moduledoc """
  What a `pg_dump` of courier's one database actually carries — read from the
  live schema, not from a list somebody wrote down.

  ## Why this is a database test and not a config test

  `config/kamal-backup.yml` declares no `paths:`, and the reason it may not need
  any is a claim about **courier's tables**: there is no `bytea` column, no
  object-store key and no attachment table, because courier has no object
  storage and uploads nothing. A test that asserted that from the YAML would be
  asserting the comment next to it.

  So this asks Postgres. It reads `information_schema.columns` for the connected
  database and asserts two things: that every table a dump would carry is a table
  courier's own migrations created (so nothing rides along unreviewed), and that
  no column anywhere holds bytes or a pointer to bytes held somewhere else
  (so the absence of a `paths:` list is true of the data rather than only of the
  config).

  That second assertion is the load-bearing one, and it is deliberately paired
  with a presence assertion. A "no bytea anywhere" test passes on a database with
  nothing in it, which is the same vacuity `Courier.TelemetryCanaryTest` was
  written against. So it also asserts the tables it *did* find, by name, and the
  row counts are not asserted at all: the claim is about the SHAPE, and a shape
  assertion that counted rows would break every time a test inserted one.

  ## The list is derived from the live schema, not from the migrations

  Reading `information_schema` rather than parsing `priv/repo/migrations` is the
  choice that matters. Migrations are history; the schema is what a dump
  contains. A migration that was later rolled back, or one that creates an index
  rather than a table, changes the first and not the second — and an operator
  restoring cares about the second.

  `oban_jobs` and `oban_peers` are in the list because Oban's DDL is applied by a
  migration that calls `Oban.Migrations.up/1` rather than by a literal
  `create table`, so a migration-reading test would miss them entirely and a
  schema-reading one does not.
  """

  # `async: true`: read-only queries against the Ecto SQL sandbox, no shared
  # process restarted and no application environment changed.
  use Courier.DataCase, async: true

  # courier's own tables, and what each one is FOR. The "for" column is why this
  # is a list of expectations rather than a set membership test: a table whose
  # purpose nobody can name is a table nobody has decided to back up.
  @expected %{
    "consumed_events" =>
      "the INBOUND queue: every event courier has received off the bus, keyed on " <>
        "the envelope's own id. **The dedupe lives here**, so this is the one " <>
        "table whose loss is not a loss of history — it is a loss of the " <>
        "guarantee. Restored, courier resumes handling at-least-once from the " <>
        "broker's redelivery window; NOT restored, and the broker's window has " <>
        "closed, every event consumed since the last snapshot is replayed and " <>
        "every handler runs a second time. The first consumer to send mail makes " <>
        "that the difference between one invitation and two",
    "email_suppressions" =>
      "the suppression list: mailboxes that hard-bounced or complained, which no send may reach",
    "idempotency_keys" =>
      "stored responses, so a replayed POST returns the first answer rather than mailing twice",
    "notification_events" =>
      "one thing that happened, once, for an account. The half of a notification " <>
        "that is not about anybody in particular, and the row every notification " <>
        "points at — so a restore that carried `notifications` without this would " <>
        "bring back inboxes whose messages say nothing",
    "notification_preferences" =>
      "a user's answer about one notification type — the thing a tenant loses first",
    # `seen_at` and `read_at` are in here and the reason is the packet this came
    # from: the reference implementation has no equivalent, because its unread
    # state is a counter nobody stored. An in-app inbox that is restored with its
    # read state lost shows every notification as unread to every person who had
    # already read it.
    "notifications" =>
      "one event addressed to one person, with WHEN THEY READ IT and WHEN THEY " <>
        "SAW IT — the only place courier can answer \"what was I told about, and " <>
        "which of those have I read?\", and the answer a restore has to bring back",
    "oban_jobs" => "the outbox relay's queue: work accepted and not yet done",
    "outbox_events" =>
      "every CloudEvents envelope courier published, and the relay's own claim query",
    "tenant_sending_domains" =>
      "a tenant's own sending domain, its provider account, and its provider " <>
        "credential SEALED under COURIER_SECRET_BOX_KEY. The row is what lets tenant " <>
        "A's mail leave from A's domain on A's credential, and a restore must bring " <>
        "back whether the domain was proven — but the credential comes back as " <>
        "ciphertext, so a restore without the SAME COURIER_SECRET_BOX_KEY brings the " <>
        "rows back and not the ability to send with them",
    "unsubscribe_tokens" =>
      "one row per RFC 8058 one-click link courier minted — a SHA-256 of the token, " <>
        "the user, the notification type and the address it was minted for. Never the " <>
        "token itself, which is why a dump of this table is not a list of mailboxes " <>
        "anybody can unsubscribe",
    "webhook_deliveries" =>
      "the attempt log for each endpoint, including its retry budget's state",
    "webhook_endpoints" => "a tenant's URL and its SEALED signing secret"
  }

  # Tables this repository does not own and does not reason about. `schema_migrations`
  # is Ecto's, `oban_peers` is Oban's advisory-lock table (ephemeral by design:
  # it records which nodes are up, and restoring yesterday's is meaningless).
  @not_ours ~w(schema_migrations oban_peers)

  describe "what the dump carries" do
    test "every table in the database is courier's own, or one named exception" do
      found = tables()

      assert found != [],
             "the connected database reports no tables at all. A schema reader that finds nothing " <>
               "agrees with a schema reader pointed at an empty database, and this test would then be " <>
               "asserting that courier stores nothing — which is the opposite of the claim."

      # `Map.keys/1` and not the map itself: `MapSet.new/1` over a map builds a
      # set of `{key, value}` TUPLES, so `MapSet.member?(ours, "email_suppressions")`
      # is false for every table in the database and the test reports all of them
      # as unexplained. A check that is wrong in the direction of "everything is
      # broken" is at least loud — but only by accident.
      ours = MapSet.new(Map.keys(@expected))
      theirs = MapSet.new(@not_ours)

      unexplained =
        found
        |> Enum.reject(&(MapSet.member?(ours, &1) or MapSet.member?(theirs, &1)))
        |> Enum.sort()

      assert unexplained == [],
             "the database carries #{inspect(unexplained)}, which is neither a table courier's " <>
               "migrations create nor one of #{inspect(@not_ours)}. A table nobody has decided to back " <>
               "up is a table a restore loses."
    end

    test "the tables it carries are the ones this test names, with nothing missing" do
      # The presence half of the test above. Together: this fails when a table is
      # added without being declared here, and the one above fails when one
      # appears in the database without being declared at all.
      found = MapSet.new(tables())
      expected = MapSet.new(Map.keys(@expected))

      missing = MapSet.difference(expected, found)

      assert MapSet.size(missing) == 0,
             "#{inspect(MapSet.to_list(missing))} #{plural(MapSet.size(missing))} named in this test " <>
               "but absent from the database. Either the migration did not run, or a table was renamed " <>
               "and this list is describing a schema that no longer exists."
    end

    test "the webhook signing secret column holds bytes, and it is the only one that does" do
      # The presence assertion the absence below needs. `webhook_endpoints.secret`
      # IS a `:text` column holding ciphertext, so "no bytea column" is not the
      # claim — the claim is that no column holds FILE bytes or a POINTER to file
      # bytes held somewhere the backup does not reach.
      secret_columns =
        for {table, column, _type} <- columns(),
            table == "webhook_endpoints" and column == "secret",
            do: {table, column}

      assert secret_columns != [],
             "webhook_endpoints has no `secret` column, so the shape this test reasons about is not " <>
               "the shape the database has."
    end
  end

  describe "what the dump does not carry, and why `paths:` is absent" do
    test "no column holds file bytes — no bytea anywhere outside the cached response body" do
      bytea =
        for {table, column, type} <- columns(), type == "bytea" do
          {table, column}
        end

      # The one bytea column that is allowed, and why: `idempotency_keys.
      # response_body` is a cached HTTP RESPONSE BODY — courier's own JSON, held
      # so a replayed request returns the first answer. It is inside Postgres, so
      # the dump carries it, and it expires on `expires_at`. It is not an upload,
      # and treating "there is one bytea column" as "there are files" would be
      # exactly the sort of guess this test exists to refuse.
      assert bytea == [{"idempotency_keys", "response_body"}],
             "these columns hold bytes: #{inspect(bytea)}. Anything beyond " <>
               "`idempotency_keys.response_body` — a cached response body inside Postgres, expired on a " <>
               "clock — is state the dump would carry once and the filesystem backup does not. If a " <>
               "column was added for uploaded content, then `config/kamal-backup.yml`'s missing " <>
               "`paths:` is a hole and object storage, not a restic snapshot, is the answer."
    end

    test "no column names a bucket, a storage key or an object id" do
      # The other shape of "state outside the database": not bytes here, but a
      # POINTER here to bytes somewhere else. A restored database whose bucket is
      # empty has every row pointing at nothing, and it fails as a missing object
      # rather than as a missing backup — which is why this is asserted rather
      # than left to a reader of the runbook.
      #
      # The match is on the COLUMN NAME, because that is what a migration names
      # and what this assertion is about. The `idempotency_keys.response_body`
      # column is deliberately not matched: `_body` is not a storage key, and a
      # rule loose enough to catch it would be a rule that could be satisfied by a
      # name rather than by the shape.
      storage_keys =
        for {table, column, _type} <- columns(),
            String.contains?(String.downcase(column), ~w(bucket object storage_key blob file)),
            do: {table, column}

      assert storage_keys == [],
             "#{inspect(storage_keys)} points outside Postgres. That is a column a restored database " <>
               "would carry while the bytes it names live somewhere this backup does not reach — the one " <>
               "gap that loses customer-visible data and that no database dump can close."
    end

    test "nothing in this repository configures an object store or an upload surface" do
      # The third leg, and the cheapest: courier has no bucket configured, so the
      # two assertions above are about a design courier does not have rather than
      # about a setting somebody forgot.
      config_files = Path.wildcard("config/*.exs")
      assert config_files != [], "config/*.exs matched no files, so this test is reading nothing."

      for path <- config_files do
        contents = File.read!(path)

        refute Enum.any?(
                 [~r/BLOB_STORAGE/, ~r/BUCKET/, ~r/OBJECT_STORE/, ~r/S3_BUCKET/],
                 &Regex.match?(&1, contents)
               ),
               "#{path} configures object storage. courier's backup configuration deliberately has " <>
                 "no `paths:` and there is nothing to snapshot on disk — which is true only while " <>
                 "courier stores nothing outside Postgres. Adding a bucket changes that, and this " <>
                 "failing is the signal."
      end

      # And there is no upload route. `openapi.yaml` is courier's contract with a
      # tenant and its paths are asserted against the router by
      # `CourierWeb.OpenAPIDocumentTest`; a multipart or attachment operation would
      # be a table the assertions above would not yet know about.
      refute Regex.match?(~r/contentType:\s*multipart/, File.read!("openapi.yaml")),
             "openapi.yaml declares a multipart operation, so courier accepts a file. Nothing in " <>
               "config/kamal-backup.yml or this repository would hold those bytes."
    end
  end

  defp tables do
    Repo.query!("""
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """).rows
    |> List.flatten()
  end

  # `List.to_tuple/1` on every row, and not the raw `rows`: Postgrex returns each
  # row as a LIST, and `{table, column, type} <- ...` does not match a
  # three-element list — it matches a three-element TUPLE. So a comprehension
  # written over the raw rows silently produces an empty list rather than
  # failing, and every assertion built on it passes for the wrong reason: three
  # tests here reported "no bytea column anywhere" and "webhook_endpoints has no
  # secret column" about a database that has both.
  defp columns do
    Repo.query!("""
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
    ORDER BY table_name, ordinal_position
    """).rows
    |> Enum.map(&List.to_tuple/1)
  end

  defp plural(1), do: "is"
  defp plural(_), do: "are"
end
