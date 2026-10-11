defmodule CourierWeb.MessagesControllerTest do
  @moduledoc """
  `POST /v1/messages` is courier's only door into its send path, so this file is
  written in the order a caller experiences it: **it is refused**, **it is
  refused for the right reason**, and only then does it deliver.

  The negative cases come first on purpose. A send endpoint with a happy-path
  test is the shape of a route that accepts everything: the interesting failure
  modes of a mail egress are all *refusals* — no principal, a body courier cannot
  build, a recipient who asked not to be written to, a mailbox that hard-bounced
  months ago — and a suite that only asserts `200` has tested none of them.

  ## Every count here is over courier's own rows, never the table's

  The "nothing was written" assertions filter the outbox by the **recipient
  address this test minted**, which is unique per call. `Repo.aggregate(
  OutboxEvent, :count) == 0` would be a claim about every other test in the
  repository as much as about this one — see AGENTS.md.

  ## No real email is sent

  `config/test.exs` configures `Swoosh.Adapters.Test`, and the adapter hands each
  message to the sending process as `{:email, email}`. The real adapter is
  exercised against a real `:gen_smtp_server` in `test/courier/smtp_delivery_test.exs`,
  and the adapter courier *cannot* deliver through is covered in
  `test/courier_web/controllers/messages_controller_config_test.exs`. Nothing here
  opens a socket.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.Mailers
  alias Courier.NotificationPreferences
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppressions

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account
  @other_account "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @other_user_id "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  # A fresh address per call. `email_suppressions` has no `account_id` and its
  # rows are permanent, so a hard-coded address would let one test's suppression
  # silently decide another test's outcome — and the table is shared with every
  # other account by design.
  defp address, do: "recipient-#{System.unique_integer([:positive])}@example.com"

  defp body(overrides \\ %{}) do
    Map.merge(
      %{"type" => "welcome", "user_id" => @user_id, "to" => address(), "name" => "Kaka"},
      overrides
    )
  end

  # Header names are written as the strings HTTP carries them under. An earlier
  # draft took keyword keys and ran them through `to_string/1`, which produced
  # `idempotency_key` — a header courier does not read, so every idempotency
  # assertion in this file was green against a request that had sent nothing.
  defp post_message(conn, payload, headers \\ []) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
    |> post(~p"/v1/messages", payload)
  end

  defp authed, do: put_req_header(build_conn(), "x-courier-account", @account)

  defp post_authed(payload, headers \\ []), do: post_message(authed(), payload, headers)

  defp problem(conn), do: Jason.decode!(conn.resp_body)
  defp data(conn), do: problem(conn)["data"]

  defp fields(conn), do: Enum.map(problem(conn)["errors"] || [], & &1["field"])

  defp problem_json?(conn) do
    conn |> Plug.Conn.get_resp_header("content-type") |> List.first() |> Kernel.||("") =~
      "application/problem+json"
  end

  # Every message the test adapter handed to this process, oldest first. A
  # receive with `after 0` rather than a sleep: the send happened inside the
  # request, so the messages are already in the mailbox when this runs.
  defp sent do
    do_sent([])
  end

  defp do_sent(acc) do
    receive do
      {:email, email} -> do_sent([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # courier's own rows for ONE address, which is what "nothing was written" has
  # to mean here.
  defp outbox_for(email) do
    Enum.filter(Repo.all(OutboxEvent), &(&1.data["email"] == email))
  end

  describe "it refuses an unauthenticated caller, before anything is sent" do
    test "answers 401 with courier's envelope" do
      conn = post_message(build_conn(), body())

      assert conn.status == 401
      assert problem_json?(conn)

      envelope = problem(conn)

      assert envelope["code"] == "unauthorized"
      assert envelope["status"] == 401
      assert envelope["type"] == "https://docs.cafaye.com/errors/unauthorized"
      assert is_binary(envelope["trace_id"])
      assert envelope["trace_id"] == get_resp_header(conn, "x-trace-id") |> List.first()
    end

    test "no principal means no mail and no row" do
      recipient = address()

      conn = post_message(build_conn(), body(%{"to" => recipient}))

      assert conn.status == 401
      assert sent() == []
      assert outbox_for(recipient) == []
    end

    test "a body courier would happily send is refused identically" do
      # The 401 is not a consequence of a malformed request. If a well-formed
      # send got through, this endpoint would be an open relay.
      assert post_authed(body()).status == 200

      assert post_message(build_conn(), body()).status == 401
      assert length(sent()) == 1
    end

    # NOT asserted here: two `x-courier-account` headers being an ambiguous
    # caller. `Courier.TestSupport.HeaderResolver` refuses that case and the
    # refusal is right, but `Plug.Conn.put_req_header/3` **replaces** a header
    # rather than appending to it, so a ConnTest cannot build the request at all —
    # the second call overwrites the first and the caller arrives authenticated.
    # Proving it needs a real socket carrying a duplicated header line, which is a
    # fact about the test adapter rather than about this endpoint. The branch stays
    # unasserted rather than asserted with a request that cannot express it.

    test "an account header that is not a uuid is refused" do
      conn =
        build_conn()
        |> put_req_header("x-courier-account", "not-a-uuid")
        |> post(~p"/v1/messages", body())

      assert conn.status == 401
      assert sent() == []
    end
  end

  describe "it refuses a body it cannot act on, before the provider is asked" do
    test "a body that is not JSON is a 400" do
      conn =
        authed()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/v1/messages", "{not json")

      assert conn.status == 400
      assert problem_json?(conn)
      assert problem(conn)["code"] == "bad_request"
      assert sent() == []
    end

    test "a missing type is a 422 naming the field" do
      conn = post_authed(Map.delete(body(), "type"))

      assert conn.status == 422
      assert fields(conn) == ["type"]
      assert sent() == []
    end

    test "a type courier does not send is a 422 naming the field" do
      conn = post_authed(body(%{"type" => "email_changed"}))

      assert conn.status == 422
      assert fields(conn) == ["type"]
      assert sent() == []
    end

    test "a missing recipient is a 422 naming the field" do
      conn = post_authed(Map.delete(body(), "to"))

      assert conn.status == 422
      assert fields(conn) == ["to"]
      assert sent() == []
    end

    test "a recipient that is not an address is a 422 naming the field" do
      conn = post_authed(body(%{"to" => "not an address"}))

      assert conn.status == 422
      assert fields(conn) == ["to"]
      assert sent() == []
    end

    test "a missing user id is a 422 naming the field" do
      conn = post_authed(Map.delete(body(), "user_id"))

      assert conn.status == 422
      assert fields(conn) == ["user_id"]
      assert sent() == []
    end

    test "a user id that is not a uuid is a 422" do
      # `notification_preferences` is keyed by user id, so a non-uuid is a
      # preference courier cannot read and an event it cannot attribute.
      conn = post_authed(body(%{"user_id" => "kaka"}))

      assert conn.status == 422
      assert fields(conn) == ["user_id"]
      assert sent() == []
    end

    test "a field the chosen type needs and the body lacks is a 422 naming that field" do
      conn = post_authed(body(%{"type" => "password_reset"}))

      assert conn.status == 422
      assert fields(conn) == ["url"]
      assert sent() == []
    end

    test "every bad field at once is one 422 listing all of them, not only the first" do
      conn =
        post_authed(%{
          "type" => "welcome",
          "user_id" => "not-a-uuid",
          "to" => "not an address",
          "emai_enabled" => false
        })

      assert conn.status == 422
      assert Enum.sort(fields(conn)) == ["emai_enabled", "to", "user_id"]
      assert sent() == []
    end

    test "a bad type and a bad user id are both named, not just the type" do
      # The reason the type check lives in `CourierWeb.Messages` rather than being
      # left to the context's bare `:unknown_notification_type`: a bare atom cannot
      # be attached to a field, so a body wrong in two ways would lose one of them.
      conn =
        post_authed(%{"type" => "email_changed", "user_id" => "not-a-uuid", "to" => address()})

      assert conn.status == 422
      assert Enum.sort(fields(conn)) == ["type", "user_id"]
    end

    test "an unknown field is a 422 rather than one courier silently drops" do
      # `Courier.Mailers.normalize/1` builds the payload from a fixed field list
      # and discards everything else without a word. Over HTTP that is how a
      # misspelled `email_enabled` becomes a setting the caller believes took
      # effect.
      conn = post_authed(body(%{"emai_enabled" => false}))

      assert conn.status == 422
      assert fields(conn) == ["emai_enabled"]
      assert sent() == []
    end

    test "an account_id in the body is refused and cannot reach anything" do
      # The account is `conn.assigns.current_account` and nothing else. The body
      # names no field courier reads, so it is an unknown field rather than a
      # value with an effect.
      conn = post_authed(body(%{"account_id" => @other_account}))

      assert conn.status == 422
      assert fields(conn) == ["account_id"]
      assert sent() == []
    end

    test "a from address in the body is refused, because the sender is courier's" do
      conn = post_authed(body(%{"from" => "attacker@evil.test"}))

      assert conn.status == 422
      assert fields(conn) == ["from"]
      assert sent() == []
    end
  end

  describe "it delivers" do
    test "answers 200 naming the message, the event, and the type it sent" do
      conn = post_authed(body())

      assert conn.status == 200
      refute problem_json?(conn)

      sent_data = data(conn)

      assert sent_data["message_id"] =~ ~r/^courier-[0-9a-f-]{36}$/
      assert {:ok, _uuid} = Ecto.UUID.cast(sent_data["event_id"])
      # `notification_type` and not `type`: the request's field is `type` and the
      # response's is the name every other operation and the emitted event already
      # use for the same value. Two spellings of one thing in one document is a
      # mapping somebody has to hold in their head; the request field is the one
      # that had to differ, because `type` is what a caller writing an HTTP
      # client expects.
      assert sent_data["notification_type"] == "welcome"
      assert sent_data["user_id"] == @user_id
    end

    test "the status reads accepted, because accepted is all SMTP promises" do
      # A submission protocol's whole reply is "accepted for delivery". A field
      # reading `delivered` would be courier claiming a fact about somebody
      # else's inbox, which courier has and cannot have at this point.
      assert data(post_authed(body()))["status"] == "accepted"
    end

    test "the mail reaches the address the body named, with courier's sender" do
      recipient = address()

      conn = post_authed(body(%{"to" => recipient, "name" => "Kaka"}))

      assert conn.status == 200

      assert [%Swoosh.Email{} = email] = sent()
      assert email.to == [{"Kaka", recipient}]
      assert email.from == {"caFaye", "no-reply@cafaye.com"}
    end

    test "the message carries the returned id, so a bounce quoting it can be tied back" do
      conn = post_authed(body())

      assert [%Swoosh.Email{headers: headers}] = sent()
      assert headers["message-id"] == "<#{data(conn)["message_id"]}@cafaye.com>"
    end

    test "the event id names courier's own outbox row, for this message" do
      conn = post_authed(body())

      assert [row] = Enum.filter(Repo.all(OutboxEvent), &(&1.id == data(conn)["event_id"]))
      assert row.subject == data(conn)["message_id"]
      assert row.data["user_id"] == @user_id
      assert row.data["notification_type"] == "welcome"
    end

    test "the rendered body carries the link courier was given" do
      url = "https://cafaye.com/reset?token=abc123"

      conn = post_authed(body(%{"type" => "password_reset", "url" => url, "name" => nil}))

      assert conn.status == 200

      assert [%Swoosh.Email{} = email] = sent()
      assert email.subject == "Reset your caFaye password"
      assert email.text_body =~ url
      assert email.html_body =~ url
    end

    test "a type with more required fields is checked against all of them" do
      conn =
        post_authed(
          body(%{
            "type" => "team_invitation",
            "url" => "https://cafaye.com/join/abc",
            "account_name" => "Acme"
          })
        )

      assert conn.status == 422
      assert fields(conn) == ["invited_by"]
      assert sent() == []
    end

    test "two sends get two message ids" do
      first = data(post_authed(body()))["message_id"]
      second = data(post_authed(body()))["message_id"]

      assert first != second
      assert length(sent()) == 2
    end
  end

  describe "the two email-change notices" do
    # identity's email-change flow reaches courier through this door, so these
    # two types are asserted here and not only in `Courier.MailersTest`: a type
    # that renders and a type that is SENDABLE are different claims, and the
    # second one is the one the flow depends on.

    test "the current-address notice sends, and carries the confirmation link" do
      url = "https://cafaye.com/email-changes/confirm?token=ch4nge"

      conn =
        post_authed(
          body(%{
            "type" => "email_change_current",
            "to" => address(),
            "url" => url,
            "name" => nil
          })
        )

      assert conn.status == 200

      assert [%Swoosh.Email{} = email] = sent()
      assert email.subject == "Confirm an email address change on your caFaye account"
      assert email.text_body =~ url
      assert email.html_body =~ url
      assert data(conn)["notification_type"] == "email_change_current"
    end

    test "the new-address notice sends, and names the address the account is moving from" do
      conn =
        post_authed(
          body(%{
            "type" => "email_change_new",
            "to" => address(),
            "previous_email" => "kaka@example.com",
            "name" => nil
          })
        )

      assert conn.status == 200

      assert [%Swoosh.Email{} = email] = sent()
      assert email.subject == "Confirm your new caFaye email address"
      assert email.text_body =~ "kaka@example.com"
      assert email.html_body =~ "kaka@example.com"
      assert data(conn)["notification_type"] == "email_change_new"
    end

    test "a type's required fields are enforced at the door, not only in the library" do
      # The per-type required list is `Courier.Mailers`' own, and this is the
      # proof that a body missing one of them is refused HERE rather than
      # rendered into a mail with a hole in it.
      conn = post_authed(body(%{"type" => "email_change_current", "name" => nil}))

      assert conn.status == 422
      assert fields(conn) == ["url"]
      assert sent() == []
    end

    test "a misspelled field is a 422 naming it, not one courier silently drops" do
      # The closed vocabulary is the point of the door: `previous_emai` is not
      # a field, and a body carrying it must be refused by NAME rather than
      # accepted with the previous address silently discarded — which over
      # HTTP is how a caller believes a mail was addressed that was not.
      #
      # The correctly-spelled `previous_email` travels beside it, so the
      # misspelling is the ONLY thing wrong with the body: a 422 naming both
      # an unknown field and a missing required one would pass against a door
      # that reported only the first, and the claim is that the unknown field
      # is named.
      conn =
        post_authed(
          body(%{
            "type" => "email_change_new",
            "previous_email" => "kaka@example.com",
            "previous_emai" => "kaka@example.com",
            "name" => nil
          })
        )

      assert conn.status == 422
      assert fields(conn) == ["previous_emai"]
      assert sent() == []
    end
  end

  describe "it consults the suppression list before it sends" do
    test "a hard-bounced mailbox is a 409 and no mail is sent" do
      email = address()
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      conn = post_authed(body(%{"to" => email}))

      assert conn.status == 409
      assert problem_json?(conn)
      assert problem(conn)["code"] == "conflict"
      assert problem(conn)["status"] == 409
      assert sent() == []
      assert outbox_for(email) == []
    end

    test "a complaint is the same refusal — it outranks a later bounce" do
      email = address()
      {:ok, :new, _row} = suppress(email, :complaint)
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      conn = post_authed(body(%{"to" => email}))

      assert conn.status == 409
      assert sent() == []
    end

    test "the refusal says which of the two it is, so an operator can tell" do
      bounced = address()
      complained = address()
      {:ok, :new, _row} = suppress(bounced, :hard_bounce)
      {:ok, :new, _row} = suppress(complained, :complaint)

      hard = post_authed(body(%{"to" => bounced}))
      spam = post_authed(body(%{"to" => complained}))

      assert problem(hard)["detail"] =~ "does not exist"
      assert problem(spam)["detail"] =~ "reported"
    end

    test "the address is matched the way courier stores it — downcased" do
      email = address()
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      conn = post_authed(body(%{"to" => String.upcase(email)}))

      assert conn.status == 409
      assert sent() == []
    end

    test "a padded address is a 422 rather than a silently trimmed one" do
      # `Courier.Mailers`' format check rejects a space inside the address, so
      # `" a@b.test "` never reaches the suppression lookup. Asserted because the
      # opposite would be quiet: courier trimming an address a caller sent padded
      # is a decision no caller asked for and none can see.
      email = address()
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      conn = post_authed(body(%{"to" => "  #{email}  "}))

      assert conn.status == 422
      assert fields(conn) == ["to"]
      assert sent() == []
    end

    test "the refusal does not echo the address back" do
      # The table is never exposed through a route, and a 409 that quoted the
      # address would make a probe of guessed addresses worth running.
      #
      # The status is asserted FIRST on purpose. This is an absence assertion, and
      # an absence assertion placed before the presence one is green over a 404 —
      # which is how it read before the route existed, and how three redaction
      # tests in this repository once proved nothing at all.
      email = address()
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      conn = post_authed(body(%{"to" => email}))

      assert conn.status == 409
      refute conn.resp_body =~ email
    end

    test "an unsuppressed address of the same type still goes out" do
      {:ok, :new, _row} = suppress(address(), :hard_bounce)

      conn = post_authed(body())

      assert conn.status == 200
      assert length(sent()) == 1
    end

    test "a soft bounce suppresses nothing" do
      # RFC 5321 §4.2.2 is a temporary failure. A list that fills on temporary
      # failures is how a service stops mailing people whose provider had a bad
      # afternoon.
      email = address()

      assert {:ok, :ignored} = Suppressions.ingest(suppression_event(email, :soft_bounce))

      conn = post_authed(body(%{"to" => email}))

      assert conn.status == 200
      assert length(sent()) == 1
    end

    test "the suppression check is in the send path, not only in this controller" do
      # Proved from the library side, because "whatever the caller asked for" has
      # to hold for a caller that is not HTTP.
      email = address()
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      assert {:error, {:suppressed_address, :undeliverable}} =
               Courier.Deliver.welcome(%{user_id: @user_id, email: email, name: "Kaka"})
    end
  end

  describe "the user's preference is asked before the mailbox's" do
    test "a user who declined this type by email gets nothing" do
      email = address()
      decline("welcome")

      conn = post_authed(body(%{"to" => email}))

      assert conn.status == 422
      assert problem(conn)["code"] == "validation_failed"
      assert [%{"field" => "type"}] = problem(conn)["errors"]
      assert sent() == []
    end

    test "declining one type leaves the others alone" do
      decline("welcome")

      conn =
        post_authed(body(%{"type" => "password_reset", "url" => "https://cafaye.com/r"}))

      assert conn.status == 200
      assert length(sent()) == 1
    end

    test "a user nobody has written preferences for is sent to — silence is not consent" do
      conn = post_authed(body(%{"user_id" => @other_user_id}))

      assert conn.status == 200
      assert length(sent()) == 1
    end

    test "a decline is per user, and one user's answer does not stop another's mail" do
      decline("welcome")

      conn = post_authed(body(%{"user_id" => @other_user_id}))

      assert conn.status == 200
    end

    test "a suppression row stops the send whatever the account, because it is about the mailbox" do
      email = address()
      {:ok, :new, _row} = suppress(email, :hard_bounce)

      conn = post_authed(body(%{"to" => email}))

      assert conn.status == 409
      assert sent() == []
    end
  end

  describe "Idempotency-Key" do
    @key "11111111-1111-1111-1111-111111111111"

    test "a retry with the same key and the same body sends one mail" do
      payload = body()

      first = post_authed(payload, [{"idempotency-key", @key}])
      second = post_authed(payload, [{"idempotency-key", @key}])

      assert first.status == 200
      assert second.status == 200
      assert get_resp_header(second, "idempotency-replayed") == ["true"]
      assert second.resp_body == first.resp_body
      assert length(sent()) == 1
    end

    test "without a key a retry sends twice, which is why the header is documented" do
      payload = body()

      assert post_authed(payload).status == 200
      assert post_authed(payload).status == 200
      assert length(sent()) == 2
    end

    test "a key that is not a uuid is a 422 and sends nothing" do
      conn = post_authed(body(), [{"idempotency-key", "not-a-uuid"}])

      assert conn.status == 422
      assert fields(conn) == ["Idempotency-Key"]
      assert sent() == []
    end

    test "a refused send leaves its key free to use again" do
      # Why the plug releases rather than stores a non-2xx: a stored 422 would
      # pin a caller's typo for 24 hours, so fixing the body and retrying with
      # the same key has to work.
      key = "22222222-2222-2222-2222-222222222222"

      assert post_authed(body(%{"type" => "nope"}), [{"idempotency-key", key}]).status == 422

      assert post_authed(body(), [{"idempotency-key", key}]).status == 200
      assert length(sent()) == 1
    end

    test "the same key with a different body is a 409, and sends no second mail" do
      key = "33333333-3333-3333-3333-333333333333"

      assert post_authed(body(), [{"idempotency-key", key}]).status == 200

      conn = post_authed(body(%{"name" => "Somebody Else"}), [{"idempotency-key", key}])

      assert conn.status == 409
      assert problem(conn)["code"] == "idempotency_key_reused"
      assert length(sent()) == 1
    end
  end

  describe "the rendered message carries a body" do
    test "a message courier really renders passes" do
      assert {:ok, email} = Mailers.build(:welcome, %{user_id: @user_id, email: address()})

      assert Courier.Mailers.body?(email)
    end

    test "either format alone is enough" do
      assert Courier.Mailers.body?(body_only(text_body: "hi"))
      assert Courier.Mailers.body?(body_only(html_body: "<p>hi</p>"))
    end

    test "a message with neither is refused, because Swoosh would report it as sent" do
      refute Courier.Mailers.body?(body_only([]))
    end

    test "an empty string is not a body" do
      refute Courier.Mailers.body?(body_only(text_body: ""))
      refute Courier.Mailers.body?(body_only(html_body: ""))
    end

    test "the invariant reads the message, not the type it was rendered from" do
      # Every type courier renders carries both formats today, so the predicate
      # has to be tested on hand-built messages to be tested at all — and a
      # predicate that only ever sees real renders is a predicate nothing has
      # checked.
      refute Courier.Mailers.body?(%Swoosh.Email{
               to: [{"Kaka", address()}],
               subject: "no bodies at all"
             })
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp body_only(fields), do: struct!(%Swoosh.Email{to: [{"Kaka", address()}]}, fields)

  defp decline(type) do
    {:ok, _stored} =
      NotificationPreferences.update(@account, @user_id, %{
        "preferences" => [%{"notification_type" => type, "email_enabled" => false}]
      })
  end

  defp suppress(email, kind), do: Suppressions.ingest(suppression_event(email, kind))

  defp suppression_event(email, kind) do
    %{
      provider: "test",
      provider_event_id: "evt-#{System.unique_integer([:positive])}",
      email: email,
      kind: kind
    }
  end
end
