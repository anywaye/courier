defmodule Courier.Workers.DispatchWebhooksWorkerTest do
  @moduledoc """
  The fan-out: an event in the outbox becomes one delivery per enabled endpoint of
  the account it belongs to.

  Delivery is at-least-once, so this worker is idempotent by construction — it
  runs on a timer, runs again after a crash, and may run twice concurrently on two
  replicas. The assertions that matter are therefore not "it sent N things" but
  "it does not send N things twice", which is what the `webhook_deliveries`
  unique index is for.
  """

  use Courier.DataCase, async: true

  use Oban.Testing, repo: Courier.Repo

  alias Courier.OutboxEvent
  alias Courier.WebhookDeliveries
  alias Courier.WebhookDelivery
  alias Courier.WebhookEndpoints
  alias Courier.Workers.DispatchWebhooksWorker

  @account_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @moduletag account: @account_id
  @other_account_id "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  defp endpoint!(attrs \\ %{}) do
    {:ok, endpoint, _secret} =
      WebhookEndpoints.create(
        Map.merge(%{url: "https://hooks.example.com/events", account_id: @account_id}, attrs)
      )

    endpoint
  end

  defp event(attrs) do
    %OutboxEvent{}
    |> OutboxEvent.changeset(
      Map.merge(
        %{
          type: "email.delivered",
          subject: "courier-1",
          data: %{"message_id" => "courier-1"}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "perform/1" do
    test "creates one delivery per enabled endpoint of the account" do
      endpoint!()
      endpoint!(%{url: "https://second.example.com/events"})
      event(%{account_id: @account_id})

      assert {:ok, %{dispatched: 2}} = perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 2
    end

    test "records the endpoint and the event on each delivery" do
      endpoint = endpoint!()
      row = event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})
      delivery = Repo.one!(WebhookDelivery)

      assert delivery.endpoint_id == endpoint.id
      assert delivery.event_id == row.id
    end

    test "does not deliver to another account's endpoints" do
      as_account(@other_account_id, fn -> endpoint!(%{account_id: @other_account_id}) end)
      event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 0
    end

    test "does not deliver another account's event to this account's endpoints" do
      endpoint!()
      event(%{account_id: @other_account_id})

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 0
    end

    test "skips a disabled endpoint" do
      endpoint = endpoint!()
      {:ok, _disabled} = WebhookEndpoints.update(endpoint, %{status: "disabled"})
      event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 0
    end

    test "creates nothing for an account with no endpoints" do
      event(%{account_id: @account_id})

      assert {:ok, %{dispatched: 0}} = perform_job(DispatchWebhooksWorker, %{})
    end

    test "creates nothing when there is nothing to dispatch" do
      assert {:ok, %{dispatched: 0}} = perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 0
    end

    test "an event courier recorded for a user rather than an account is not dispatched" do
      endpoint!()
      event(%{account_id: nil})

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 0
    end

    test "marks the event dispatched, so the next run does not redo it" do
      endpoint!()
      row = event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})
      assert Repo.get!(OutboxEvent, row.id).webhooks_dispatched_at

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.aggregate(WebhookDelivery, :count) == 1
    end

    test "re-dispatching an event does not duplicate a delivery" do
      endpoint!()
      event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})
      perform_job(DispatchWebhooksWorker, %{})

      assert [%{webhook_id: webhook_id}] = Repo.all(WebhookDelivery)
      assert String.starts_with?(webhook_id, "msg_")
    end

    test "keeps the same webhook_id when the dispatch is repeated" do
      endpoint!()
      row = event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})
      first = Repo.one!(WebhookDelivery).webhook_id

      row
      |> Ecto.Changeset.change(webhooks_dispatched_at: nil)
      |> Repo.update!()

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.one!(WebhookDelivery).webhook_id == first
    end

    test "two events to the same endpoint are two deliveries with different ids" do
      endpoint!()
      event(%{account_id: @account_id})
      event(%{account_id: @account_id, subject: "courier-2"})

      perform_job(DispatchWebhooksWorker, %{})

      ids = Repo.all(WebhookDelivery) |> Enum.map(& &1.webhook_id)

      assert length(Enum.uniq(ids)) == 2
    end

    test "starts every delivery pending, with no attempt yet made" do
      endpoint!()
      event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})

      delivery = Repo.one!(WebhookDelivery)
      assert delivery.status == :pending
      assert delivery.attempt == 0
      assert delivery.next_attempt_at == nil
      assert delivery.status_code == nil
    end

    test "leaves a succeeded delivery alone when its event is re-dispatched" do
      endpoint = endpoint!()
      row = event(%{account_id: @account_id})
      perform_job(DispatchWebhooksWorker, %{})
      delivery = Repo.one!(WebhookDelivery)
      WebhookDeliveries.succeed!(endpoint, row.id, status_code: 200, duration_ms: 5)

      row
      |> Ecto.Changeset.change(webhooks_dispatched_at: nil)
      |> Repo.update!()

      perform_job(DispatchWebhooksWorker, %{})

      assert Repo.get!(WebhookDelivery, delivery.id).status == :succeeded
      assert Repo.aggregate(WebhookDelivery, :count) == 1
    end
  end

  describe "the claim" do
    test "takes a batch, so one slow account does not hold up the rest" do
      for index <- 1..3, do: event(%{account_id: @account_id, subject: "courier-#{index}"})

      assert {:ok, %{dispatched: _at_least_one}} = perform_job(DispatchWebhooksWorker, %{})
    end

    test "does not claim an event that is already dispatched" do
      endpoint!()
      row = event(%{account_id: @account_id})

      perform_job(DispatchWebhooksWorker, %{})
      assert Repo.get!(OutboxEvent, row.id).webhooks_dispatched_at

      assert {:ok, %{dispatched: 0}} = perform_job(DispatchWebhooksWorker, %{})
    end
  end

  describe "job options" do
    test "runs on its own queue" do
      assert DispatchWebhooksWorker.__opts__()[:queue] == :webhooks
    end
  end
end
