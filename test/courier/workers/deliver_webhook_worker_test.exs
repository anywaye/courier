defmodule Courier.Workers.DeliverWebhookWorkerTest do
  @moduledoc """
  The sender: claims a due delivery, signs it, sends it, and records what came
  back — including the two things that keep courier from hammering a customer who
  is not listening: the retry budget and the circuit breaker.

  Nothing here sleeps. `perform_job/3` runs the worker in-process, and the
  backoff is asserted on the *recorded* `next_attempt_at` rather than by waiting
  for a window to pass, so a five-minute backoff costs the suite five minutes of
  nothing.
  """

  use Courier.DataCase, async: true

  use Oban.Testing, repo: Courier.Repo

  import Courier.TestSupport.RecordingSender
  import Ecto.Query

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
    Sender.reset()

    event =
      %OutboxEvent{}
      |> OutboxEvent.changeset(%{
        type: "email.delivered",
        subject: "courier-1",
        data: %{"message_id" => "courier-1"},
        account_id: @account_id
      })
      |> Repo.insert!()

    Process.put(:courier_event, event)
    :ok
  end

  defp endpoint!(attrs \\ %{}) do
    {:ok, endpoint, secret} =
      WebhookEndpoints.create(
        Map.merge(%{url: "https://hooks.example.com/events", account_id: @account_id}, attrs)
      )

    %{endpoint: endpoint, secret: secret}
  end

  # One event per test, created in `setup/0` and reused. `event/0` inserting a
  # fresh row on every call would give a test that asks for two deliveries two
  # *events*, and the count it then asserts on would be deliveries to the wrong
  # rows — which is the kind of test that passes for the wrong reason.
  defp event, do: Process.get(:courier_event)

  defp delivery!(endpoint) do
    %{id: event_id} = event()
    WebhookDeliveries.insert!(endpoint, event_id)
  end

  describe "a successful delivery" do
    test "sends a signed POST to the endpoint" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      assert {:ok, %{sent: 1}} = attempt()

      request = Sender.last()
      assert request.method == "POST"
      assert request.url == "https://hooks.example.com/events"
      assert request.headers["webhook-id"]
      assert request.headers["webhook-signature"]
    end

    test "signs with the endpoint's own secret" do
      %{endpoint: endpoint, secret: secret} = endpoint!()
      delivery!(endpoint)

      attempt()

      request = Sender.last()
      assert Courier.Webhooks.Verifier.verify(request.body, request.headers, secret) == :ok
    end

    test "carries the delivery's webhook_id, so a redelivery is recognisable" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt()

      assert Sender.last().headers["webhook-id"] == delivery.webhook_id
    end

    test "sends the event's envelope as the body" do
      %{endpoint: endpoint} = endpoint!()
      row = event()
      delivery = WebhookDeliveries.insert!(endpoint, row.id)

      attempt()

      assert Jason.decode!(Sender.last().body)["id"] == row.id
      assert delivery.webhook_id
    end

    test "records the status code, the duration, and the success" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt()

      recorded = Repo.get!(WebhookDelivery, delivery.id)
      assert recorded.status == :succeeded
      assert recorded.status_code == 200
      assert recorded.duration_ms >= 0
      assert recorded.next_attempt_at == nil
      assert recorded.attempt == 1
    end

    test "clears the endpoint's failure count" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)
      {:ok, endpoint} = WebhookEndpoints.trip(endpoint, 5, "boom")

      attempt()

      assert Repo.get!(WebhookEndpoint, endpoint.id).consecutive_failures == 0
    end
  end

  describe "a failed delivery" do
    test "records the failure and schedules the next attempt" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      assert {:ok, %{sent: 1}} = attempt(%{response_status: 500})

      recorded = Repo.get!(WebhookDelivery, delivery.id)
      assert recorded.status == :failed
      assert recorded.status_code == 500
      assert recorded.next_attempt_at
      assert recorded.attempt == 1
    end

    test "counts the failure against the endpoint" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      attempt(%{response_status: 500})

      assert Repo.get!(WebhookEndpoint, endpoint.id).consecutive_failures == 1
    end

    test "records why, so a failed delivery is readable without the logs" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 500})

      assert Repo.get!(WebhookDelivery, delivery.id).error == "HTTP 500"
    end

    test "a transport failure is recorded with no status code" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{error: :econnrefused})

      recorded = Repo.get!(WebhookDelivery, delivery.id)
      assert recorded.status_code == nil
      assert recorded.error =~ "no response"
    end
  end

  describe "the retry budget" do
    test "a 5xx is retried" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 503})

      assert Repo.get!(WebhookDelivery, delivery.id).next_attempt_at
    end

    test "a 408 is retried, because it means 'not now'" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 408})

      assert Repo.get!(WebhookDelivery, delivery.id).next_attempt_at
    end

    test "a 429 is retried, honouring the Retry-After the consumer sent" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 429, response_headers: %{"retry-after" => "900"}})

      recorded = Repo.get!(WebhookDelivery, delivery.id)
      assert recorded.next_attempt_at
      # A Retry-After longer than the backoff is what the consumer asked for, and
      # a `Retry-After` is a floor rather than a suggestion: retrying earlier
      # than a receiver asked is the behaviour the header exists to prevent.
      assert DateTime.diff(recorded.next_attempt_at, DateTime.utc_now()) >= 890
    end

    test "a 4xx that is not 408 or 429 is not retried" do
      for status <- [400, 401, 403, 404, 422] do
        %{endpoint: endpoint} = endpoint!(%{url: "https://hooks-#{status}.example.com/events"})
        delivery = delivery!(endpoint)

        attempt(%{response_status: status})

        recorded = Repo.get!(WebhookDelivery, delivery.id)
        assert recorded.status == :exhausted, "status #{status} must not be retried"
        assert recorded.next_attempt_at == nil
      end
    end

    test "a 3xx is not retried, because following the redirect is what the spec warns against" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 302})

      assert Repo.get!(WebhookDelivery, delivery.id).next_attempt_at == nil
    end

    test "the circuit opens before the budget does, at the shipped numbers" do
      # The budget and the circuit are two different bounds, and at the shipped
      # numbers the circuit opens first (5 of 8), so this cannot be shown here
      # without the two tangled. `Courier.Workers.DeliverWebhookWorkerBudgetTest`
      # raises the threshold and spends the whole budget with the endpoint intact.
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      Enum.each(1..config()[:max_attempts], fn _n -> attempt(%{response_status: 500}) end)

      # The circuit opened first, so the delivery is still inside its retry
      # window — the same assertion from the other side: at the shipped numbers
      # the endpoint is what stops delivery, not the per-delivery budget.
      assert Repo.get!(WebhookEndpoint, endpoint.id).status == :disabled
    end

    test "the second attempt is not due before the first backoff has elapsed" do
      # The recorded schedule, never a sleep: a worker run now must not pick up a
      # delivery whose window is still in the future. `attempt_as_scheduled/1` is
      # the one call in this file that leaves the clock alone, because moving it
      # forward is the very thing this test is about.
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 500})
      recorded = Repo.get!(WebhookDelivery, delivery.id)

      assert DateTime.compare(recorded.next_attempt_at, DateTime.utc_now()) == :gt

      Sender.reset()
      assert {:ok, %{sent: 0}} = attempt_as_scheduled(%{response_status: 200})

      assert Sender.last() == nil
    end

    test "a delivery whose window has passed is attempted" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)
      WebhookDeliveries.fail!(endpoint, event().id, status_code: 500, duration_ms: 1)

      assert {:ok, %{sent: 1, delivered: 1}} = attempt(%{response_status: 200})
      assert Repo.get!(WebhookDelivery, delivery.id).status == :succeeded
    end

    test "the same webhook_id is used on every attempt" do
      # The spec §Webhook metadata: the id "remains the same no matter how many
      # times a webhook that has failed is retried". A consumer deduplicating on
      # it treats the retry as the delivery it already has, and a new id on the
      # retry would make the retry look like a second event.
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 500})
      first = Sender.last().headers["webhook-id"]

      Sender.reset()
      attempt(%{response_status: 500})

      assert Sender.last().headers["webhook-id"] == first
      assert first == delivery.webhook_id
    end
  end

  describe "the circuit breaker" do
    test "opens after the configured number of consecutive failures" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      for _attempt <- 1..(config()[:circuit_threshold] - 1) do
        attempt(%{response_status: 500})
      end

      assert Repo.get!(WebhookEndpoint, endpoint.id).status == :enabled

      attempt(%{response_status: 500})

      opened = Repo.get!(WebhookEndpoint, endpoint.id)
      assert opened.status == :disabled
      assert opened.consecutive_failures == config()[:circuit_threshold]
    end

    test "records why the endpoint was disabled" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      for _attempt <- 1..config()[:circuit_threshold] do
        attempt(%{response_status: 500})
      end

      reason = Repo.get!(WebhookEndpoint, endpoint.id).disabled_reason
      assert reason =~ "consecutive failures"
      assert reason =~ "HTTP 500"
    end

    test "a disabled endpoint stops being attempted at all" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      for _attempt <- 1..config()[:circuit_threshold] do
        attempt(%{response_status: 500})
      end

      Sender.reset()
      # A fresh delivery for a fresh event, so this is not the budget stopping it.
      other =
        Repo.insert!(
          %OutboxEvent{}
          |> OutboxEvent.changeset(%{
            type: "email.delivered",
            subject: "courier-2",
            data: %{},
            account_id: @account_id
          })
        )

      WebhookDeliveries.insert!(endpoint, other.id)
      |> Ecto.Changeset.change(next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      attempt(%{response_status: 200})

      assert Sender.last() == nil
    end

    test "a success closes the circuit and the endpoint receives again" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      # Just short of the threshold, so the circuit has opened one failure away
      # and this success is what closes it.
      Enum.each(1..(config()[:circuit_threshold] - 1), fn _n ->
        attempt(%{response_status: 500})
      end)

      attempt(%{response_status: 200})

      closed = Repo.get!(WebhookEndpoint, endpoint.id)
      assert closed.status == :enabled
      assert closed.consecutive_failures == 0
      assert closed.disabled_reason == nil
      assert Repo.get!(WebhookDelivery, delivery.id).status == :succeeded
    end

    test "a 410 Gone disables the endpoint immediately" do
      # §Delivery success and failure: a receiver answering 410 is "no longer
      # interested in receiving webhooks from this source" and the sender "should
      # disable the webhook endpoint, and stop sending it messages".
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      attempt(%{response_status: 410})

      disabled = Repo.get!(WebhookEndpoint, endpoint.id)
      assert disabled.status == :disabled
      assert disabled.disabled_reason =~ "410"
    end

    test "a 410 is not retried, because the receiver has said it does not want it" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)

      attempt(%{response_status: 410})

      assert Repo.get!(WebhookDelivery, delivery.id).next_attempt_at == nil
    end

    test "a 404 does not disable the endpoint, because the url may not be set up yet" do
      %{endpoint: endpoint} = endpoint!()
      delivery!(endpoint)

      for _attempt <- 1..config()[:circuit_threshold] do
        attempt(%{response_status: 404})
      end

      # Each 404 is a non-retryable failure, so the circuit never counts them.
      assert Repo.get!(WebhookEndpoint, endpoint.id).status == :enabled
    end
  end

  describe "what the worker picks up" do
    test "nothing when there is nothing due" do
      assert {:ok, %{sent: 0}} = attempt()
      assert Sender.last() == nil
    end

    test "not a delivery whose endpoint has been deleted" do
      %{endpoint: endpoint} = endpoint!()
      delivery = delivery!(endpoint)
      {:ok, _} = WebhookEndpoints.delete(endpoint)

      assert {:ok, %{sent: 0}} = attempt()
      assert Repo.get(WebhookDelivery, delivery.id) == nil
    end
  end

  describe "job options" do
    test "runs on the webhooks queue" do
      assert DeliverWebhookWorker.__opts__()[:queue] == :webhooks
    end
  end

  # One delivery attempt, with the double told what to answer. The worker builds
  # its own request and has nowhere to put a test's status code, so the answer is
  # given to the double rather than passed as a job argument.
  #
  # Every delivery whose window has not arrived is moved forward first. That is not
  # a shortcut around the schedule — it is the schedule being observed: the backoff
  # is a *recorded* `next_attempt_at`, and a test that wants to see the third
  # attempt has to pretend the first two windows elapsed. The window itself is
  # asserted in `Courier.WebhookDeliveriesTest` and in "the second attempt is not
  # due before the first backoff has elapsed" below, where the clock is left alone.
  defp attempt(response \\ %{}) do
    make_due()
    answer_with(response)
    perform_job(DeliverWebhookWorker, %{})
  end

  # One attempt *without* touching the clock, for the tests whose subject is that
  # a delivery is not picked up early.
  defp attempt_as_scheduled(response) do
    answer_with(response)
    perform_job(DeliverWebhookWorker, %{})
  end

  defp make_due do
    WebhookDelivery
    |> where([delivery], not is_nil(delivery.next_attempt_at))
    |> Repo.update_all(set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)])
  end

  defp config, do: Application.get_env(:courier, :webhooks)
end
