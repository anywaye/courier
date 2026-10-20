defmodule Courier.Consumers.MemberInvitedTest do
  @moduledoc """
  `identity.member.invited` → an invitation email, and the refusal that is the
  honest answer for most of the events this bus will ever deliver.

  ## WHAT THIS FILE IS, AND WHY IT IS MOSTLY REFUSALS

  This is the **first event courier consumes**, so it is also the first place
  the consumer contract gets written down:

    * an event courier can parse is dispatched, and the handler is reached;
    * a payload courier **cannot** parse is refused by name and **nothing is
      sent** — a malformed event is refused, never guessed at;
    * a payload courier could parse but not render is refused *with the reason*,
      and a counterfactual proves the refusal is about this payload rather than
      a function that refuses everything.

  ## THE PAYLOAD GAP IS THE SUBJECT OF THIS FILE, NOT A FOOTNOTE

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

  ## WHY THE LOOKUPS ARE NOT BUILT ANYWAY

  `account_name` and the inviter's display name could each be fetched from
  identity over HTTP. Building those calls would make this handler a second
  identity client — a second base URL, a second credential, a second failure
  mode, a second thing to keep in step with identity's `openapi.yaml` — in
  exchange for **a mail with a broken link in it**. Strictly worse than
  refusing, and that is why the refusals below are refusals rather than "not
  implemented yet".

  ## THE HANDLER TAKES THE ROW

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

  # The five fields identity publishes, in the payload's own order.
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
        # The subject is the ACCOUNT, per core's catalog.
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
      # The relay publishes on `event.type` with no mapping between the two, and
      # core's rule is that the type IS the subject. A consumer that mapped
      # `identity.member.invited` onto something of its own would break the day a
      # second consumer of the same type appeared.
      assert Subject.for("identity.member.invited") == "identity.member.invited"
    end

    test "takes an atom too, because a handler can be handed either" do
      assert Subject.for(:"identity.member.invited") == "identity.member.invited"
    end
  end

  describe "an event courier can parse" do
    test "is dispatched and the payload reaches the handler whole" do
      # The positive arm, paired with every refusal below for the reason this
      # repository keeps repeating: a handler that refuses everything passes
      # every refusal test.
      assert {:ok, invitation} = MemberInvited.parse(row())

      assert invitation.email == "invitee@example.com"
      assert invitation.account_id == "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
      assert invitation.invitation_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert invitation.role == "member"
      assert invitation.invited_by_id == "7b6c5d4e-2222-4333-8444-555566667777"
    end

    test "names the same type the registry is keyed on" do
      # Two strings that must be one: the handler's `type/0` and the key in
      # `config :courier, :consumers`. A refactor that changes one and not the
      # other is a message received and dropped, and it is a test rather than a
      # comment because the two live in different files.
      assert MemberInvited.type() == "identity.member.invited"
      assert Courier.Consumers.handler_for(MemberInvited.type()) == MemberInvited
    end

    test "carries no token and no url, and that is asserted rather than assumed" do
      # The load-bearing negative. identity returns the token in the 201 and
      # stores its digest, so an envelope carrying one would be evidence the
      # publisher had changed — and the handler would then be withholding mail
      # it could send. This is the assertion that would catch that change.
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
      # `Courier.Consumers.record/2` refuses these before the row exists; this
      # arm is the handler refusing a hand-built one, so a caller reaching past
      # the record path gets a refusal rather than a crash.
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
      # A number, a list, a nested object: `to_string/1` would render all three
      # happily and produce an invitation naming `invitee@example.com` from a
      # field that was a list. **The refusal is on the SHAPE, before the value
      # is read**, so the reason cannot be produced by a field whose type is
      # wrong — which is the whole point of checking shape first.
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
      # The heart of the packet. courier has all five of these; the invitation
      # cannot be sent because of the four it does not, and the reason says
      # which.
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)
    end

    test "refuses BEFORE anything is dialled, so no row claims an invitation went out" do
      # The whole point of checking first: a send that reached the provider and
      # then refused would leave an outbox row and a `courier.email.delivered`
      # event for mail nobody received — the silent-default failure the adapter
      # work in this repository exists to end, reached from the consumer side.
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)

      assert Repo.aggregate(Courier.OutboxEvent, :count, :id) == 0
      assert_no_email_sent()
    end

    test "would send, and is refused before the provider only because the url is absent" do
      # The counterfactual, and a test rather than a comment because it is the
      # only thing that proves `:missing_acceptance_url` is a refusal about THIS
      # payload and not a function that refuses everything. Mutation: make
      # `deliver/1` ignore the url and this fails.
      {:ok, invitation} = MemberInvited.parse(row())

      assert {:ok, %{message_id: message_id}} = MemberInvited.deliver(renderable(invitation))

      assert is_binary(message_id)
      assert String.starts_with?(message_id, "courier-")
    end

    test "with a url but no names, courier's refusal is followed by `Courier.Mailers`' — and the ORDER is url first" do
      # The second gap, and a different shape from the first.
      #
      # `account_name` and `invited_by` are RECOVERABLE — a lookup closes them —
      # and `Courier.Mailers` already refuses them, in its own vocabulary, as a
      # changeset. `url` is not recoverable, so courier refuses it in its own.
      #
      # **The order matters and is asserted here.** Checking the names first would
      # answer `:invalid_payload` — a validation error that reads like the
      # caller's mistake, on an event courier did not author — and would hide the
      # permanent gap behind the recoverable one. The permanent one is reported
      # first, in courier's own vocabulary, because courier is the thing that
      # knows it.
      {:ok, invitation} = MemberInvited.parse(row())
      invitation = Map.put(invitation, :url, "https://cafaye.example/invitations/tok")

      assert {:error, {:invalid_payload, changeset}} = MemberInvited.deliver(invitation)

      fields = Enum.map(changeset.errors, &elem(&1, 0))

      assert :account_name in fields
      assert :invited_by in fields
    end

    test "reaches `Courier.Deliver`, so the preferences and the mailbox are consulted" do
      # The send goes through the ONE door, not around it: a handler that dialled
      # a provider itself would skip the preference check, the unsubscribe check
      # and the suppression check, and an invitee who unsubscribed from team
      # invitations would get one anyway. **Asserting on the mail is what makes
      # that a claim** — it reads what the adapter was handed, so a handler that
      # rendered the message and threw it away fails here.
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

    # What the invitation would carry **if identity published it**: the three
    # fields the template requires and the event does not have, so the
    # counterfactual arms can reach the provider at all.
    defp renderable(invitation) do
      Map.merge(invitation, %{
        url: "https://cafaye.example/invitations/tok",
        account_name: "Acme",
        invited_by: "Ada"
      })
    end
  end

  describe "a handler that fails" do
    test "answers rather than raising, so the loop can record it and move on" do
      # A raise here would be a denial of service on the whole event stream:
      # `Courier.Consumers` wraps the call, but the handler should not rely on
      # being wrapped for its own error handling. A payload whose email is nil
      # reaches `Courier.Deliver` and is refused by `Courier.Mailers`.
      {:ok, invitation} = MemberInvited.parse(row())
      invitation = Map.put(invitation, :url, "https://cafaye.example/invitations/tok")

      assert {:error, {:invalid_payload, _changeset}} =
               MemberInvited.deliver(%{invitation | email: nil})
    end

    test "the refusal is one of courier's own, not a new vocabulary" do
      # **This handler adds exactly ONE refusal of its own** —
      # `:missing_acceptance_url` — and everything else it returns is
      # `Courier.Deliver`'s or `Courier.Mailers`', unchanged. A handler that
      # invented a third dialect for them would put every future caller in the
      # position of matching on strings nobody else produces.
      {:ok, invitation} = MemberInvited.parse(row())

      # Its own, because the accept link is not recoverable from any event.
      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)

      # `Courier.Mailers`', once there is a url to refuse over.
      assert {:error, {:invalid_payload, _changeset}} =
               MemberInvited.deliver(Map.put(renderable(invitation), :email, nil))
    end
  end
end
