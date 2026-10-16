defmodule Courier.Consumers.PaymentSucceededTest do
  @moduledoc """
  `billing.payment.succeeded` → the receipt, and the first mail courier sends
  about money.

  ## WHAT THIS FILE PROVES

  The three consumers before it were, in order, a refusal with no URL to
  recover, a notification with no address, and a notice with one. This payload
  carries the recipient AND the fact AND the settled amount, so the positive
  arm is a real send through the real `Courier.Deliver` — asserted on the
  message, not on the return value — and every refusal below is paired with
  it: a handler that refuses everything passes every refusal test, and that
  is the failure this repository has caught twice.

    * an event courier can parse is dispatched, and the receipt is sent to the
      address the payload carries;
    * the amount renders at the currency's own places — two for USD, zero for
      JPY — so the receipt names what was paid rather than its minor units;
    * an invoice-backed receipt carries the invoice id, and a Checkout-backed
      one-off without one still sends rather than being dropped;
    * a payload with no address, or no amount, is refused by name and nothing
      is sent;
    * a handler failure leaves `consumed_at` NULL, so the row is retried
      rather than dropped;
    * a redelivered envelope id is deduped at the record layer, sent exactly
      once.

  ## THE PAYLOAD, AND WHY IT IS SUFFICIENT

  billing's `Webhooks::StripeEvents.payment_emission`, measured there and not
  re-derived here: the normalized invoice event — `customer_id`,
  `cafaye_customer_id`, `subscription_id`, `invoice_id`, `payment_intent_id`,
  `paid`, `amount: {"amount_minor", "currency"}`, `attempt_count` — plus the
  recipient fact `with_recipient` merges in, `email`. The handler reads three
  of those fields and no others.

  ## THE HANDLER TAKES THE ROW

  `handle/1` is given the `consumed_events` row, not the envelope as it
  arrived. These tests build the row the subscriber would have written for
  the unit arms, and go through `Consumers.record/1` + `Consumers.consume()`
  for the integration arms, so the dedupe and the retry claims are claims
  about the loop rather than about the handler.
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Consumers.PaymentSucceeded

  # The event's payload as billing publishes it, spelled out rather than
  # minimized: the handler reads three fields, and the remaining ones are
  # here because a publisher sends them and a consumer sees them.
  @payload %{
    "kind" => "payment",
    "processor" => "stripe",
    "processor_event_id" => "evt_1UQxoTCmN780pAiWht9dbsPL",
    "customer_id" => "cus_VRrXegFhTSKs5T",
    "cafaye_customer_id" => "df15dff4-b274-460d-84e5-1ee8ba4532e7",
    "subscription_id" => "sub_1UQxoRCmN780pAiWnnZnHH5Q",
    "invoice_id" => "in_1UQxoPCmN780pAiW8Kp4oks8",
    "payment_intent_id" => "pi_3UQxoPCmN780pAiW1wrSRQIO",
    "paid" => true,
    "amount" => %{"amount_minor" => 1_900, "currency" => "USD"},
    "attempt_count" => 0,
    "email" => "buyer@example.com"
  }

  @envelope_id "9c8d7e6f-1111-4222-8333-444455556678"

  # The subject is the processor's own subscription id — billing's decision,
  # recorded there — and it is what the receipt's event is filed under.
  @subject @payload["subscription_id"]

  defp row(overrides \\ %{}) do
    struct!(
      %ConsumedEvent{
        id: @envelope_id,
        type: "billing.payment.succeeded",
        source: "billing",
        subject: @subject,
        time: ~U[2026-10-16 12:00:00.000000Z],
        attempt_count: 0,
        data: @payload
      },
      overrides
    )
  end

  defp envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => @envelope_id,
        "type" => "billing.payment.succeeded",
        "source" => "billing",
        "subject" => @subject,
        "time" => "2026-10-16T12:00:00Z",
        "data" => @payload
      },
      overrides
    )
  end

  describe "an event courier can parse" do
    test "is dispatched and the receipt is sent to the address the payload carries" do
      # The positive arm, paired with every refusal below. `handle/1` is parse
      # plus send, so the parsed fields are asserted on `parse`, and the send
      # on the message it produced.
      assert {:ok, receipt} = PaymentSucceeded.parse(row())

      assert receipt.email == "buyer@example.com"
      assert receipt.payer == "df15dff4-b274-460d-84e5-1ee8ba4532e7"
      # 1_900 minor units of USD is 19.00, rendered here rather than in the
      # template: courier has no Money concept.
      assert receipt.amount_display == "19.00 USD"
      assert receipt.invoice_id == "in_1UQxoPCmN780pAiW8Kp4oks8"

      assert {:ok, _} = PaymentSucceeded.deliver(receipt)

      assert_email_sent(fn email ->
        # Swoosh normalizes a single `{name, address}` recipient into a one-item
        # list, so the assertion is against the list.
        assert email.to == [{"", "buyer@example.com"}]
        assert email.subject == "We received your caFaye payment"
        assert email.html_body =~ "19.00 USD"
        assert email.text_body =~ "19.00 USD"
        assert email.html_body =~ "in_1UQxoPCmN780pAiW8Kp4oks8"
      end)
    end

    test "names the same type the registry is keyed on" do
      # Two strings that must be one: the handler's `type/0` and the key in
      # `config :courier, :consumers`. A refactor that changes one and not the
      # other is a message received and dropped — and the money this one
      # carries is somebody's payment.
      assert PaymentSucceeded.type() == "billing.payment.succeeded"
      assert Consumers.handler_for(PaymentSucceeded.type()) == PaymentSucceeded
    end

    test "writes the outbox row, so a sent receipt is visible to the platform" do
      assert {:ok, %{event_id: event_id}} = PaymentSucceeded.deliver(%{
        email: "buyer@example.com",
        payer: "df15dff4-b274-460d-84e5-1ee8ba4532e7",
        amount_display: "19.00 USD",
        invoice_id: "in_1UQxoPCmN780pAiW8Kp4oks8"
      })

      assert Repo.get(Courier.OutboxEvent, event_id).type == "courier.email.delivered"
    end

    test "renders a zero-decimal currency at its own places: 2400 JPY stays 2400" do
      # The one currency branch in `render/1`. A JPY receipt that read "24.00"
      # would be a receipt that names a payment nobody made.
      {:ok, receipt} =
        PaymentSucceeded.parse(row(%{data: @payload |> put_in(["amount"], %{"amount_minor" => 2_400, "currency" => "jpy"})}))

      assert receipt.amount_display == "2400 JPY"
    end

    test "a Checkout-backed one-off sends without an invoice to reference" do
      # The payment shapes: an invoice-backed payment carries `invoice_id`, a
      # one-off Checkout does not. Refusing the send for the second shape would
      # drop receipts for payments the platform legitimately produces, so the
      # handler passes it through when present and the template renders the
      # line only when it has one.
      {:ok, receipt} = PaymentSucceeded.parse(row(%{data: Map.delete(@payload, "invoice_id")}))

      assert receipt.invoice_id == nil

      assert {:ok, _} = PaymentSucceeded.deliver(receipt)

      assert_email_sent(fn email ->
        # The refute first and the assert last: a fun ending in `refute` returns
        # false, and `assert_email_sent` asserts the fun's return value — a fun
        # ending in refute fails having proved exactly what it claimed.
        refute email.html_body =~ "invoice is"
        assert email.html_body =~ "19.00 USD"
      end)
    end
  end

  describe "what is refused, and sends nothing" do
    test "a payload with no address is refused by name" do
      # A customer created in the processor's dashboard, or a cafaye customer
      # whose email was never set: billing keeps the field absent, and a
      # receipt nobody can be sent is not a receipt.
      assert {:error, {:incomplete_payload, "email"}} = PaymentSucceeded.handle(row(%{data: Map.delete(@payload, "email")}))
      assert_no_email_sent()
    end

    test "a payload naming no cafaye customer is refused by name" do
      # The send is attributed to the customer the money moved for; without it
      # the event says a payment happened and does not say whose.
      assert {:error, {:incomplete_payload, "cafaye_customer_id"}} =
               PaymentSucceeded.handle(row(%{data: Map.delete(@payload, "cafaye_customer_id")}))
      assert_no_email_sent()
    end

    test "a payload with no amount is refused by name" do
      assert {:error, {:incomplete_payload, "amount"}} =
               PaymentSucceeded.handle(row(%{data: %{@payload | "amount" => nil}}))
      assert_no_email_sent()
    end

    test "an amount with only one of its halves is refused" do
      data = %{@payload | "amount" => %{"currency" => "USD"}}

      assert {:error, {:incomplete_payload, "amount"}} = PaymentSucceeded.handle(row(%{data: data}))
      assert_no_email_sent()
    end
  end

  describe "a handler that fails" do
    test "a refusal is delivered through `Courier.Mailers` and is not this handler's vocabulary" do
      # A malformed address passes parse — it is a string — and is refused by
      # the format validation. The handler adds one refusal of its own (the
      # incomplete payload) and everything else is `Courier.Deliver`'s.
      {:ok, receipt} =
        PaymentSucceeded.parse(row(%{data: %{@payload | "email" => "not-an-email"}}))

      assert {:error, {:invalid_payload, _changeset}} = PaymentSucceeded.deliver(receipt)
    end
  end

  describe "the loop, wired together" do
    test "a delivered payment event reaches the handler and is recorded" do
      {:ok, _} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1
      assert summary.failed == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert row.type == "billing.payment.succeeded"
      assert row.consumed_at

      assert_email_sent(fn email ->
        assert email.text_body =~ "19.00 USD"
      end)
    end

    test "a handler failure leaves consumed_at NULL, so the event is retried" do
      # The packet's claim, over the real loop: a payload with no address
      # reaches the handler, is refused, and the row comes back on the next
      # pass rather than being dropped on the floor — which is what makes the
      # refusal above safe.
      {:ok, _} = Consumers.record(envelope(%{"data" => Map.delete(@payload, "email")}))

      summary = Consumers.consume()

      assert summary.failed == 1
      assert summary.handled == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert is_nil(row.consumed_at)
      assert row.attempt_count == 1

      assert_no_email_sent()
    end

    test "a redelivered envelope id is deduped, not mailed twice" do
      # One payment, one receipt. The second insert of the same envelope id is
      # refused by the unique constraint, so the handler runs once — the claim
      # "not mailed twice" is a claim about the mail, not only the row.
      assert {:ok, _} = Consumers.record(envelope())
      assert {:error, :already_consumed} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1

      assert_email_sent(fn email ->
        assert email.text_body =~ "19.00 USD"
      end)
    end
  end
end
