defmodule Courier.Consumers.MemberInvitedTest do
  @moduledoc """
  `identity.member.invited` → an invitation email, and the refusal that is the
  honest answer for most of the events this bus will ever deliver.

  ## WHAT THIS FILE IS, AND WHY IT IS MOSTLY REFUSALS

  This is the **first event courier consumes**, so it is also the first place
  the consumer contract has to be written down. The contract this file proves:

    * an envelope courier can parse is dispatched, and the handler is reached;
    * an envelope courier **cannot** parse is refused with a named reason and
      **nothing is sent** — a malformed event is refused, never guessed at;
    * an event courier does not subscribe to is not a failure and not a send;
    * a handler that fails does not take the consumer down.

  ## THE PAYLOAD GAP IS THE SUBJECT OF THIS FILE, NOT A FOOTNOTE

  `identity.member.invited` (identity's `internal/outbox/tenancy.go`, verified
  there and **not re-derived here**) carries exactly five fields:

      account_id, invitation_id, email, role, invited_by_id

  `Courier.Mailers`'s `team_invitation` requires `email`, `url`,
  `account_name`, and `invited_by` — and **none of the four beyond `email` is
  in the event.** Two of the three gaps could be closed by a lookup. The third
  cannot be closed by anything:

  > **`url` is unrecoverable from the event, and so is the invitation token.**

  identity returns the one-time token in the `201` and **stores only its
  SHA-256** (`internal/accounts/store.go:145` stores `token_digest`;
  `internal/httpapi/accounts.go:563` says the token "is returned in the 201 and
  never again"). No column holds it, no operation re-reads it. So a consumer
  cannot render a working accept link, because there is no link to render.

  **This is why the handler refuses rather than sends.** A `team_invitation`
  with an empty `url` renders `Accept the invitation:` followed by nothing — a
  mail that reaches a stranger and asks them to trust a product they have never
  heard of, with a broken promise at the end of it. `Courier.Mailers` would
  refuse it anyway (`url` is in `required/1`), and the refusal this consumer
  produces is the one with the *reason* attached.

  The fix belongs in identity — carry the token, or a redeemable URL, in the
  event — and this repository does not touch identity. So the gap is REPORTED,
  in `REPORT-courier-consumer-invite-01.md`, with the one-line change that
  closes it.

  ## WHY THE LOOKUPS ARE NOT BUILT ANYWAY

  `account_name` and the inviter's display name could each be fetched from
  identity over HTTP. Building those calls would make this handler a second
  identity client — a second base URL, a second credential, a second failure
  mode, a second thing to keep in step with identity's `openapi.yaml` — in
  exchange for **a mail with a broken link in it**. That is a strictly worse
  trade than refusing, and it is the reason the refusals below are refusals
  rather than "unsupported because we have not got round to it".
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.Consumers.MemberInvited
  alias Courier.Consumers.Subject

  # The envelope exactly as identity builds it: `newTenancyEvent` stamps
  # `source: "identity"` and the `subject` is the ACCOUNT, per core's catalog
  # ("identity.member.invited | the account").
  defp envelope(attrs \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => "6a3f2b1c-0000-4000-8000-000000000001",
        "type" => "identity.member.invited",
        "source" => "identity",
        "subject" => "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51",
        "time" => "2026-10-06T12:00:00Z",
        "data" => %{
          "account_id" => "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51",
          "invitation_id" => "9c8d7e6f-1111-4222-8333-444455556666",
          "email" => "invitee@example.com",
          "role" => "member",
          "invited_by_id" => "7b6c5d4e-2222-4333-8444-555566667777"
        }
      },
      attrs
    )
  end

  describe "the subject courier would claim an envelope under" do
    test "is the envelope's own type, not a mapping table" do
      # The relay publishes on `event.type` with no mapping between the two, and
      # core's rule is that the type IS the subject. A consumer that mapped
      # `identity.member.invited` onto something of its own would break the day
      # a second consumer of the same type appeared.
      assert Subject.for("identity.member.invited") == "identity.member.invited"
    end

    test "is an atom too, because an Oban job's args come back as Elixir terms" do
      assert Subject.for(:"identity.member.invited") == "identity.member.invited"
    end
  end

  describe "an envelope courier can parse" do
    test "is dispatched to the handler and the payload reaches it whole" do
      # The positive arm, and it is paired with every refusal below for the
      # reason this repository keeps repeating: a handler that refuses everything
      # passes every refusal test.
      assert {:ok, invitation} = MemberInvited.handle(envelope())

      assert invitation.email == "invitee@example.com"
      assert invitation.account_id == "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
      assert invitation.invitation_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert invitation.role == "member"
      assert invitation.invited_by_id == "7b6c5d4e-2222-4333-8444-555566667777"
    end

    test "carries no token, and that is asserted rather than assumed" do
      # The load-bearing negative. identity returns the token in the 201 and
      # stores its digest, so an envelope carrying one would be evidence that the
      # publisher changed — and the handler below would then be withholding mail
      # it could send.
      {:ok, invitation} = MemberInvited.handle(envelope())

      refute Map.has_key?(invitation, :token)
      refute Map.has_key?(invitation, :url)
    end
  end

  describe "an envelope courier cannot parse" do
    test "is refused when the envelope is not a map" do
      assert {:error, :unreadable_envelope} = MemberInvited.handle("identity.member.invited")
    end

    test "is refused when the type is not the one this handler is for" do
      assert {:error, :not_this_event} =
               MemberInvited.handle(envelope(%{"type" => "identity.member.removed"}))
    end

    test "is refused when a required payload field is missing" do
      for field <- ~w(account_id invitation_id email role invited_by_id) do
        data = Map.delete(envelope()["data"], field)

        assert {:error, {:incomplete_payload, ^field}} =
                 MemberInvited.handle(envelope(%{"data" => data})),
               "a payload missing #{field} must be refused by name, not guessed at"
      end
    end

    test "is refused when a required payload field is not a string" do
      # A number, a list, a nested object: `to_string/1` would render all three
      # happily and produce an invitation naming `invitee@example.com` from a
      # field that was a list. The refusal is on the SHAPE, before the value is
      # read, so the reason cannot be produced by a field whose type is wrong.
      data = %{"email" => ["invitee@example.com"]}

      assert {:error, {:incomplete_payload, "email"}} =
               MemberInvited.handle(envelope(%{"data" => data}))
    end

    test "is refused when the envelope carries no id to claim it under" do
      assert {:error, :unreadable_envelope} =
               MemberInvited.handle(envelope(%{"id" => nil}))
    end

    test "refuses on the ENVELOPE, so a body with no data is refused and not treated as empty" do
      assert {:error, {:incomplete_payload, "data"}} =
               MemberInvited.handle(envelope(%{"data" => nil}))
    end
  end

  describe "a payload courier could render" do
    test "is refused, and the reason names the field that cannot be known" do
      # The heart of the packet. Every one of these five fields courier has; the
      # invitation cannot be sent because of the ones it does not, and the reason
      # says which.
      {:ok, invitation} = MemberInvited.handle(envelope())

      assert {:error, :missing_acceptance_url} = MemberInvited.deliver(invitation)
    end

    test "would send, and is refused before the provider, if the payload ever carried one" do
      # The counterfactual, and it is a test rather than a comment because it is
      # the only thing that proves `:missing_acceptance_url` is a refusal about
      # THIS payload and not a function that refuses everything. Mutation: make
      # `deliver/1` ignore the `url` and these two fail.
      {:ok, invitation} = MemberInvited.handle(envelope())
      invitation = Map.put(invitation, :url, "https://cafaye.example/invitations/tok")

      assert {:ok, %{message_id: message_id}} = MemberInvited.deliver(invitation)

      assert is_binary(message_id)
      assert String.starts_with?(message_id, "courier-")
    end

    test "reaches `Courier.Deliver`, so the preferences and the mailbox are consulted" do
      # The send goes through the ONE door, not around it: a handler that dialled
      # a provider itself would skip the preference check, the unsubscribe check
      # and the suppression check, and an invitee who unsubscribed from team
      # invitations would get one anyway. Asserting on the MAIL is what makes
      # that a claim — `assert_email_sent/1` reads what the adapter was handed,
      # so a handler that rendered the message and threw it away would fail
      # here, and `Courier.Deliver`'s own refusal would fail the test above it.
      {:ok, invitation} = MemberInvited.handle(envelope())
      invitation = Map.put(invitation, :url, "https://cafaye.example/invitations/tok")

      assert {:ok, _} = MemberInvited.deliver(invitation)

      assert_email_sent(fn email ->
        assert {_, "invitee@example.com"} = email.to
        assert email.text_body =~ "invitations/tok"
      end)
    end
  end

  describe "a handler that fails" do
    test "returns an error rather than raising, so the consumer can nack and move on" do
      # `MemberInvited.deliver/1` on a payload with no `url` answers rather than
      # raises; this is the property that makes that safe to call from a loop
      # that must not die. A raise here is a denial of service on the whole
      # subject, and it is a one-line mutation to prove.
      {:ok, invitation} = MemberInvited.handle(envelope())

      refute match?({:ok, _}, MemberInvited.deliver(%{invitation | email: nil}))
    end
  end
end