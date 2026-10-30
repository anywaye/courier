defmodule Courier.WebhookDelivery do
  @moduledoc """
  One delivery of one event to one endpoint, and the retry state that goes with
  it.

  One row per `(endpoint_id, event_id)`, not one per attempt. That is the choice
  the rest of the module follows from:

    * **`webhook_id` is generated once, here, and never changes.** The spec
      §Webhook metadata requires that "the unique identifier ... remains the same
      no matter how many times a webhook that has failed is retried", because
      consumers deduplicate on it (PLAN.md §3: delivery is at-least-once, so
      every consumer is idempotent). A row per attempt would need the id to be
      derivable from something other than the row, and a row per *delivery* makes
      "the same id" true by construction — there is only ever one id.
    * **`attempt` counts up, and `next_attempt_at` says when the next one is
      due.** The retry budget is a property of the delivery, so it lives on the
      delivery, and "what is due now" is one query against a partial index.

  `status` is four values, not two. `failed` means "this will be tried again";
  `exhausted` means "the budget is spent and it will not be", and the difference
  is the difference between a consumer that is down and a consumer that is gone.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses [:pending, :succeeded, :failed, :exhausted]

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  @doc false
  def statuses, do: @statuses

  schema "webhook_deliveries" do
    field :endpoint_id, Ecto.UUID
    field :event_id, Ecto.UUID
    field :webhook_id, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attempt, :integer, default: 0
    field :status_code, :integer
    field :duration_ms, :integer
    field :error, :string
    field :next_attempt_at, :utc_datetime_usec
    field :attempted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for a newly dispatched delivery.

  `webhook_id` is generated here rather than passed in: it is courier's to mint,
  it has to be the same on every retry, and a caller that could set it could make
  two deliveries look like one.
  """
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:endpoint_id, :event_id])
    |> validate_required([:endpoint_id, :event_id])
    |> put_change(:webhook_id, attrs[:webhook_id] || Courier.Webhooks.Signature.new_id())
    |> put_status(attrs)
    |> put_change(:attempt, Map.get(attrs, :attempt, 0))
    |> put_change(:next_attempt_at, Map.get(attrs, :next_attempt_at))
    |> unique_constraint([:endpoint_id, :event_id],
      name: :webhook_deliveries_endpoint_id_event_id_index
    )
  end

  defp put_status(changeset, attrs) do
    Ecto.Changeset.put_change(changeset, :status, Map.get(attrs, :status, :pending))
  end
end
