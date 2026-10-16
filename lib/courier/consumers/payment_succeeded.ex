defmodule Courier.Consumers.PaymentSucceeded do
  @moduledoc """
  `billing.payment.succeeded` → the receipt a person is owed when money moves.

  ## THE EVENT, AND WHY THIS HANDLER CAN ACT ON IT

  billing publishes this from `Webhooks::StripeEvents.payment_emission`, in the
  same transaction as the charge it records — an event without a charge
  announces a payment nobody took, and a charge without the event is money in
  billing's ledger the person was never told about. The payload carries the
  settled amount as integer minor units plus a currency, the recipient
  (`email`), and the processor's invoice id when the payment came with one.

  **Measured in billing, not re-derived here.** The whole of the wire shape is
  the normalized invoice event — `customer_id`, `cafaye_customer_id`,
  `subscription_id`, `invoice_id`, `payment_intent_id`, `paid`, `amount`,
  `attempt_count` — plus the one field `with_recipient` adds, `email`, which
  exists precisely because of the fleet's consumer design: courier has no
  billing client and no billing tables (REPORT-courier-consumer-invite-01.md
  §2.6), so an event with no address on it is one nobody can mail. This is the
  subscription that field was put there for.

  ## THE AMOUNT ARRIVES RENDERED, AND THIS IS THE MODULE THAT RENDERS IT

  The event carries `amount: {"amount_minor" => 1900, "currency" => "USD"}` —
  integer minor units, which is how every number in this fleet crosses a wire.
  Courier has no Money concept: no money module, no currency table, and the
  templates must never compute. So THIS consumer renders the figure into a
  display string (`19.00 USD`) and the template prints it, which is the same
  direction as the checkouts and invoices in every other service: the amount
  is decided in one place, here, and a consumer on the other end gets a
  figure it can put in front of a person.

  The decimal places come from a small zero-decimal table (JPY, KRW, CLP and
  VND are the currencies that have no minor unit) and default to 2. The
  default is the safe direction precisely because it is only a count: a
  wrong count produces a receipt with a decimal point in it, which a reader
  notices and which no money moved over. A currency this table does not name
  is still a receipt.

  ## THE INVOICE ID IS THE ONE OPTIONAL FIELD, AND THAT IS DELIBERATE

  An invoice-backed payment carries `invoice_id`; a Checkout-backed one-off
  does not — there is no invoice to reference. Refusing the send for that
  shape would drop receipts for payments the platform legitimately produces,
  so the handler passes the reference through when it is present and the
  template renders that line only when it has one. The second refusal of its
  own is therefore not about the id at all: {:error, {:incomplete_payload,
  field}} is about the recipient and the amount, the two things a receipt
  cannot exist without.

  ## THE HANDLER TAKES THE ROW, NOT THE ENVELOPE

  `handle/1` is given the `consumed_events` row rather than the envelope as it
  arrived — the same principle as every other consumer in this repository:
  the payload a handler acts on is byte for byte the payload courier stored,
  including on a redelivery days later.

  ## WHO A RECEIPT IS ABOUT: THE CUSTOMER, NOT A USER

  `Courier.Deliver` attributes a send to a user, and the money event names no
  USER — it names the cafaye CUSTOMER the money moved for. Billing has no
  users: its `customers` row is account-owned, whose id is what the event
  carries as `cafaye_customer_id`, and the platform's consumer rule forbids
  looking people up anywhere (REPORT-courier-consumer-invite-01.md §2.6), so
  neither the user nor their address can be derived from an account.

  So the payer's customer id is the identifier this handler attributes the
  send to, and every check in `Deliver` still runs — three of the four
  questions are about the ADDRESS and the type, not the person:

    * preference: a customer id has no stored preference and the default is
      enabled, so a receipt is sent unless a person turns it off;
    * per-type unsubscribe: vacuous — a `:transactional` type carries no
      unsubscribe header, so nothing can have recorded one;
    * mailbox suppression: unchanged and the load-bearing one — a hard bounce
      or a complaint still stops the receipt.

  The tension is stated rather than hidden: the `courier.email.delivered`
  event's `user_id` carries the CUSTOMER's id for this one type, which is the
  payer, not a person with settings. A `payer_identity` field core owned would
  be the honest fix and is reported in
  `REPORT-courier-consumer-paymentreceipt-01.md`.

  ## THE CORE ENUM GAP, REPORTED AND NOT APPLIED

  Adding `receipt` to `Courier.Mailers.types/0` means the
  `courier.email.delivered` event's `data.notification_type` can carry an
  eighth value, and `core/schemas/events/courier/email/delivered.schema.json`
  freezes that field to the seven names courier sent when core last froze it.
  The switch is one row in `Courier.Mailers` plus one enum value in core, and
  core is not this repository's to change:
  `REPORT-courier-consumer-paymentreceipt-01.md`.
  """

  alias Courier.ConsumedEvent
  alias Courier.Deliver

  @type receipt :: %{
          required(:email) => String.t(),
          required(:amount_display) => String.t(),
          # nil for a Checkout-backed one-off, which no invoice names.
          required(:invoice_id) => String.t() | nil,
          # The cafaye customer the money moved for, carried as the send's
          # attribution. See the moduledoc.
          required(:payer) => String.t()
        }

  @event_type "billing.payment.succeeded"

  @doc """
  The type this handler is for. Named as a function rather than only as the
  attribute because the two must be the same string, and a test asserting
  they are is cheaper than a refactor that changes one.
  """
  @spec type() :: String.t()
  def type, do: @event_type

  @doc """
  Parses one delivered `consumed_events` row, sends the receipt, or refuses.

  **One function with `handle/1`, not two, and that is the registry's
  contract** — `Courier.Consumers` calls `handle/1`, treats `{:ok, _}` as
  "done" and marks the row handled on it.

  `{:ok, receipt}` or one of:

    * `{:error, :unreadable_envelope}` — a row with no `id` to attribute a
      refusal to
    * `{:error, :not_this_event}` — a type this handler is not for
    * `{:error, {:incomplete_payload, field}}` — the recipient, the amount, or
      neither of the two facts a receipt is made of

  **The shape is checked before the value is read**, and the ordering is the
  point: `to_string/1` on a map or a list would render into a receipt naming a
  string that was never there, and a refusal produced *by* the malformed
  field cannot quote it correctly.
  """
  @spec handle(ConsumedEvent.t() | map()) :: {:ok, term()} | {:error, term()}
  def handle(row) do
    with {:ok, receipt} <- parse(row), do: deliver(receipt)
  end

  @doc """
  Parses one row into a receipt, or refuses it. Public because every arm
  below is a refusal that must happen before anything is dialled.
  """
  @spec parse(ConsumedEvent.t() | map()) :: {:ok, receipt()} | {:error, term()}
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
  Sends the receipt, or passes `Courier.Deliver`'s answer through.

  `{:ok, %{message_id: _, event_id: _}}` when the payload can be rendered, and
  `Courier.Deliver`'s own refusal otherwise. This handler adds one refusal of
  its own — the incomplete payload — and nothing else.
  """
  @spec deliver(receipt()) :: {:ok, map()} | {:error, term()}
  def deliver(receipt) do
    # `user_id` is the key `Courier.Deliver` attributes a send to, and the
    # value is the cafaye CUSTOMER — see the moduledoc for why the event names
    # no user and what the three checks still are.
    Deliver.receipt(%{
      "email" => receipt.email,
      "user_id" => receipt.payer,
      "amount_display" => receipt.amount_display,
      "invoice_id" => receipt.invoice_id
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

  # The recipient. A payment event without one is a receipt nobody can be
  # sent — the customer was created in the processor's dashboard, or the
  # customer's email was never set — and billing keeps the field absent in
  # that case rather than null, so the two states arrive here the same way.
  defp fetch_email(data) do
    case Map.fetch(data, "email") do
      {:ok, email} when is_binary(email) and email != "" -> {:ok, email}
      _missing_or_wrong_shape -> {:error, {:incomplete_payload, "email"}}
    end
  end

  # The money. `{"amount_minor" => 1900, "currency" => "USD"}`, both halves
  # required: a currency with no count and a count with no currency are both
  # amounts nobody can render, and an invoice for either is a receipt nobody
  # should read.
  defp fetch_amount(data) do
    case Map.fetch(data, "amount") do
      {:ok, %{"amount_minor" => minor, "currency" => currency}}
      when is_integer(minor) and is_binary(currency) and currency != "" ->
        {:ok, {minor, currency}}

      _missing_or_wrong_shape ->
        {:error, {:incomplete_payload, "amount"}}
    end
  end

  # The cafaye customer the money moved for. Required: it is the identifier
  # `Courier.Deliver` attributes the send to, and a payment without one is a
  # payment this event does not say whose it was — the shape billing's
  # invoice-backed events always carry, and a payment-mode Checkout does not.
  defp fetch_payer(data) do
    case Map.fetch(data, "cafaye_customer_id") do
      {:ok, payer} when is_binary(payer) and payer != "" -> {:ok, payer}
      _missing_or_wrong_shape -> {:error, {:incomplete_payload, "cafaye_customer_id"}}
    end
  end

  # The processor's invoice id, when the payment came with one. Optional by
  # design — see the moduledoc — and present-as-null is treated the same as
  # absent, because a receipt that renders "nil" has rendered a bug.
  defp invoice_of(data) do
    case Map.fetch(data, "invoice_id") do
      {:ok, invoice_id} when is_binary(invoice_id) and invoice_id != "" -> invoice_id
      _absent_null_or_something_else -> nil
    end
  end

  ## ---------------------------------------------------------------------
  ## The figure
  ## ---------------------------------------------------------------------

  # The currencies with no minor unit — a number in them IS the number —
  # rather than a table of every currency's exponent. The default of 2 is a
  # count, and being wrong about a count is a receipt a reader notices.
  @zero_decimal ~w(JPY KRW CLP VND ISK)

  @spec render({integer(), String.t()}) :: String.t()
  def render({minor, currency}) do
    currency = String.upcase(currency)

    if currency in @zero_decimal do
      "#{minor} #{currency}"
    else
      whole = div(minor, 100)
      cents = rem(rem(minor, 100) + 100, 100)
      "#{whole}.#{Integer.to_string(cents) |> String.pad_leading(2, "0")} #{currency}"
    end
  end
end
