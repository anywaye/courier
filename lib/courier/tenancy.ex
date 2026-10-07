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

  ## WHY THE TRANSACTION IS THE WORK, NOT THE REQUEST

  An earlier shape of this control made a stronger claim — "the request IS the
  transaction" — with a plug (`CourierWeb.Plugs.TenantIdentity`) wrapping the
  rest of the pipeline in `with_account/3`. That claim was false, and it failed
  the way false security claims fail: silently in the suite, loudly in
  production. A plug's `call/2` returns before the downstream plugs and the
  controller run, so the transaction it opened was already committed by the time
  the first protected write happened — and a commit discards the
  transaction-local identity. Every authenticated request then ran with no
  identity: protected writes raised `42501` and protected reads returned zero
  rows. The suite could not see it because the sandbox turns the plug's
  transaction into a SAVEPOINT whose release does NOT discard the setting (see
  `Courier.DataCase`), so in-suite the downstream saw the identity that
  production never had.

  So `with_account/3` is called where a transaction can legitimately wrap the
  work, and that is never a plug: each controller action opens one around its
  whole body, and `CourierWeb.Plugs.Idempotency` opens one around each of its
  own claim, lookup and store. The request is therefore several scoped
  transactions rather than one, and the properties below belong to each of
  them:

    * **One connection is held for the length of each unit of work.**
      `pool_size` therefore sizes concurrency, and a request that waits on an
      external dependency holds its connection while it waits. `POST
      /v1/messages` already did exactly this inside `Courier.Deliver`'s own
      transaction — AGENTS.md records the choice and its price — so this is not
      a new contention class, it is the same one kept where it was.
    * **A nested `Repo.transaction` is NOT a savepoint, and a nested
      `Repo.rollback` fails the whole transaction.** Statement errors under a
      scope are therefore contained with `mode: :savepoint` on the operation
      itself (Ecto's documented remedy) rather than with an inner transaction
      that rolls back: an inner rollback under a scoped request was measured
      failing the outer commit as `{:error, :rollback}` — every retry a 503.
      The pre-existing control-flow rollbacks in `Courier.Unsubscribes`,
      `Courier.Notifications` and `Courier.InboundReports` predate per-action
      scoping and now nest inside it; their failure paths are the known
      exposure (see the W105 handoff), not a shape this packet re-verified.
      (`Courier.Deliver`'s send path is the exception: `send_and_record/3`
      returns its failures as values rather than rolling back, because a
      nested rollback fails the request's own scoped commit — measured as
      two red provider-retry tests, fixed where the rollback was.)
    * **The response leaves before the COMMIT.** This is the honest cost and it
      is the one place this arrangement is weaker than it could be: the
      controller calls `send_resp` inside the transaction, so a client can be
      told `201` by a transaction that then fails to commit. It is rare (a
      dropped connection at COMMIT) and it is **not** a tenancy risk — the
      identity is discarded by the rollback either way — but it is a durability
      ordering this module does not fix. The fix is to buffer the response and
      write it after the commit, which means replacing the `Plug.Conn`
      adapter, and an adapter swap inside a security control is the kind of
      cleverness this repository's own substrate comments warn against.
      Recorded, not done.
      **One place could have turned this into a lost write and does not**:
      `CourierWeb.Plugs.Idempotency` stores its cached response in
      `before_send`, after `send_resp`, in its OWN scoped transaction, and it
      ignores that transaction's outcome precisely because a failure there
      "must not turn a 201 into a 500". It cannot raise, so it cannot roll
      anything back but its own store.

  ## THE SHAPE THAT WAS REFUSED, AND WHY IT STAYS REFUSED

  Holding one checked-out connection for the whole request — set the GUC on it
  in the plug, check it back in `before_send` — would restore "one transaction
  per request". It is refused because the only connection-holding Ecto offers
  is function-scoped (`Repo.transaction/2`, `Repo.checkout/2`), and the
  alternatives are the two failures this module exists to prevent: a
  session-level `set_config` on a pooled connection leaks one account's
  identity to whoever is handed the connection next, and reaching past Ecto
  into the pool's private checkout API is a second way to obtain an identity —
  the thing this moduledoc's one rule forbids. Per-unit-of-work transactions
  are transaction-local everywhere, which is the property that makes a leak
  structurally impossible rather than merely unobserved. A site that forgets
  its scope fails closed — `42501` on a write, zero rows on a read — which is
  loud on the write half and is why the read half is covered by tests that
  seed under one account and read back under the scope.

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

  Used by the proofs and by the HTTP layer's own tests to say *where* the
  identity is scoped, rather than inferring it from a row count.
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
