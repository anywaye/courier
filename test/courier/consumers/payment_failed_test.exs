defmodule Courier.Consumers.PaymentFailedTest do
  @moduledoc """
  `billing.payment.failed` → the warning for an attempt that did not go
  through, and the receipt's other half.


  The sibling of `Courier.Consumers.PaymentSucceededTest`, arm for arm — the
  two events are built by one builder in billing, so a shape this refuses and
  the receipt handler accepts would be the two halves of one payload
  disagreeing. Every refusal below is paired with the positive arm in the same
  file, because a handler that refuses everything passes every refusal test.

    * an event courier can parse is dispatched, and the warning is sent to the
      address the payload carries, naming the amount that did not move;
    * the amount renders at the currency's own places, through the one renderer
      the payment family shares;
    * an invoice-backed attempt carries the invoice id, and a one-off without
      one still sends rather than being dropped;
    * a payload with no address, no payer, or no amount is refused by name and
      nothing is sent;
    * a handler failure leaves `consumed_at` NULL, so the row is retried rather
      than dropped;
    * a redelivered envelope id is deduped at the record layer, sent exactly
      once.


  billing's `Webhooks::StripeEvents.payment_emission` over an
  `invoice.payment_failed`, measured there and not re-derived here: the same
  normalized invoice event as the receipt's with `paid: false`, plus
  `attempt_count` and `next_payment_attempt`, plus the recipient fact
  `with_recipient` merges in, `email`. The handler reads four of those fields
  and no others — the retry schedule is deliberately not one of them, see the
  handler's moduledoc.
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Consumers.PaymentFailed

  @payload %{
    "kind" => "payment",
    "processor" => "stripe",
    "processor_event_id" => "evt_1URCjRCmN780pAiWe4VyAfOy",
    "customer_id" => "cus_VS6x3l4EsHvbxt",
    "anywaye_customer_id" => "865e9942-4b65-432b-8bf4-5d34b9dae5b8",
    "subscription_id" => "sub_1URCjPCmN780pAiWor6nCnGD",
    "invoice_id" => "in_1URCjNCmN780pAiWMWoH0Bxd",
    "payment_intent_id" => "pi_3URCjNCmN780pAiW1wrSRQIO",
    "paid" => false,
    "amount" => %{"amount_minor" => 4_900, "currency" => "USD"},
    "attempt_count" => 1,
    "next_payment_attempt" => "2026-10-19T09:00:00Z",
    "email" => "buyer@example.com"
  }

  @envelope_id "9c8d7e6f-1111-4222-8333-444455556679"

  @subject @payload["subscription_id"]

  defp row(overrides \\ %{}) do
    struct!(
      %ConsumedEvent{
        id: @envelope_id,
        type: "billing.payment.failed",
        source: "billing",
        subject: @subject,
        time: ~U[2026-10-16 15:07:41.000000Z],
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
        "type" => "billing.payment.failed",
        "source" => "billing",
        "subject" => @subject,
        "time" => "2026-10-16T15:07:41Z",
        "data" => @payload
      },
      overrides
    )
  end

  describe "an event courier can parse" do
    test "is dispatched and the warning is sent to the address the payload carries" do
      assert {:ok, warning} = PaymentFailed.parse(row())

      assert warning.email == "buyer@example.com"
      assert warning.payer == "865e9942-4b65-432b-8bf4-5d34b9dae5b8"
      assert warning.amount_display == "49.00 USD"
      assert warning.invoice_id == "in_1URCjNCmN780pAiWMWoH0Bxd"

      assert {:ok, _} = PaymentFailed.deliver(warning)

      assert_email_sent(fn email ->
        assert email.to == [{"", "buyer@example.com"}]
        assert email.subject == "Your Anywaye payment did not go through"
        assert email.html_body =~ "49.00 USD"
        assert email.text_body =~ "49.00 USD"
        assert email.html_body =~ "in_1URCjNCmN780pAiWMWoH0Bxd"
        assert email.html_body =~ "Nothing was charged."
      end)
    end

    test "names the same type the registry is keyed on" do
      assert PaymentFailed.type() == "billing.payment.failed"
      assert Consumers.handler_for(PaymentFailed.type()) == PaymentFailed
    end

    test "writes the outbox row, so a sent warning is visible to the platform" do
      assert {:ok, %{event_id: event_id}} =
               PaymentFailed.deliver(%{
                 email: "buyer@example.com",
                 payer: "865e9942-4b65-432b-8bf4-5d34b9dae5b8",
                 amount_display: "49.00 USD",
                 invoice_id: "in_1URCjNCmN780pAiWMWoH0Bxd"
               })

      assert Repo.get(Courier.OutboxEvent, event_id).type == "courier.email.delivered"
    end

    test "renders a zero-decimal currency at its own places: 2400 JPY stays 2400" do
      {:ok, warning} =
        PaymentFailed.parse(
          row(%{
            data: @payload |> put_in(["amount"], %{"amount_minor" => 2_400, "currency" => "jpy"})
          })
        )

      assert warning.amount_display == "2400 JPY"
    end

    test "a one-off attempt without an invoice still sends" do
      {:ok, warning} = PaymentFailed.parse(row(%{data: Map.delete(@payload, "invoice_id")}))

      assert warning.invoice_id == nil

      assert {:ok, _} = PaymentFailed.deliver(warning)

      assert_email_sent(fn email ->
        refute email.html_body =~ "The attempt was for invoice"
        assert email.html_body =~ "49.00 USD"
      end)
    end

    test "names the retry schedule nowhere, because the schedule is the processor's" do
      {:ok, warning} = PaymentFailed.parse(row())

      assert {:ok, _} = PaymentFailed.deliver(warning)

      assert_email_sent(fn email ->
        refute email.html_body =~ "2026-10-19"
        refute email.text_body =~ "2026-10-19"
        assert email.html_body =~ "Nothing was charged."
      end)
    end
  end

  describe "what is refused, and sends nothing" do
    test "a payload with no address is refused by name" do
      assert {:error, {:incomplete_payload, "email"}} =
               PaymentFailed.handle(row(%{data: Map.delete(@payload, "email")}))

      assert_no_email_sent()
    end

    test "a payload naming no anywaye customer is refused by name" do
      assert {:error, {:incomplete_payload, "anywaye_customer_id"}} =
               PaymentFailed.handle(row(%{data: Map.delete(@payload, "anywaye_customer_id")}))

      assert_no_email_sent()
    end

    test "a payload with no amount is refused by name" do
      assert {:error, {:incomplete_payload, "amount"}} =
               PaymentFailed.handle(row(%{data: %{@payload | "amount" => nil}}))

      assert_no_email_sent()
    end

    test "an amount with only one of its halves is refused" do
      data = %{@payload | "amount" => %{"currency" => "USD"}}

      assert {:error, {:incomplete_payload, "amount"}} =
               PaymentFailed.handle(row(%{data: data}))

      assert_no_email_sent()
    end
  end

  describe "a handler that fails" do
    test "a malformed address is refused by `Courier.Mailers`, not by this handler" do
      {:ok, warning} =
        PaymentFailed.parse(row(%{data: %{@payload | "email" => "not-an-email"}}))

      assert {:error, {:invalid_payload, _changeset}} = PaymentFailed.deliver(warning)
    end
  end

  describe "the loop, wired together" do
    test "a delivered failure event reaches the handler and is recorded" do
      {:ok, _} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1
      assert summary.failed == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert row.type == "billing.payment.failed"
      assert row.consumed_at

      assert_email_sent(fn email ->
        assert email.text_body =~ "49.00 USD"
      end)
    end

    test "a handler failure leaves consumed_at NULL, so the event is retried" do
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
      assert {:ok, _} = Consumers.record(envelope())
      assert {:error, :already_consumed} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1

      assert_email_sent(fn email ->
        assert email.text_body =~ "49.00 USD"
      end)
    end
  end
end
