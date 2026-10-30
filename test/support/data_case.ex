defmodule Courier.DataCase do
  @moduledoc """
  The test harness: the SQL sandbox, and the account identity it now carries.


  `config/test.exs` connects as **`courier_app`**, which owns nothing and is a
  subject of every row-level-security policy the substrate installed
  (`priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs`).
  Every test that writes a row to `idempotency_keys`, `notification_preferences`
  or `webhook_endpoints` therefore needs an account identity set, because the
  policy's `with check` is `account_id = anywaye.current_account_id()`.

  It used not to need one, and the reason is the finding this harness change
  exists to record: the suite connected as `postgres`, a **superuser**, and a
  superuser bypasses RLS whatever `FORCE ROW LEVEL SECURITY` says. So 1276 green
  tests could not tell an enforced boundary from an inert one, and the context
  tests wrote account-scoped rows with no identity anywhere and passed.

  Measured on the four account-scoped context files, with `config/test.exs`
  already moved to `courier_app` and this harness NOT yet carrying an identity:

      35/107 passed, 72 failures, every one `42501` on an INSERT


  `Ecto.Adapters.SQL.Sandbox` already wraps every test in a **transaction**, so
  `set_config('anywaye.account_id', …, is_local := true)` is held by that one and
  discarded by the rollback at the end of the test. `with_account/3` would open a
  nested transaction — a SAVEPOINT — and the identity would still be visible
  afterwards, because `RELEASE SAVEPOINT` does not discard a transaction-local
  setting made inside it (measured, and recorded in `Courier.Tenancy`'s moduledoc
  and in `test/courier/tenancy_test.exs`). Setting it directly on the sandbox
  connection is both simpler and strictly more correct: the test body IS the
  transaction.

  DECLARE IT GETS A LOUD `42501`

  Which is the right failure. A harness that guessed an account would make the
  boundary untestable, because a wrong guess and a working policy look identical
  from inside a test that only ever writes one account's rows.


  A test that reads only `outbox_events`, `email_suppressions`,
  `unsubscribe_tokens` or `webhook_deliveries` needs **no** tag: those tables
  carry no `account_id` and are deliberately unprotected (the protection
  migration says so, and `tenancy.yml`'s `rls.tables` is empty). So the tag is
  a statement about which of courier's tables the test touches, not a ritual.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Courier.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Courier.DataCase
    end
  end

  setup tags do
    Courier.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Also sets the account identity, when the file declared one with
  `@moduletag account: "…"`. See the moduledoc for why it is transaction-local
  and why it is set here rather than in a `with_account/3`.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Courier.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    case tags[:account] do
      nil -> :ok
      account_id -> Courier.Tenancy.begin_account(Courier.Repo, account_id)
    end
  end

  @doc """
  Runs `fun` as `account_id`, then puts the file's own identity back.


  Because `with_account/3` does not restore what it replaced, and inside the
  sandbox its transaction is a **SAVEPOINT** — and `RELEASE SAVEPOINT` does not
  discard a transaction-local setting made inside it. Measured, one `psql`
  session:

      begin; begin_account(A); savepoint sp1; release savepoint sp1;
      select current_account_id()  ->  A          <-- still set

  So a test that switched and came back would leave the file's identity replaced
  for the rest of its body, and the next assertion would be scoped to the wrong
  account **with no error anywhere** — a cross-tenant test passing for the wrong
  reason, which is the shape `tenancy.yml` exists to make impossible. Reading the
  previous identity back and re-setting it makes the switch balanced.


  `with_account/3` answers `{:ok, result}` or `{:error, reason}` because a
  *request* has to be able to fail its transaction and tell that from success. A
  test helper has no such caller: every use is
  `assert x = as_account(other, fn -> … end)` on a statement whose own result is
  the thing under test, and a second `{:ok, …}` means every call site unwraps by
  hand. That is not hypothetical — the first version of this helper returned
  `{:ok, value}` and produced

      left:  {:ok, true}
      right: {:ok, nil}

  on a body that had **passed**. A helper whose wrapper is easy to get wrong is a
  helper that will be.

  A rollback inside `fun` still raises rather than returning, because
  `with_account/3` re-raises after unwinding and a test that swallowed it would
  go on to assert against a transaction that never committed.

  `with_account/3` is used rather than a bare `Repo.transaction/1` because it is
  the only function in the tree that opens this transaction on purpose, and a
  second way to obtain an identity is a second thing to get wrong.
  """
  def as_account(account_id, fun) when is_function(fun, 0) do
    previous = Courier.Tenancy.current_account_id(Courier.Repo)

    try do
      case Courier.Tenancy.with_account(Courier.Repo, account_id, fun) do
        {:ok, result} -> result
      end
    after
      Courier.Tenancy.begin_account(Courier.Repo, previous)
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
