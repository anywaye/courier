defmodule Courier.Consumers.MemberAcceptedTest do
  @moduledoc """
  `identity.member.accepted` → an in-app notification, and the first event
  courier consumes that it can act on.


  The invite packet's handler refuses by design — the accept URL is
  unrecoverable from any event. This handler is the opposite shape: the
  payload's three fields are exactly what `Courier.Notifications` takes, so
  the positive arm is a real write to real tables, and every refusal below is
  paired with it for the reason this repository keeps repeating: a handler
  that refuses everything passes every refusal test.

    * an event courier can parse is dispatched, and the notification is
      recorded and readable back through the surface that owns it;
    * a payload courier **cannot** parse is refused by name and **nothing is
      recorded** — a malformed event is refused, never guessed at;
    * a handler failure leaves `consumed_at` NULL, so the event is retried
      rather than dropped;
    * a redelivered envelope id is deduped at the record layer, so the action
      happens exactly once.


  `identity.member.accepted` (identity's `internal/outbox/tenancy.go`,
  `NewMemberAccepted`, verified there and **not re-derived here**) carries
  exactly three fields:

      account_id, user_id, role

  Two absences are decisions rather than gaps:

    * **No email address.** The mail a member would want ("you joined account
      X") needs the address and the account name; the payload carries neither,
      and courier has no identity client. The handler mails nobody — see the
      moduledoc and `REPORT-courier-consumer-memberaccepted-01`.
    * **No account name.** `params` carries `role` and nothing else: the
      account is a column on the event row, and a blank where the name should
      be is the one outcome this packet exists to prevent.


  `notification_events` and `notifications` are RLS-protected with
  `account_id = anywaye.current_account_id()`, and the account this handler
  writes is the **payload's** — so the test's tenant identity must be the same
  uuid, or every write is refused `42501`. The tag is the file-level statement
  of that fact, and the payload's account id is the tag's value.


  `handle/1` is given the `consumed_events` row, not the envelope as it
  arrived — the same principle as `Courier.Consumers.MemberInvited`. These
  tests build the row the subscriber would have written for the unit arms, and
  go through `Consumers.record/2` + `Consumers.consume()` for the integration
  arms, so the dedupe and the retry claims are claims about the loop rather
  than about the handler.
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Consumers.MemberAccepted
  alias Courier.Notifications

  @account_id "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
  @moduletag account: @account_id

  @payload %{
    "account_id" => @account_id,
    "user_id" => "9c8d7e6f-1111-4222-8333-444455556666",
    "role" => "member"
  }

  @envelope_id "7b4c3d2e-0000-4000-8000-000000000001"

  defp row(overrides \\ %{}) do
    struct!(
      %ConsumedEvent{
        id: @envelope_id,
        type: "identity.member.accepted",
        source: "identity",
        subject: @account_id,
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
        "type" => "identity.member.accepted",
        "source" => "identity",
        "subject" => @account_id,
        "time" => "2026-10-06T12:00:00Z",
        "data" => @payload
      },
      overrides
    )
  end

  describe "an event courier can parse" do
    test "is dispatched and the payload reaches the handler whole" do
      assert {:ok, membership} = MemberAccepted.parse(row())

      assert membership.account_id == @account_id
      assert membership.user_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert membership.role == "member"
    end

    test "names the same type the registry is keyed on" do
      assert MemberAccepted.type() == "identity.member.accepted"
      assert Consumers.handler_for(MemberAccepted.type()) == MemberAccepted
    end

    test "carries no email address, and that is asserted rather than assumed" do
      {:ok, membership} = MemberAccepted.parse(row())

      refute Map.has_key?(membership, :email)
      refute Map.has_key?(membership, :account_name)
    end
  end

  describe "an event courier cannot parse" do
    test "is refused when the row is not a row" do
      assert {:error, :unreadable_envelope} = MemberAccepted.parse("identity.member.accepted")
      assert {:error, :unreadable_envelope} = MemberAccepted.parse(%{})
    end

    test "is refused when the row has no id to attribute the refusal to" do
      assert {:error, :unreadable_envelope} = MemberAccepted.parse(row(%{id: nil}))
      assert {:error, :unreadable_envelope} = MemberAccepted.parse(row(%{id: ""}))
    end

    test "is refused when the type is not the one this handler is for" do
      assert {:error, :not_this_event} =
               MemberAccepted.parse(row(%{type: "identity.member.invited"}))
    end

    test "is refused when a required payload field is missing" do
      for field <- ~w(account_id user_id role) do
        assert {:error, {:incomplete_payload, ^field}} =
                 MemberAccepted.parse(row(%{data: Map.delete(@payload, field)})),
               "a payload missing #{field} must be refused by name, not guessed at"
      end
    end

    test "is refused when a required payload field is not a string" do
      assert {:error, {:incomplete_payload, "role"}} =
               MemberAccepted.parse(row(%{data: %{@payload | "role" => ["member"]}}))

      assert {:error, {:incomplete_payload, "role"}} =
               MemberAccepted.parse(row(%{data: %{@payload | "role" => 42}}))
    end

    test "is refused, by name, when the payload is empty" do
      assert {:error, {:incomplete_payload, "data"}} = MemberAccepted.parse(row(%{data: %{}}))
    end
  end

  describe "a payload courier can parse" do
    test "is recorded as an in-app notification, addressed to the member" do
      {:ok, membership} = MemberAccepted.parse(row())

      assert {:ok, %{event: event, notifications: [notification]}} =
               MemberAccepted.notify(membership)

      assert event.type == "welcome"
      assert event.account_id == @account_id
      assert event.params["role"] == "member"

      assert notification.recipient_type == "user"
      assert notification.recipient_id == "9c8d7e6f-1111-4222-8333-444455556666"

      assert [listed] = Notifications.list(@account_id, {"user", @payload["user_id"]})
      assert listed.id == notification.id
      assert Notifications.unread_count(@account_id, {"user", @payload["user_id"]}) == 1
    end

    test "records nothing when the payload is refused" do
      assert {:error, {:incomplete_payload, "data"}} = MemberAccepted.handle(row(%{data: %{}}))

      assert Notifications.unread_count(@account_id, {"user", @payload["user_id"]}) == 0
    end

    test "mails nobody, because the payload has no address to mail" do
      {:ok, membership} = MemberAccepted.parse(row())

      assert {:ok, _} = MemberAccepted.notify(membership)

      assert_no_email_sent()
    end

    test "passes `Courier.Notifications`' refusal through unchanged" do
      {:ok, membership} = MemberAccepted.parse(row())

      assert {:error, {:notification, changeset}} =
               MemberAccepted.notify(%{membership | user_id: String.duplicate("u", 300)})

      assert {:recipient_id, {_message, _opts}} = List.keyfind(changeset.errors, :recipient_id, 0)
    end
  end

  describe "the loop, wired together" do
    test "a delivered acceptance event reaches the handler and is recorded" do
      {:ok, _} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1
      assert summary.failed == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert row.type == "identity.member.accepted"
      assert row.consumed_at

      assert Notifications.unread_count(@account_id, {"user", @payload["user_id"]}) == 1
    end

    test "a handler failure leaves consumed_at NULL, so the event is retried" do
      {:ok, _} =
        Consumers.record(envelope(%{"data" => %{@payload | "account_id" => "not-a-uuid"}}))

      summary = Consumers.consume()

      assert summary.failed == 1
      assert summary.handled == 0

      row = Repo.get(ConsumedEvent, @envelope_id)
      assert is_nil(row.consumed_at)
      assert row.attempt_count == 1
      assert row.last_error =~ "account_id"
    end

    test "a redelivered envelope id is deduped, not acted on twice" do
      assert {:ok, _} = Consumers.record(envelope())
      assert {:error, :already_consumed} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1
      assert Notifications.unread_count(@account_id, {"user", @payload["user_id"]}) == 1
    end
  end
end
