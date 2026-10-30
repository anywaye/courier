defmodule Courier.NotificationsBoundaryTest do
  @moduledoc """
  The two tables' **account boundary**, and the reason this file is separate from
  `Courier.NotificationsTest`.


  `Courier.NotificationsTest` proves the record's shape: one event, one row per
  recipient, `seen`/`read` as different facts, idempotent marks. **Every one of
  its cross-account assertions would be green with `protect_table` never
  called.** Its queries carry `account_id` in Elixir, so an absent policy changes
  nothing they can observe — that is a query test, not a boundary test.

  This file makes the refusals **the database's**, with a query that has no
  predicate to drop:

      select count(*) from notifications

  under each account's identity, with no `where` clause anywhere in it.


  `config/test.exs` connects as **`courier_app`**: `NOSUPERUSER`, `NOBYPASSRLS`,
  and a named subject of all four policies on both tables. A superuser bypasses
  RLS whatever `FORCE ROW LEVEL SECURITY` says, which is how 1276 green tests
  once could not tell an enforced boundary from an inert one
  (`REPORT-courier-row-level-security` §3). The first test in the last
  describe block asserts that precondition, so it fails loudly if the
  connection ever becomes one that bypasses the policies again.


  * **no identity** → zero rows, and **zero rows rather than an error**
  * **another account's VALID identity** → zero rows of their rows
  * **its own identity** → its own rows

  The first is satisfied by a table with **no policy at all** — which is the bug
  — and the third is satisfied by a policy that permits everything. Only the
  three together are the property, so all three are here and the third is the
  control the two need.


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


  `anywaye.unprotected_tables()` returning nothing is satisfied by a sweep that
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

  @tables ~w(notifications notification_events)

  setup do
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
      for table <- @tables do
        assert MapSet.new(policy_commands(table)) ==
                 MapSet.new([
                   {"#{table}_anywaye_select", "r"},
                   {"#{table}_anywaye_insert", "a"},
                   {"#{table}_anywaye_update", "w"},
                   {"#{table}_anywaye_delete", "d"}
                 ]),
               "#{table} does not carry exactly the four per-command policies: " <>
                 inspect(policy_commands(table))
      end
    end

    test "and each policy NAMES both roles, rather than leaving it to PUBLIC" do
      for table <- @tables do
        owner = owner_of(table)

        for {name, _command} <- policy_commands(table) do
          assert roles(name) == Enum.sort([owner, "courier_app"]),
                 "#{name} does not name both the owner and courier_app: #{inspect(roles(name))}"
        end
      end
    end

    test "the sweep does not name either table" do
      assert Enum.sort(@tables -- named_by_sweep()) == Enum.sort(@tables),
             """
             anywaye.unprotected_tables() named one of the two tables this packet
             added:


             Either a table courier holds account rows in without a boundary, or
             `protect_table` was not called for it. Either way the assertion
             belongs here rather than in a report.
             """
    end

    test "THE CONTROL: the sweep DOES name `outbox_events`, so the empty answer above means something" do
      assert "outbox_events" in named_by_sweep(),
             """
             anywaye.unprotected_tables() named nothing at all, so the assertion
             that it does not name `notifications` is satisfied by a sweep that
             reports nothing.

             That is the control for the control, and it failing means the sweep is
             not working — not that the boundary is fine.
             """
    end
  end

  describe "three denials and one allowance, as the login role" do
    test "no identity reads NO ROWS — and reads none rather than erroring" do
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

      as_account(@account_b, fn ->
        assert 1 == rows_of("notification_events", @account_b),
               "the refused insert left a row behind"
      end)
    end

    test "its OWN identity reads its OWN rows — the allowance, and the control" do
      as_account(@account_a, fn ->
        for table <- @tables do
          assert 1 == rows_of(table, @account_a), "#{table} hid account A's own row from A"
        end

        assert [_theirs] = Notifications.list(@account_a, @recipient_a)
        assert 1 == Notifications.unread_count(@account_a, @recipient_a)
      end)
    end

    test "and it reads ONLY its own rows, by a query with NO predicate in it" do
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
      assert 1 == as_account(@account_a, fn -> unrestricted_rows("notifications") end)
      assert 1 == as_account(@account_b, fn -> unrestricted_rows("notifications") end)
    end
  end

  describe "the owner role, and why this file reads the catalog instead" do
    test "the test connection is NOT a superuser, so the denials above mean something" do
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
      for table <- @tables do
        assert enabled?(table) and forced?(table) and policy_commands(table) != [],
               "#{table} is not what the sweep calls protected"
      end
    end
  end



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
      Repo.query!("select table_name from anywaye.unprotected_tables() order by table_name")

    Enum.map(rows, fn [name] -> name end)
  end

  defp bool!(sql) do
    %{rows: [[value]]} = Repo.query!(sql)
    value
  end

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
