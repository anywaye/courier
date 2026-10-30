defmodule Courier.Consumers.SessionsRevokedTest do
  @moduledoc """
  `identity.session.revoked` → the notice a person is owed when their
  credentials end, and the first event courier consumes that it can mail.


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


  `handle/1` is given the `consumed_events` row, not the envelope as it
  arrived — the same principle as `Courier.Consumers.MemberInvited` and
  `Courier.Consumers.MemberAccepted`. These tests build the row the subscriber
  would have written for the unit arms, and go through `Consumers.record/2` +
  `Consumers.consume()` for the integration arms, so the dedupe and the retry
  claims are claims about the loop rather than about the handler.


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
      assert {:ok, revocation} = SessionsRevoked.parse(row())

      assert revocation.user_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert revocation.email == "kaka@example.com"
      assert revocation.reason == "password reset"
    end

    test "names the same type the registry is keyed on" do
      assert SessionsRevoked.type() == "identity.session.revoked"
      assert Consumers.handler_for(SessionsRevoked.type()) == SessionsRevoked
    end

    test "carries no url and no account name, and that is asserted rather than assumed" do
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
      {:ok, revocation} = SessionsRevoked.parse(row())

      assert {:ok, %{notification_type: "account_security"}} = SessionsRevoked.deliver(revocation)

      assert_email_sent(fn email ->
        assert [{_name, "kaka@example.com"}] = email.to
        assert email.subject == "Security notice for your Anywaye account"
        assert email.text_body =~ "Your password was changed."
      end)
    end

    test "branches on the reason into the email-address wording" do
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "reason" => "email address changed"}}))

      assert {:ok, _} = SessionsRevoked.deliver(revocation)

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
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "reason" => "account deleted"}}))

      assert {:error, {:unknown_reason, "account deleted"}} = SessionsRevoked.deliver(revocation)

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 0
      assert_no_email_sent()
    end

    test "refuses a missing reason before anything is dialled" do
      assert {:error, {:incomplete_payload, "reason"}} =
               SessionsRevoked.parse(row(%{data: Map.delete(@payload, "reason")}))

      assert_no_email_sent()
    end
  end

  describe "a handler that fails" do
    test "answers rather than raising, so the loop can record it and move on" do
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "email" => "not-an-email"}}))

      assert {:error, {:invalid_payload, _changeset}} = SessionsRevoked.deliver(revocation)
    end

    test "the refusal is one of `Courier.Deliver`'s, not a new vocabulary" do
      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "reason" => "account deleted"}}))

      assert {:error, {:unknown_reason, "account deleted"}} = SessionsRevoked.deliver(revocation)

      {:ok, revocation} =
        SessionsRevoked.parse(row(%{data: %{@payload | "email" => "not-an-email"}}))

      assert {:error, {:invalid_payload, _changeset}} = SessionsRevoked.deliver(revocation)
    end
  end

  describe "the loop, wired together" do
    test "a delivered revocation event reaches the handler and is recorded" do
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
