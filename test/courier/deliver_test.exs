defmodule Courier.DeliverTest do
  @moduledoc """
  `Courier.Deliver` is where courier's three promises meet: the user's
  preference wins, the provider's answer is recorded, and the event describing
  the send is written in the same transaction as the send — so a message that
  went out is a message the platform can see, and a message the platform cannot
  see did not go out.

  Nothing here touches NATS. The relay that publishes to NATS is
  `Courier.Workers.ProcessOutboxWorker`, and this file asserts only that the row
  is there, in the shape the relay will publish.
  """

  use Courier.DataCase, async: true

  import Swoosh.TestAssertions

  alias Courier.Deliver
  alias Courier.NotificationPreferences
  alias Courier.OutboxEvent
  alias Courier.Unsubscribes

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @other_user_id "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  # The address the unsubscribe tests use. A per-file constant and not a shared
  # one: `email_suppressions` has no `account_id` and its rows are permanent, so an
  # address another test also unsubscribed would decide this one's outcome.
  @email "unsubscribe-deliver@example.com"

  # A tenancy key, not a credential and not a secret: the account a stored
  # preference belongs to. The delivery payload carries no account, and that is
  # what this block exists to show is fine.
  @account_id "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account_id

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        url: "https://cafaye.com/verify?token=abc123"
      },
      overrides
    )
  end

  # Read with no `order_by`, deliberately — see the assertion at the end of
  # "every type courier sends". courier promises what each row *is*, not what
  # order the database hands rows back in, so nothing here may depend on the
  # second one.
  defp outbox, do: Repo.all(OutboxEvent)

  # The rows that record a SEND. Separate from `outbox/0` because the one-click
  # unsubscribe announces itself — it writes a `courier.notification.suppressed`
  # row of its own — and the claim under test is "no send was recorded", not "the
  # outbox is empty". A test asserting the second would be asserting something
  # false, and fixing it by clearing the table would be asserting something else.
  defp sends,
    do: Repo.all(from event in OutboxEvent, where: event.type == ^Courier.Events.delivered_type())

  describe "welcome" do
    test "sends the mail" do
      assert {:ok, _result} = Deliver.welcome(payload())

      assert_email_sent(subject: "Welcome to caFaye", to: [{"Kaka", "kaka@example.com"}])
    end

    test "returns the notification's message id and the id of the event recording it" do
      assert {:ok, result} = Deliver.welcome(payload())

      assert result.notification_type == "welcome"
      assert result.message_id =~ ~r/^courier-[0-9a-f-]{36}$/
      assert {:ok, _uuid} = Ecto.UUID.cast(result.event_id)
    end

    test "the sent message carries the returned id, as a real Message-ID header" do
      assert {:ok, result} = Deliver.welcome(payload())

      # Swoosh's Test adapter hands the message over as `{:email, email}`, and
      # `assert_email_sent/0` returns that message as it received it.
      assert {:email, sent} = assert_email_sent()
      assert sent.headers["message-id"] == "<#{result.message_id}@cafaye.com>"
    end

    test "the event subject is the notification the event is about" do
      assert {:ok, result} = Deliver.welcome(payload())

      assert [event] = outbox()
      assert event.subject == result.message_id
    end

    test "records the send in the outbox, unpublished" do
      assert {:ok, _result} = Deliver.welcome(payload())

      assert [event] = outbox()
      assert event.type == "courier.email.delivered"
      assert event.source == "courier"
      assert event.published_at == nil
      assert event.attempt_count == 0
      assert %DateTime{time_zone: "Etc/UTC"} = event.occurred_at
    end

    test "the recorded event carries the message id, the recipient, and the user" do
      assert {:ok, result} = Deliver.welcome(payload())

      assert [event] = outbox()

      assert event.data["message_id"] == result.message_id
      assert event.data["email"] == "kaka@example.com"
      assert event.data["user_id"] == @user_id
      assert event.data["notification_type"] == "welcome"
    end

    test "the recorded data is about the send, not a copy of the payload" do
      # The event goes to every subscriber on NATS. A verification token or an
      # invitation id in there would be a credential leak into a fan-out, so the
      # data is the send's own fields and nothing else.
      {:ok, _} = Deliver.welcome(payload())

      assert [event] = outbox()

      refute "url" in Map.keys(event.data)
      refute "name" in Map.keys(event.data)
    end

    test "two sends are two notifications with two ids" do
      assert {:ok, first} = Deliver.welcome(payload())
      assert {:ok, second} = Deliver.welcome(payload())

      refute first.message_id == second.message_id
      refute first.event_id == second.event_id
      assert length(outbox()) == 2
    end
  end

  describe "every type courier sends" do
    test "sends and records each one under its own notification type" do
      assert {:ok, welcome} = Deliver.welcome(payload())

      assert {:ok, reset} =
               Deliver.password_reset(payload(%{url: "https://cafaye.com/reset?t=1"}))

      assert {:ok, invitation} =
               Deliver.team_invitation(payload(%{account_name: "Moon", invited_by: "Ruto"}))

      assert {:ok, security} =
               Deliver.account_security(payload(%{reason: "password reset"}))

      assert {:ok, change_current} =
               Deliver.email_change_current(
                 payload(%{url: "https://cafaye.com/email-changes/c?t=1"})
               )

      assert {:ok, change_new} =
               Deliver.email_change_new(payload(%{previous_email: "kaka@example.com"}))

      assert welcome.notification_type == "welcome"
      assert reset.notification_type == "password_reset"
      assert invitation.notification_type == "team_invitation"
      assert security.notification_type == "account_security"
      assert change_current.notification_type == "email_change_current"
      assert change_new.notification_type == "email_change_new"

      # Sorted on both sides, and that is the whole point of this assertion. What
      # courier promises is that each of the six sends recorded a row under its
      # own notification type — a set of six, one per type. `outbox/0` reads
      # with no `ORDER BY`, so the order rows come back in is PostgreSQL's choice
      # and not a contract; comparing sequences here asserted an ordering nobody
      # promised and failed in roughly one run in eight. Sorting keeps the
      # assertion exactly as strong (all six types present, each exactly once,
      # nothing else) while dropping the part that was never courier's promise.
      assert outbox() |> Enum.map(& &1.data["notification_type"]) |> Enum.sort() ==
               Enum.sort(
                 ~w(welcome password_reset team_invitation account_security email_change_current email_change_new)
               )
    end

    test "a password reset and a team invitation are different messages" do
      {:ok, _} = Deliver.password_reset(payload(%{url: "https://cafaye.com/reset?t=1"}))
      {:ok, _} = Deliver.team_invitation(payload(%{account_name: "Moon", invited_by: "Ruto"}))

      assert_email_sent(subject: "Reset your caFaye password")
      assert_email_sent(subject: "Ruto invited you to join Moon")
    end
  end

  describe "preferences" do
    setup do
      # An account, because a preference now records the account entitled to it.
      # Which account it is does not matter here and that is the point being
      # asserted four times over: `Courier.Deliver` reads `enabled?/3`, which
      # takes a user and no account, so the delivery path is unaffected by which
      # tenant the answer was stored under.
      {:ok, _} =
        NotificationPreferences.update(@account_id, @user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })

      :ok
    end

    test "a type the user turned off sends no mail" do
      assert {:error, :suppressed} = Deliver.welcome(payload())

      refute_received {:email, _email}
    end

    test "a type the user turned off records no event" do
      assert {:error, :suppressed} = Deliver.welcome(payload())

      assert outbox() == []
    end

    test "another type still goes out" do
      assert {:ok, _result} =
               Deliver.password_reset(
                 payload(%{email: @email, url: "https://cafaye.com/reset?t=1"})
               )

      assert_email_sent(subject: "Reset your caFaye password")
      assert [%{type: "courier.email.delivered"}] = outbox()
    end

    test "another user is unaffected" do
      assert {:ok, _result} = Deliver.welcome(payload(%{user_id: @other_user_id}))

      assert [%{data: %{"user_id" => @other_user_id}}] = outbox()
    end
  end

  describe "a one-click unsubscribe" do
    setup do
      # Minted through the real endpoint's own path — `issue/3`, then
      # `unsubscribe/1` — rather than by writing a row, so what is set up here is
      # exactly what a `POST` from a mail client would leave behind.
      {:ok, token} = Unsubscribes.issue(@user_id, "welcome", @email)
      {:ok, :recorded} = Unsubscribes.unsubscribe(token)
      :ok
    end

    test "a type they unsubscribed from sends no mail" do
      assert {:error, {:unsubscribed, "welcome"}} = Deliver.welcome(payload(%{email: @email}))

      refute_received {:email, _email}
    end

    test "a type they unsubscribed from records no event" do
      assert {:error, {:unsubscribed, "welcome"}} = Deliver.welcome(payload(%{email: @email}))

      assert sends() == []
    end

    test "another type still goes out, and that is the whole point of the row" do
      # A one-click unsubscribe is an instruction about ONE type, so it is recorded
      # as an `email_suppressions` row with **no state** — a stateful row there is
      # read by the address-level check and would stop a password reset as well.
      assert {:ok, _result} =
               Deliver.password_reset(
                 payload(%{email: @email, url: "https://cafaye.com/reset?t=1"})
               )

      assert_email_sent(subject: "Reset your caFaye password")
      assert [%{type: "courier.email.delivered"}] = sends()
    end

    test "and it is a different refusal from a declined preference" do
      # Two facts about the same person with two different remedies, and a caller
      # that cannot tell them apart cannot act: one is a `PUT` away from being sent
      # again and the other is not. `Courier.UnsubscribesTest` proves the row is
      # state-less; this proves the send path names them differently.
      assert {:error, {:unsubscribed, "welcome"}} = Deliver.welcome(payload(%{email: @email}))

      {:ok, _} =
        NotificationPreferences.update(@account_id, @user_id, %{
          "preferences" => [%{"notification_type" => "team_invitation", "email_enabled" => false}]
        })

      assert {:error, :suppressed} =
               Deliver.team_invitation(
                 payload(%{
                   email: @email,
                   url: "https://cafaye.com/join",
                   account_name: "Acme",
                   invited_by: "Kaka"
                 })
               )
    end
  end

  describe "failures" do
    test "a payload courier cannot send is refused before the provider is asked" do
      assert {:error, {:invalid_payload, changeset}} = Deliver.welcome(payload(%{email: nil}))

      assert %{email: ["can't be blank"]} = errors_on(changeset)
      refute_received {:email, _email}
      assert outbox() == []
    end

    test "a payload with no user has no preferences to check and no row to write" do
      assert {:error, :missing_user_id} = Deliver.welcome(payload(%{user_id: nil}))

      assert outbox() == []
    end

    test "an unknown notification type is an error, not a best guess" do
      assert {:error, :unknown_notification_type} =
               Deliver.email("weekly_digest", payload())

      assert outbox() == []
    end
  end
end
