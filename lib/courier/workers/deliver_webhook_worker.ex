defmodule Courier.Workers.DeliverWebhookWorker do
  @moduledoc """
  The sender: takes a due delivery, signs it, POSTs it, and records what came
  back — then decides whether that is worth another attempt.


  Everything between "a delivery is due" and "a delivery has an outcome": the
  signature, the request, the classification of the answer, the retry schedule,
  and the circuit breaker. `Courier.WebhookDeliveries` owns the arithmetic,
  `Courier.Webhooks.Sender` owns the classification, and this is the loop that
  puts them together and updates the endpoint's state.


  | answer | delivery | endpoint |
  | ------ | -------- | -------- |
  | `2xx` | succeeded | failure count cleared, circuit closed |
  | `5xx`, `408`, `429`, no response | failed, next attempt scheduled by the backoff | failure counted; at the threshold, disabled with a reason |
  | `3xx`, other `4xx` | exhausted, no further attempts | failure counted |
  | `410 Gone` | exhausted, no further attempts | disabled immediately |

  A `410` is the one answer that ends the endpoint on its own, because the spec is
  explicit that a receiver answering it "should disable the webhook endpoint, and
  stop sending it messages". Everything else waits for the count to reach the
  threshold, because a consumer that is briefly down should not lose its endpoint
  over one bad minute.


  A delivery is attempted at most `max_attempts` times and then left alone, and
  an endpoint is disabled after `circuit_threshold` consecutive failures. Both
  are configuration. PLAN.md §7 requires bounded budgets and forbids naive
  retries, and the two bounds do different jobs: the first stops one delivery, the
  second stops all of them.


  Deliveries are claimed with `for update skip locked`, and the request is made
  inside that transaction. Holding the lock across the call is the same trade
  `Courier.Workers.ProcessOutboxWorker` makes and for the same reason: a delivery
  two workers both send is a duplicate a consumer has to recognise, and
  at-least-once already means duplicates happen. Releasing the lock before the
  call would buy throughput at the cost of the property this table exists to
  provide — one row per `(endpoint, event)`, one `webhook_id`, one attempt at a
  time.
  """

  import Ecto.Query

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.WebhookDeliveries
  alias Courier.WebhookDelivery
  alias Courier.WebhookEndpoint
  alias Courier.WebhookEndpoints
  alias Courier.Webhooks.Payload
  alias Courier.Webhooks.Sender
  alias Courier.Webhooks.Signature

  @max_attempts Application.compile_env(:courier, :webhooks)[:max_attempts]

  use Oban.Worker, queue: :webhooks, max_attempts: @max_attempts

  @doc """
  Claims the due deliveries and attempts each.

  `{:ok, %{sent: n, delivered: d, failed: f}}`. Every attempted delivery is
  recorded before this returns, including the ones that failed — a consumer's
  answer is never lost because the worker crashed afterwards.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    summary =
      config()[:delivery_batch_size]
      |> due_deliveries()
      |> Enum.reduce(%{sent: 0, delivered: 0, failed: 0}, fn delivery, summary ->
        case attempt(delivery) do
          {:delivered, result} ->
            record_success(delivery, result)
            %{summary | sent: summary.sent + 1, delivered: summary.delivered + 1}

          {:failed, result} ->
            record_failure(delivery, result)
            %{summary | sent: summary.sent + 1, failed: summary.failed + 1}

          {:skipped, %{delivery: delivery, reason: reason}} ->
            record_undeliverable(delivery, reason)
            summary
        end
      end)

    {:ok, summary}
  end

  defp due_deliveries(limit) do
    enabled_endpoint_ids =
      WebhookEndpoint
      |> where([endpoint], endpoint.status == :enabled)
      |> select([endpoint], endpoint.id)
      |> Repo.all()

    WebhookDeliveries.due(limit)
    |> Enum.filter(&(&1.endpoint_id in enabled_endpoint_ids))
    |> Enum.filter(&WebhookDeliveries.claimable?/1)
    |> lock_claimed()
  end

  defp attempt(%WebhookDelivery{} = delivery) do
    with {:ok, endpoint} <- fetch(WebhookEndpoint, delivery.endpoint_id),
         {:ok, event} <- fetch(OutboxEvent, delivery.event_id),
         {:ok, secret} <- WebhookEndpoints.secret(endpoint) do
      send_to(endpoint, delivery, event, secret)
    else
      {:error, reason} -> {:skipped, %{delivery: delivery, reason: reason}}
    end
  end

  defp send_to(endpoint, delivery, event, secret) do
    result =
      Sender.impl().send(%{
        url: endpoint.url,
        secret: secret,
        msg_id: delivery.webhook_id,
        payload: Payload.body(event),
        timestamp: Signature.unix_now()
      })

    case result do
      {:ok, %{success?: true} = result} ->
        {:delivered, %{endpoint: endpoint, delivery: delivery, result: result}}

      {:ok, result} ->
        {:failed, %{endpoint: endpoint, delivery: delivery, result: result}}

      {:error, reason} ->
        {:failed, transport_failure(endpoint, delivery, reason)}
    end
  end

  defp record_success(%WebhookDelivery{} = delivery, %{endpoint: endpoint, result: result}) do
    WebhookDeliveries.succeed!(endpoint, delivery.event_id, attempt_attrs(result))
    {:ok, _endpoint} = WebhookEndpoints.record_success(endpoint)
  end

  defp record_failure(%WebhookDelivery{} = delivery, %{endpoint: endpoint, result: result}) do
    WebhookDeliveries.fail!(
      endpoint,
      delivery.event_id,
      attempt_attrs(result,
        retryable?: Sender.retryable?(result),
        retry_after: result.retry_after_seconds
      )
    )

    if Sender.gone?(result) do
      {:ok, _endpoint} =
        WebhookEndpoints.disable(
          endpoint,
          "the receiver answered 410 Gone: it is no longer accepting webhooks"
        )
    else
      {:ok, _endpoint} =
        WebhookEndpoints.trip(endpoint, config()[:circuit_threshold], Sender.describe(result))
    end
  end

  defp record_undeliverable(%WebhookDelivery{} = delivery, reason) do
    WebhookDeliveries.fail!(endpoint_stub(delivery), delivery.event_id,
      status_code: nil,
      duration_ms: 0,
      error: "courier could not send this delivery: #{inspect(reason)}",
      retryable?: false
    )
  end

  defp endpoint_stub(%WebhookDelivery{endpoint_id: id}), do: %WebhookEndpoint{id: id}

  defp lock_claimed(deliveries) do
    ids = Enum.map(deliveries, & &1.id)

    WebhookDelivery
    |> where([delivery], delivery.id in ^ids)
    |> order_by([delivery], asc: delivery.inserted_at, asc: delivery.id)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp transport_failure(endpoint, delivery, reason) do
    %{
      endpoint: endpoint,
      delivery: delivery,
      result: %Sender.Result{success?: false, error: reason}
    }
  end

  defp attempt_attrs(result, overrides \\ []) do
    Keyword.merge(
      [
        status_code: result.status_code,
        duration_ms: result.duration_ms,
        error: Sender.describe(result)
      ],
      overrides
    )
  end

  defp fetch(schema, id) do
    case Repo.get(schema, id) do
      nil -> {:error, :missing}
      record -> {:ok, record}
    end
  end

  defp config, do: Application.get_env(:courier, :webhooks, [])
end
