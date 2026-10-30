defmodule Courier.Workers.DispatchWebhooksWorkerIdentityTest do
  @moduledoc """
  The fan-out reads `webhook_endpoints` **under the account it is fanning out
  to**, and this file is the one that can fail when it stops doing so.


  `dispatch_webhooks_worker_test.exs` asserts the fan-out's ARITHMETIC — two
  endpoints, two deliveries — and it is right to. But that file passes with the
  identity switched off, because `config/test.exs` connects as `postgres` and
  `postgres` is `rolsuper = t, rolbypassrls = t` on this cluster: **a superuser
  bypasses RLS whatever `FORCE ROW LEVEL SECURITY` says.** Measured on the role
  the suite actually uses:

      rolname | rolsuper | rolbypassrls
      postgres       t             t

  So "the worker created 2 deliveries" is green whether the worker holds an
  identity or not, and a green suite was the reason this defect survived the
  packet that found it. The same measurement arrives at the same place from the
  other direction.

  **A row count therefore cannot be the assertion.** Not in this suite. It is
  asserted against a `NOSUPERUSER` owner, which gets 0 deliveries where this file
  gets 2 — the only difference being the role.


  **The identity on the connection, at the moment the read ran.** That is
  observable in-suite even as a superuser, because `anywaye.current_account_id()`
  does not care whether the role would have been filtered: it reports what a
  policy *would* compare against, which is the thing that has to be right.
  Every `webhook_endpoints` statement courier issues during `perform/1` is
  captured with the identity visible at that moment, and the assertion is that
  the identity is the account of the event being fanned out.

  That is a stronger claim than the row count, not a weaker one. A worker that
  read the right rows *without* an identity would pass the row count and fail
  this; a worker that read under the WRONG account would pass both.


  Delete the `Courier.Tenancy.with_account/3` call from `DispatchWebhooksWorker`
  and every recorded read carries `nil` instead of the event's account. Verified
  red before verified green; see
  `REPORT-courier-queue-identity-01` §5.


  Because it ATTACHES a telemetry handler, and a telemetry handler is a
  registration against the whole VM rather than against this process. Every other
  test in the suite emits `[:courier, :repo, :query]` while it runs, and an
  `async: true` file would be sending those to a test process that has already
  exited. It is detached in `on_exit`, and the file is the only one that attaches
  this handler id.
  """

  use Courier.DataCase, async: false

  import Ecto.Query

  alias Courier.OutboxEvent
  alias Courier.Tenancy
  alias Courier.WebhookDelivery
  alias Courier.WebhookEndpoints
  alias Courier.Workers.DispatchWebhooksWorker

  use Oban.Testing, repo: Courier.Repo

  @account_a "b1c2d3e4-5f60-4718-8293-a4b5c6d7e8f9"

  @moduletag account: @account_a
  @account_b "c2d3e4f5-6071-4829-93a4-b5c6d7e8f9a0"

  @handler {__MODULE__, :webhook_endpoints_reads}

  setup do
    parent = self()

    handler = fn _event, _measurements, metadata, config ->
      observe_read(metadata.query, config.parent, config)
    end

    :ok =
      :telemetry.attach_many(@handler, [[:courier, :repo, :query]], handler, %{parent: parent})

    on_exit(fn -> :telemetry.detach(@handler) end)
  end

  defp observe_read(query, parent, _config) when is_binary(query) do
    if String.contains?(query, "webhook_endpoints") and not reading_identity?() do
      send(parent, {:read, identity_now()})
    end

    :ok
  end

  defp observe_read(_query, _parent, _config), do: :ok

  defp reading_identity?, do: Process.get(:dispatch_identity_reading, false)

  defp identity_now do
    Process.put(:dispatch_identity_reading, true)

    try do
      {Tenancy.current_account_id(Repo), Tenancy.in_transaction?(Repo)}
    after
      Process.delete(:dispatch_identity_reading)
    end
  end

  defp reads do
    receive do
      {:read, reading} -> [reading | reads()]
    after
      0 -> []
    end
  end

  defp flush_reads do
    receive do
      {:read, _reading} -> flush_reads()
    after
      0 -> :ok
    end
  end

  defp endpoint!(account_id) do
    {:ok, endpoint, _secret} =
      WebhookEndpoints.create(%{url: "https://hooks.example.com/events", account_id: account_id})

    endpoint
  end

  defp event(account_id, subject) do
    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      type: "email.delivered",
      subject: subject,
      data: %{"message_id" => subject},
      account_id: account_id
    })
    |> Repo.insert!()
  end

  describe "the identity on the read path" do
    test "one account's fan-out reads webhook_endpoints under THAT account" do
      endpoint = endpoint!(@account_a)
      row = event(@account_a, "courier-a")

      flush_reads()

      assert {:ok, %{dispatched: 1}} = perform_job(DispatchWebhooksWorker, %{})

      assert [{@account_a, true}] = reads()

      assert [delivery] = Repo.all(where(WebhookDelivery, endpoint_id: ^endpoint.id))
      assert delivery.event_id == row.id
    end

    test "two accounts in one batch are read under two DIFFERENT identities" do
      endpoint!(@account_a)
      as_account(@account_b, fn -> endpoint!(@account_b) end)
      event(@account_a, "courier-a")
      event(@account_b, "courier-b")

      flush_reads()

      assert {:ok, %{dispatched: 2}} = perform_job(DispatchWebhooksWorker, %{})

      identities = reads() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert identities == Enum.sort([@account_a, @account_b])
    end

    test "the identity is set on a TRANSACTION, and every read is inside it" do
      endpoint!(@account_a)
      event(@account_a, "courier-a")

      flush_reads()

      perform_job(DispatchWebhooksWorker, %{})

      for {account_id, in_transaction?} <- reads() do
        assert in_transaction?,
               "a read of webhook_endpoints ran with the identity set outside a " <>
                 "transaction, where it expires at the end of the statement that " <>
                 "set it and the next query sees NULL"

        assert account_id == @account_a
      end
    end

    test "an event courier recorded for a USER never reaches the protected table at all" do
      endpoint!(@account_a)
      event(nil, "courier-nil")

      flush_reads()

      assert {:ok, %{dispatched: 0}} = perform_job(DispatchWebhooksWorker, %{})

      assert [] = reads()
    end
  end
end
