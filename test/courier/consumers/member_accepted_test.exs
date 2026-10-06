defmodule Courier.Consumers.MemberAcceptedTest do
  @moduledoc """
  `identity.member.accepted` → an in-app notification, and the first event
  courier consumes that it can act on.

  ## WHAT THIS FILE PROVES

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

  ## THE PAYLOAD, AND THE TWO ABSENCES THIS HANDLER TREATS AS FACTS

  `identity.member.accepted` (identity's `internal/outbox/tenancy.go`,
  `NewMemberAccepted`, verified there and **not re-derived here**) carries
  exactly three fields:

      account_id, user_id, role

  Two absences are decisions rather than gaps:

    * **No email address.** The mail a member would want ("you joined account
      X") needs the address and the account name; the payload carries neither,
      and courier has no identity client. The handler mails nobody — see the
      moduledoc and `REPORT-courier-consumer-memberaccepted-01.md`.
    * **No account name.** `params` carries `role` and nothing else: the
      account is a column on the event row, and a blank where the name should
      be is the one outcome this packet exists to prevent.

  ## WHY THE FILE CARRIES `@moduletag account:`

  `notification_events` and `notifications` are RLS-protected with
  `account_id = cafaye.current_account_id()`, and the account this handler
  writes is the **payload's** — so the test's tenant identity must be the same
  uuid, or every write is refused `42501`. The tag is the file-level statement
  of that fact, and the payload's account id is the tag's value.

  ## THE HANDLER TAKES THE ROW

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

  # The account is the payload's and the tag's — see the moduledoc.
  @account_id "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
  @moduletag account: @account_id

  # The three fields identity publishes, in the payload's own order.
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
        # The subject is the ACCOUNT, per core's catalog.
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
      # The positive arm, paired with every refusal below.
      assert {:ok, membership} = MemberAccepted.parse(row())

      assert membership.account_id == @account_id
      assert membership.user_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert membership.role == "member"
    end

    test "names the same type the registry is keyed on" do
      # Two strings that must be one: the handler's `type/0` and the key in
      # `config :courier, :consumers`. A refactor that changes one and not the
      # other is a message received and dropped, and it is a test rather than a
      # comment because the two live in different files.
      assert MemberAccepted.type() == "identity.member.accepted"
      assert Consumers.handler_for(MemberAccepted.type()) == MemberAccepted
    end

    test "carries no email address, and that is asserted rather than assumed" do
      # The load-bearing negative. The payload has no address and no account
      # name, so an envelope carrying either would be evidence the publisher
      # had changed — and the handler would then be withholding a mail it could
      # send. This is the assertion that would catch that change.
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
      # `Courier.Consumers.record/2` refuses these before the row exists; this
      # arm is the handler refusing a hand-built one, so a caller reaching past
      # the record path gets a refusal rather than a crash.
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
      # A number, a list, a nested object: `to_string/1` would render all three
      # happily and produce a membership naming `"member"` from a field that was
      # a list. **The refusal is on the SHAPE, before the value is read**, so
      # the reason cannot be produced by a field whose type is wrong.
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
      # The action, asserted through the surface that owns it: the write is real,
      # the row is readable back, and the unread count is the number a badge
      # shows. A handler that wrote nowhere would fail the second assertion.
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
      # The paired negative: a refusal is a refusal, and no row anywhere
      # claims a notification went out. Without this arm the test above would
      # pass with a handler that recorded nothing on every path. An empty
      # payload is refused as `"data"`, the same shape `MemberInvited` answers.
      assert {:error, {:incomplete_payload, "data"}} = MemberAccepted.handle(row(%{data: %{}}))

      assert Notifications.unread_count(@account_id, {"user", @payload["user_id"]}) == 0
    end

    test "mails nobody, because the payload has no address to mail" do
      # The surface decision as an assertion. The member would want a "you
      # joined" mail; the payload carries no address and no account name, and
      # courier has no identity client — so the honest action is the in-app
      # record and nothing else. Mutation: make `notify/1` call
      # `Courier.Deliver` and this fails.
      {:ok, membership} = MemberAccepted.parse(row())

      assert {:ok, _} = MemberAccepted.notify(membership)

      assert_no_email_sent()
    end

    test "passes `Courier.Notifications`' refusal through unchanged" do
      # A recipient id too long for the column is refused by the notification
      # changeset — a real refusal through the real code path, and the shape
      # the loop records. The handler adds no vocabulary of its own: whatever
      # `Courier.Notifications` answers is what the handler answers.
      #
      # A non-uuid `account_id` was tried here first and it RAISES
      # `Ecto.ChangeError` at dump time, because `account_id` is `put_change`d
      # past the cast — the loop's rescue catches that (the integration test
      # below proves it), but a raise is not a refusal, and the claim being
      # made is about the refusal path.
      {:ok, membership} = MemberAccepted.parse(row())

      assert {:error, {:notification, changeset}} =
               MemberAccepted.notify(%{membership | user_id: String.duplicate("u", 300)})

      assert {:recipient_id, {_message, _opts}} = List.keyfind(changeset.errors, :recipient_id, 0)
    end
  end

  describe "the loop, wired together" do
    test "a delivered acceptance event reaches the handler and is recorded" do
      # The integration, over the real table and the real registry. Without
      # this the unit tests above could all be green with a registry nothing
      # read.
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
      # The packet's claim, over the real loop. A payload whose account_id is
      # not a uuid reaches `Courier.Notifications` and is refused by the
      # changeset — the handler ran, the action failed, and the row must come
      # back on the next pass rather than being dropped on the floor.
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
      # Core's rule 1, at the level it is enforced: the unique constraint IS
      # the dedupe. The second insert is refused, so the handler runs once and
      # one notification exists — the claim "not acted on twice" is a claim
      # about the action, not only about the row.
      assert {:ok, _} = Consumers.record(envelope())
      assert {:error, :already_consumed} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1
      assert Notifications.unread_count(@account_id, {"user", @payload["user_id"]}) == 1
    end
  end
end
