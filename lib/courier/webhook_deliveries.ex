defmodule Courier.WebhookDeliveries do
  @moduledoc """
  The delivery record and the retry budget around it.


  PLAN.md §7 adopted bounded budgets and forbade naive retries, so the numbers
  here are the packet's answer and every one of them is configuration rather than
  a constant in a worker:

  | | value | why |
  | --- | --- | --- |
  | attempts | 8 | bounded, and the row stops being claimable at the cap rather than being retried forever |
  | first wait | 5 min | long enough not to be a hot loop against a consumer that just failed |
  | growth | doubling | the spec §Deliverability asks for "an exponential backoff" |
  | cap | 6 h | a consumer that comes back overnight is picked up; one that is gone stops costing anything |
  | jitter | ¼ of the wait | the spec asks for jitter "to prevent cases where the failures are due to recurring load caused by the webhook attempts themselves" |
  | total | ≈16 h | the spec's "spanning multiple days" in a shape one service can defend |


  This is the detail that matters and the one that is easy to get wrong. Jitter
  added to an exponential schedule can make attempt N+1's wait *shorter* than
  attempt N's — a consumer under load then gets hammered at a rate that
  increases with every attempt, which is precisely the failure the spec's jitter
  recommendation exists to prevent. So the jitter is drawn from `0..base/4` and
  added to a wait that is already ≥ the previous attempt's floor, and the ordering
  property is asserted in the test rather than assumed.


  Per the spec §Delivery success and failure and the brief: a `4xx` other than
  `408` and `429` is a failure that will fail again, so it is recorded and the
  budget is not spent on it. `410 Gone` additionally disables the endpoint — the
  spec is unambiguous that a consumer answering `410` "is no longer interested in
  receiving webhooks from this source" and the sender "should disable the webhook
  endpoint". `3xx` is a failure with no retry: the spec says following redirects
  "causes unnecessary load on both the sender and the receiver" and the customer
  should update the url instead.
  """

  import Ecto.Query

  alias Courier.Repo
  alias Courier.WebhookDelivery
  alias Courier.WebhookEndpoint

  @type result :: {:ok, WebhookDelivery.t()} | {:error, term()}

  @doc """
  Records a new delivery for `(endpoint, event_id)`, or the one that is already
  there.

  Idempotent by design: a re-dispatched event must not create a second delivery
  for an endpoint, and the `webhook_id` of the existing row is what the retry
  will keep using.
  """
  @spec insert!(WebhookEndpoint.t(), Ecto.UUID.t(), keyword()) :: WebhookDelivery.t()
  def insert!(%WebhookEndpoint{} = endpoint, event_id, attrs \\ []) do
    result =
      %WebhookDelivery{}
      |> WebhookDelivery.changeset(
        attrs
        |> Map.new()
        |> Map.merge(%{endpoint_id: endpoint.id, event_id: event_id})
      )
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:endpoint_id, :event_id]
      )

    case result do
      _inserted_or_conflicted ->
        case existing(endpoint.id, event_id) do
          %WebhookDelivery{} = delivery ->
            delivery

          nil ->
            raise ArgumentError,
                  "webhook delivery for endpoint #{endpoint.id} and event #{event_id} is not in the table after an insert"
        end
    end
  end

  @doc """
  The delivery for `(endpoint_id, event_id)`, if there is one.
  """
  @spec existing(Ecto.UUID.t(), Ecto.UUID.t()) :: WebhookDelivery.t() | nil
  def existing(endpoint_id, event_id) do
    Repo.get_by(WebhookDelivery, endpoint_id: endpoint_id, event_id: event_id)
  end

  @doc """
  Deliveries whose `next_attempt_at` has arrived, oldest first, `limit` of them.
  """
  @spec due(pos_integer()) :: [WebhookDelivery.t()]
  def due(limit) do
    now = DateTime.utc_now()

    WebhookDelivery
    |> where([delivery], delivery.status in [:pending, :failed])
    |> where([delivery], is_nil(delivery.next_attempt_at) or delivery.next_attempt_at <= ^now)
    |> order_by([delivery], asc: delivery.inserted_at, asc: delivery.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Whether `delivery` is due and still has budget.

  The two halves are the whole policy: a delivery past the cap is left alone
  (core's outbox spec: "past the cap, alert and leave the row alone"), and one
  whose window has not arrived is not touched early.
  """
  @spec claimable?(WebhookDelivery.t()) :: boolean()
  def claimable?(%WebhookDelivery{} = delivery) do
    delivery.status in [:pending, :failed] and delivery.attempt < config()[:max_attempts] and
      due_now?(delivery)
  end

  defp due_now?(%WebhookDelivery{next_attempt_at: nil}), do: true

  defp due_now?(%WebhookDelivery{next_attempt_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  @doc """
  Records a successful attempt: the status code, how long it took, and an end.

  `attempt` is read from the row and incremented here, never taken from `attrs`.
  The caller is a worker that has just sent a request; it does not know how many
  have gone before, and an attempt number passed in from outside is an attempt
  number that can disagree with the row and hand a delivery a second budget.
  """
  @spec succeed!(WebhookEndpoint.t(), Ecto.UUID.t(), keyword()) :: WebhookDelivery.t()
  def succeed!(%WebhookEndpoint{} = endpoint, event_id, attrs) do
    record(endpoint, event_id, fn delivery ->
      delivery
      |> Ecto.Changeset.change(
        status: :succeeded,
        status_code: Keyword.get(attrs, :status_code),
        duration_ms: Keyword.get(attrs, :duration_ms),
        error: nil,
        next_attempt_at: nil,
        attempted_at: DateTime.utc_now(),
        attempt: delivery.attempt + 1
      )
    end)
  end

  @doc """
  Records a failed attempt and schedules the next one.

  `retryable?` says whether the attempt is worth repeating at all — a `404` is
  not, and spending sixteen hours of budget on a url that will keep answering
  `404` is a way of not noticing that the customer changed their endpoint.

  A non-retryable failure, and a retryable one that has used its budget, both end
  as `:exhausted` with no `next_attempt_at`. They are the same row state for the
  same reason: nothing further will happen without a human.
  """
  @spec fail!(WebhookEndpoint.t(), Ecto.UUID.t(), keyword()) :: WebhookDelivery.t()
  def fail!(%WebhookEndpoint{} = endpoint, event_id, attrs) do
    record(endpoint, event_id, fn delivery ->
      attempt = delivery.attempt + 1
      retryable? = Keyword.get(attrs, :retryable?, true)
      retry_after = Keyword.get(attrs, :retry_after)

      changes =
        [
          status_code: Keyword.get(attrs, :status_code),
          duration_ms: Keyword.get(attrs, :duration_ms),
          error: Keyword.get(attrs, :error),
          attempted_at: DateTime.utc_now(),
          attempt: attempt
        ]
        |> put_next_attempt(attempt, retryable?, retry_after)

      Ecto.Changeset.change(delivery, changes)
    end)
  end

  defp put_next_attempt(changes, attempt, retryable?, retry_after) do
    if retryable? and attempt < config()[:max_attempts] do
      Keyword.merge(changes,
        status: :failed,
        next_attempt_at: DateTime.add(DateTime.utc_now(), wait(attempt, retry_after), :second)
      )
    else
      Keyword.merge(changes, status: :exhausted, next_attempt_at: nil)
    end
  end

  defp wait(attempt, retry_after) do
    scheduled = backoff(attempt)

    case retry_after do
      seconds when is_integer(seconds) and seconds > 0 ->
        max(scheduled, min(seconds, config()[:backoff_cap_seconds]))

      _absent ->
        scheduled
    end
  end

  @doc """
  How long to wait before attempt `attempt + 1`, in seconds.

  Exponential in the attempt from the configured base, capped, and jittered
  within a quarter of the base. Pass `jitter: false` for the exact schedule —
  which is what the test that asserts the recorded numbers does, and what a
  support conversation about "when did you retry" needs.
  """
  @spec backoff(pos_integer(), keyword()) :: pos_integer()
  def backoff(attempt, opts \\ []) do
    wait =
      attempt
      |> max(1)
      |> Kernel.-(1)
      |> then(&(config()[:backoff_base_seconds] * Integer.pow(2, &1)))
      |> min(config()[:backoff_cap_seconds])

    if Keyword.get(opts, :jitter, true) do
      jitter(wait)
    else
      wait
    end
  end

  defp jitter(wait) do
    headroom = config()[:backoff_cap_seconds] - wait

    if headroom > 0 do
      wait + :rand.uniform(min(div(wait, config()[:jitter_divisor]), headroom))
    else
      wait
    end
  end

  @doc """
  The whole schedule, for documentation and for the tests that assert it.
  """
  @spec schedule() :: [pos_integer()]
  def schedule do
    for attempt <- 1..config()[:max_attempts], do: backoff(attempt, jitter: false)
  end

  defp record(%WebhookEndpoint{} = endpoint, event_id, change) do
    delivery =
      case existing(endpoint.id, event_id) do
        nil -> insert!(endpoint, event_id)
        delivery -> delivery
      end

    delivery |> change.() |> Repo.update!()
  end

  defp config, do: Application.get_env(:courier, :webhooks, [])
end
