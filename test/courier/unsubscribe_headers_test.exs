defmodule Courier.UnsubscribeHeadersTest do
  @moduledoc """
  **THE HEADERS, ON REAL MESSAGE BYTES.** Two claims, and they are proved at the
  two levels where each can fail.

  ## The negative, on the messages courier composes today

  All six of courier's notification types are transactional, so **no message
  courier can currently send carries `List-Unsubscribe` or
  `List-Unsubscribe-Post`.** That is asserted over a real composed message per
  type, through the function `Courier.Deliver` actually calls, with a paired
  assertion that no token row was minted — a "no header" assertion on its own is
  satisfied by a code path that does nothing at all, which is the same vacuity
  `Courier.TelemetryCanaryTest` was written against.

  This is the half that matters most and it is not a formality. An
  account-management email with an unsubscribe link is its own defect: a person
  who resets their password and finds an unsubscribe link has learned that the
  link does something they did not expect.

  ## The positive, on the wire

  The other half — a message that DOES carry the two headers — is asserted
  against **the bytes a real SMTP server received**: a real `gen_smtp` listener
  on a real loopback port, the real `Swoosh.Adapters.SMTP`, the real
  `gen_smtp_client` conversation, and `handle_DATA/4`'s raw `DATA` read back out
  of ETS. `Swoosh.Email.header/3` writes into a map on the struct, and a struct is
  not a message — nothing about it proves the header survives Swoosh's
  serialisation onto the wire, which is exactly where a header courier believes it
  sent can disappear. The same round trip is asserted in the negative direction,
  so "the header was on the wire" and "no header is" are both measured rather
  than one of them assumed.

  `Courier.TestSupport.SmtpServer.received?/2` matches the raw bytes rather than a
  parsed structure, for the reason its own docs give: a parser that dropped a
  header would let a leak pass.

  ## And the honest limit, stated here rather than discovered later

  **courier sends no bulk mail, so `Courier.Deliver` never takes the `:bulk` arm
  of `Courier.Unsubscribes.decorate_for/3`.** It cannot: a bulk type would have to
  be a new entry in `Courier.Mailers.kinds/0`, and adding a notification type
  is a change in **core** — every payload courier publishes carries
  `notification_type`, and `core/schemas/events/courier/email/*.schema.json`
  freezes that field to an enum of the names courier sends. This repository
  does not own those schemas, and a type the enum does not hold would put a
  value on the bus that four payload schemas reject. The fourth type,
  `account_security`, and the two email-change notices are exactly that
  reported divergence — all three are `:transactional`, so they change nothing
  here, and the gap is recorded in
  `REPORT-courier-consumer-sessionsrevoked-01` rather than hidden by this
  file's "no bulk mail" claim, which is about the `:bulk` arm and still holds.

  So the positive case is proved where it can be proved honestly: on a real
  composed message through the real `decorate/2`, and on the wire through the real
  adapter. What is **not** proved is the branch inside `Courier.Deliver` that
  reads `Mailers.bulk?/1` and calls `decorate/2` — a bulk type does not exist to
  drive it. That is one line, and the day the core-side enum grows a fourth name
  the assertion that matters is the one this file already makes: `Mailers.kinds/0`
  covers `types/0`, so a type cannot be sent without a kind, and a kind cannot be
  `:bulk` without a row saying so.
  """

  # `async: false`, and the reason is the application environment rather than the
  # network: the wire test replaces `config :courier, Courier.Mailer`, which the
  # whole VM shares, so two of them running at once would deliver through each
  # other's adapter. Same rule as `Courier.SmtpDeliveryTest` and every other
  # `*ConfigTest` in this suite.
  use Courier.DataCase, async: false

  alias Courier.Deliver
  alias Courier.Mailers
  alias Courier.UnsubscribeToken
  alias Courier.Unsubscribes

  import Swoosh.TestAssertions

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @email "headers@example.com"

  setup do
    # The suite's default is `Swoosh.Adapters.Test`, and it has to be restored
    # whether or not the test below it gets that far.
    previous = Application.get_env(:courier, Courier.Mailer)
    on_exit(fn -> Application.put_env(:courier, Courier.Mailer, previous) end)
    :ok
  end

  describe "every type courier can send today carries no unsubscribe" do
    test "on the composed message, for each of the seven types" do
      # Driven through `Courier.Deliver`, not through `Courier.Mailers.build/2`:
      # the claim is that the SEND PATH leaves the message alone, and a test that
      # stopped one layer short would pass against a `Deliver` that decorated
      # every message it sent.
      for type <- Mailers.types() do
        {:ok, _result} = Deliver.email(type, payload(type))

        assert_email_sent(fn email ->
          assert email.headers["List-Unsubscribe"] == nil,
                 "a #{type} message carries List-Unsubscribe, and a password reset " <>
                   "with an unsubscribe link is its own defect"

          assert email.headers["List-Unsubscribe-Post"] == nil,
                 "a #{type} message carries List-Unsubscribe-Post"
        end)
      end
    end

    test "and mints no token for any of them" do
      # The paired presence assertion, and the reason this file is not satisfied by
      # the one above: a `decorate_for/3` that returned early without either
      # minting or checking would pass "no header" forever.
      for type <- Mailers.types() do
        {:ok, _result} = Deliver.email(type, payload(type))
      end

      # Scoped to this test's own user, never counted over the table: a whole-table
      # count is a claim about every other test in the repository, which is the
      # shape REPORT-courier-15 documents.
      {:ok, user_uuid} = Ecto.UUID.cast(@user_id)

      assert 0 ==
               Repo.one(
                 from token in UnsubscribeToken,
                   where: token.user_id == ^user_uuid,
                   select: count(token.id)
               ),
             "a transactional send minted an unsubscribe token, so a row exists " <>
               "whose credential nobody was ever offered"
    end

    test "and the message is otherwise the one courier composed" do
      # So "no header" cannot be satisfied by a message that is not the real one.
      {:ok, _result} = Deliver.welcome(payload("welcome"))

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Cafaye"
        assert [{_name, @email}] = email.to
        assert Mailers.body?(email)
        assert email.headers["message-id"] =~ ~r/^<courier-[0-9a-f-]+@cafaye\.com>$/
      end)
    end
  end

  describe "a decorated message reaches the wire with both headers" do
    setup do
      {:ok, server, port} = Courier.TestSupport.SmtpServer.start_link()
      put_smtp_adapter(port)
      %{server: server}
    end

    test "and the transaction a bulk send would use mints the token it points at", %{
      server: server
    } do
      # A real composed message, decorated by the real function, delivered through
      # the real adapter to a real listener. The token in the header is then used
      # for real: `find/1` resolves it to the row, which is the whole chain the
      # endpoint depends on.
      {:ok, message} = Mailers.build("welcome", payload("welcome"))
      {:ok, token} = Unsubscribes.issue(@user_id, "welcome", @email)

      assert {:ok, _metadata} =
               Courier.Mailer.deliver(Unsubscribes.decorate(message, token))

      assert [received] = Courier.TestSupport.SmtpServer.take(server)

      # The URI, byte for byte, out of the DATA the provider would have read.
      assert received.data =~ "List-Unsubscribe: <#{Unsubscribes.url(token)}>"
      assert received.data =~ "List-Unsubscribe-Post: List-Unsubscribe=One-Click"

      # And the token in that URI resolves to the row, so the header is not a
      # decoration on a URL nothing answers.
      assert {:ok, %UnsubscribeToken{user_id: @user_id}} = Unsubscribes.find(token)
    end

    test "and a message courier did not decorate carries neither, on the wire too", %{
      server: server
    } do
      # The negative on the wire as well as on the struct, because "the header was
      # there" and "no header is" are two measurements and only doing the first
      # would leave the second as an assumption about a serialiser.
      {:ok, _result} = Deliver.welcome(payload("welcome"))

      assert [received] = Courier.TestSupport.SmtpServer.take(server)
      refute received.data =~ "List-Unsubscribe"
      assert received.data =~ "Subject: Welcome to Cafaye"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp payload(type) do
    %{
      user_id: @user_id,
      email: @email,
      name: "Header Proof",
      url: "https://cafaye.test/#{type}",
      account_name: "Acme",
      invited_by: "Kaka",
      role: "member",
      # `account_security` requires a reason and `email_change_new` requires a
      # previous address; the other types ignore both. One payload shape for
      # the whole `Mailers.types()` iteration, so the fourth, fifth and sixth
      # types are covered by the same arms as the first three.
      reason: "password reset",
      previous_email: "previous@example.com",
      # `receipt` requires an amount and ignores the rest; the invoice id is
      # optional in its template, so the shape above covers the seventh type
      # with the same arms as the first six.
      amount_display: "19.00 USD"
    }
  end

  # The same adapter shape `Courier.SmtpDeliveryTest` uses, and the reason for the
  # empty strings is written down there: `Swoosh.Adapters.SMTP.enforce_type!/2`
  # rejects a `nil` username before it opens a socket, so `auth: :never` does not
  # make the key optional.
  defp put_smtp_adapter(port) do
    Application.put_env(:courier, Courier.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: "127.0.0.1",
      port: port,
      username: "",
      password: "",
      auth: :never,
      tls: :never,
      ssl: false
    )
  end
end
