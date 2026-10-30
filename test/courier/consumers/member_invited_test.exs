defmodule Courier.Consumers.MemberInvitedTest do
  @moduledoc """
  `identity.member.invited` → an invitation email, and the refusal that is the
  honest answer for most of the events this bus will ever deliver.


  This is the **first event courier consumes**, so it is also the first place
  the consumer contract gets written down:

    * an event courier can parse is dispatched, and the handler is reached;
    * a payload courier **cannot** parse is refused by name and **nothing is
      sent** — a malformed event is refused, never guessed at;
    * a payload courier could parse but not render is refused *with the reason*,
      and a counterfactual proves the refusal is about this payload rather than
      a function that refuses everything.


  `identity.member.invited` (identity's `internal/outbox/tenancy.go`, verified
  there and **not re-derived here**) carries exactly five fields:

      account_id, invitation_id, email, role, invited_by_id

  `Courier.Mailers`'s `team_invitation` requires `email`, `url`,
  `account_name`, and `invited_by` — and **none of the four beyond `email` is
  in the event.** Two of the three gaps could be closed by a lookup. The third
  cannot be closed by anything:

  > **The accept `url` is unrecoverable from the event, and so is the invitation
  > token.** identity returns the one-time token in the `201` and stores only its
  > SHA-256 (`internal/accounts/store.go:145` holds `token_digest`;
  > `internal/httpapi/accounts.go` says the token is "returned in the 201 and
  > never again — there is no column holding it, only its SHA-256, and no
  > operation that re-reads one").

  So a consumer cannot render a working accept link, because there is no link to
  render. **That is why this handler refuses rather than sends**: a
  `team_invitation` with an empty `url` renders `Accept the invitation:`
  followed by nothing — mail to a stranger, on a domain they have no reason to
  trust, ending in a broken promise.

  The fix belongs in identity — carry the token, or a redeemable URL, in the
  event — and this repository does not touch identity. It is REPORTED, in
  `REPORT-courier-consumer-invite-01`.


  `account_name` and the inviter's display name could each be fetched from
  identity over HTTP. Building those calls would make this handler a second
  identity client — a second base URL, a second credential, a second failure
  mode, a second thing to keep in step with identity's `openapi.yaml` — in
  exchange for **a mail with a broken link in it**. Strictly worse than
  refusing, and that is why the refusals below are refusals rather than "not
  implemented yet".


  `handle/1` is given the `consumed_events` row, not the envelope as it arrived.
  These tests build the row the subscriber would have written, which is also why
  every arm below is a malformed **payload** rather than a malformed envelope:
  a row courier cannot key is refused earlier than this, by
  `Courier.Consumers.record/2`, because an envelope with no id has nothing to be
  idempotent on.
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers.MemberInvited
  alias Courier.Consumers.Subject

  @payload %{
    "account_id" => "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51",
    "invitation_id" => "9c8d7e6f-1111-4222-8333-444455556666",
    "email" => "invitee@example.com",
    "role" => "member",
    "invited_by_id" => "7b6c5d4e-2222-4333-8444-555566667777"
  }

  defp row(overrides \\ %{}) do
    struct!(
      %ConsumedEvent{
        id: "6a3f2b1c-0000-4000-8000-000000000001",
        type: "identity.member.invited",
        source: "identity",
        subject: "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51",
        time: ~U[2026-10-06 12:00:00.000000Z],
        attempt_count: 0,
        data: @payload
      },
      overrides
    )
  end

  describe "the subject courier claims an envelope under" do
    test "is the envelope's own type, not a mapping table" do
      assert Subject.for("identity.member.invited") == "identity.member.invited"
    end

    test "takes an atom too, because a handler can be handed either" do
      assert Subject.for(:"identity.member.invited") == "identity.member.invited"
    end
  end

  describe "an event courier can parse" do
    test "is dispatched and the payload reaches the handler whole" do
      assert {:ok, invitation} = MemberInvited.parse(row())

      assert invitation.email == "invitee@example.com"
      assert invitation.account_id == "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
      assert invitation.invitation_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert invitation.role == "member"
      assert invitation.invited_by_id == "7b6c5d4e-2222-4333-8444-555566667777"
    end

    test "names the same type the registry is keyed on" do
      assert MemberInvited.type() == "identity.member.invited"
      assert Courier.Consumers.handler_for(MemberInvited.type()) == MemberInvited
    end

    test "carries no token and no url, and that is asserted rather than assumed" do
      {:ok, invitation} = MemberInvited.parse(row())

      refute Map.has_key?(invitation, :token)
      refute Map.has_key?(invitation, :url)
    end
  end

  describe "an event courier cannot parse" do
    test "is refused when the row is not a row" do
      assert {:error, :unreadable_envelope} = MemberInvited.parse("identity.member.invited")
      assert {:error, :unreadable_envelope} = MemberInvited.parse(%{})
    end

    test "is refused when the row has no id to attribute the refusal to" do
      assert {:error, :unreadable_envelope} = MemberInvited.parse(row(%{id: nil}))
      assert {:error, :unreadable_envelope} = MemberInvited.parse(row(%{id: ""}))
    end

    test "is refused when the type is not the one this handler is for" do
      assert {:error, :not_this_event} =
               MemberInvited.parse(row(%{type: "identity.member.removed"}))
    end

    test "is refused when a required payload field is missing" do
      for field <- ~w(account_id invitation_id email role invited_by_id) do
        assert {:error, {:incomplete_payload, ^field}} =
                 MemberInvited.parse(row(%{data: Map.delete(@payload, field)})),
               "a payload missing #{field} must be refused by name, not guessed at"
      end
    end

    test "is refused when a required payload field is not a string" do
      assert {:error, {:incomplete_payload, "email"}} =
               MemberInvited.parse(row(%{data: %{@payload | "email" => ["invitee@example.com"]}}))

      assert {:error, {:incomplete_payload, "email"}} =
               MemberInvited.parse(row(%{data: %{@payload | "email" => 42}}))
    end

    test "is refused, by name, when the payload is empty" do
      assert {:error, {:incomplete_payload, "data"}} = MemberInvited.parse(row(%{data: %{}}))
    end
  end

  describe "a payload courier could parse but not render" do
    test "is refused, and the reason names what cannot be known" do
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)
    end

    test "refuses BEFORE anything is dialled, so no row claims an invitation went out" do
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 0
      assert_no_email_sent()
    end

    test "would send, and is refused before the provider only because the url is absent" do
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:ok, %{message_id: message_id}} = MemberInvited.deliver(renderable(invitation))

      assert is_binary(message_id)
      assert String.starts_with?(message_id, "courier-")
    end

    test "with a url but no names, courier's refusal is followed by `Courier.Mailers`' — and the ORDER is url first" do
      {:ok, invitation} = MemberInvited.parse(row())
      invitation = Map.put(invitation, :url, "https://anywaye.example/invitations/tok")

      assert {:error, {:invalid_payload, changeset}} = MemberInvited.deliver(invitation)

      fields = Enum.map(changeset.errors, &elem(&1, 0))

      assert :account_name in fields
      assert :invited_by in fields
    end

    test "reaches `Courier.Deliver`, so the preferences and the mailbox are consulted" do
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:ok, _} = MemberInvited.deliver(renderable(invitation))

      assert_email_sent(fn email ->
        assert [{_name, "invitee@example.com"}] = email.to
        assert email.text_body =~ "invitations/tok"
      end)
    end

    test "writes the outbox row, so a sent invitation is visible to the platform" do
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:ok, %{event_id: event_id}} = MemberInvited.deliver(renderable(invitation))

      assert Repo.get(Courier.OutboxEvent, event_id).type == "courier.email.delivered"
    end

    defp renderable(invitation) do
      Map.merge(invitation, %{
        url: "https://anywaye.example/invitations/tok",
        account_name: "Acme",
        invited_by: "Ada"
      })
    end
  end

  describe "a handler that fails" do
    test "answers rather than raising, so the loop can record it and move on" do
      {:ok, invitation} = MemberInvited.parse(row())
      invitation = Map.put(invitation, :url, "https://anywaye.example/invitations/tok")

      assert {:error, {:invalid_payload, _changeset}} =
               MemberInvited.deliver(%{invitation | email: nil})
    end

    test "the refusal is one of courier's own, not a new vocabulary" do
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)

      assert {:error, {:invalid_payload, _changeset}} =
               MemberInvited.deliver(Map.put(renderable(invitation), :email, nil))
    end
  end
end
