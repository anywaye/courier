defmodule Courier.Consumers.PaymentFailed do
  @moduledoc """
  `billing.payment.failed` → the warning a person is owed when their money did
  not move.

  ## THE SIBLING OF THE RECEIPT, AND WHY IT EXISTS AT ALL

  A settled payment already has its mail (`Courier.Consumers.PaymentSucceeded`).
  This is the other half of the same event family: billing publishes
  `billing.payment.failed` from the same `payment_emission` builder when the
  processor says an attempt failed — a declined card, an abandoned 3-D Secure
  challenge — and until this handler existed, the event reached the bus and
  nobody acted on it. A card that quietly stops working is revenue that stops
  arriving with nobody told, which is the one money event a person must hear
  about.

  The payload is the same normalized invoice event as the receipt's, read
  there and not re-derived here: `customer_id`, `anywaye_customer_id`,
  `subscription_id`, `invoice_id`, `payment_intent_id`, `paid: false`,
  `amount: {"amount_minor", "currency"}`, `attempt_count`,
  `next_payment_attempt`, plus the recipient fact `with_recipient` merges in,
  `email`. This handler reads the same four fields the receipt's does and no
  others: the address, the amount, the invoice to name, and the payer to
  attribute the send to.

  **The retry schedule is deliberately not in the mail.** The payload carries
  `next_payment_attempt` and this handler ignores it, because rendering it
  would make courier compute a date — a locale-sensitive presentation
  decision this repository has no concept for, and a promise about a schedule
  the processor owns (the retry policy lives in Stripe's dashboard, not in
  this fleet). The mail's job is the fact and the remedy.

  ## THE ALLOWANCE, SAID RATHER THAN HIDDEN

  A failure is not always final: the processor retries on its own schedule,
  and a renewed card mid-retry is a subscription that never lapses. So the
  copy asks for the update without announcing an ending it cannot see, and the
  amount named is the amount of the attempt that failed.

  ## THE HANDLER TAKES THE ROW, AND ATTRIBUTES LIKE ITS SIBLING

  `handle/1` is given the `consumed_events` row — byte for byte the payload
  courier stored, including on a redelivery. And the send is attributed to the
  anywaye CUSTOMER rather than a user, for the reason the receipt's moduledoc
  gives in full: the money event names a customer, courier looks nothing up,
  and the three checks in `Courier.Deliver` that are about the address still
  run unchanged.
  """

  alias Courier.ConsumedEvent
  alias Courier.Deliver

  @type warning :: %{
          required(:email) => String.t(),
          required(:amount_display) => String.t(),
          # nil for a Checkout-backed one-off, which no invoice names.
          required(:invoice_id) => String.t() | nil,
          # The anywaye customer the failed payment was for, carried as the
          # send's attribution. See the moduledoc.
          required(:payer) => String.t()
        }

  @event_type "billing.payment.failed"

  @doc """
  The type this handler is for. Named as a function rather than only as the
  attribute because the two must be the same string, and a test asserting
  they are is cheaper than a refactor that changes one.
  """
  @spec type() :: String.t()
  def type, do: @event_type

  @doc """
  Parses one delivered `consumed_events` row, sends the warning, or refuses.

  The shape is the receipt handler's, arm for arm, and that is the point: the
  two events are built by one builder in billing, so a field this refuses and
  the receipt handler accepts would be the two halves of one payload
  disagreeing. `handle/1` is the registry's contract — `{:ok, _}` marks the
  row handled — and the refusals are:
  `{:error, :unreadable_envelope}`, `{:error, :not_this_event}` and
  `{:error, {:incomplete_payload, field}}` for the recipient, the payer or
  the amount.
  """
  @spec handle(ConsumedEvent.t() | map()) :: {:ok, term()} | {:error, term()}
  def handle(row) do
    with {:ok, warning} <- parse(row), do: deliver(warning)
  end

  @doc """
  Parses one row into a warning, or refuses it. Public because every arm
  below is a refusal that must happen before anything is dialled.
  """
  @spec parse(ConsumedEvent.t() | map()) :: {:ok, warning()} | {:error, term()}
  def parse(%ConsumedEvent{id: id} = event) when is_binary(id) and id != "" do
    with :ok <- fetch_type(event),
         {:ok, data} <- fetch_data(event),
         {:ok, email} <- fetch_email(data),
         {:ok, payer} <- fetch_payer(data),
         {:ok, amount} <- fetch_amount(data) do
      {:ok,
       %{email: email, amount_display: render(amount), invoice_id: invoice_of(data), payer: payer}}
    end
  end

  def parse(%ConsumedEvent{}), do: {:error, :unreadable_envelope}
  def parse(_not_a_row), do: {:error, :unreadable_envelope}

  @doc """
  Sends the warning, or passes `Courier.Deliver`'s answer through.
  """
  @spec deliver(warning()) :: {:ok, map()} | {:error, term()}
  def deliver(warning) do
    Deliver.email("payment_failed", %{
      "email" => warning.email,
      "user_id" => warning.payer,
      "amount_display" => warning.amount_display,
      "invoice_id" => warning.invoice_id
    })
  end

  ## ---------------------------------------------------------------------
  ## The payload, one field at a time
  ## ---------------------------------------------------------------------

  defp fetch_type(%ConsumedEvent{type: @event_type}), do: :ok
  defp fetch_type(%ConsumedEvent{}), do: {:error, :not_this_event}

  defp fetch_data(%ConsumedEvent{data: data}) when is_map(data) do
    if map_size(data) == 0, do: {:error, {:incomplete_payload, "data"}}, else: {:ok, data}
  end

  defp fetch_data(%ConsumedEvent{}), do: {:error, {:incomplete_payload, "data"}}

  # The recipient: a warning nobody can be sent is not a warning, and an event
  # with no address on it (a customer created in the processor's dashboard,
  # or one whose email was never set) is refused rather than guessed at.
  defp fetch_email(data) do
    case Map.fetch(data, "email") do
      {:ok, email} when is_binary(email) and email != "" -> {:ok, email}
      _missing_or_wrong_shape -> {:error, {:incomplete_payload, "email"}}
    end
  end

  # The failed attempt's amount, in the same integer-minor-units shape the
  # receipt handler renders: `{"amount_minor" => 1900, "currency" => "USD"}`,
  # both halves required.
  defp fetch_amount(data) do
    case Map.fetch(data, "amount") do
      {:ok, %{"amount_minor" => minor, "currency" => currency}}
      when is_integer(minor) and is_binary(currency) and currency != "" ->
        {:ok, {minor, currency}}

      _missing_or_wrong_shape ->
        {:error, {:incomplete_payload, "amount"}}
    end
  end

  # The anywaye customer the failed payment was for. Required: it is the
  # identifier `Courier.Deliver` attributes the send to, exactly as on the
  # receipt.
  defp fetch_payer(data) do
    case Map.fetch(data, "anywaye_customer_id") do
      {:ok, payer} when is_binary(payer) and payer != "" -> {:ok, payer}
      _missing_or_wrong_shape -> {:error, {:incomplete_payload, "anywaye_customer_id"}}
    end
  end

  # The processor's invoice id, when the failed attempt came with one —
  # optional by design, the same arm as the receipt's: a one-off
  # Checkout-backed attempt has no invoice, and refusing it would drop a
  # warning the platform legitimately produces.
  defp invoice_of(data) do
    case Map.fetch(data, "invoice_id") do
      {:ok, invoice_id} when is_binary(invoice_id) and invoice_id != "" -> invoice_id
      _absent_null_or_something_else -> nil
    end
  end

  ## ---------------------------------------------------------------------
  ## The figure
  ## ---------------------------------------------------------------------

  # Through the one renderer the payment family shares
  # (`Courier.Consumers.AmountDisplay`): billing builds this event and the
  # receipt with one `amount` shape, and one figure must not read two ways.
  @spec render({integer(), String.t()}) :: String.t()
  defdelegate render(amount), to: Courier.Consumers.AmountDisplay
end
