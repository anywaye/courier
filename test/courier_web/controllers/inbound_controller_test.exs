defmodule CourierWeb.InboundControllerTest do
  @moduledoc """
  `POST /inbound/resend` — the door `Courier.Suppressions.ingest/1` was waiting for.

  ## The negative cases are this file

  `Courier.InboundTest` proves the library half: verify, then parse, then ingest,
  and an unsigned payload records nothing. This file proves the half that only
  exists at HTTP, and it is the half that can go wrong without anybody noticing:

    * **an unauthenticated `POST` that records suppressions.** Anyone who finds
      the URL could suppress anyone's mail, which is a denial of service on the
      whole product delivered by the feature meant to protect it. So every
      refusal below is paired with `assert_nothing_written/1` over the address
      that refusal's payload named.
    * **a route that parses before it verifies.** `CourierWeb.Plugs.ParseBody` is
      an *endpoint* plug, so it runs on every request; on this route it must not,
      or a decoder sees a body nobody has authenticated. The direct evidence is
      `test/courier_web/plugs/parse_body_test.exs`, and the behavioural evidence
      is the first describe below: an unsigned request carrying a payload courier
      would happily have acted on is refused, and records nothing.
    * **an answer that echoes the address.** `POST /v1/messages` deliberately does
      not, and this route has the same reason and more of it: the table has no
      `account_id`, so anything that quotes an address back is a way to ask
      courier questions about mailboxes it holds. A refusal carries the *reason*
      and no part of the *request*, and that is asserted with a canary rather
      than by reading the strings.

  ## Every count is over this test's own address

  `email_suppressions` has no `account_id`, its rows are permanent, and
  `AGENTS.md` is explicit that a count over the whole table is a claim about
  every other test in the repository. So every assertion here filters by an
  address minted for that one call, and `assert_nothing_written/1` is the one
  place that says it.

  ## The events are asserted, not inferred

  `Courier.Events.bounced/1` and `complained/1` had no caller when this packet
  started, which is the defect the previous packet was opened for. A builder with
  no caller is indistinguishable from a builder that is wrong, so the events are
  read out of `outbox_events` here — and a bounce is published with the `user_id`
  and `notification_type` of the **send that caused it**, which the test obtains
  by really sending one and using the message id the provider would have quoted.
  """

  use CourierWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Courier.Events
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppression
  alias Courier.Suppressions
  alias Courier.TestSupport.FakeResend

  @path "/inbound/resend"
  @account "4c5d6e7f-8a9b-4c0d-9e1f-2a3b4c5d6e7f"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The address each test mints. Unique per call, and it has to be:
  # `email_suppressions` rows are permanent, so a hard-coded address would let one
  # test's suppression decide another test's outcome.
  defp address, do: "bounce-#{System.unique_integer([:positive])}@example.com"

  # The `Message-ID` as a provider quotes it back: angle brackets, and the
  # qualifier `Courier.Deliver.tag/2` puts on the wire. `Courier.Suppression`
  # stores the identifier with the brackets stripped and the qualifier KEPT, while
  # `outbox_events.subject` holds courier's bare id — so the route's join has to
  # try both spellings. See `CourierWeb.InboundReports`.
  defp quoted(message_id), do: "<#{message_id}@anywaye.com>"

  # --- helpers -----------------------------------------------------------------

  defp deliver(body, headers) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("content-type", "application/json")
    |> post(@path, body)
  end

  defp deliver_signed(body, opts \\ []) do
    {body, headers} = FakeResend.signed(body, opts)
    deliver(body, headers)
  end

  # A real send, so the bounce's `message_id` is a message courier really wrote an
  # outbox row for rather than a string that looks like one.
  defp send_message(recipient) do
    conn =
      build_conn()
      |> put_req_header("x-courier-account", @account)
      |> post("/v1/messages", %{
        "type" => "welcome",
        "user_id" => @user_id,
        "to" => recipient,
        "name" => "Kaka"
      })

    assert conn.status == 200,
           "the send this test's report is about did not happen: #{inspect(conn.resp_body)}"

    decoded(conn)["data"]["message_id"]
  end

  defp decoded(conn), do: Jason.decode!(conn.resp_body)
  defp problem(conn), do: decoded(conn)
  defp data(conn), do: problem(conn)["data"]

  defp fields(conn) do
    conn |> problem() |> Map.get("errors") |> Enum.map(& &1["field"])
  end

  defp field_codes(conn) do
    conn |> problem() |> Map.get("errors") |> Enum.map(& &1["code"])
  end

  defp problem_json?(conn) do
    conn |> get_resp_header("content-type") |> List.first() |> Kernel.||("") =~
      "application/problem+json"
  end

  defp rows(address), do: Suppressions.history(address)

  defp outbox(type, address) do
    Enum.filter(Repo.all(OutboxEvent), &(&1.type == type and &1.data["email"] == address))
  end

  # The one place this file says "nothing was written", so no test can assert it
  # about a different table or a different address than it means.
  defp assert_nothing_written(address) do
    assert rows(address) == [],
           "a refused report was recorded: #{inspect(rows(address))}"

    assert Suppressions.state(address) == nil
    assert outbox(Events.bounced_type(), address) == []
    assert outbox(Events.complained_type(), address) == []
  end

  defp counts(conn) do
    %{
      "received" => data(conn)["received"],
      "recorded" => data(conn)["recorded"],
      "duplicates" => data(conn)["duplicates"],
      "ignored" => data(conn)["ignored"],
      "events" => data(conn)["events"]
    }
  end

  defp nothing(counts) do
    assert counts == %{
             "received" => 0,
             "recorded" => 0,
             "duplicates" => 0,
             "ignored" => 0,
             "events" => 0
           }
  end

  # ---------------------------------------------------------------------------
  # Verify before parse — the property the whole base exists for
  # ---------------------------------------------------------------------------

  describe "an unauthenticated request never reaches the parser" do
    test "an unsigned but perfectly well-formed bounce is refused and records nothing" do
      # THE test. The body below is one courier would have acted on: a `Permanent`
      # bounce for a real address. The only thing missing is the signature, and the
      # answer is a refusal with an empty table behind it.
      #
      # If the endpoint's JSON parser ran first and the controller trusted what it
      # decoded, this is the request that suppresses a live mailbox — so the
      # assertion is deliberately about rows and not about a status code.
      recipient = address()

      conn = deliver(FakeResend.bounce(recipients: [recipient]), %{})

      assert conn.status == 401
      assert problem_json?(conn)
      assert problem(conn)["code"] == "unauthorized"
      assert_nothing_written(recipient)
    end

    test "the 401 carries the reason and no part of the request" do
      # A refusal that echoes a request value back is an oracle. The reason is
      # courier's own vocabulary — an atom, or a header NAME, both public in the
      # spec — and this asserts the difference on a request whose only identifying
      # values are ones courier must not repeat.
      canary = "canary-#{System.unique_integer([:positive])}"

      {body, headers} =
        FakeResend.signed(
          FakeResend.bounce(recipients: ["#{canary}@example.com"]),
          id: "#{canary}-id",
          timestamp: 1_731_705_121
        )

      conn = deliver(body, headers)
      encoded = problem(conn) |> Jason.encode!()

      assert conn.status == 401
      assert problem(conn)["detail"] =~ "replay window"

      for {_name, value} <- headers, is_binary(value) do
        refute encoded =~ value,
               "the 401 repeated a request value (#{inspect(value)})"
      end
    end

    test "signed by a stranger, with a same-shaped secret" do
      # The point of `FakeResend.other_secret/0` being the same SHAPE and LENGTH as
      # the real one: a malformed secret would be refused as `:invalid_secret`
      # before the comparison, and this test would pass without ever exercising the
      # HMAC check.
      recipient = address()
      {body, headers} = FakeResend.signed_by_stranger(FakeResend.bounce(recipients: [recipient]))

      conn = deliver(body, headers)

      assert conn.status == 401
      assert problem(conn)["code"] == "unauthorized"
      assert_nothing_written(recipient)
    end

    test "a signature over a body that is not the body that arrived" do
      # The re-serialization attack, and the one the spec names as "a very common
      # failure mode" of signature verification: courier verifies the bytes as
      # received. The address in the tampered copy is a second one, so both are
      # asserted — a body that was rewritten after signing must not be recorded
      # under EITHER address.
      original = address()
      swapped = address()
      signed_body = FakeResend.bounce(recipients: [original])
      {_, headers} = FakeResend.signed(signed_body)

      tampered = String.replace(signed_body, original, swapped)

      assert tampered != signed_body, "the test did not actually change the body"
      assert deliver(tampered, headers).status == 401
      assert_nothing_written(original)
      assert_nothing_written(swapped)
    end

    test "a timestamp outside the tolerance" do
      # The other half of replay defence. Inside the window a replay is
      # deduplicated by the unique index (there is a test for that below); outside
      # it the signature is stale and there is nothing to deduplicate.
      recipient = address()

      conn =
        deliver_signed(FakeResend.bounce(recipients: [recipient]),
          timestamp: Courier.Webhooks.Signature.unix_now() - FakeResend.tolerance() - 60
        )

      assert conn.status == 401
      assert problem(conn)["detail"] =~ "replay window"
      assert_nothing_written(recipient)
    end

    test "the `webhook-` prefix is accepted as well as `svix-`" do
      # Spec §Webhook headers: "All of the headers should be prefixed with
      # `webhook-`", and Svix's docs say white-labelled accounts send that instead
      # of the `svix-` prefix Resend sends. Both are read; neither substitutes for
      # the other.
      recipient = address()

      conn = deliver_signed(FakeResend.bounce(recipients: [recipient]), prefix: "webhook")

      assert conn.status == 200
      assert [%Suppression{state: :undeliverable}] = rows(recipient)
    end
  end

  # ---------------------------------------------------------------------------
  # The accepted path
  # ---------------------------------------------------------------------------

  describe "a signed hard bounce" do
    test "records the suppression and publishes courier.email.bounced" do
      recipient = address()
      message_id = send_message(recipient)

      conn =
        deliver_signed(FakeResend.bounce(recipients: [recipient], message_id: quoted(message_id)))

      assert conn.status == 200

      assert counts(conn) == %{
               "received" => 1,
               "recorded" => 1,
               "duplicates" => 0,
               "ignored" => 0,
               "events" => 1
             }

      assert [%Suppression{state: :undeliverable, provider: "resend"} = row] = rows(recipient)
      assert row.message_id == "#{message_id}@anywaye.com"

      # The event, and its payload is core's schema field for field: the four
      # fields `courier.email.delivered` carries, with `email` naming the address
      # that BOUNCED — which for a broadcast is not the address the send was for.
      assert [event] = outbox(Events.bounced_type(), recipient)

      assert event.subject == message_id

      assert event.data == %{
               "message_id" => message_id,
               "user_id" => @user_id,
               "notification_type" => "welcome",
               "email" => recipient
             }

      assert outbox(Events.complained_type(), recipient) == []
    end

    test "a complaint records :suppressed and publishes courier.email.complained" do
      recipient = address()
      message_id = send_message(recipient)

      conn =
        deliver_signed(
          FakeResend.complaint(recipients: [recipient], message_id: quoted(message_id))
        )

      assert conn.status == 200
      assert counts(conn)["recorded"] == 1
      assert counts(conn)["events"] == 1
      assert [%Suppression{state: :suppressed}] = rows(recipient)

      assert [event] = outbox(Events.complained_type(), recipient)
      assert event.subject == message_id
      assert event.data["email"] == recipient
      assert outbox(Events.bounced_type(), recipient) == []
    end

    test "a complaint outranks a bounce for the same mailbox, and both are published" do
      # The precedence `Courier.Suppressions` exists to make unbreakable, asserted
      # from the route rather than from the context. The complaint arrives second
      # and is a DIFFERENT provider event id, so the unique index does not mistake
      # it for a repeat — and the state folds to `:suppressed`.
      recipient = address()
      message_id = send_message(recipient)

      assert deliver_signed(
               FakeResend.bounce(recipients: [recipient], message_id: quoted(message_id))
             ).status == 200

      assert deliver_signed(
               FakeResend.complaint(recipients: [recipient], message_id: quoted(message_id))
             ).status == 200

      assert Suppressions.state(recipient) == :suppressed
      assert [bounce] = outbox(Events.bounced_type(), recipient)
      assert [complaint] = outbox(Events.complained_type(), recipient)
      assert bounce.id != complaint.id
    end

    test "a soft bounce records nothing and publishes nothing, and says so" do
      # `Transient` is RFC 5321 §4.2.2 temporary failure. Suppressing on one is how
      # a suppression list starts eating live addresses, so `ingest/1` answers
      # `{:ok, :ignored}` — a THIRD shape, and the response has to be able to say
      # which of the three happened without a caller having to know courier's
      # table.
      recipient = address()
      message_id = send_message(recipient)

      conn =
        deliver_signed(
          FakeResend.bounce(
            recipients: [recipient],
            bounce_type: "Transient",
            message_id: quoted(message_id)
          )
        )

      assert conn.status == 200
      assert counts(conn)["ignored"] == 1
      assert counts(conn)["recorded"] == 0
      assert counts(conn)["events"] == 0
      assert_nothing_written(recipient)
    end

    test "a broadcast is one report per recipient, and one event each" do
      # Resend's `to` is "Array of impacted recipient email addresses" and a
      # broadcast shares one `email_id` across all of them. Keyed on the email
      # alone, four of five bounces would collide with the first and four live
      # mailboxes would go on being mailed forever.
      recipients = Enum.map(1..3, fn _ -> address() end)
      message_id = send_message(List.first(recipients))

      conn =
        deliver_signed(FakeResend.bounce(recipients: recipients, message_id: quoted(message_id)))

      assert conn.status == 200
      assert counts(conn)["received"] == 3
      assert counts(conn)["recorded"] == 3
      assert counts(conn)["events"] == 3

      for recipient <- recipients do
        assert [%Suppression{state: :undeliverable}] = rows(recipient)
        assert [event] = outbox(Events.bounced_type(), recipient)
        assert event.subject == message_id
      end
    end

    test "an event courier has read and has no opinion on is a 200 with nothing done" do
      # `email.delivered` is the provider telling courier the mail arrived. courier
      # has no opinion about that, and `{:ok, []}` is a distinct answer rather than
      # a success the caller should retry.
      conn = deliver_signed(FakeResend.event("email.delivered"))

      assert conn.status == 200
      assert nothing(counts(conn))
    end
  end

  # ---------------------------------------------------------------------------
  # Idempotency, deliberately
  # ---------------------------------------------------------------------------

  describe "a provider delivering the same report twice" do
    test "the second delivery is a 200 that says duplicate, and writes nothing new" do
      recipient = address()
      message_id = send_message(recipient)

      {body, headers} =
        FakeResend.signed(
          FakeResend.bounce(recipients: [recipient], message_id: quoted(message_id))
        )

      assert deliver(body, headers).status == 200

      second = deliver(body, headers)

      assert second.status == 200

      assert counts(second) == %{
               "received" => 1,
               "recorded" => 0,
               "duplicates" => 1,
               "ignored" => 0,
               "events" => 0
             }

      assert length(rows(recipient)) == 1
      assert length(outbox(Events.bounced_type(), recipient)) == 1
    end

    test "the same report under a FRESH signature is still one write" do
      # This is the choice the route makes rather than the `:idempotent` pipeline,
      # asserted. Deduplication is on `(provider, provider_event_id)`, which
      # `Courier.Inbound.Resend` derives from the report's own CONTENT — so a
      # provider that re-signs a retry (a new `svix-id`, a new timestamp) is
      # deduplicated all the same, and somebody cannot get a second write by
      # resending with a new header.
      recipient = address()
      message_id = send_message(recipient)
      body = FakeResend.bounce(recipients: [recipient], message_id: quoted(message_id))

      assert deliver_signed(body).status == 200
      assert deliver_signed(body, id: "msg_second-attempt").status == 200
      assert deliver_signed(body, id: "msg_third-attempt").status == 200

      assert length(rows(recipient)) == 1
      assert length(outbox(Events.bounced_type(), recipient)) == 1
    end

    test "and a replay past the tolerance is refused, still writing nothing new" do
      # The two halves of replay defence, and this is the other one: the index
      # deduplicates inside the window and the signature is refused outside it.
      recipient = address()
      {body, headers} = FakeResend.signed(FakeResend.bounce(recipients: [recipient]))

      assert deliver(body, headers).status == 200

      late =
        Map.put(
          headers,
          "svix-timestamp",
          to_string(Courier.Webhooks.Signature.unix_now() - FakeResend.tolerance() - 60)
        )

      assert deliver(body, late).status == 401
      assert length(rows(recipient)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Refusals after verification
  # ---------------------------------------------------------------------------

  describe "a report courier cannot act on" do
    test "a body that is not JSON is a 400 and writes nothing" do
      recipient = address()

      # Signed OVER the malformed bytes. A 400 here is reachable only by somebody
      # holding the signing secret, which is the point: `openapi.yaml` declares it
      # and says why an unsigned malformed body is a 401 instead.
      conn = deliver_signed(FakeResend.bounce(recipients: [recipient]) <> "{not json")

      assert conn.status == 400
      assert problem_json?(conn)
      assert problem(conn)["code"] == "bad_request"
      assert_nothing_written(recipient)
    end

    test "JSON that is not an object is a 400" do
      assert deliver_signed("[1,2,3]").status == 400
      assert deliver_signed("\"a string\"").status == 400
    end

    test "an event type courier has not read is a 422, a log line, and nothing written" do
      recipient = address()

      # `Courier.Inbound.Resend`'s moduledoc asks for exactly this: "a provider
      # that adds a bounce type should produce a log line, not silence". A 200
      # would be courier claiming it did something with a report it could not read,
      # so this is a 422 and the provider is told.
      log =
        capture_log(fn ->
          conn =
            deliver_signed(FakeResend.event("email.suppression_added", recipients: [recipient]))

          assert conn.status == 422
          assert problem(conn)["code"] == "validation_failed"
          assert fields(conn) == ["type"]
          assert field_codes(conn) == ["unsupported_event"]
          assert_nothing_written(recipient)
        end)

      assert log =~ "email.suppression_added",
             "the refusal did not name the event type courier could not classify, so an " <>
               "operator reading the log cannot tell which provider change to look for"
    end

    test "a bounce type outside the documented vocabulary is a 422, and the value is logged" do
      recipient = address()

      log =
        capture_log(fn ->
          conn =
            deliver_signed(
              FakeResend.bounce(
                recipients: [recipient],
                bounce_type: "Ragequit",
                message_id: quoted("courier-00000000-0000-4000-8000-000000000000")
              )
            )

          assert conn.status == 422
          assert fields(conn) == ["bounce"]
          assert field_codes(conn) == ["unknown_bounce_type"]
          assert_nothing_written(recipient)
        end)

      assert log =~ "Ragequit"
    end

    test "a recipient courier cannot send to is a 422 that does not quote it" do
      # The address is in courier's LOGS and not in its RESPONSE. The parser names
      # it precisely so an operator can act on it; the response is a body anybody
      # who can reach the route can read, and this table is not exposed through any
      # route for the same reason the 409 on `POST /v1/messages` does not echo one.
      bad = "not-an-address@@example.com"

      log =
        capture_log(fn ->
          conn = deliver_signed(FakeResend.bounce(recipients: [bad]))

          assert conn.status == 422
          assert fields(conn) == ["to"]
          assert field_codes(conn) == ["invalid_recipient"]
          refute conn.resp_body =~ bad
          assert Suppressions.state(bad) == nil
        end)

      assert log =~ bad
    end

    test "a payload missing a field courier needs names that field" do
      # `type` present, `data` absent. A 422 rather than a 500: the request was
      # authentic and well-formed JSON and the thing it asked for is not allowed,
      # which is core's own "anything semantically wrong is 422".
      conn =
        deliver_signed(~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z"}))

      assert conn.status == 422
      assert fields(conn) == ["data"]
      assert field_codes(conn) == ["required"]
    end

    test "a body larger than courier will verify is refused before the parser" do
      # An unauthenticated caller must not be able to make courier buffer an
      # unbounded body. Every provider report courier accepts is a few kilobytes,
      # so the bound is generous, and the refusal happens before verification
      # rather than after it.
      recipient = address()
      oversize = FakeResend.bounce(recipients: [recipient]) |> overflow()

      conn = deliver_signed(oversize)

      assert conn.status == 400
      assert problem(conn)["code"] == "bad_request"
      # The size refusal and not a parse refusal: the body padded above is still
      # valid JSON carrying a bounce courier would have acted on, so a 400 for any
      # other reason would be a different answer to a different question.
      assert problem(conn)["detail"] =~ "larger than"
      assert_nothing_written(recipient)
    end
  end

  # ---------------------------------------------------------------------------
  # A report courier cannot attribute to a send
  # ---------------------------------------------------------------------------

  describe "a bounce courier cannot tie back to a send" do
    test "records the suppression, publishes no event, and says why in a log" do
      # The suppression is the load-bearing fact: the address is not going to be
      # mailed again whatever courier can say about which message it was. So the
      # row is written, the transaction commits, and the missing event is a log
      # line rather than a rollback that would throw the row away with it.
      recipient = address()
      send_message(recipient)

      log =
        capture_log(fn ->
          conn =
            deliver_signed(
              FakeResend.bounce(
                recipients: [recipient],
                message_id: "<something-else@another-provider.example>"
              )
            )

          assert conn.status == 200
          assert counts(conn)["recorded"] == 1
          assert counts(conn)["events"] == 0

          assert [%Suppression{state: :undeliverable}] = rows(recipient)
          assert outbox(Events.bounced_type(), recipient) == []
        end)

      assert log =~ "something-else"

      # And the message courier DID send is untouched, which is the point: an
      # unattributable bounce says nothing about whether that message arrived.
      assert length(outbox(Events.delivered_type(), recipient)) == 1
    end

    test "a report with no Message-ID at all is the same case" do
      # Resend documents `message_id` on the bounced payload and a provider that
      # omits it is not hypothetical — an SMTP-level bounce arriving through a
      # relay courier does not control quotes no `Message-ID` at all. So this is
      # the case where a suppression is the *only* thing courier can record, and
      # the assertion is that the row is there anyway.
      #
      # Built with `Jason.encode!/1` rather than the documented literal the rest
      # of this file uses, because the field is *absent* here and a hand-written
      # body with a missing key is a typo waiting to become a test that passes
      # for the wrong reason. `FakeResend` cannot build it: its `encode_value/1`
      # has no clause for `nil`, and adding one would make a fake able to write
      # `"message_id": null` — a payload that is documented and that courier
      # therefore has to accept.
      recipient = address()

      body =
        Jason.encode!(%{
          "type" => "email.bounced",
          "created_at" => "2026-11-22T23:41:12.126Z",
          "data" => %{
            "email_id" => "56761188-7520-42d8-8898-ff6fc54ce618",
            "to" => [recipient],
            "bounce" => %{"type" => "Permanent", "subType" => "General"}
          }
        })

      capture_log(fn ->
        conn = deliver_signed(body)

        assert conn.status == 200
        assert counts(conn)["recorded"] == 1
        assert counts(conn)["events"] == 0
      end)

      assert [%Suppression{state: :undeliverable, message_id: nil}] = rows(recipient)
    end
  end

  # ---------------------------------------------------------------------------
  # The response, and what it must never carry
  # ---------------------------------------------------------------------------

  describe "nothing in the response is about a mailbox" do
    # The six answers the six requests below are built to produce, asserted
    # together. A list written down beside the requests it describes is a check
    # that can only fail for a case somebody remembered to type, and the point of
    # this one is that the refusals differ from each other — a 400 that quietly
    # became a 422 would still keep every address out of every body below.
    @answers [200, 401, 401, 400, 422, 422]

    test "the accepted answer and every refusal carry no address" do
      [genuine, unsigned, stranger, malformed, unknown_type, unclassifiable] =
        Enum.map(1..6, fn _ -> address() end)

      conns =
        [
          fn -> deliver_signed(FakeResend.bounce(recipients: [genuine])) end,
          fn -> deliver(FakeResend.bounce(recipients: [unsigned]), %{}) end,
          fn ->
            {body, headers} =
              FakeResend.signed_by_stranger(FakeResend.bounce(recipients: [stranger]))

            deliver(body, headers)
          end,
          fn -> deliver_signed(FakeResend.bounce(recipients: [malformed]) <> "{not json") end,
          fn ->
            deliver_signed(FakeResend.event("email.brand_new", recipients: [unknown_type]))
          end,
          fn ->
            deliver_signed(FakeResend.bounce(recipients: [unclassifiable], bounce_type: "Nope"))
          end
        ]
        |> Enum.map(& &1.())

      statuses = Enum.map(conns, & &1.status)

      assert statuses == @answers,
             "the six requests were supposed to reach six different answers, and reached " <>
               "#{inspect(statuses)}"

      for {conn, recipient} <-
            Enum.zip(conns, [genuine, unsigned, stranger, malformed, unknown_type, unclassifiable]) do
        refute conn.resp_body =~ recipient,
               "#{conn.status} quoted a suppressed address back: #{inspect(conn.resp_body)}"

        refute conn.resp_body =~ "example.com"
      end
    end

    test "every non-2xx this route sends is courier's problem+json envelope" do
      for conn <- [
            deliver(FakeResend.bounce(), %{}),
            deliver_signed("{not json"),
            deliver_signed(FakeResend.event("email.brand_new")),
            deliver_signed(FakeResend.bounce(bounce_type: "Nope"))
          ] do
        assert conn.status >= 400
        assert problem_json?(conn)

        envelope = problem(conn)

        assert envelope["code"] == envelope["type"] |> String.split("/") |> List.last()
        assert is_binary(envelope["trace_id"]) and envelope["trace_id"] != ""
        assert envelope["trace_id"] == get_resp_header(conn, "x-trace-id") |> List.first()
      end
    end
  end

  # A body one byte over the bound, so the assertion is about the bound and not
  # about a kilobyte of test data.
  defp overflow(body) do
    room = CourierWeb.InboundController.max_body_bytes() - byte_size(body) + 1
    body <> String.duplicate(" ", room)
  end
end
