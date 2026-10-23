defmodule Courier.MailersTest do
  @moduledoc """
  Courier composes mail; it does not send it, store it, or model users. These
  tests pin what the platform hands in — a payload map keyed the way the
  platform's events are keyed — to what a person receives.

  `build/2` is what `Courier.Deliver` calls, and it is the seam that keeps
  Swoosh out of the assertions: a built `Swoosh.Email` can be read directly,
  field by field, with no adapter and no mailbox.
  """

  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias Courier.Mailers

  @from_name "Anywaye"
  @from_address "no-reply@anywaye.com"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp welcome_payload(overrides \\ %{}) do
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

  defp password_reset_payload(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        url: "https://anywaye.com/reset?token=t0ken"
      },
      overrides
    )
  end

  defp team_invitation_payload(overrides \\ %{}) do
    Map.merge(
      %{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        account_name: "Moon Labs",
        invited_by: "Ruto",
        role: "member",
        url: "https://anywaye.com/invitations/i_01J9Z8"
      },
      overrides
    )
  end

  describe "welcome" do
    test "addresses the mail from the configured sender" do
      assert {:ok, email} = Mailers.build(:welcome, welcome_payload())

      assert email.from == {@from_name, @from_address}
    end

    test "addresses the mail to the address the platform sent" do
      assert {:ok, email} = Mailers.build(:welcome, welcome_payload())

      assert [{"Kaka", "kaka@example.com"}] = email.to
    end

    test "the subject is the configured one" do
      assert {:ok, email} = Mailers.build(:welcome, welcome_payload())

      assert email.subject == "Welcome to Anywaye"
    end

    test "the body greets the person by name and offers the link it was sent" do
      assert {:ok, email} = Mailers.build(:welcome, welcome_payload())

      assert email.html_body =~ "Kaka"
      assert email.html_body =~ "https://anywaye.com/verify?token=abc123"
    end

    test "a plain-text alternative carries the same link" do
      assert {:ok, email} = Mailers.build(:welcome, welcome_payload())

      assert email.text_body =~ "https://anywaye.com/verify?token=abc123"
    end

    test "the body's layout is the shared one, so every email is wrapped alike" do
      assert {:ok, welcome} = Mailers.build(:welcome, welcome_payload())
      assert {:ok, reset} = Mailers.build(:password_reset, password_reset_payload())

      assert welcome.html_body =~ "<html"
      assert reset.html_body =~ "<html"
      assert shared_chrome(welcome.html_body) == shared_chrome(reset.html_body)
    end

    test "a payload without a name still builds" do
      assert {:ok, email} =
               Mailers.build(:welcome, welcome_payload(%{name: nil}))

      assert email.html_body =~ "https://anywaye.com/verify?token=abc123"
    end

    test "a payload without a link still builds" do
      assert {:ok, email} = Mailers.build(:welcome, welcome_payload(%{url: nil}))

      refute email.html_body =~ "<a href=\"https://anywaye.com/verify"
    end

    test "a payload with no address is an error, not an email to nobody" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:welcome, welcome_payload(%{email: nil}))

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "a payload with an address that is not an address is an error" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:welcome, welcome_payload(%{email: "kaka@localhost"}))

      assert %{email: ["is not an email address"]} = errors_on(changeset)
    end
  end

  describe "password_reset" do
    test "the body carries the reset link and nothing else can stand in for it" do
      assert {:ok, email} = Mailers.build(:password_reset, password_reset_payload())

      assert email.html_body =~ "https://anywaye.com/reset?token=t0ken"
    end

    test "the link has no url in it" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:password_reset, password_reset_payload(%{url: nil}))

      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "the subject is the configured one" do
      assert {:ok, email} = Mailers.build(:password_reset, password_reset_payload())

      assert email.subject == "Reset your Anywaye password"
    end
  end

  describe "team_invitation" do
    test "the subject names who invited and what they were invited to" do
      assert {:ok, email} = Mailers.build(:team_invitation, team_invitation_payload())

      assert email.subject == "Ruto invited you to join Moon Labs"
    end

    test "the body carries the account, the inviter, and the invitation link" do
      assert {:ok, email} = Mailers.build(:team_invitation, team_invitation_payload())

      assert email.html_body =~ "Moon Labs"
      assert email.html_body =~ "Ruto"
      assert email.html_body =~ "https://anywaye.com/invitations/i_01J9Z8"
    end

    test "the body names the role the inviter chose" do
      assert {:ok, email} =
               Mailers.build(:team_invitation, team_invitation_payload(%{role: "admin"}))

      assert email.html_body =~ "admin"
    end

    test "an invitation with no account is an error" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:team_invitation, team_invitation_payload(%{account_name: nil}))

      assert %{account_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "an invitation with no inviter is an error, because the subject needs one" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:team_invitation, team_invitation_payload(%{invited_by: nil}))

      assert %{invited_by: ["can't be blank"]} = errors_on(changeset)
    end

    test "an invitation with no link is an error: an invitation with no way in is noise" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:team_invitation, team_invitation_payload(%{url: nil}))

      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "account_security" do
    defp account_security_payload(overrides \\ %{}) do
      Map.merge(
        %{
          user_id: @user_id,
          email: "kaka@example.com",
          name: "Kaka",
          reason: "password reset"
        },
        overrides
      )
    end

    test "the subject is the configured one, and reason-agnostic" do
      # One subject for both reasons, because the configuration is one line per
      # type and the body is where the reason-specific wording lives.
      assert {:ok, email} = Mailers.build(:account_security, account_security_payload())

      assert email.subject == "Security notice for your Anywaye account"
    end

    test "the password-reset reason renders the password wording" do
      assert {:ok, email} = Mailers.build(:account_security, account_security_payload())

      assert email.html_body =~ "Your password was changed."
      assert email.text_body =~ "Your password was changed."
      refute email.text_body =~ "The email address on your account was changed."
    end

    test "the email-address reason renders the email wording, from the one template" do
      # The branch is on the mail, not on the type: one template, two renderings.
      assert {:ok, email} =
               Mailers.build(
                 :account_security,
                 account_security_payload(%{reason: "email address changed"})
               )

      assert email.html_body =~ "The email address on your account was changed."
      assert email.text_body =~ "The email address on your account was changed."
      refute email.text_body =~ "Your password was changed."
    end

    test "a payload with no reason is an error, not a mail in the wrong branch" do
      # The template cannot render a branch for a reason it was not given, so
      # the renderer refuses a payload without one rather than defaulting.
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:account_security, account_security_payload(%{reason: nil}))

      assert %{reason: ["can't be blank"]} = errors_on(changeset)
    end

    test "a payload with no address is an error, not an email to nobody" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:account_security, account_security_payload(%{email: nil}))

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "email_change_current" do
    defp email_change_current_payload(overrides \\ %{}) do
      Map.merge(
        %{
          user_id: @user_id,
          email: "kaka@example.com",
          name: "Kaka",
          url: "https://anywaye.com/email-changes/confirm?token=ch4nge"
        },
        overrides
      )
    end

    test "the subject is the configured one" do
      assert {:ok, email} = Mailers.build(:email_change_current, email_change_current_payload())

      assert email.subject == "Confirm an email address change on your Anywaye account"
    end

    test "the body names the account's address and carries the confirmation link" do
      # The security notice's whole content: who must act, and the one link that
      # acts on it. Asserted on both formats, because a text-only reader is a
      # reader too and the link is the point of the mail.
      assert {:ok, email} = Mailers.build(:email_change_current, email_change_current_payload())

      assert email.html_body =~ "kaka@example.com"
      assert email.html_body =~ "https://anywaye.com/email-changes/confirm?token=ch4nge"
      assert email.text_body =~ "kaka@example.com"
      assert email.text_body =~ "https://anywaye.com/email-changes/confirm?token=ch4nge"
    end

    test "a payload with no link is an error, not a mail with no way to confirm" do
      # The link is the action the notice asks for; a mail without it tells the
      # reader something happened and gives them nothing to do about it.
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:email_change_current, email_change_current_payload(%{url: nil}))

      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "a payload with no address is an error, not an email to nobody" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:email_change_current, email_change_current_payload(%{email: nil}))

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "email_change_new" do
    defp email_change_new_payload(overrides \\ %{}) do
      Map.merge(
        %{
          user_id: @user_id,
          email: "new@example.com",
          name: "Kaka",
          previous_email: "kaka@example.com"
        },
        overrides
      )
    end

    test "the subject is the configured one" do
      assert {:ok, email} = Mailers.build(:email_change_new, email_change_new_payload())

      assert email.subject == "Confirm your new Anywaye email address"
    end

    test "the body names the address the account is moving from" do
      # The one fact the new address's owner is owed: where the account lived
      # before. Asserted on both formats, like its sibling.
      assert {:ok, email} = Mailers.build(:email_change_new, email_change_new_payload())

      assert email.html_body =~ "kaka@example.com"
      assert email.text_body =~ "kaka@example.com"
    end

    test "a payload with no previous address is an error" do
      # Without it the mail cannot say what it is about: "somebody asked to move
      # the account on <nothing> to this address" is not a sentence a person can
      # act on, and rendering it would be a mail with a hole in it.
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:email_change_new, email_change_new_payload(%{previous_email: nil}))

      assert %{previous_email: ["can't be blank"]} = errors_on(changeset)
    end

    test "a payload with no address is an error, not an email to nobody" do
      assert {:error, {:invalid_payload, changeset}} =
               Mailers.build(:email_change_new, email_change_new_payload(%{email: nil}))

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "types" do
    test "the notification types are exactly the seven courier sends" do
      # EIGHT, and the eighth is `payment_failed` — the warning for an attempt
      # that did not go through, `Courier.Consumers.PaymentFailed`, and the
      # receipt's other half. The seventh was `receipt`; this list is the
      # catalog every preference, subject and template is asserted against, so
      # a type added without it fails here by name.
      assert Mailers.types() ==
               ~w(welcome password_reset team_invitation account_security
                  email_change_current email_change_new receipt payment_failed)
    end

    test "a type courier does not have is an error rather than a fallback" do
      assert {:error, :unknown_notification_type} =
               Mailers.build(:weekly_digest, welcome_payload())
    end

    test "the type may be given as a string, because it arrives as one over JSON" do
      assert {:ok, email} = Mailers.build("welcome", welcome_payload())

      assert email.subject == "Welcome to Anywaye"
    end
  end

  describe "deliver/2" do
    test "hands the built email to Swoosh, which in test is the test process" do
      assert {:ok, _metadata} = Mailers.deliver(:welcome, welcome_payload())

      assert_email_sent(subject: "Welcome to Anywaye", to: [{"Kaka", "kaka@example.com"}])
    end
  end

  # The parts of the layout that are not this particular email's copy. Two emails
  # that agree on these are rendered through the same template, which is the
  # thing worth asserting — byte-comparing whole bodies would only prove that
  # the fixtures are stable.
  defp shared_chrome(body) do
    for line <- String.split(body, "\n"),
        String.contains?(line, "Anywaye"),
        not String.contains?(line, "Kaka"),
        do: String.trim(line)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
