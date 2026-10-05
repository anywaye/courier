defmodule Courier.Workers.DeliverWebhookWorkerBudgetTest do
  @moduledoc """
  The retry budget on its own, with the circuit breaker held out of the way.

  The two bounds are separate — PLAN.md §7 requires bounded budgets, and courier
  has two of them — but at the shipped numbers the circuit opens after 5 failures
  and the budget is 8, so the budget can only be observed with the circuit raised
  out of reach. `on_exit` puts the real configuration back.

  `async: false` because application env is VM-global: while this module holds a
  raised threshold, an async worker test would be asserting against a circuit that
  is not the one courier ships.
  """

  use Courier.DataCase, async: false

  use Oban.Testing, repo: Courier.Repo

  import Courier.TestSupport.RecordingSender

  alias Courier.OutboxEvent
  alias Courier.TestSupport.RecordingSender, as: Sender
  alias Courier.WebhookDeliveries
  alias Courier.WebhookDelivery
  alias Courier.WebhookEndpoint
  alias Courier.WebhookEndpoints
  alias Courier.Workers.DeliverWebhookWorker

  @account_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account_id

  setup do
    original = Application.get_env(:courier, :webhooks)

    # A threshold the budget can never reach: the point of this file is the
    # delivery's own attempt count, and the circuit is measured in
    # `Courier.Workers.DeliverWebhookWorkerTest`.
    Application.put_env(
      :courier,
      :webhooks,
      Keyword.put(original, :circuit_threshold, 1_000)
    )

    on_exit(fn ->
      Application.put_env(:courier, :webhooks, original)
      Sender.reset()
    end)

    Sender.reset()
    :ok
  end

  defp event do
    %OutboxEvent{}
    |> OutboxEvent.changeset(%{
      type: "email.delivered",
      subject: "courier-1",
      data: %{"message_id" => "courier-1"},
      account_id: @account_id
    })
    |> Repo.insert!()
  end

  defp delivery! do
    {:ok, endpoint, _secret} =
      WebhookEndpoints.create(%{
        url: "https://hooks.example.com/events",
        account_id: @account_id
      })

    WebhookDeliveries.insert!(endpoint, event().id)
  end

  defp attempt(status) do
    # Move the window forward rather than waiting for it. The backoff is asserted
    # as a recorded value in `Courier.WebhookDeliveriesTest`; what is left to
    # observe here is the *count*, and a count cannot be watched across a
    # sixteen-hour schedule.
    WebhookDelivery
    |> Ecto.Query.where([delivery], not is_nil(delivery.next_attempt_at))
    |> Repo.update_all(set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)])

    answer_with(%{response_status: status})
    perform_job(DeliverWebhookWorker, %{})
  end

  defp config, do: Application.get_env(:courier, :webhooks)

  test "a delivery is attempted exactly max_attempts times, and then not again" do
    delivery = delivery!()

    Enum.each(1..config()[:max_attempts], fn n ->
      Sender.reset()
      assert {:ok, %{sent: 1}} = attempt(500), "attempt #{n} must be made"
    end)

    recorded = Repo.get!(WebhookDelivery, delivery.id)
    assert recorded.attempt == config()[:max_attempts]
    assert recorded.status == :exhausted
    assert recorded.next_attempt_at == nil

    # The last attempt is the cap, not one past it. A worker run after the budget
    # is spent must not send anything.
    Sender.reset()
    assert {:ok, %{sent: 0}} = perform_job(DeliverWebhookWorker, %{})

    assert Sender.last() == nil
    assert Repo.get!(WebhookDelivery, delivery.id).attempt == config()[:max_attempts]
  end

  test "the endpoint is still enabled when the budget runs out, because the circuit is a separate bound" do
    delivery = delivery!()

    Enum.each(1..config()[:max_attempts], fn _n -> attempt(500) end)

    endpoint_id = Repo.get!(WebhookDelivery, delivery.id).endpoint_id

    assert Repo.get!(WebhookEndpoint, endpoint_id).status == :enabled
  end

  test "the same webhook_id is used on every one of the budget's attempts" do
    delivery = delivery!()

    ids =
      Enum.map(1..config()[:max_attempts], fn _n ->
        attempt(500)
        Sender.last().headers["webhook-id"]
      end)

    # One id for the whole budget. A consumer deduplicating on it sees one event
    # however many times courier retried, which is the whole reason the spec says
    # the id "remains the same no matter how many times a webhook that has failed
    # is retried".
    assert length(Enum.uniq(ids)) == 1
    assert [id] = Enum.uniq(ids)
    assert id == delivery.webhook_id
  end
end
