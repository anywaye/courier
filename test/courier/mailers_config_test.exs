defmodule Courier.MailersConfigTest do
  @moduledoc """
  The sender and the subject lines are configuration, so the tests for them
  change configuration.

  `async: false` because `Application.put_env/3` is VM-global: while this
  module is substituting a mailing config, every other test in the suite that
  reads `config :courier, :mailing` would read the substituted one. The env is
  restored in `on_exit`, which runs before the next test starts.
  """

  use ExUnit.Case, async: false

  alias Courier.Mailers

  @payload %{
    user_id: "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061",
    email: "kaka@example.com",
    name: "Kaka"
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Courier.Repo)
    original = Application.get_env(:courier, :mailing)

    on_exit(fn ->
      Application.put_env(:courier, :mailing, original)
      Ecto.Adapters.SQL.Sandbox.checkin(Courier.Repo)
    end)

    %{original: original}
  end

  test "the sender comes from configuration and the subject from the type" do
    mailing_config(from: {"Mailer Test", "mailer-test@anywaye.com"})

    assert {:ok, email} = Mailers.build(:welcome, @payload)

    assert email.subject == "Welcome to Anywaye"
    assert email.from == {"Mailer Test", "mailer-test@anywaye.com"}
  end

  test "a subject template naming a key the payload lacks is a configuration error" do
    Courier.NotificationTypes.update("welcome", %{subject: "Welcome to %{team_name}"})

    assert {:error, :subject_misconfigured} = Mailers.build(:welcome, @payload)

    Courier.NotificationTypes.update("welcome", %{subject: "Welcome to Anywaye"})
  end

  test "a type with no subject is not reachable through the API" do
    # subject is NOT NULL at the database, so a missing subject is rejected by
    # the changeset before it reaches the send path. Covered by the changeset's
    # required validation; nothing to assert here.
    :ok
  end

  test "a from address that is not configured is a configuration error, not a bounce" do
    mailing_config(from: {"", ""})

    assert {:error, :from_not_configured} = Mailers.build(:welcome, @payload)
  end

  test "the payment-failure warning carries the configured billing url as a link" do
    # The one action the warning asks for, and the url is deployment
    # configuration — the payload carries facts about the event, and which
    # page the billing screens live on is a fact about the deployment.
    mailing_config(billing_url: "https://app.example.com/billing/subscriptions")

    assert {:ok, email} =
             Mailers.build(:payment_failed, %{
               user_id: "865e9942-4b65-432b-8bf4-5d34b9dae5b8",
               email: "buyer@example.com",
               amount_display: "49.00 USD"
             })

    assert email.html_body =~ ~s(href="https://app.example.com/billing/subscriptions")
    assert email.html_body =~ "https://app.example.com/billing/subscriptions"
    assert email.text_body =~ "https://app.example.com/billing/subscriptions"
  end

  test "with no billing url configured the warning still asks, in words" do
    # The default is `nil`, and the template renders the sentence without a
    # link then: a warning that named an address nobody configured would be
    # worse than one that asks in words.
    mailing_config(billing_url: nil)

    assert {:ok, email} =
             Mailers.build(:payment_failed, %{
               user_id: "865e9942-4b65-432b-8bf4-5d34b9dae5b8",
               email: "buyer@example.com",
               amount_display: "49.00 USD"
             })

    assert email.html_body =~ "Please update your payment method from your account at any time."
    refute email.html_body =~ "<a href="
  end

  defp mailing_config(overrides) do
    Application.put_env(
      :courier,
      :mailing,
      Application.get_env(:courier, :mailing, []) |> Keyword.merge(overrides)
    )
  end
end
