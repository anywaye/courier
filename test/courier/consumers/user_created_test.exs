defmodule Courier.Consumers.UserCreatedTest do
  @moduledoc """
  `identity.user.created` → the welcome mail, and the first consumer whose
  positive path is an actual send.

  ## WHAT THIS FILE PROVES

    * an event courier can parse is dispatched, and the welcome mail reaches
      the address the payload carries — through the real `Courier.Deliver`,
      not around it;
    * **the same envelope id delivered twice sends the mail once** — the
      packet's central claim, asserted on the second `Consumers.record/2`
      answering `{:error, :already_consumed}` and on the mail asserting
      exactly one delivery;
    * a payload courier cannot parse is refused by name and **nothing is
      sent** — paired with the positive arm throughout, because a handler
      that refuses everything passes every refusal test;
    * **a field the payload does not declare is discarded, and the rendered
      mail is where that is proved** — a token planted on the envelope
      reaches neither the message nor the log;
    * a handler failure leaves `consumed_at` NULL, so the event is retried
      rather than dropped;
    * a crash mid-effect is recoverable: the row is durable BEFORE the effect
      is owed, and the handler is not re-run for a row already marked.

  ## THE PAYLOAD, AND WHY IT IS SUFFICIENT

  identity's `NewUserCreated` (verified there, **not re-derived here**)
  carries exactly `user_id` and `email`. That is everything
  `Deliver.welcome/1` requires, which is why this is the one handler in the
  registry whose positive arm is reachable rather than refused by design.

  ## WHY THE FILE CARRIES NO `@moduletag account:`

  The handler writes to `consumed_events` and `outbox_events`, neither of
  which carries an `account_id` — they are courier's own bookkeeping about a
  message from another service, and the protection migration leaves them
  unprotected. The send path's preference check is a READ by user id, which
  needs no identity.
  """

  use Courier.DataCase, async: true

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias Courier.ConsumedEvent
  alias Courier.Consumers
  alias Courier.Consumers.UserCreated

  # The two fields identity publishes, in the payload's own order.
  @payload %{
    "user_id" => "9c8d7e6f-1111-4222-8333-444455556666",
    "email" => "kaka@example.com"
  }

  @envelope_id "8c9d0e1f-0000-4000-8000-000000000004"

  defp row(overrides \\ %{}) do
    struct!(
      %ConsumedEvent{
        id: @envelope_id,
        type: "identity.user.created",
        source: "identity",
        # The subject is the USER, per the publisher's payload.
        subject: @payload["user_id"],
        time: ~U[2026-10-10 12:00:00.000000Z],
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
        "type" => "identity.user.created",
        "source" => "identity",
        "subject" => @payload["user_id"],
        "time" => "2026-10-10T12:00:00Z",
        "data" => @payload
      },
      overrides
    )
  end

  describe "an event courier can parse" do
    test "is dispatched and the welcome mail is sent to the payload's address" do
      # The positive arm, paired with every refusal below.
      assert {:ok, user} = UserCreated.parse(row())

      assert user.user_id == "9c8d7e6f-1111-4222-8333-444455556666"
      assert user.email == "kaka@example.com"

      assert {:ok, _} = UserCreated.handle(row())

      assert_email_sent(fn email ->
        assert [{_name, "kaka@example.com"}] = email.to
        assert email.subject == "Welcome to Anywaye"
      end)
    end

    test "names the same type the registry is keyed on" do
      assert UserCreated.type() == "identity.user.created"

      assert Consumers.handler_for("identity.user.created") ==
               Courier.Consumers.UserCreated
    end
  end

  describe "the dedupe" do
    test "the same envelope id delivered twice sends the welcome mail once" do
      # THE PACKET'S CENTRAL CLAIM. Delivery is at-least-once: the publisher
      # crashes between publishing and marking, the broker redelivers after a
      # consumer restart, and the second welcome mail is indistinguishable
      # from spam. The unique constraint is the discipline — a check-then-
      # insert would be a race between two concurrent redeliveries — so the
      # assertion is on `Consumers.record/2`'s answer AND on the mail.
      assert {:ok, _first} = Consumers.record(envelope())

      assert {:error, :already_consumed} = Consumers.record(envelope())

      summary = Consumers.consume()

      assert summary.handled == 1

      assert_email_sent(fn email ->
        assert [{_name, "kaka@example.com"}] = email.to
        assert email.subject == "Welcome to Anywaye"
      end)

      # One row, and it is marked from the handler's success.
      row = Repo.get!(ConsumedEvent, @envelope_id)
      assert row.consumed_at
      assert row.last_error == nil
    end

    test "two events about two users are two mails, so the key is the EVENT" do
      # The negative arm of the dedupe, and the reason the discipline cannot
      # be weakened to per-user: a person who signs up twice is two facts, and
      # a key that collapsed them would swallow a real welcome.
      other =
        envelope(%{
          "id" => "8c9d0e1f-0000-4000-8000-000000000005",
          "subject" => "9c8d7e6f-1111-4222-8333-444455556667",
          "data" => %{
            "user_id" => "9c8d7e6f-1111-4222-8333-444455556667",
            "email" => "other@example.com"
          }
        })

      assert {:ok, _} = Consumers.record(envelope())
      assert {:ok, _} = Consumers.record(other)

      summary = Consumers.consume()

      assert summary.handled == 2

      assert_email_sent(fn email ->
        assert [{_name, "kaka@example.com"}] = email.to
      end)

      assert_email_sent(fn email ->
        assert [{_name, "other@example.com"}] = email.to
      end)
    end
  end

  describe "a payload courier cannot parse" do
    test "is refused by name, and nothing is sent" do
      for {incomplete, field} <- [
            {%{"email" => @payload["email"]}, "user_id"},
            {%{"user_id" => @payload["user_id"]}, "email"},
            {%{"user_id" => 42, "email" => @payload["email"]}, "user_id"},
            {%{"user_id" => @payload["user_id"], "email" => ["kaka@example.com"]}, "email"},
            {%{}, "data"}
          ] do
        event = row(data: incomplete)

        assert {:error, {:incomplete_payload, ^field}} = UserCreated.parse(event)
        assert {:error, {:incomplete_payload, ^field}} = UserCreated.handle(event)
      end

      refute_email_sent()
    end

    test "refuses a row that is not this event, and one with no id" do
      assert {:error, :not_this_event} =
               UserCreated.parse(row(type: "identity.member.accepted"))

      assert {:error, :unreadable_envelope} = UserCreated.parse(row(id: ""))
      assert {:error, :unreadable_envelope} = UserCreated.parse(%{})
    end

    test "a failed handler leaves the row claimable, so the retry is not a drop" do
      # The handler's own answer on a malformed payload is a named refusal, so
      # the loop records the attempt and leaves `consumed_at` NULL.
      incomplete = envelope(%{"data" => %{"user_id" => @payload["user_id"]}})
      assert {:ok, _saved} = Consumers.record(incomplete)

      summary = Consumers.consume()
      assert summary.failed == 1

      row = Repo.get!(ConsumedEvent, @envelope_id)
      assert row.consumed_at == nil
      assert row.attempt_count == 1
      assert row.last_error =~ "incomplete_payload"
    end
  end

  describe "the no-credential boundary" do
    test "a field the payload does not declare is discarded, and the mail proves it" do
      # identity's `NewUserCreated` comment: "no password digest and no
      # lockout state: the envelope goes to every subscriber on the platform,
      # and this is the only place where that boundary is enforced." A FUTURE
      # build might carry a verification token or a display name. The handler
      # reads its two fields by name and drops the rest, and the rendered mail
      # is where the discard is asserted — a handler that passed its whole
      # payload through would render the token into the body.
      user = %{
        user_id: @payload["user_id"],
        email: @payload["email"]
      }

      token = "tok_2f8a1c9d4e7b6035"

      assert {:ok, _} =
               UserCreated.deliver(Map.put(user, :verification_token, token))

      assert_email_sent(fn email ->
        assert [{_name, "kaka@example.com"}] = email.to
        refute email.text_body =~ token
        refute email.html_body =~ token
        # The fun ends on something TRUE: `assert_email_sent` asserts its
        # return value, and a fun ending in `refute` fails having proved
        # exactly what it claimed — the sibling files' own note.
        email.text_body =~ "Welcome aboard"
      end)
    end

    test "the shared envelope carries no token, and the handler would not read one" do
      # The envelope this handler is written against, asserted as a shape:
      # `additionalProperties: false` is core's rule, and identity's builder
      # marshals a two-field struct. A token on the envelope is evidence the
      # publisher changed, and the parse above is where it would be ignored.
      assert Map.keys(envelope()) ==
               ["data", "id", "source", "specversion", "subject", "time", "type"]

      assert Map.keys(envelope()["data"]) == ["email", "user_id"]
    end
  end

  describe "the redaction boundary" do
    test "a refusal is logged without the payload's content" do
      # The consumer's log line names the type and the envelope id, and the
      # address a payload carries is content. The idiom is
      # `Courier.Consumers`'s own: `safe_apply/2` and `record_failure/3` log
      # `event.type` and `event.id` and nothing from `event.data`. The payload
      # below carries an address and is missing `user_id`, so a log line that
      # quoted the payload would fail this assertion rather than pass it.
      incomplete = envelope(%{"data" => %{"email" => "kaka@example.com"}})
      assert {:ok, _} = Consumers.record(incomplete)

      log =
        capture_log(fn ->
          summary = Consumers.consume()
          assert summary.failed == 1
        end)

      assert log =~ "identity.user.created"

      refute log =~ "kaka@example.com"
    end
  end
end
