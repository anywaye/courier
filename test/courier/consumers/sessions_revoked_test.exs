defmodule Courier.Consumers.SessionsRevokedTest do
  @moduledoc """
  `identity.session.revoked` → the notice a person is owed when their
  credentials end, and the first event courier consumes that it can mail.

  ## WHAT THIS FILE PROVES

  The two earlier consumers could not send mail: the invitation's accept URL is
  unrecoverable from any event, and the acceptance carried no address at all.
  This payload carries the recipient and the fact — `user_id`, `email`,
  `reason` — so the positive arm is a real send through the real `Courier.Deliver`,
  and every refusal below is paired with it for the reason this repository keeps
  repeating: a handler that refuses everything passes every refusal test.

    * an event courier can parse is dispatched, and the notice is sent to the
      address the payload carries;
    * the two reasons render as two wordings of one template, and the branch is
      asserted on the mail rather than on the handler's return;
    * a payload courier **cannot** parse is refused by name and **nothing is
      sent** — a malformed event is refused, never guessed at;
    * a reason outside the closed set is refused before anything is dialled, so
      no row claims a notice went out;
    * a handler failure leaves `consumed_at` NULL, so the event is retried
      rather than dropped;
    * a redelivered envelope id is deduped at the record layer, so the notice is
      sent exactly once.

  ## THE PAYLOAD, AND WHY IT IS SUFFICIENT

  `identity.session.revoked` (identity's `internal/outbox/recovery.go`,
  `NewSessionsRevoked`, verified there and **not re-derived here**) carries
  exactly three fields:

      user_id, email, reason

  — and the subject is the user id. The `reason` is one of a closed set,
  `password reset` or `email address changed`, transcribed from the same file.
  This is the first event courier consumes whose payload needs no lookup: the
  invitation was missing the one field that mattered and the acceptance carried
  no address, so both earlier handlers refused or recorded in-app. This one
  mails.

  ## THE HANDLER TAKES THE ROW

  `handle/1` is given the `consumed_events` row, not the envelope as it
  arrived — the same principle as `Courier.Consumers.MemberInvited` and
  `Courier.Consumers.MemberAccepted`. These tests build the row the subscriber
  would have written for the unit arms, and go through `Consumers.record/2` +
  `Consumers.consume()` for the integration arms, so the dedupe and the retry
  claims are claims about the loop rather than about the handler.

  ## WHY THE FILE CARRIES NO `@moduletag account:`

  The handler writes to `consumed_events` and `outbox_events`, neither of which
  carries an `account_id` — they are courier's own bookkeeping about a message
  from another service, and the protection migration leaves them unprotected.
  The send path's preference check is a READ by user id, which needs no
  identity. So this file touches no account-scoped table, and the tag would be
  a claim the file does not make.
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Consumers.SessionsRevoked

  # The three fields identity publishes, in the payload's own order.
  @payload %{
    "user_id" => "9c8d7e6f-1111-4222-8333-444455556666",
    "email" => "kaka@example.com",
    "reason" => "password reset"
  }

  @envelope_id "8c9d0e1f-0000-4000-8000-000000000003"

  defp row(overrides \\ %{}) do
    struct!(
      %ConsumedEvent{
        id: @envelope_id,
        type: "identity.session.revoked",
        source: "identity",
        # The subject is the USER, per the publisher's payload.
        subject: @payload["user_id"],
        time: ~U[2026-10-06 12:00:00.000000Z],
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
        "type" => "identity.session.revoked",
        "source" => "identity",
        "subject" => @payload["user_id"],
        "time" => "2026-10-06T12:00:00Z",
        "data" => @payload
      },
      overrides
    )
  end

  describe "an event courier can parse" do
    test "is dispatched and the payload reaches the handler whole" do
      # The positive arm, paired with every refusal below.
      assert {:ok, revocation} = SessionsRevoked.parse(row())

      assert revocation.user_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert revocation.email == "kaka@example.com"
      assert revocation.reason == "password reset"
    end

    test "names the same type the registry is keyed on" do
      # Two strings that must be one: the handler's `type/0` and the key in
      # `config :courier, :consumers`. A refactor that changes one and not the
      # other is a message received and dropped, and it is a test rather than a
      # comment because the two live in different files.
      assert SessionsRevoked.type() == "identity.session.revoked"
      assert Consumers.handler_for(SessionsRevoked.type()) == SessionsRevoked
    end

    test "carries no url and no account name, and that is asserted rather than assumed" do
      # The load-bearing negative. The payload has only the three fields
      # identity publishes, so a revocation carrying a url or an account name
      # would be evidence the publisher had changed — and the handler would then
      # be withholding a lookup it could do. This is the assertion that would
      # catch that change.
      {:ok, revocation} = SessionsRevoked.parse(row())

      refute Map.has_key?(revocation, :url)
      refute Map.has_key?(revocation, :account_name)
    end
  end

  describe "an event courier cannot parse" do
    test "is refused when the row is not a row" do
      assert {:error, :unreadable_envelope} = SessionsRevoked.parse("identity.session.revoked")
      assert {:error, :unreadable_envelope} = SessionsRevoked.parse(%{})
    end

    test "is refused when the row has no id to attribute the refusal to" do
      # `Courier.Consumers.record/2` refuses these before the row exists; this
      # arm is the handler refusing a hand-built one, so a caller reaching past
      # the record path gets a refusal rather than a crash.
      assert {:error, :unreadable_envelope} = SessionsRevoked.parse(row(%{id: nil}))
      assert {:error, :unreadable_envelope} = SessionsRevoked.parse(row(%{id: ""}))
    end

    test "is refused when the type is not the one this handler is for" do
      assert {:error, :not_this_event} =
               SessionsRevoked.parse(row(%{type: "identity.member.invited"}))
    end

    test "is refused when a required payload field is missing" do
      for field <- ~w(user_id email reason) do
        assert {:error, {:incomplete_payload, ^field}} =
                 SessionsRevoked.parse(row(%{data: Map.delete(@payload, field)})),
               "a payload missing #{field} must be refused by name, not guessed at"
      end
    end

    test "is refused when a required payload field is not a string" do
      # A number, a list, a nested object: `to_string/1` would render all three
      # happily and produce a revocation naming `"kaka@example.com"` from a field
      # that was a list. **The refusal is on the SHAPE, before the value is
      # read**, so the reason cannot be produced by a field whose type is wrong.
      assert {:error, {:incomplete_payload, "email"}} =
               SessionsRevoked.parse(row(%{data: %{@payload | "email" => ["kaka@example.com"]}}))

      assert {:error, {:incomplete_payload, "email"}} =
               SessionsRevoked.parse(row(%{data: %{@payload | "email" => 42}}))
    end

    test "is refused, by name, when the payload is empty" do
      assert {:error, {:incomplete_payload, "data"}} = SessionsRevoked.parse(row(%{data: %{}}))
    end
  end

  describe "a payload courier can parse" do
    test "sends the notice to the address the payload carries" do
      # The action, asserted through the surface that owns it: the mail is real,
      # it is addressed to the person whose credentials ended, and it is the
      # password-reset wording. A handler that rendered the message and threw
      # it away fails here.
      {:ok, revocation} = SessionsRevoked.parse(row())

      assert {:ok, %{notification_type: "account_security"}} = SessionsRevoked.deliver(revocation)

      assert_email_sent(fn email ->
        assert [{_name, "kaka@example.com"}] = email.to
        assert email.subject == "Security notice for your caFaye account"
        assert email.text_body =~ "Your password was changed."
      end)
    end

    test "branches on the reason into the email-address wording" do
      # The second rendering of the one template, and the reason this handler
      # validates the closed set: a notice that does not name which fact
      # happened forces the reader to guess, and the two facts have different
      # remediations. Mutation: make the template ignore `@reason` and this
      # fails.
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "reason" => "email address changed"}}))

      assert {:ok, _} = SessionsRevoked.deliver(revocation)

      # The `refute` is NOT the last expression: `refute` returns `false` on
      # success (`not assert(!value)`), and `assert_email_sent` asserts the
      # fun's return value — a fun ending in `refute` fails having proved
      # exactly what it claimed.
      assert_email_sent(fn email ->
        refute email.text_body =~ "Your password was changed."
        assert email.text_body =~ "The email address on your account was changed."
      end)
    end

    test "writes the outbox row, so a sent notice is visible to the platform" do
      {:ok, revocation} = SessionsRevoked.parse(row())

      assert {:ok, %{event_id: event_id}} = SessionsRevoked.deliver(revocation)

      assert Repo.get(Courier.OutboxEvent, event_id).type == "courier.email.delivered"
    end

    test "refuses an unknown reason before anything is dialled" do
      # The closed set is the publisher's contract, and the consumer's own copy
      # of it — the publisher's build-time validation is not the consumer's
      # boundary. A reason outside the two identity publishes is refused by
      # name, and no row claims a notice went out: a notice saying "your email
      # address was moved" about an admin revocation is a false claim about
      # somebody's account, delivered to their inbox.
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "reason" => "account deleted"}}))

      assert {:error, {:unknown_reason, "account deleted"}} = SessionsRevoked.deliver(revocation)

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 0
      assert_no_email_sent()
    end

    test "refuses a missing reason before anything is dialled" do
      # The handler requires all three fields, so a payload without a reason is
      # refused by NAME in parse — before anything is dialled. The renderer's
      # own refusal of a reason-less payload (`{:invalid_payload, changeset}`)
      # is `Courier.Mailers`' to assert, and it is asserted in
      # `Courier.MailersTest` — this file proves the handler's half: the
      # refusal happens before the provider is reached, so no row claims a
      # notice went out.
      assert {:error, {:incomplete_payload, "reason"}} =
               SessionsRevoked.parse(row(%{data: Map.delete(@payload, "reason")}))

      assert_no_email_sent()
    end
  end

  describe "a handler that fails" do
    test "answers rather than raising, so the loop can record it and move on" do
      # A malformed address passes the handler's parse (it is a string) and is
      # refused by `Courier.Mailers`' format validation — a real refusal through
      # the real code path, and the shape the loop records. The handler adds no
      # vocabulary of its own: whatever `Courier.Deliver` answers is what the
      # handler answers.
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "email" => "not-an-email"}}))

      assert {:error, {:invalid_payload, _changeset}} = SessionsRevoked.deliver(revocation)
    end

    test "the refusal is one of `Courier.Deliver`'s, not a new vocabulary" do
      # **This handler adds exactly ONE refusal of its own** —
      # `{:unknown_reason, reason}` — and everything else it returns is
      # `Courier.Deliver`'s or `Courier.Mailers`', unchanged. A handler that
      # invented a third dialect for them would put every future caller in the
      # position of matching on strings nobody else produces.
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "reason" => "account deleted"}}))

      # Its own, because the reason is outside the closed set.
      assert {:error, {:unknown_reason, "account deleted"}} = SessionsRevoked.deliver(revocation)

      # `Courier.Deliver`'s, once the reason is valid and the address is not.
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "email" => "not-an-email"}}))

      assert {:error, {:invalid_payload, _changeset}} = SessionsRevoked.deliver(revocation)
    end
  end

  describe "the loop, wired together" do
    test "a delivered revocation event reaches the handler and is recorded" do
      # The integration, over the real table and the real registry. Without
      # this the unit tests above could all be green with a registry nothing
      # read.
      {:ok, _} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1
      assert summary.failed == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert row.type == "identity.session.revoked"
      assert row.consumed_at

      assert_email_sent(fn email ->
        assert email.text_body =~ "Your password was changed."
      end)
    end

    test "a handler failure leaves consumed_at NULL, so the event is retried" do
      # The packet's claim, over the real loop. A payload whose address is not
      # an address reaches `Courier.Mailers` and is refused by the format
      # validation — the handler ran, the action failed, and the row must come
      # back on the next pass rather than being dropped on the floor.
      {:ok, _} =
        Consumers.record(envelope(%{"data" => %{@payload | "email" => "not-an-email"}}))

      summary = Consumers.consume()

      assert summary.failed == 1
      assert summary.handled == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert is_nil(row.consumed_at)
      assert row.attempt_count == 1
      assert row.last_error =~ "email"
    end

    test "a redelivered envelope id is deduped, not mailed twice" do
      # Core's rule 1, at the level it is enforced: the unique constraint IS
      # the dedupe. The second insert is refused, so the handler runs once and
      # one notice exists — the claim "not mailed twice" is a claim about the
      # action, not only about the row.
      assert {:ok, _} = Consumers.record(envelope())
      assert {:error, :already_consumed} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1

      assert_email_sent(fn email ->
        assert email.text_body =~ "Your password was changed."
      end)
    end
  end
end
