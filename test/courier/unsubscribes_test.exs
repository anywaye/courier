defmodule Courier.UnsubscribesTest do
  @moduledoc """
  The one-click unsubscribe as a library: mint a token, find it, act on it.

  This is the half of the RFC 8058 implementation that is not HTTP. The route
  that calls it is `CourierWeb.UnsubscribeControllerTest`, and the headers it puts
  on a message are `Courier.UnsubscribeHeadersTest` — three files because the
  claims are three different ones and a file asserting all of them would be a file
  whose failures do not say which thing broke.


  Here: the token is stored as a digest and never as itself; a token courier did
  not issue is not a token; the row it writes carries **no state** and is
  therefore invisible to the address-level fold; the row and its event are written
  together or not at all; a second call changes nothing and announces nothing; and
  the payload on the bus is the four fields **core's** schema requires, with the
  user as the subject and no `message_id`.


  A bounce and a complaint carry a state and stop **every** type courier sends.
  An unsubscribe stops **one**. If the row this module wrote carried `:suppressed`,
  a person who unsubscribed from product updates would no longer receive their
  password reset — so the tests assert the negative as well as the positive: the
  row has no state, `Suppressions.state/1` is `nil` for that address,
  `Suppressions.suppressed?/1` is false, and a real `Courier.Deliver` send of a
  *different* type still goes out.


  "The row and its event are written in one transaction" is the kind of claim a
  test proves by breaking one of them and looking at the other. So it is broken:
  the test mints a token for a notification type courier does not send, which is
  what a deployment gets by withdrawing a type after the fact — written with raw
  SQL because the changeset refuses it, and the refusal **is** the subject under
  test. `Courier.Suppressions.unsubscribe/1` then refuses it at the far end, the
  transaction unwinds, and the assertion is that **no event was published**. A
  half-recorded unsubscribe is the whole failure, and the positive case (both rows
  present) is asserted beside it so a file that recorded nothing cannot pass it.
  """

  use Courier.DataCase, async: true

  alias Courier.Deliver
  alias Courier.Events
  alias Courier.Mailers
  alias Courier.OutboxEvent
  alias Courier.Suppression
  alias Courier.Suppressions
  alias Courier.UnsubscribeToken
  alias Courier.Unsubscribes

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @email "unsubscribe-me@example.com"
  @notification_type "welcome"

  defp assert_is_an_instruction_not_a_suppression(row) do
    assert row.provider == "unsubscribe"
    assert row.state == nil
    assert Suppressions.state(row.email) == nil
    refute Suppressions.suppressed?(row.email)
    assert Suppressions.find(row.email) == nil
  end

  describe "the kind table" do
    test "classifies every type courier sends, and nothing else" do
      assert Mailers.kinds() |> Map.keys() |> Enum.sort() == Enum.sort(Mailers.types())
    end

    test "and the default for a type with no row is transactional" do
      assert Mailers.kind("a_type_nobody_wrote_down") == :transactional
      refute Mailers.bulk?("a_type_nobody_wrote_down")
      assert Mailers.kind(:welcome) == :transactional
      refute Mailers.bulk?(:welcome)
    end

    test "and courier ships no bulk type, which is a fact about core" do
      assert Mailers.kinds() |> Map.values() |> Enum.uniq() == [:transactional]
    end
  end

  describe "issue/3" do
    test "returns a token and stores a digest of it, never the token" do
      assert {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)

      [digest] =
        Repo.query!("SELECT token_digest FROM unsubscribe_tokens", []).rows |> List.flatten()

      assert digest == UnsubscribeToken.digest(token)
      refute digest == token

      refute String.contains?(digest, token),
             "the stored digest contains the token, so the column is the token"
    end

    test "the token is 32 bytes of randomness in URL-safe base64" do
      assert {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)

      assert String.length(token) == UnsubscribeToken.token_length()
      assert String.length(UnsubscribeToken.digest(token)) == UnsubscribeToken.digest_length()

      assert token =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "two tokens are never the same" do
      assert {:ok, one} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, two} = Unsubscribes.issue(@user_id, @notification_type, @email)

      refute one == two
      refute UnsubscribeToken.digest(one) == UnsubscribeToken.digest(two)
    end

    test "records the message it was minted for, and normalises the address" do
      assert {:ok, _token} =
               Unsubscribes.issue(@user_id, @notification_type, "  Mixed@Example.COM ")

      row = Repo.one!(UnsubscribeToken)

      assert row.user_id == @user_id
      assert row.notification_type == @notification_type
      assert row.email == "mixed@example.com"
    end

    test "refuses an address courier could not send to" do
      assert {:error, changeset} =
               Unsubscribes.issue(@user_id, @notification_type, "not an address")

      assert %{email: ["is not an email address"]} = errors_on(changeset)
      assert minted_for(@user_id) == 0
    end

    test "refuses a notification type courier does not send" do
      assert {:error, changeset} = Unsubscribes.issue(@user_id, "carrier_pigeon", @email)
      assert %{notification_type: ["is not a notification type"]} = errors_on(changeset)
      assert minted_for(@user_id) == 0
    end
  end

  describe "find/1" do
    test "finds the row a token names" do
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)

      assert {:ok, %UnsubscribeToken{} = row} = Unsubscribes.find(token)
      assert row.user_id == @user_id
      assert row.notification_type == @notification_type
    end

    test "and is an error for a token courier never issued" do
      assert Unsubscribes.find(UnsubscribeToken.generate()) == :error
    end

    test "and is an error for something that is not a token's shape" do
      for not_a_token <- ["", "x", "a" <> String.duplicate("b", 42), nil, :atom, 42] do
        assert Unsubscribes.find(not_a_token) == :error
      end
    end
  end

  describe "unsubscribe/1" do
    setup do
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      %{token: token}
    end

    test "records the recipient's answer, with no state at all", %{token: token} do
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert [row] = Repo.all(Suppression)
      assert row.email == @email
      assert row.notification_type == @notification_type
      assert row.user_id == @user_id
      assert row.reason =~ "one-click"

      assert_is_an_instruction_not_a_suppression(row)
    end

    test "and the send path refuses THAT TYPE and no other", %{token: token} do
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert {:error, {:unsubscribed, "welcome"}} =
               Deliver.welcome(%{user_id: @user_id, email: @email, name: "Unsub Me"})

      assert {:ok, _sent} =
               Deliver.password_reset(%{
                 user_id: @user_id,
                 email: @email,
                 url: "https://anywaye.test/reset"
               })

      assert {:ok, _sent} =
               Deliver.team_invitation(%{
                 user_id: @user_id,
                 email: @email,
                 url: "https://anywaye.test/join",
                 account_name: "Acme",
                 invited_by: "Kaka"
               })
    end

    test "and publishes courier.notification.suppressed, with core's payload", %{
      token: token
    } do
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert [event] =
               Repo.all(from event in OutboxEvent, where: event.type == ^Events.suppressed_type())

      assert event.subject == @user_id
      assert {:ok, _uuid} = Ecto.UUID.cast(event.subject)
      refute event.subject =~ ~r/^courier-/

      assert event.data == %{
               "user_id" => @user_id,
               "notification_type" => @notification_type,
               "email" => @email,
               "reason" => "preference_off"
             }

      assert Unsubscribes.reason() in Events.reasons()
      assert event.data["reason"] in Events.reasons()

      refute Map.has_key?(event.data, "message_id")
    end

    test "and the envelope the relay would publish satisfies the envelope schema", %{
      token: token
    } do
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      envelope = Repo.one!(OutboxEvent) |> OutboxEvent.envelope()

      assert envelope["type"] == "courier.notification.suppressed"
      assert envelope["source"] == "courier"
      assert envelope["specversion"] == "1.0"
      assert {:ok, _uuid} = Ecto.UUID.cast(envelope["id"])
      assert envelope["subject"] == @user_id
      assert is_map(envelope["data"])
    end

    test "a second call changes nothing and announces nothing", %{token: token} do
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)
      assert {:ok, :already_unsubscribed} = Unsubscribes.unsubscribe(token)

      assert own_rows(token) |> length() == 1
      assert own_events(@user_id) |> length() == 1
    end

    test "and an unknown token is refused, and writes nothing" do
      assert {:error, :unknown_token} = Unsubscribes.unsubscribe(UnsubscribeToken.generate())

      assert Repo.all(Suppression) == []
      assert own_events(@user_id) == []
    end

    test "a row courier cannot write is a rollback, not a half-record" do
      insert_token_for("welcome", "not an address")

      assert {:error, %Ecto.Changeset{}} = Unsubscribes.unsubscribe(stale_token())

      assert Repo.all(Suppression) == []
      assert own_events(@user_id) == []
    end

    test "and a token for a type courier no longer sends is still recorded" do
      insert_token_for("withdrawn_type", @email)

      assert {:ok, :recorded} = Unsubscribes.unsubscribe(stale_token())

      assert [%Suppression{notification_type: "withdrawn_type"}] = Repo.all(Suppression)
    end

    test "and the positive case beside it wrote both rows" do
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert own_rows(token) |> length() == 1
      assert own_events(@user_id) |> length() == 1
    end
  end

  describe "the address-level fold is untouched" do
    test "a bounce still stops everything, after an unsubscribe" do
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert {:ok, :new, _row} = Suppressions.ingest(report("bounce-1", :hard_bounce))

      assert Suppressions.state(@email) == :undeliverable
      assert Suppressions.suppressed?(@email)
      assert Suppressions.unsubscribed?(@email, @notification_type)

      assert {:error, {:unsubscribed, "welcome"}} =
               Deliver.welcome(%{user_id: @user_id, email: @email, name: "Unsub Me"})
    end

    test "a complaint outranks the unsubscribe, as it outranks a bounce" do
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert {:ok, :new, _row} = Suppressions.ingest(report("complaint-1", :complaint))

      assert Suppressions.state(@email) == :suppressed
      assert Suppressions.find(@email).state == :suppressed

      assert Suppressions.unsubscribed?(@email, @notification_type)
      refute Suppressions.unsubscribed?(@email, "password_reset")
    end

    test "and `unsubscribed?/2` is never true for a row that carries a state" do
      assert {:ok, :new, _row} = Suppressions.ingest(report("bounce-2", :hard_bounce))

      refute Suppressions.unsubscribed?(@email, "welcome")
    end
  end

  describe "the URL" do
    test "is courier's public base URL and the router's path" do
      assert Unsubscribes.path_prefix() == "/unsubscribe"

      assert %{route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(CourierWeb.Router, "POST", "/unsubscribe/abc", "")

      assert %{route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/unsubscribe/abc", "")
    end

    test "carries no port when the scheme's default would do" do
      assert put_url(host: "anywaye.com", scheme: "https", port: 443) == "https://anywaye.com"
      assert put_url(host: "anywaye.com", scheme: "https", port: 8443) == "https://anywaye.com:8443"

      assert put_url(host: "courier.test", scheme: "http", port: 4000) ==
               "http://courier.test:4000"
    end

    test "and in production it is an HTTPS URI, as RFC 8058 §3.1 requires" do
      url = with_boot_variables(fn -> prod_config()[:courier][CourierWeb.Endpoint][:url] end)

      assert url[:scheme] == "https",
             "config/runtime.exs builds the endpoint's public URL with " <>
               "#{inspect(url[:scheme])}, and the List-Unsubscribe header is built from it. " <>
               "RFC 8058 §3.1 requires an HTTPS URI there."

      assert is_binary(url[:host]) and url[:host] != ""
    end
  end

  describe "the headers" do
    test "are exactly the two RFC 8058 names, and §5's value byte for byte" do
      decorated = Unsubscribes.decorate(message(), "the-token")

      assert decorated.headers["List-Unsubscribe"] == "<#{Unsubscribes.url("the-token")}>"
      assert decorated.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"

      assert Unsubscribes.one_click_header() == "List-Unsubscribe-Post"
      assert Unsubscribes.one_click_value() == "List-Unsubscribe=One-Click"
    end

    test "and there is exactly one of each" do
      decorated = Unsubscribes.decorate(Unsubscribes.decorate(message(), "the-token"), "other")

      names = decorated.headers |> Map.keys() |> Enum.filter(&(&1 =~ ~r/^List-Unsubscribe/))
      assert Enum.sort(names) == ["List-Unsubscribe", "List-Unsubscribe-Post"]
      assert decorated.headers["List-Unsubscribe"] == "<#{Unsubscribes.url("other")}>"
    end

    test "and a decorated message still has the body it had" do
      decorated = Unsubscribes.decorate(message(), "the-token")

      assert Mailers.body?(decorated)
      assert decorated.text_body == message().text_body
      assert decorated.html_body == message().html_body
    end
  end


  defp message do
    {:ok, message} =
      Mailers.build(@notification_type, %{
        user_id: @user_id,
        email: @email,
        name: "Unsubscribe Me"
      })

    message
  end

  defp insert_token_for(notification_type, email) do
    Repo.query!(
      """
      INSERT INTO unsubscribe_tokens (id, token_digest, user_id, notification_type, email,
                                     inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, now(), now())
      """,
      [
        Ecto.UUID.dump!(stale_id()),
        UnsubscribeToken.digest(stale_token()),
        Ecto.UUID.dump!(@user_id),
        notification_type,
        email
      ]
    )
  end

  defp stale_id, do: "3f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp stale_token, do: "stale" <> String.duplicate("0", 38)

  defp minted_for(user_id) do
    {:ok, uuid} = Ecto.UUID.cast(user_id)

    Repo.one(
      from token in UnsubscribeToken, where: token.user_id == ^uuid, select: count(token.id)
    )
  end

  defp report(provider_event_id, kind),
    do: %{provider: "resend", provider_event_id: provider_event_id, email: @email, kind: kind}

  defp own_rows(token) do
    {:ok, row} = Unsubscribes.find(token)

    Repo.all(from s in Suppression, where: s.provider_event_id == ^row.id)
  end

  defp own_events(user_id),
    do:
      Repo.all(
        from event in OutboxEvent,
          where:
            event.type == ^Events.suppressed_type() and
              fragment("?->>'user_id'", event.data) == ^user_id
      )

  defp put_url(url) do
    previous = Application.get_env(:courier, CourierWeb.Endpoint)
    on_exit(fn -> Application.put_env(:courier, CourierWeb.Endpoint, previous) end)
    Application.put_env(:courier, CourierWeb.Endpoint, Keyword.put(previous, :url, url))

    Unsubscribes.base_url()
  end

  @boot_variables %{
    "COURIER_IDENTITY_TOKEN" => "anywaye_fixture-not-a-real-credential",
    "COURIER_SECRET_BOX_KEY" => "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE=",
    "COURIER_INBOUND_RESEND_SECRET" => "whsec_dGVzdC1vbmx5LWZpeHR1cmU=",
    "COURIER_ERROR_RELAY_TOKEN" => "test-only-not-a-secret",
    "COURIER_MAIL_ADAPTER" => "smtp",
    "COURIER_SMTP_HOST" => "smtp.test",
    "COURIER_SMTP_USERNAME" => "fixture-not-a-credential",
    "COURIER_SMTP_PASSWORD" => "fixture-not-a-credential",
    "DATABASE_URL" => "ecto://postgres:postgres@localhost/courier_test",
    "SECRET_KEY_BASE" => "test-only-not-a-secret-000000000000000000000000000000"
  }

  defp with_boot_variables(fun) do
    previous = Enum.map(@boot_variables, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(@boot_variables, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp prod_config, do: Config.Reader.read!("config/runtime.exs", env: :prod)
end
