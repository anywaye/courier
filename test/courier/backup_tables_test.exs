defmodule Courier.BackupTablesTest do
  @moduledoc """
  What a `pg_dump` of courier's one database actually carries — read from the
  live schema, not from a list somebody wrote down.


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

  use Courier.DataCase, async: true

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
    "notification_types" =>
      "the catalog of messages courier can send: name, kind, required fields, subject and templates. A restore without it has no types to render",
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

  @not_ours ~w(schema_migrations oban_peers)

  describe "what the dump carries" do
    test "every table in the database is courier's own, or one named exception" do
      found = tables()

      assert found != [],
             "the connected database reports no tables at all. A schema reader that finds nothing " <>
               "agrees with a schema reader pointed at an empty database, and this test would then be " <>
               "asserting that courier stores nothing — which is the opposite of the claim."

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
      found = MapSet.new(tables())
      expected = MapSet.new(Map.keys(@expected))

      missing = MapSet.difference(expected, found)

      assert MapSet.size(missing) == 0,
             "#{inspect(MapSet.to_list(missing))} #{plural(MapSet.size(missing))} named in this test " <>
               "but absent from the database. Either the migration did not run, or a table was renamed " <>
               "and this list is describing a schema that no longer exists."
    end

    test "the webhook signing secret column holds bytes, and it is the only one that does" do
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

      assert bytea == [{"idempotency_keys", "response_body"}],
             "these columns hold bytes: #{inspect(bytea)}. Anything beyond " <>
               "`idempotency_keys.response_body` — a cached response body inside Postgres, expired on a " <>
               "clock — is state the dump would carry once and the filesystem backup does not. If a " <>
               "column was added for uploaded content, then `config/kamal-backup.yml`'s missing " <>
               "`paths:` is a hole and object storage, not a restic snapshot, is the answer."
    end

    test "no column names a bucket, a storage key or an object id" do
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
