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

  @email "unsubscribe-deliver@example.com"

  @account_id "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"

  @moduletag account: @account_id

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        url: "https://anywaye.com/verify?token=abc123"
      },
      overrides
    )
  end

  defp outbox, do: Repo.all(OutboxEvent)

  defp sends,
    do: Repo.all(from event in OutboxEvent, where: event.type == ^Courier.Events.delivered_type())

  describe "welcome" do
    test "sends the mail" do
      assert {:ok, _result} = Deliver.welcome(payload())

      assert_email_sent(subject: "Welcome to Anywaye", to: [{"Kaka", "kaka@example.com"}])
    end

    test "returns the notification's message id and the id of the event recording it" do
      assert {:ok, result} = Deliver.welcome(payload())

      assert result.notification_type == "welcome"
      assert result.message_id =~ ~r/^courier-[0-9a-f-]{36}$/
      assert {:ok, _uuid} = Ecto.UUID.cast(result.event_id)
    end

    test "the sent message carries the returned id, as a real Message-ID header" do
      assert {:ok, result} = Deliver.welcome(payload())

      assert {:email, sent} = assert_email_sent()
      assert sent.headers["message-id"] == "<#{result.message_id}@anywaye.com>"
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
               Deliver.password_reset(payload(%{url: "https://anywaye.com/reset?t=1"}))

      assert {:ok, invitation} =
               Deliver.team_invitation(payload(%{account_name: "Moon", invited_by: "Ruto"}))

      assert {:ok, security} =
               Deliver.account_security(payload(%{reason: "password reset"}))

      assert {:ok, change_current} =
               Deliver.email_change_current(
                 payload(%{url: "https://anywaye.com/email-changes/c?t=1"})
               )

      assert {:ok, change_new} =
               Deliver.email_change_new(payload(%{previous_email: "kaka@example.com"}))

      assert {:ok, receipt} =
               Deliver.receipt(payload(%{amount_display: "19.00 USD", invoice_id: "in_1UQ"}))

      assert welcome.notification_type == "welcome"
      assert reset.notification_type == "password_reset"
      assert invitation.notification_type == "team_invitation"
      assert security.notification_type == "account_security"
      assert change_current.notification_type == "email_change_current"
      assert change_new.notification_type == "email_change_new"
      assert receipt.notification_type == "receipt"

      assert outbox() |> Enum.map(& &1.data["notification_type"]) |> Enum.sort() ==
               Enum.sort(
                 ~w(welcome password_reset team_invitation account_security email_change_current
                    email_change_new receipt)
               )
    end

    test "a password reset and a team invitation are different messages" do
      {:ok, _} = Deliver.password_reset(payload(%{url: "https://anywaye.com/reset?t=1"}))
      {:ok, _} = Deliver.team_invitation(payload(%{account_name: "Moon", invited_by: "Ruto"}))

      assert_email_sent(subject: "Reset your Anywaye password")
      assert_email_sent(subject: "Ruto invited you to join Moon")
    end
  end

  describe "preferences" do
    setup do
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
                 payload(%{email: @email, url: "https://anywaye.com/reset?t=1"})
               )

      assert_email_sent(subject: "Reset your Anywaye password")
      assert [%{type: "courier.email.delivered"}] = outbox()
    end

    test "another user is unaffected" do
      assert {:ok, _result} = Deliver.welcome(payload(%{user_id: @other_user_id}))

      assert [%{data: %{"user_id" => @other_user_id}}] = outbox()
    end
  end

  describe "a one-click unsubscribe" do
    setup do
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
      assert {:ok, _result} =
               Deliver.password_reset(
                 payload(%{email: @email, url: "https://anywaye.com/reset?t=1"})
               )

      assert_email_sent(subject: "Reset your Anywaye password")
      assert [%{type: "courier.email.delivered"}] = sends()
    end

    test "and it is a different refusal from a declined preference" do
      assert {:error, {:unsubscribed, "welcome"}} = Deliver.welcome(payload(%{email: @email}))

      {:ok, _} =
        NotificationPreferences.update(@account_id, @user_id, %{
          "preferences" => [%{"notification_type" => "team_invitation", "email_enabled" => false}]
        })

      assert {:error, :suppressed} =
               Deliver.team_invitation(
                 payload(%{
                   email: @email,
                   url: "https://anywaye.com/join",
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
