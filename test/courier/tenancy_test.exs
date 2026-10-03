defmodule Courier.TenancyTest do
  @moduledoc """
  The identity reaches the database, in a transaction, and dies with it.

  ## WHAT THIS FILE PROVES

  That `cafaye.current_account_id()` holds the caller's account **while the
  transaction runs** — read back through the substrate's own accessor, so the
  value asserted on is the value a policy would compare against.

  ## WHAT THIS FILE DELIBERATELY DOES NOT PROVE, AND WHY IT IS NOT A GAP

  Two things, both of which look assertable and are not:

    * **That the policies then refuse a cross-account read.** `config/test.exs`
      connects as `postgres`, which on this cluster is `rolsuper = t,
      rolbypassrls = t` — a **superuser bypasses RLS whatever `FORCE ROW LEVEL
      SECURITY` says.** An in-suite assertion that account A cannot read account
      B's rows would therefore pass **whether or not the identity was ever set**,
      which is a test that cannot fail. This is the whole finding the packet
      exists to close: 1276 green tests could not see an inert boundary.
      The denial is proved in `reports/courier-row-level-security/prove.sh` and
      `prove-identity-leak.sh`, which connect as `courier_app`
      (`NOSUPERUSER`, `NOBYPASSRLS`).

    * **That the identity does not outlive the transaction.** This one was
      *written* in this file, went **red**, and was removed after being measured,
      because in this suite it cannot be observed. `Ecto.Adapters.SQL.Sandbox`
      wraps every test in a transaction, so `Repo.transaction` inside a test is a
      **SAVEPOINT** — and `RELEASE SAVEPOINT` does not discard a
      transaction-local setting made inside it. Measured, in one `psql`
      session:

          begin; begin_account(A); savepoint sp1; release savepoint sp1;
          select current_account_id()  ->  A          <-- still set
          rollback;    select …       ->  null

      `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` looks like the escape — it checks
      a connection out with no ownership transaction — and it is **not one**.
      Measured on the same cluster, inside `unboxed_run`:

          before: pg_stat_activity.state = "active", in_xact = t
          after:  pg_stat_activity.state = "active", in_xact = t
          cafaye.current_account_id()  ->  A          <-- survives COMMIT

      So the assertion fails for a reason that has nothing to do with courier,
      and an assertion that is always red teaches a reader to ignore the file.

      **The shape the assertion needs is the one the prove scripts run**: a
      connection with no ambient transaction at all, where `BEGIN` … `COMMIT`
      really does end. There, measured in `psql`:

          begin; begin_account(A); select current_account_id() -> A
          commit;  select current_account_id() -> (null)
          -- and in AUTOCOMMIT, the substrate's own documented consequence:
          select begin_account(A);  select current_account_id() -> (null)

      The autocommit line is why `with_account/3` exists at all: `is_local :=
      true` outside a transaction expires at the end of the statement that set it,
      so a query that forgot to open one reads **zero rows** rather than everything.
  """

  use Courier.DataCase, async: true

  alias Courier.Tenancy

  @account_a "3f1b7a26-9d0e-4f8b-8a1c-2b7e5c1d0a11"
  @account_b "8c4d2f70-1a3b-4e6c-9d5f-0a1b2c3d4e55"

  describe "with_account/3" do
    test "the database sees the account, on the connection the queries will use" do
      assert {:ok, @account_a} =
               Tenancy.with_account(Repo, @account_a, fn ->
                 assert Tenancy.in_transaction?(Repo)

                 Tenancy.current_account_id(Repo)
               end)
    end

    test "and it really is a transaction, which is the whole mechanism" do
      # `in_transaction?/1` is the half that matters: `is_local := true` outside a
      # transaction expires at the end of the statement that set it, so a query
      # that ran without one would read zero rows. So "the identity is set" is not
      # the claim — "the identity is set AND a transaction is open to hold it" is.
      assert {:ok, inside} =
               Tenancy.with_account(Repo, @account_a, fn ->
                 Tenancy.in_transaction?(Repo)
               end)

      assert inside
    end

    test "a later identity REPLACES an earlier one on the same transaction" do
      # The shape that matters for a nested call or a worker: within one
      # transaction the most recent `begin_account/1` is the one the policies see.
      # An identity that silently did nothing would leave the boundary reading as
      # the FIRST account rather than as nothing — the opposite failure to the one
      # a reader worries about, and the one no test would catch.
      assert {:ok, @account_b} =
               Tenancy.with_account(Repo, @account_a, fn ->
                 assert @account_a == Tenancy.current_account_id(Repo)

                 Tenancy.begin_account(Repo, @account_b)
                 Tenancy.current_account_id(Repo)
               end)
    end

    test "nil CLEARS one already set, on the same transaction" do
      # `cafaye.begin_account(NULL)` CLEARS rather than failing, and it clears
      # *within* the transaction — which is what makes the negative control "zero
      # rows, not an error": a request whose account is unknown does not go on
      # reading as whoever it was a moment ago.
      assert {:ok, nil} =
               Tenancy.with_account(Repo, @account_a, fn ->
                 assert @account_a == Tenancy.current_account_id(Repo)
                 Tenancy.begin_account(Repo, nil)
                 Tenancy.current_account_id(Repo)
               end)
    end

    test "a nil identity from the start is an answer, not a failure" do
      assert {:ok, seen} =
               Tenancy.with_account(Repo, nil, fn ->
                 Tenancy.current_account_id(Repo)
               end)

      assert is_nil(seen)
    end

    test "an exception in the function unwinds the transaction and re-raises" do
      assert_raise RuntimeError, "the downstream blew up", fn ->
        Tenancy.with_account(Repo, @account_a, fn -> raise "the downstream blew up" end)
      end
    end

    test "a rollback is reported, and the identity did not become the answer" do
      assert {:error, :gave_up} =
               Tenancy.with_account(Repo, @account_a, fn -> Repo.rollback(:gave_up) end)
    end
  end

  describe "begin_account/2" do
    test "a malformed account is refused in Elixir, before the database is asked" do
      # `Ecto.UUID.dump!/1` raises `ArgumentError`, and that is deliberate rather
      # than incidental. The substrate's `current_account_id()` is written to raise
      # `22023` on a non-uuid with a hint naming `begin_account/1`, but reaching
      # that needs the value to survive encoding — and Postgrex's `uuid` encoder
      # refuses a malformed string first, with a message about **bytes** rather
      # than about tenancy. So the refusal happens one layer earlier than the
      # substrate intended, and the message names the value, which is the more
      # useful half.
      assert_raise ArgumentError, ~r/cannot dump given UUID/, fn ->
        Tenancy.begin_account(Repo, "not-a-uuid")
      end
    end
  end
end
