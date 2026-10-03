defmodule Courier.Workers.DispatchWebhooksWorker do
  @moduledoc """
  The fan-out: takes an event from courier's outbox and gives every enabled
  endpoint of that event's account a delivery to make.

  It is a *dispatcher*, not a sender. The two are separate jobs because they fail
  differently: a dispatch that cannot be made (a database is down) is worth
  retrying in seconds and never touches a customer's server, while a delivery
  that fails is a customer problem with a sixteen-hour budget and a circuit
  breaker. Folding them into one worker would mean every unreachable consumer
  retried the dispatch loop as fast as the database could answer.

  ## Idempotence

  This worker runs on a timer, so it runs again after a crash and may run
  concurrently on two replicas. Three things make a second run harmless:

    * `webhooks_dispatched_at` is set from the same transaction that created the
      deliveries, so a dispatch that half-happened is visible as not-happened and
      is redone rather than lost.
    * `webhook_deliveries` is unique on `(endpoint_id, event_id)`, so a repeated
      dispatch returns the row that already exists — with the *same* `webhook_id`.
      That matters: a second `webhook_id` would look like a second event to a
      consumer deduplicating on it, which is the one thing the spec's id exists
      to prevent.
    * the claim is `for update skip locked`, so two replicas do not dispatch the
      same event at the same time.

  ## Events with no account

  `Courier.Deliver` records `email.delivered` for a person, and courier does not
  know which account that person is in, so those events have no `account_id` and
  this worker skips them. Fanning them out to every account would deliver one
  customer's mail events to another — the payloads carry a recipient address.

  ## THE FAN-OUT READS UNDER AN IDENTITY, AND THAT IS THE POINT OF THIS SECTION

  `webhook_endpoints` is one of the three tables
  `20261003090000_protect_account_scoped_tables` protects, and it does so with
  `FORCE ROW LEVEL SECURITY` — which is the setting that removes the *owner's*
  exemption. So the role courier's application connects as is a policy subject,
  and **a policy subject holding no identity reads zero rows.** Not every row,
  and not an error: an empty result set, a `{:ok, %{dispatched: 0}}` and nothing
  in any log.

  That is what this worker used to do, and it is measured rather than asserted —
  `reports/courier-queue-identity/prove-queue-identity.sh`, against a
  `NOSUPERUSER` owner as kit's cluster creates one:

      without identity   {:ok, %{dispatched: 0}}   0 deliveries   0 log lines
      with identity      {:ok, %{dispatched: 2}}   2 deliveries

  A fan-out that reaches nothing and logs nothing is indistinguishable from one
  that worked, to everything downstream of it. Every other boundary in this
  service refuses loudly — `permission denied for table`, `violates row-level
  security policy`, 23505 — and this one was returning an empty list.

  So `fan_out/1` opens `Courier.Tenancy.with_account/3` around the read, **per
  event**. Per event rather than per batch is the load-bearing word: one batch
  spans several accounts, and a single identity for the batch would be one
  account's endpoints read on another account's behalf — a cross-tenant read
  wearing the costume of a fan-out. `with_account/3` is transaction-local, so the
  identity is discarded by the COMMIT without courier's cooperation and cannot
  outlive the event it was set for. That is why it is this wrapper and not a
  policy that lets an unidentified worker read everything: the point is that the
  identity **exists**.

  The delivery rows are written OUTSIDE that wrapper, which is deliberate. They
  go into `webhook_deliveries`, which carries no `account_id` and no policy —
  `protect_table` refuses a table with no tenancy column by name, and the
  protection migration names both this table and `outbox_events` as the two
  account-scoped-shaped tables it deliberately leaves alone. The read is the
  thing RLS governs here.

  `test/courier/workers/dispatch_webhooks_worker_identity_test.exs` asserts the
  identity is on the connection for every read of the protected table during
  `perform/1`, and is deleted-flavoured: remove the `with_account/3` below and it
  goes red. The row-count half cannot be asserted in-suite at all, because
  `config/test.exs` connects as a superuser and a superuser bypasses RLS — which
  is precisely why this went unnoticed for as long as it did.
  """

  import Ecto.Query

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Tenancy
  alias Courier.WebhookDeliveries
  alias Courier.WebhookEndpoints

  # Read at compile time because Oban reads a worker's options when it builds a
  # job, and the same number is in `config :courier, :webhooks` for the runtime
  # read. The two agreeing is what "past the cap" means.
  @max_batch Application.compile_env(:courier, :webhooks)[:dispatch_batch_size]

  use Oban.Worker, queue: :webhooks, max_attempts: @max_batch

  @doc """
  Claims a batch of undispatched events and creates their deliveries.

  `{:ok, %{dispatched: n}}` where `n` is the number of delivery rows created. An
  event that had no endpoints still counts as dispatched: it was considered and
  found to have nowhere to go, and re-considering it every minute forever is not
  work.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, dispatched} = Repo.transaction(&dispatch/0)

    {:ok, %{dispatched: dispatched}}
  end

  defp dispatch do
    Enum.reduce(claim(), 0, fn event, dispatched ->
      # One transaction per event: the deliveries and the mark that says they were
      # made commit together or not at all. A dispatch recorded without its
      # deliveries is an event nobody will ever deliver again, silently.
      {:ok, created} = Repo.transaction(fn -> fan_out(event) end)

      {:ok, _event} = mark_dispatched(event)

      dispatched + created
    end)
  end

  defp fan_out(event) do
    {:ok, endpoints} =
      Tenancy.with_account(Repo, event.account_id, fn ->
        WebhookEndpoints.enabled(event.account_id)
      end)

    Enum.count(endpoints, fn endpoint ->
      WebhookDeliveries.insert!(endpoint, event.id)
      true
    end)
  end

  defp claim do
    OutboxEvent
    |> where(
      [event],
      not is_nil(event.account_id) and is_nil(event.webhooks_dispatched_at)
    )
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> limit(^batch_size())
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp mark_dispatched(event) do
    event
    |> Ecto.Changeset.change(webhooks_dispatched_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp batch_size, do: config()[:dispatch_batch_size]

  defp config, do: Application.get_env(:courier, :webhooks, [])
end
