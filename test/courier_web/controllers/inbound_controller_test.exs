defmodule CourierWeb.InboundControllerTest do
  @moduledoc """
  `POST /inbound/resend` — the door `Courier.Suppressions.ingest/1` was waiting for.


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


  `email_suppressions` has no `account_id`, its rows are permanent, and
  `AGENTS.md` is explicit that a count over the whole table is a claim about
  every other test in the repository. So every assertion here filters by an
  address minted for that one call, and `assert_nothing_written/1` is the one
  place that says it.


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

  defp address, do: "bounce-#{System.unique_integer([:positive])}@example.com"

  defp quoted(message_id), do: "<#{message_id}@anywaye.com>"


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


  describe "an unauthenticated request never reaches the parser" do
    test "an unsigned but perfectly well-formed bounce is refused and records nothing" do
      recipient = address()

      conn = deliver(FakeResend.bounce(recipients: [recipient]), %{})

      assert conn.status == 401
      assert problem_json?(conn)
      assert problem(conn)["code"] == "unauthorized"
      assert_nothing_written(recipient)
    end

    test "the 401 carries the reason and no part of the request" do
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
      recipient = address()
      {body, headers} = FakeResend.signed_by_stranger(FakeResend.bounce(recipients: [recipient]))

      conn = deliver(body, headers)

      assert conn.status == 401
      assert problem(conn)["code"] == "unauthorized"
      assert_nothing_written(recipient)
    end

    test "a signature over a body that is not the body that arrived" do
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
      recipient = address()

      conn = deliver_signed(FakeResend.bounce(recipients: [recipient]), prefix: "webhook")

      assert conn.status == 200
      assert [%Suppression{state: :undeliverable}] = rows(recipient)
    end
  end


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
      conn = deliver_signed(FakeResend.event("email.delivered"))

      assert conn.status == 200
      assert nothing(counts(conn))
    end
  end


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


  describe "a report courier cannot act on" do
    test "a body that is not JSON is a 400 and writes nothing" do
      recipient = address()

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
      conn =
        deliver_signed(~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z"}))

      assert conn.status == 422
      assert fields(conn) == ["data"]
      assert field_codes(conn) == ["required"]
    end

    test "a body larger than courier will verify is refused before the parser" do
      recipient = address()
      oversize = FakeResend.bounce(recipients: [recipient]) |> overflow()

      conn = deliver_signed(oversize)

      assert conn.status == 400
      assert problem(conn)["code"] == "bad_request"
      assert problem(conn)["detail"] =~ "larger than"
      assert_nothing_written(recipient)
    end
  end


  describe "a bounce courier cannot tie back to a send" do
    test "records the suppression, publishes no event, and says why in a log" do
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

      assert length(outbox(Events.delivered_type(), recipient)) == 1
    end

    test "a report with no Message-ID at all is the same case" do
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


  describe "nothing in the response is about a mailbox" do
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

  defp overflow(body) do
    room = CourierWeb.InboundController.max_body_bytes() - byte_size(body) + 1
    body <> String.duplicate(" ", room)
  end
end
