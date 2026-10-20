defmodule Courier.NotificationsBoundaryTest do
  @moduledoc """
  The two tables' **account boundary**, and the reason this file is separate from
  `Courier.NotificationsTest`.

  ## WHAT THIS FILE PROVES, AND WHAT IT CANNOT

  `Courier.NotificationsTest` proves the record's shape: one event, one row per
  recipient, `seen`/`read` as different facts, idempotent marks. **Every one of
  its cross-account assertions would be green with `protect_table` never
  called.** Its queries carry `account_id` in Elixir, so an absent policy changes
  nothing they can observe — that is a query test, not a boundary test.

  This file makes the refusals **the database's**, with a query that has no
  predicate to drop:

      select count(*) from notifications

  under each account's identity, with no `where` clause anywhere in it.

  ## WHY THIS CAN BE ASSERTED IN-SUITE AT ALL

  `config/test.exs` connects as **`courier_app`**: `NOSUPERUSER`, `NOBYPASSRLS`,
  and a named subject of all four policies on both tables. A superuser bypasses
  RLS whatever `FORCE ROW LEVEL SECURITY` says, which is how 1276 green tests
  once could not tell an enforced boundary from an inert one
  (`REPORT-courier-row-level-security` §3). The first test in the last
  describe block asserts that precondition, so it fails loudly if the
  connection ever becomes one that bypasses the policies again.

  ## THREE DENIALS AND ONE ALLOWANCE, AND NEITHER HALF ALONE

  * **no identity** → zero rows, and **zero rows rather than an error**
  * **another account's VALID identity** → zero rows of their rows
  * **its own identity** → its own rows

  The first is satisfied by a table with **no policy at all** — which is the bug
  — and the third is satisfied by a policy that permits everything. Only the
  three together are the property, so all three are here and the third is the
  control the two need.

  ## THE HALF NO LOGIN-ROLE DENIAL CAN DETECT

  Postgres exempts a table's **OWNER** from its own policies unless `ALTER TABLE
  … FORCE ROW LEVEL SECURITY` is set, and courier's migrations run as that owner.
  A suite that only proves `courier_app` is filtered is green against a database
  where the role a migration connects as reads every account's rows.

  `assert forced?("notifications")` is the witness for that, read out of
  `pg_class` rather than proved by a denial — because **a denial cannot be made
  from this connection**: it is `courier_app`, which is not the owner, and
  `Courier.OwnerRepo` is a superuser here, which bypasses RLS unconditionally.
  The owner's denials are made for real elsewhere, by `SET ROLE` out of
  superuser.

  ## THE CONTROL, AND IT IS A REAL TABLE RATHER THAN A FIXTURE

  `cafaye.unprotected_tables()` returning nothing is satisfied by a sweep that
  reports nothing, so this file's sweep assertion is worth nothing on its own.
  The control is **`outbox_events`**: a real courier table with an `account_id`
  column and no policies, deliberately — `Courier.Deliver` records
  `email.delivered` for a *user* and does not know which account they are in, so
  the migration says so in full. The sweep must name it, every run, and that is
  what makes the empty answer over the two notification tables a measurement.

  **A PLANTED FIXTURE WOULD HAVE BEEN WORSE, AND THE REASON IS WORTH WRITING
  DOWN.** `create temporary table` inside the sandbox transaction survives the
  rollback: a temporary table lives for the **session**, not the transaction, and
  a pooled connection would carry it into every later test in this VM.
  `kit/templates/database/tenancy/isolation.sql` relies on the same property from
  the other direction — its control lives in `pg_temp` precisely because the
  sweep's scope includes this session's temporary schema — so a control table is
  only safe there because that script is the whole connection.
  """

  use Courier.DataCase, async: true

  alias Courier.NotificationEvent
  alias Courier.Notifications

  @account_a "aaaaaaaa-0000-4000-8000-0000000000a1"
  @account_b "bbbbbbbb-0000-4000-8000-0000000000b1"
  @user_a "aaaaaaaa-0000-4000-8000-0000000000c1"
  @user_b "bbbbbbbb-0000-4000-8000-0000000000c1"

  @recipient_a {"user", @user_a}
  @recipient_b {"user", @user_b}

  # The two tables this packet added. `notifications` is the one with a
  # recipient; `notification_events` is the one a notification points at, and it
  # carries `account_id` too — which is the column a policy is written against
  # and the reason it is not a retrofit.
  @tables ~w(notifications notification_events)

  setup do
    # Seed one row per account, each written UNDER ITS OWN IDENTITY. An insert
    # with no identity is refused `42501` by the policy's `with check`, which is
    # itself the write-side denial — see `Courier.DataCase`.
    as_account(@account_a, fn ->
      {:ok, _} = Notifications.record(@account_a, type: "comment", recipient: @recipient_a)
    end)

    as_account(@account_b, fn ->
      {:ok, _} = Notifications.record(@account_b, type: "comment", recipient: @recipient_b)
    end)

    :ok
  end

  describe "the catalog says the tables are protected" do
    test "row level security is ENABLED on both" do
      for table <- @tables do
        assert enabled?(table), "#{table} does not have row level security enabled"
      end
    end

    test "AND IS FORCED, which is the half a login-role denial cannot see" do
      for table <- @tables do
        assert forced?(table),
               "#{table} has policies but is not FORCEd, so its OWNER reads every " <>
                 "account's rows. That is the state a policy-that-exists looks " <>
                 "like in review, and no lint in the fleet checks it."
      end
    end

    test "four policies per table, one per command" do
      # Named and per-command rather than `for all`. `for all … using (true)` is
      # the shape every "permissive RLS policy" lint is written to flag, and one
      # policy covering every command is a policy a later grant can widen.
      for table <- @tables do
        assert MapSet.new(policy_commands(table)) ==
                 MapSet.new([
                   {"#{table}_cafaye_select", "r"},
                   {"#{table}_cafaye_insert", "a"},
                   {"#{table}_cafaye_update", "w"},
                   {"#{table}_cafaye_delete", "d"}
                 ]),
               "#{table} does not carry exactly the four per-command policies: " <>
                 inspect(policy_commands(table))
      end
    end

    test "and each policy NAMES both roles, rather than leaving it to PUBLIC" do
      # An unnamed policy is evaluated for every role, including the ones that
      # should never reach the table; naming them is what stops the evaluation
      # early. The owner is in the list on purpose — FORCE removed its exemption,
      # so without an owner policy the owner reads NOTHING, not everything.
      #
      # **THE OWNER IS READ OUT OF `pg_class`, NOT OUT OF `current_user`.** The
      # test connection is `courier_app`, and `protect_table` names the role that
      # *ran the migration* — a third role. Asserting against `current_user` is
      # the mistake this comment is for; it reported
      # `["courier_app", "kaka"] does not name both the owner and courier_app`,
      # where the policy was right and the expectation was wrong. A catalog read
      # is not a convenience here: it is the only way to name the right role.
      for table <- @tables do
        owner = owner_of(table)

        for {name, _command} <- policy_commands(table) do
          assert roles(name) == Enum.sort([owner, "courier_app"]),
                 "#{name} does not name both the owner and courier_app: #{inspect(roles(name))}"
        end
      end
    end

    test "the sweep does not name either table" do
      # **NOT `== []`.** The sweep legitimately names `outbox_events`: courier
      # owns it, it carries an `account_id`, and it is deliberately unprotected.
      # So the assertion is about the two tables this packet added and nothing
      # else — and the test below is what makes an empty answer over them mean
      # something.
      # **BOTH SIDES ARE SORTED, and the reason is that `@tables` is written
      # notification-first while the sweep sorts by name.** The first version
      # compared `["notification_events", "notifications"]` with
      # `["notifications", "notification_events"]` and reported:
      #
      #     cafaye.unprotected_tables() named one of the two tables this packet
      #     added:
      #       ["notifications", "notification_events"]
      #
      # which is a **false report of a leak**, produced by a set operation on two
      # lists written in different orders. A message that says "a boundary is
      # missing" and is wrong is worse than no message: it is the kind a reader
      # stops believing.
      assert Enum.sort(@tables -- named_by_sweep()) == Enum.sort(@tables),
             """
             cafaye.unprotected_tables() named one of the two tables this packet
             added:

               #{inspect(@tables -- named_by_sweep())}

             Either a table courier holds account rows in without a boundary, or
             `protect_table` was not called for it. Either way the assertion
             belongs here rather than in a report.
             """
    end

    test "THE CONTROL: the sweep DOES name `outbox_events`, so the empty answer above means something" do
      # See the moduledoc: a real table, deliberately unprotected, whose presence
      # in the sweep's output is courier's documented position
      # (`20261003090000_protect_account_scoped_tables.exs` §"THE FOURTH
      # ACCOUNT-SCOPED TABLE") rather than a fixture this file would have to plant
      # and clean up.
      assert "outbox_events" in named_by_sweep(),
             """
             cafaye.unprotected_tables() named nothing at all, so the assertion
             that it does not name `notifications` is satisfied by a sweep that
             reports nothing.

             That is the control for the control, and it failing means the sweep is
             not working — not that the boundary is fine.
             """
    end
  end

  describe "three denials and one allowance, as the login role" do
    test "no identity reads NO ROWS — and reads none rather than erroring" do
      # Zero rows, not an error. `cafaye.begin_account(NULL)` CLEARS rather than
      # failing, and a policy that raised on an absent identity would tell a
      # caller its request was unauthenticated — which a caller can be made to
      # believe about somebody else's request.
      as_account(nil, fn ->
        for table <- @tables do
          assert 0 == unrestricted_rows(table), "#{table} answered a row with no identity"
        end
      end)
    end

    test "ANOTHER TENANT'S VALID identity reads NO ROWS of their rows" do
      as_account(@account_a, fn ->
        for table <- @tables do
          assert 0 == rows_of(table, @account_b), "#{table} leaked account B to account A"
        end

        # And through the context, which is what a caller would use.
        assert [] == Notifications.list(@account_a, @recipient_b)
        assert 0 == Notifications.unread_count(@account_a, @recipient_b)
      end)
    end

    test "ANOTHER TENANT'S identity cannot reach their notification by id either" do
      %{notifications: [theirs]} =
        as_account(@account_b, fn ->
          {:ok, result} =
            Notifications.record(@account_b, type: "comment", recipient: @recipient_b)

          result
        end)

      as_account(@account_a, fn ->
        assert nil == Notifications.get(@account_a, @recipient_a, theirs.id)
        assert {:error, :not_found} = Notifications.mark_read(@account_a, @recipient_a, theirs.id)
        assert {:error, :not_found} = Notifications.mark_seen(@account_a, @recipient_a, theirs.id)
      end)
    end

    test "ANOTHER TENANT'S identity cannot WRITE a row into their account" do
      # The write-side twin of the read denial: `with check` is
      # `account_id = (select cafaye.current_account_id())`, so a row created in
      # somebody else's account is **refused** rather than hidden.
      #
      # **THE ANSWER IS A RAISE, NOT AN `{:error, _}`, AND THAT IS THE POINT.**
      # Nothing translates it: `Courier.Notifications` writes the account from its
      # own argument and a caller cannot name another one, so there is no code
      # path through the API that could produce this write. It is asserted as a
      # raise precisely because it is unreachable through the API — which is the
      # property, and is the contrast with
      # `Courier.NotificationPreferences.store_all/3`, which has to rescue a
      # `42501` to turn the same refusal into a 404.
      #
      # **AND `as_account/2` ANSWERS `{:error, :rollback}`, WHICH IS ASSERTED
      # RATHER THAN WORKED AROUND.** A Postgrex error inside a transaction leaves
      # that transaction ABORTED, so the COMMIT that follows cannot succeed and
      # `Courier.Tenancy.with_account/3` reports `{:error, :rollback}` even though
      # the function returned normally. That is the correct answer — the write was
      # refused and nothing was committed — and a test that ignored it would be
      # asserting a shape the context does not actually produce.
      # **`Courier.Tenancy.with_account/3` RATHER THAN THE `as_account/2` HELPER,
      # AND THE HELPER'S SHAPE IS WHY.** `Courier.DataCase.as_account/2` is
      #
      #     case Courier.Tenancy.with_account(Repo, account_id, fun) do
      #       {:ok, result} -> result
      #     end
      #
      # — a `case` with ONE clause, so a transaction that ends in
      # `{:error, :rollback}` raises `CaseClauseError` rather than returning
      # anything. That is the right design for the helper's users (a successful
      # scoped read) and it is unable to express this one case, so the
      # transaction is opened here directly. Measured, not read off the source:
      # the first version of this test went through the helper and reported
      #
      #     ** (CaseClauseError) no case clause matching: {:error, :rollback}
      #
      # which names the symptom and reads as though the RLS refusal had produced
      # an unexpected answer rather than as though the helper had one clause.
      assert {:error, :rollback} =
               Courier.Tenancy.with_account(Repo, @account_a, fn ->
                 assert_raise Postgrex.Error, ~r/row-level security policy/, fn ->
                   Repo.insert!(%NotificationEvent{
                     account_id: @account_b,
                     type: "comment",
                     params: %{}
                   })
                 end
               end)

      # And nothing was written, read back under B's own identity.
      as_account(@account_b, fn ->
        assert 1 == rows_of("notification_events", @account_b),
               "the refused insert left a row behind"
      end)
    end

    test "its OWN identity reads its OWN rows — the allowance, and the control" do
      # **WITHOUT THIS, THE TWO DENIALS ABOVE PROVE NOTHING.** A table with no
      # policy at all satisfies "another account reads nothing" perfectly well.
      as_account(@account_a, fn ->
        for table <- @tables do
          assert 1 == rows_of(table, @account_a), "#{table} hid account A's own row from A"
        end

        assert [_theirs] = Notifications.list(@account_a, @recipient_a)
        assert 1 == Notifications.unread_count(@account_a, @recipient_a)
      end)
    end

    test "and it reads ONLY its own rows, by a query with NO predicate in it" do
      # `unrestricted_rows/1` is the whole file: `select count(*) from
      # notifications`, no `where` clause at all. There is no `account_id` for a
      # refactor to drop, so the filtering this measures is the database's and not
      # courier's — which is exactly the trap the reference fell into
      # (`REF-jumpstart-inventory.md` §15.1 item 5).
      as_account(@account_a, fn ->
        for table <- @tables do
          assert 1 == unrestricted_rows(table)
        end
      end)

      as_account(@account_b, fn ->
        for table <- @tables do
          assert 1 == unrestricted_rows(table)
        end
      end)
    end

    test "BOTH identities at once: one row each, and neither sees the other's" do
      # Two identities, two answers, both 1. **A table with no policies answers 2
      # to both**, so this is the assertion that would go red on a substrate that
      # had `protect_table` silently do nothing.
      assert 1 == as_account(@account_a, fn -> unrestricted_rows("notifications") end)
      assert 1 == as_account(@account_b, fn -> unrestricted_rows("notifications") end)
    end
  end

  describe "the owner role, and why this file reads the catalog instead" do
    # **NOTHING ABOVE PROVES ANYTHING ABOUT THE OWNER.** Every statement runs on
    # `courier_app`. Postgres exempts a table's OWNER from its own policies
    # unless FORCE is set, and courier's migrations run as the owner — so a suite
    # that only proves `courier_app` is filtered is green against a database
    # where the role a migration connects as reads every account's rows.
    #
    # The denial **cannot be made from this connection**, and the reason is worth
    # stating rather than working around: the test connection is `courier_app`,
    # which is not the owner, and `Courier.OwnerRepo` — the only credential that
    # IS the owner — is a superuser on this machine, and a superuser bypasses RLS
    # whatever the catalog says. There is no third role available here that is
    # both non-superuser and the owner.
    #
    # So the FORCE half is read out of `pg_class`, which is the only in-suite
    # witness, and the owner's denials are proved where they can be made honestly:
    # a `SET ROLE` out of superuser. Adding a fourth copy here would be a proof
    # that cannot fail,
    # which is the thing this file exists to avoid.
    test "the test connection is NOT a superuser, so the denials above mean something" do
      # **THE PRECONDITION, ASSERTED.** Every denial in this file is worthless if
      # the connection bypasses RLS — and `config/test.exs` moving back to
      # `postgres` would do exactly that silently, with this file green. Measured
      # on the role this file used to assume:
      #
      #     rolname | rolsuper | rolbypassrls
      #     kaka    | t        | t
      #
      # which is the whole of `REPORT-courier-row-level-security` §3.
      assert superuser?() == false,
             """
             The test connection is a superuser, so it bypasses row-level security
             whatever `FORCE ROW LEVEL SECURITY` says and every denial in this
             file is satisfied by the connection rather than by the policy.

             `config/test.exs` connects as `courier_app` for exactly this reason.
             """
    end

    test "the FORCE bit is set on both tables, read from pg_class" do
      for table <- @tables do
        assert forced?(table)
      end
    end

    test "and the sweep's definition of protected agrees with those two reads" do
      # `cafaye.unprotected_tables()` judges a table on three facts — RLS
      # enabled, FORCEd, and carrying at least one policy — and the second is the
      # one no lint anywhere checks. This asserts the sweep agrees with the two
      # catalog reads above, so a substrate change that made the sweep silent
      # shows up as a disagreement rather than as a green sweep.
      for table <- @tables do
        assert enabled?(table) and forced?(table) and policy_commands(table) != [],
               "#{table} is not what the sweep calls protected"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The catalog reads
  #
  # `$1::regclass` IS NOT USED, and the reason is measured: Postgrex resolves
  # `::regclass` to the `oid` type and then hands the **`oid` encoder** a string,
  # which refuses it —
  #
  #     you tried to use a binary for an oid type (notifications) when an
  #     integer was expected
  #
  # The table names are the two literals in `@tables` and nothing else reaches
  # these, so interpolating them is not a parameterisation hole. Where a VALUE
  # does cross the boundary — the account id in `rows_of/2` — it is bound, and
  # bound as `::uuid` with `Ecto.UUID.dump!/1`, because the `uuid` encoder wants
  # 16 raw bytes and a 36-character string is not them.
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # The catalog reads
  #
  # `$1::regclass` IS NOT USED, and the reason is measured: Postgrex resolves
  # `::regclass` to the `oid` type and then hands the **`oid` encoder** a string,
  # which refuses it —
  #
  #     you tried to use a binary for an oid type (notifications) when an
  #     integer was expected
  #
  # The table names are the two literals in `@tables` and nothing else reaches
  # these, so interpolating them is not a parameterisation hole. Where a VALUE
  # does cross the boundary — the account id in `rows_of/2` — it is bound, and
  # bound as `::uuid` with `Ecto.UUID.dump!/1`, because the `uuid` encoder wants
  # 16 raw bytes and a 36-character string is not them.
  # ---------------------------------------------------------------------------

  # The role that RAN THE MIGRATION, which is what `protect_table` put in the
  # policy's `to` list. It is not `current_user` (this connection is
  # `courier_app`) and not a literal: on this machine it is `kaka`, on kit's
  # cluster it is `courier`, and in CI it is `postgres`. A literal would be
  # correct on exactly one of the three.
  defp owner_of(table) do
    %{rows: [[owner]]} =
      Repo.query!("select relowner::regrole::text from pg_class where relname = '#{table}'")

    owner
  end

  defp enabled?(table),
    do: bool!("select relrowsecurity from pg_class where relname = '#{table}'")

  defp forced?(table),
    do: bool!("select relforcerowsecurity from pg_class where relname = '#{table}'")

  defp superuser? do
    %{rows: [[value]]} =
      Repo.query!("select rolsuper from pg_roles where rolname = current_user")

    value
  end

  defp policy_commands(table) do
    %{rows: rows} =
      Repo.query!(
        "select polname, polcmd from pg_policy where polrelid = '#{table}'::regclass order by polname"
      )

    Enum.map(rows, fn [name, command] -> {name, to_string(command)} end)
  end

  defp roles(policy) do
    %{rows: [[roles]]} =
      Repo.query!("select polroles::regrole[]::text from pg_policy where polname = '#{policy}'")

    roles
    |> String.replace(~r/\{|\}/, "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.sort()
  end

  defp named_by_sweep do
    %{rows: rows} =
      Repo.query!("select table_name from cafaye.unprotected_tables() order by table_name")

    Enum.map(rows, fn [name] -> name end)
  end

  defp bool!(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

  # **THE QUERY WITH NO PREDICATE, and the whole reason this file exists.**
  #
  # `Repo.aggregate(Notification, :count)` is the same statement in Ecto, and the
  # raw form is used on purpose: the subject of the assertion is that the DATABASE
  # filtered the rows, and a reader who cannot see the absence of a `where`
  # clause has to take it on trust.
  defp unrestricted_rows(table) do
    %{rows: [[count]]} = Repo.query!("select count(*) from #{table}")
    count
  end

  defp rows_of(table, account_id) do
    %{rows: [[count]]} =
      Repo.query!("select count(*) from #{table} where account_id = $1::uuid", [
        Ecto.UUID.dump!(account_id)
      ])

    count
  end
end
