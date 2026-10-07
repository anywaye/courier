defmodule Courier.UnsubscribesTest do
  @moduledoc """
  The one-click unsubscribe as a library: mint a token, find it, act on it.

  This is the half of the RFC 8058 implementation that is not HTTP. The route
  that calls it is `CourierWeb.UnsubscribeControllerTest`, and the headers it puts
  on a message are `Courier.UnsubscribeHeadersTest` — three files because the
  claims are three different ones and a file asserting all of them would be a file
  whose failures do not say which thing broke.

  ## What is asserted here, and what is asserted elsewhere

  Here: the token is stored as a digest and never as itself; a token courier did
  not issue is not a token; the row it writes carries **no state** and is
  therefore invisible to the address-level fold; the row and its event are written
  together or not at all; a second call changes nothing and announces nothing; and
  the payload on the bus is the four fields **core's** schema requires, with the
  user as the subject and no `message_id`.

  ## The state-less row is the load-bearing assertion in this file

  A bounce and a complaint carry a state and stop **every** type courier sends.
  An unsubscribe stops **one**. If the row this module wrote carried `:suppressed`,
  a person who unsubscribed from product updates would no longer receive their
  password reset — so the tests assert the negative as well as the positive: the
  row has no state, `Suppressions.state/1` is `nil` for that address,
  `Suppressions.suppressed?/1` is false, and a real `Courier.Deliver` send of a
  *different* type still goes out.

  ## The transaction, and how a rollback is provoked rather than assumed

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

  # The three things that have to be true together for the claim "this is an
  # unsubscribe and not a suppression" to mean anything: the row's own provider,
  # the absence of a state, and the address-level answer courier now gives.
  defp assert_is_an_instruction_not_a_suppression(row) do
    assert row.provider == "unsubscribe"
    assert row.state == nil
    assert Suppressions.state(row.email) == nil
    refute Suppressions.suppressed?(row.email)
    assert Suppressions.find(row.email) == nil
  end

  describe "the kind table" do
    test "classifies every type courier sends, and nothing else" do
      # The property that makes the table a gate rather than a suggestion: a type
      # with no row would be classified by the DEFAULT, and a default that happens
      # to be right is a default nothing checked. So the keys are `types/0` —
      # sorted, because a table and a list are sets and the order is not the claim.
      assert Mailers.kinds() |> Map.keys() |> Enum.sort() == Enum.sort(Mailers.types())
    end

    test "and the default for a type with no row is transactional" do
      # The direction of the default is the whole decision, and it is asserted
      # rather than left in a comment: a type nobody classified must NOT grow an
      # unsubscribe link. An account-management email carrying one is its own
      # defect — see `Courier.Mailers`' comment on the table.
      assert Mailers.kind("a_type_nobody_wrote_down") == :transactional
      refute Mailers.bulk?("a_type_nobody_wrote_down")
      assert Mailers.kind(:welcome) == :transactional
      refute Mailers.bulk?(:welcome)
    end

    test "and courier ships no bulk type, which is a fact about core" do
      # Every value in the table is `:transactional` because there is no bulk type
      # to declare, and **adding one is a change in core**: every payload courier
      # publishes carries `notification_type`, and
      # `core/schemas/events/courier/email/*.schema.json` freezes that field to an
      # enum of the names in `types/0`. This is the half of the
      # deliverability gate that is not courier's to close, and asserting it here
      # is what makes the report's "no bulk mail today" a measurement.
      assert Mailers.kinds() |> Map.values() |> Enum.uniq() == [:transactional]
    end
  end

  describe "issue/3" do
    test "returns a token and stores a digest of it, never the token" do
      assert {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)

      # Read as raw SQL rather than through the schema, on the reasoning
      # `Courier.SecretBoxTest` gives: the claim is about the COLUMN, and a
      # changeset would only prove that the struct has no field for the token.
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

      # A `/` or a `+` here is a percent-encoding argument every mail client and
      # every proxy resolves differently, and the value goes in a URL path segment.
      assert token =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "two tokens are never the same" do
      # The unique index on the digest is a backstop, not the mechanism. If
      # generation were ever predictable this is what would catch it, and the
      # assertion is on the values rather than on a count of rows.
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
      # The same shape `Courier.Mailers` validates a recipient with, and for the
      # same reason: a token minted for an unusable address would record an answer
      # about a mailbox courier could never have written to.
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
      # One answer for "no such token" and "not a token": the endpoint cannot tell
      # them apart either, so a distinction here would be a distinction with no
      # consequence and one more thing to get wrong.
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

      # The three properties that together make this an instruction rather than a
      # fact about the mailbox. Asserted as a set because any one of them alone is
      # also true of a row courier did not write.
      assert_is_an_instruction_not_a_suppression(row)
    end

    test "and the send path refuses THAT TYPE and no other", %{token: token} do
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      # The half that is worth the whole design. `Suppressions.state/1` is `nil` for
      # this address and `enabled?/3` knows nothing about it, so the only thing
      # standing between this address and a refused password reset is the per-type
      # question in `Courier.Deliver` — and this is a real send through the real
      # composer and the real adapter, not a predicate.
      assert {:error, {:unsubscribed, "welcome"}} =
               Deliver.welcome(%{user_id: @user_id, email: @email, name: "Unsub Me"})

      assert {:ok, _sent} =
               Deliver.password_reset(%{
                 user_id: @user_id,
                 email: @email,
                 url: "https://cafaye.test/reset"
               })

      assert {:ok, _sent} =
               Deliver.team_invitation(%{
                 user_id: @user_id,
                 email: @email,
                 url: "https://cafaye.test/join",
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

      # The subject is the USER and not a message, because no message was
      # rendered — core's D8, and the one thing that makes this payload different
      # from the other three courier emits.
      assert event.subject == @user_id
      assert {:ok, _uuid} = Ecto.UUID.cast(event.subject)
      refute event.subject =~ ~r/^courier-/

      assert event.data == %{
               "user_id" => @user_id,
               "notification_type" => @notification_type,
               "email" => @email,
               "reason" => "preference_off"
             }

      # The reason is core's enum, not courier's, and this is the assertion that a
      # future edit to the string goes red here rather than putting a value on the
      # bus that four payload schemas reject.
      assert Unsubscribes.reason() in Events.reasons()
      assert event.data["reason"] in Events.reasons()

      # No `message_id`, and the absence is asserted as well as the set: an event
      # naming a notification that was never sent is the lie this type exists to
      # avoid, and `additionalProperties: false` would reject it downstream.
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

      # Counted over **this unsubscribe's own rows**, never over the table. A count
      # over the whole table is a claim about every other test in this repository
      # as much as about the code under test.
      assert own_rows(token) |> length() == 1
      assert own_events(@user_id) |> length() == 1
    end

    test "and an unknown token is refused, and writes nothing" do
      assert {:error, :unknown_token} = Unsubscribes.unsubscribe(UnsubscribeToken.generate())

      assert Repo.all(Suppression) == []
      assert own_events(@user_id) == []
    end

    test "a row courier cannot write is a rollback, not a half-record" do
      # The break described in the moduledoc: a token whose address courier can no
      # longer parse — which is what a deployment gets after an address rule
      # tightens, or a row written by whatever was running when it did not. The
      # mint-time validation cannot catch it, because the mint was in the past, so
      # the refusal happens at the far end in
      # `Courier.Suppression.unsubscribe_changeset/2`; the transaction unwinds; and
      # the load-bearing assertion is that NO EVENT was published.
      insert_token_for("welcome", "not an address")

      assert {:error, %Ecto.Changeset{}} = Unsubscribes.unsubscribe(stale_token())

      assert Repo.all(Suppression) == []
      assert own_events(@user_id) == []
    end

    test "and a token for a type courier no longer sends is still recorded" do
      # The opposite case, and it is a decision rather than an omission. The mint
      # validated the type; a type withdrawn afterwards makes the row a no-op,
      # because `Courier.Mailers.build/2` will not compose it — so refusing here
      # would throw away a fact the recipient stated, and the row costs nothing.
      insert_token_for("withdrawn_type", @email)

      assert {:ok, :recorded} = Unsubscribes.unsubscribe(stale_token())

      assert [%Suppression{notification_type: "withdrawn_type"}] = Repo.all(Suppression)
    end

    test "and the positive case beside it wrote both rows" do
      # The pairing that makes the test above mean something. A negative assertion
      # on its own is satisfied by a file that records nothing ever.
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert own_rows(token) |> length() == 1
      assert own_events(@user_id) |> length() == 1
    end
  end

  describe "the address-level fold is untouched" do
    test "a bounce still stops everything, after an unsubscribe" do
      # The two mechanisms in one table, and the assertion that adding the second
      # did not weaken the first. The order is the interesting part: the
      # unsubscribe is recorded first, so if the fold were counting rows instead of
      # states, the `nil` would be a row that changed the answer.
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert {:ok, :new, _row} = Suppressions.ingest(report("bounce-1", :hard_bounce))

      assert Suppressions.state(@email) == :undeliverable
      assert Suppressions.suppressed?(@email)
      assert Suppressions.unsubscribed?(@email, @notification_type)

      # The refusal is the UNSUBSCRIBE and not the bounce, and that is the
      # documented order rather than an accident: "does this person want this
      # mail?" is asked before "can this mailbox still receive it?", so a caller is
      # told the answer the recipient gave before the fact a provider reported.
      # Both stop the send; the order decides which one the caller is handed.
      assert {:error, {:unsubscribed, "welcome"}} =
               Deliver.welcome(%{user_id: @user_id, email: @email, name: "Unsub Me"})
    end

    test "a complaint outranks the unsubscribe, as it outranks a bounce" do
      # `:suppressed` outranks `:undeliverable` in courier's vocabulary and the
      # fold is unchanged by any of this, so the claim is asserted rather than
      # assumed: one address, three rows, two of them with no state.
      {:ok, token} = Unsubscribes.issue(@user_id, @notification_type, @email)
      assert {:ok, :recorded} = Unsubscribes.unsubscribe(token)

      assert {:ok, :new, _row} = Suppressions.ingest(report("complaint-1", :complaint))

      assert Suppressions.state(@email) == :suppressed
      assert Suppressions.find(@email).state == :suppressed

      # And the per-type answer is unaffected by either, because it is a different
      # question with a different key.
      assert Suppressions.unsubscribed?(@email, @notification_type)
      refute Suppressions.unsubscribed?(@email, "password_reset")
    end

    test "and `unsubscribed?/2` is never true for a row that carries a state" do
      # The predicate's own guard, asserted on rows courier did not write. If
      # `state IS NULL` were dropped from the query, a bounce for this address
      # would answer "unsubscribed from welcome" as well — a second, wrong reason
      # for a send to stop, and one with a different remedy.
      assert {:ok, :new, _row} = Suppressions.ingest(report("bounce-2", :hard_bounce))

      refute Suppressions.unsubscribed?(@email, "welcome")
    end
  end

  describe "the URL" do
    test "is courier's public base URL and the router's path" do
      # Both halves, and they are two different files: a rename that moved one of
      # them produces a header pointing at a 404, and the failure mode of that is
      # a silently unmet deliverability requirement rather than an error.
      assert Unsubscribes.path_prefix() == "/unsubscribe"

      assert %{route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(CourierWeb.Router, "POST", "/unsubscribe/abc", "")

      assert %{route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/unsubscribe/abc", "")
    end

    test "carries no port when the scheme's default would do" do
      # `https://cafaye.com:443` in a `List-Unsubscribe` header is a valid URL that
      # no two mail clients spell the same way.
      assert put_url(host: "cafaye.com", scheme: "https", port: 443) == "https://cafaye.com"
      assert put_url(host: "cafaye.com", scheme: "https", port: 8443) == "https://cafaye.com:8443"

      assert put_url(host: "courier.test", scheme: "http", port: 4000) ==
               "http://courier.test:4000"
    end

    test "and in production it is an HTTPS URI, as RFC 8058 §3.1 requires" do
      # **Read out of production's own configuration**, not out of this paragraph.
      # RFC 8058 §3.1: "The List-Unsubscribe header field MUST contain one HTTPS
      # URI", and the header is built from the endpoint's public URL, so if an
      # operator configured that without a scheme the requirement is unmet and no
      # other test would say so.
      #
      # `config/runtime.exs` is read **as a boot**, which is what it is: it is the
      # file a release evaluates, so evaluating it needs the variables a release
      # needs. They are set and restored here rather than avoided, and the list is
      # written out so that a newly required variable fails this test by name — a
      # boot contract asserted in one place is worth more than a boot contract
      # nowhere.
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

      # The same two strings the module publishes, so a test can name the section
      # and a reader can check the spelling without reading the module.
      assert Unsubscribes.one_click_header() == "List-Unsubscribe-Post"
      assert Unsubscribes.one_click_value() == "List-Unsubscribe=One-Click"
    end

    test "and there is exactly one of each" do
      # §3.1: "places **one** List-Unsubscribe header field and **one**
      # List-Unsubscribe-Post header field in the message", and decorating twice
      # must not produce two. `Swoosh.Email.header/3` replaces by name, so this is
      # a property of the call rather than of a filter — and a filter would have
      # been a second place for the spelling to live.
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

  # --- helpers ---------------------------------------------------------------

  # A real composed message, through the real composer.
  # `Courier.UnsubscribeHeadersTest` asserts what the send path does with these;
  # here they are only the carrier, and a hand-built one would be a way to pass
  # this file's tests with a shape courier never sends.
  defp message do
    {:ok, message} =
      Mailers.build(@notification_type, %{
        user_id: @user_id,
        email: @email,
        name: "Unsubscribe Me"
      })

    message
  end

  # A token for a type courier does not send, which is what a deployment gets by
  # withdrawing a type after the fact. Written with raw SQL because the changeset
  # refuses it — and that refusal is the point of the test that uses this.
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

  # How many tokens this test's own user has. A count over the whole table would be
  # a claim about every other test in the repository, which is the shape
  # REPORT-courier-15 documents and the rule in AGENTS.md.
  defp minted_for(user_id) do
    {:ok, uuid} = Ecto.UUID.cast(user_id)

    Repo.one(
      from token in UnsubscribeToken, where: token.user_id == ^uuid, select: count(token.id)
    )
  end

  # One provider report, in `Courier.Suppressions.event/0`'s own shape — so these
  # tests go through the same `ingest/1` a real bounce arrives by, rather than
  # reaching past the vocabulary into a raw changeset.
  defp report(provider_event_id, kind),
    do: %{provider: "resend", provider_event_id: provider_event_id, email: @email, kind: kind}

  # The rows written for one token: joined by the token's id, which is the
  # `provider_event_id` the unsubscribe records it under.
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

  # The endpoint's public URL, for the test that checks how it is assembled. The
  # application env is shared by the whole VM, so the previous value is restored
  # whatever the assertion does.
  defp put_url(url) do
    previous = Application.get_env(:courier, CourierWeb.Endpoint)
    on_exit(fn -> Application.put_env(:courier, CourierWeb.Endpoint, previous) end)
    Application.put_env(:courier, CourierWeb.Endpoint, Keyword.put(previous, :url, url))

    Unsubscribes.base_url()
  end

  # `config/runtime.exs` as a release evaluates it, with every variable it
  # refuses to boot without. `COURIER_SMTP_HOST` is here because
  # `Courier.MailerAdapter.adapter!(:prod)` requires it once the adapter is
  # `smtp`, and `DATABASE_URL` / `SECRET_KEY_BASE` because the release block reads
  # them the same way. Values are fixtures in a test process; nothing here reaches
  # a deployment.
  @boot_variables %{
    "COURIER_IDENTITY_TOKEN" => "cafaye_fixture-not-a-real-credential",
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
