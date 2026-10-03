defmodule Courier.Tenancy do
  @moduledoc """
  courier's account identity, as the database sees it.

  ## WHY THIS MODULE EXISTS AT ALL

  `priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs`
  installed kit's substrate: three tables now carry `CREATE POLICY`, `ENABLE ROW
  LEVEL SECURITY` and **`FORCE ROW LEVEL SECURITY`**. FORCE is the setting that
  removes the *owner's* exemption, so from that migration onwards the role
  courier connects as is a **policy subject** — and a policy subject with no
  identity set reads **zero rows**.

  Zero rows, not an error. That is the whole finding this module exists to close:
  `GET /v1/webhook_endpoints` would answer `{"data": []}`, and
  `POST /v1/messages` would find no idempotency record, with nothing in any log.
  The boundary was installed and inert.

  It was invisible on a development machine for one reason and the reason is
  worth writing down somewhere it will be read: **`config/dev.exs` and
  `config/test.exs` both connect as `postgres`, which is a superuser, and a
  superuser bypasses RLS whatever FORCE says.** 1276 green tests could not see it.
  kit's actual cluster creates the service owner `NOSUPERUSER`
  (`kit/templates/compose/postgres/initdb/10-cluster.sh:219`), so the deployed
  stack is the configuration where it bites.

  ## THE ONE RULE, AND IT IS TWO HALVES

      cafaye.begin_account/1  is  set_config('cafaye.account_id', …, is_local := true)

  `is_local := true` is transaction-local, and both halves of that are load-bearing:

    * **It must be inside a transaction.** Outside one, `is_local` expires at the
      end of the statement that set it, so the next query sees NULL. That is safe
      (zero rows, loudly) and it is the substrate's own documented consequence —
      it is not a way to make a leak.
    * **It cannot outlive the transaction.** This is the half that matters. A
      session-level `set_config` on a pooled connection hands account A's identity
      to whoever is handed the connection next, and account B then reads account
      A's rows. **Transaction-local cannot do that**: `COMMIT` and `ROLLBACK` both
      discard it, in the database, without courier's cooperation.

  So `with_account/3` is the only way to obtain an identity, and it is the only
  function here that opens a transaction. There is no exported way to set the
  GUC for the life of a connection, on purpose.

  ## WHY THE TRANSACTION IS THE REQUEST

  `with_account/3` returns the value `fun` returns, so the natural caller is a
  Plug that wraps the rest of the pipeline:

      CourierWeb.Plugs.TenantIdentity

  The request **is** the transaction. That is a strong claim and it has a cost,
  stated rather than assumed:

    * **One connection is held for the whole request.** `pool_size` therefore
      sizes concurrency, and a request that waits on an external dependency holds
      its connection while it waits. `POST /v1/messages` already did exactly this
      inside `Courier.Deliver`'s own transaction — AGENTS.md records the choice
      and its price — so this is not a new contention class, it is the same one
      moved up a level.
    * **A nested `Repo.transaction` becomes a SAVEPOINT.** `Courier.Deliver`,
      `Courier.Unsubscribes` and `Courier.Idempotency` all open their own; inside
      ours they nest correctly and a `Repo.rollback` of one unwinds only that one.
      The GUC set at the outer level survives a savepoint release, because it was
      already set when the savepoint was taken.
    * **The response leaves before the COMMIT.** This is the honest cost and it is
      the one place this arrangement is weaker than it could be: the controller
      calls `send_resp` inside the transaction, so a client can be told `201` by a
      transaction that then fails to commit. It is rare (a dropped connection at
      COMMIT) and it is **not** a tenancy risk — the identity is discarded by the
      rollback either way — but it is a durability ordering this module does not
      fix. The fix is to buffer the response and write it after the commit, which
      means replacing the `Plug.Conn` adapter, and an adapter swap inside a
      security control is the kind of cleverness this repository's own substrate
      comments warn against. Recorded, not done.
      **One place could have turned this into a lost write and does not**:
      `CourierWeb.Plugs.Idempotency` stores its cached response in `before_send`,
      after `send_resp`, and it `rescue`s everything precisely because a failure
      there "must not turn a 201 into a 500". It cannot raise, so it cannot roll
      this transaction back.

  ## NO IDENTITY IS ALSO AN ANSWER

  `begin_account(repo, nil)` calls `cafaye.begin_account(NULL)`, which the
  substrate defines as **clearing** rather than failing. So a request with no
  account reads **zero rows** — not every row, not an error. That is the substrate's
  deliberate design and it is the right one: a policy that raised on an absent
  identity would tell a caller its request was not authenticated, and a caller can
  be made to believe that about somebody else's request.

  ## WHAT THIS IS NOT

  It is not a substitute for the `WHERE account_id = ?` in courier's own queries.
  The substrate says so and it is right: the predicate is what makes a query
  indexable and what catches a mistake in the policy expression. RLS is defence in
  depth. This module turns that depth on.
  """

  @typedoc "A uuid, or `nil` for \"this session has no account\"."
  @type account_id :: Ecto.UUID.t() | nil

  # `$1::uuid` and a `Ecto.UUID.dump/1` value, together. Both halves are required
  # and measured: Postgrex resolves `$1` to the `uuid` OID from the cast and then
  # hands the *encoder for `uuid`* a value, and `uuid`'s encoder wants 16 raw bytes
  # while `Ecto.UUID` strings are 36. Passing the string alone raises
  #
  #     ** (DBConnection.EncodeError) Postgrex expected a binary of 16 bytes,
  #        got "6d3c5d11-c440-46fa-9543-4c8a589810c3"
  #
  # which is the shape of a bug in a caller that is passing a perfectly good uuid.
  @begin_account "select cafaye.begin_account($1::uuid)"
  @current_account "select cafaye.current_account_id()"

  @doc """
  Runs `fun` in a transaction whose `cafaye.account_id` is `account_id`.

  `nil` is a legitimate argument and clears the identity, which reads as zero
  rows rather than as an error. See the moduledoc.

  Returns `{:ok, value}` when the transaction committed and `{:error, reason}`
  when `fun` rolled it back. **An exception in `fun` is not returned — it is
  re-raised after the rollback**, so the request fails the way it would have
  without this module and `Phoenix.Endpoint.RenderErrors` renders it.
  """
  @spec with_account(module(), account_id(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_account(repo, account_id, fun) when is_function(fun, 0) do
    repo.transaction(fn ->
      begin_account(repo, account_id)
      fun.()
    end)
  end

  @doc """
  Sets the identity for the **current transaction**.

  Transaction-local, so this is only meaningful inside `with_account/3`, and it is
  public so that the proofs and the tests can assert what the database actually
  holds rather than asserting that a function was called.

  Raises if the substrate is not installed — `cafaye` not existing means
  `protect_account_scoped_tables` has not run, and a boundary that is silently
  absent is worse than one that is loudly missing.
  """
  @spec begin_account(module(), account_id()) :: term()
  def begin_account(repo, account_id) when is_nil(account_id) do
    # `nil` is dumped to `nil` by `Ecto.UUID.dump/1`, so this one line carries
    # both shapes. `cafaye.begin_account(NULL)` CLEARS the identity rather than
    # failing — see the moduledoc, and the substrate's own comment on why.
    Ecto.Adapters.SQL.query!(repo, @begin_account, [dump(account_id)])
  end

  def begin_account(repo, account_id) when is_binary(account_id) do
    Ecto.Adapters.SQL.query!(repo, @begin_account, [dump(account_id)])
  end

  defp dump(nil), do: nil
  defp dump(account_id), do: Ecto.UUID.dump!(account_id)

  @doc """
  The account the database currently sees, or `nil`.

  Read back through the substrate's own accessor, so a test that asserts on this
  is asserting about the value a policy would compare against rather than about
  the string courier sent.
  """
  @spec current_account_id(module()) :: Ecto.UUID.t() | nil
  def current_account_id(repo) do
    %{rows: [[account_id]]} = Ecto.Adapters.SQL.query!(repo, @current_account, [])

    # `Ecto.UUID.load/1`, and this is the twin of the `dump` above rather than a
    # convenience. `cafaye.current_account_id()` is declared `returns uuid`, so
    # Postgrex hands back the `uuid` OID's **raw 16 bytes** — measured, not
    # remembered:
    #
    #     {:ok, "3f1b7a26-9d0e-4f8b-8a1c-2b7e5c1d0a11"}   # dump! of what was set
    #     <<63, 27, 122, 38, 157, 14, 79, 139, 138, 28, 43, 126, 92, 29, 10, 17>>
    #
    # Returning that raw binary from a function whose spec says `Ecto.UUID.t()`
    # would make every test comparing it to the account it set fail on a value
    # that is *correct*, and — worse — would make an identity check comparing two
    # of them to each other fail in a way that looks like a leak and is not one.
    case account_id do
      nil -> nil
      raw -> Ecto.UUID.load!(raw)
    end
  end

  @doc """
  Whether the calling process is already inside a transaction on `repo`.

  Used by the proofs and by `CourierWeb.Plugs.TenantIdentity`'s own tests to say
  *where* the identity is scoped, rather than inferring it from a row count.
  """
  # `Ecto.Adapters.SQL.in_transaction?/1` takes the adapter META, not the repo
  # module — it pattern-matches on `%{pid: pool}` — so it is reached through
  # `Ecto.Adapter.lookup_meta/1`. Measured: passing the module raises a
  # `FunctionClauseError` naming `%{pid: pool}`, which is a confusing way to learn
  # that.
  @spec in_transaction?(module()) :: boolean()
  def in_transaction?(repo) do
    repo
    |> Ecto.Adapter.lookup_meta()
    |> Ecto.Adapters.SQL.in_transaction?()
  end
end
