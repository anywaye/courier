defmodule CourierWeb.UnsubscribeControllerTest do
  @moduledoc """
  `POST` and `GET /unsubscribe/:token` over real requests: the RFC 8058 one-click
  door, and everything the recipient's mail client can do to it.

  ## This is the file that proves the endpoint, and it drives the real router

  Not `Courier.Unsubscribes` — that is `Courier.UnsubscribesTest`, and a library
  test cannot show that the route is served, that the token in the path is what is
  read, that an unauthenticated `POST` is not a 401, or that no `Location` header
  comes back. Those are all facts about HTTP.

  ## The body is exercised the way RFC 8058 §8.1 spells it

  The RFC's own worked example sends
  `Content-Type: application/x-www-form-urlencoded` with the body
  `List-Unsubscribe=One-Click`, and §3.2 says the receiver "sends the key/value
  pair in the `List-Unsubscribe-Post` header as the request body". So that exact
  request is one of the tests: an endpoint that only worked for an empty body
  would work for nobody.

  ## The `POST` that acts on the path rather than on the body

  `Plug.Parsers` merges a request body into `conn.params`, so a body carrying its
  own `token` could name a different mailbox than the path did — and the whole
  authority of this route is the path segment. The test below sends exactly that
  request, with a real token in the body and a real one in the path, and asserts
  the path won.

  ## What is deliberately NOT tested here

  **No 401.** RFC 8058 §3.1 forbids this request from carrying authorization at
  all, and `openapi.yaml` declares no 401 for either operation; a token courier
  did not issue is a **404**, which is the subject's absence rather than a
  refused credential. `CourierWeb.OpenAPIErrorResponsesTest` provokes the statuses
  this route can send against the document, so the two cannot disagree.
  """

  use CourierWeb.ConnCase, async: true

  # `from/2` only: `ConnCase` imports the connection helpers and nothing from
  # `Ecto.Query`, so the one query macro this file needs is imported by name
  # rather than dragging in `update/3`, which `CourierWeb.Plugs.Idempotency`'s
  # tests would then have to work around.
  import Ecto.Query, only: [from: 2]

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppression
  alias Courier.Suppressions
  alias Courier.UnsubscribeToken
  alias Courier.Unsubscribes

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # An address the changeset refuses, written straight past it: what a deployment
  # gets when an address rule tightens under a token minted years ago.
  @unusable_email "not an address"

  defp address, do: "unsubscribe-#{System.unique_integer([:positive])}@example.com"

  setup do
    email = address()
    {:ok, token} = Unsubscribes.issue(@user_id, "welcome", email)
    %{email: email, token: token, path: "/unsubscribe/#{token}"}
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "the one-click POST" do
    test "unsubscribes with no session, no header and no body", %{conn: conn, path: path} do
      # RFC 8058 §3.1: the request "MUST NOT include cookies, HTTP
      # authorization, or any other context information" — so this is the shape the
      # MUA is *forbidden* to deviate from, and the one every mail client sends.
      response = post(conn, path)

      assert response.status == 200
      assert body(response) == %{"data" => %{"status" => "unsubscribed"}}
    end

    test "and the body RFC 8058 §8.1 sends reaches the same answer", %{
      conn: conn,
      path: path,
      token: token
    } do
      # The RFC's own worked example, verbatim: urlencoded, with the key/value
      # pair as the body. §3.2 also says "Since there is no provision for extra
      # POST arguments, any information about the message or recipient is encoded
      # in the URI" — so courier reads none of it, and this proves it reads none
      # of it rather than merely not requiring it.
      response =
        send_request(
          conn,
          :post,
          path,
          "List-Unsubscribe=One-Click",
          "application/x-www-form-urlencoded"
        )

      assert response.status == 200
      assert body(response) == %{"data" => %{"status" => "unsubscribed"}}
      assert Suppressions.unsubscribed?(address_for(token), "welcome")
    end

    test "and a multipart body reaches it too", %{conn: conn, path: path} do
      # §3.2 gives `multipart/form-data` as the SHOULD and urlencoded as the MAY,
      # so the endpoint has to survive the one browsers send.
      boundary = "----courierunsubscribe"

      payload =
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"List-Unsubscribe\"\r\n\r\nOne-Click\r\n--#{boundary}--\r\n"

      response =
        send_request(
          conn,
          :post,
          path,
          payload,
          "multipart/form-data; boundary=#{boundary}"
        )

      assert response.status == 200
    end

    test "and it records the answer, and announces it", %{conn: conn, path: path, email: email} do
      assert post(conn, path).status == 200

      assert [%Suppression{} = row] = Repo.all(Suppression)
      assert row.email == email
      assert row.notification_type == "welcome"
      assert row.state == nil

      assert [event] =
               Repo.all(
                 from event in OutboxEvent, where: event.type == "courier.notification.suppressed"
               )

      assert event.subject == @user_id
      assert event.data["notification_type"] == "welcome"
    end

    test "and a second POST is the same answer, and writes nothing more", %{
      conn: conn,
      path: path
    } do
      email = address_for(path)

      first = post(conn, path)
      second = post(build_conn(), path)

      # Byte for byte, not merely the same status: a mail client that retried must
      # not be able to tell a retry from a first attempt, and a body that said
      # "already_unsubscribed" would be a body a client has to understand.
      assert body(first) == body(second)
      assert second.status == 200

      # Scoped, never counted over the table: `email_suppressions` and
      # `outbox_events` are shared by every test in this repository, and a whole-
      # table count is a claim about all of them.
      assert 1 ==
               Repo.one(from s in Suppression, where: s.email == ^email, select: count(s.id))

      assert 1 ==
               Repo.one(
                 from event in OutboxEvent,
                   where: event.subject == @user_id,
                   select: count(event.id)
               )
    end

    test "and it acts on the token in the PATH, whatever the body names", %{
      conn: conn,
      path: path,
      email: email
    } do
      # The whole authority of this route is the path segment, and
      # `Plug.Parsers` merges the body into `conn.params` — so a body naming its
      # own `token` is a way to act on a mailbox the URL did not.
      other = address()
      {:ok, other_token} = Unsubscribes.issue(@user_id, "password_reset", other)

      response =
        send_request(
          conn,
          :post,
          path,
          Jason.encode!(%{"token" => other_token}),
          "application/json"
        )

      assert response.status == 200
      assert Suppressions.unsubscribed?(email, "welcome")
      refute Suppressions.unsubscribed?(other, "password_reset")
    end

    test "and it is not a redirect, which RFC 8058 §3.1 forbids", %{conn: conn, path: path} do
      # "The mail sender MUST NOT return an HTTPS redirect, since redirected
      # POST actions have historically not worked reliably, and many browsers have
      # turned redirected HTTP POSTs into GETs." A redirect is the one thing here
      # that would work for a browser and silently break the mail client that
      # matters, and its absence is not something a client would report.
      response = post(conn, path)

      assert response.status == 200
      assert Plug.Conn.get_resp_header(response, "location") == []
    end

    test "and no response quotes an address or a user", %{path: path, email: email} do
      # An unauthenticated surface: anything echoed back is available to whoever
      # found the URL, and the token is not a session. Both answers and both
      # refusals are checked, because the refusal is the one a forger can iterate on.
      for request <- [
            fn -> post(build_conn(), path) end,
            fn -> get(build_conn(), path) end,
            fn -> post(build_conn(), "/unsubscribe/#{UnsubscribeToken.generate()}") end
          ] do
        rendered =
          request.()
          |> then(&(&1.resp_body <> inspect(Plug.Conn.get_resp_header(&1, "location"))))

        refute rendered =~ email
        refute rendered =~ @user_id
        refute rendered =~ @account
      end
    end
  end

  describe "the GET fallback" do
    test "unsubscribes too, and answers the same body", %{conn: conn, path: path} do
      # RFC 8058 §3.2: the POST target is "the same as the one in the GET action
      # for a manual unsubscription", and some clients only ever follow a link.
      response = get(conn, path)

      assert response.status == 200
      assert body(response) == %{"data" => %{"status" => "unsubscribed"}}
      assert Suppressions.unsubscribed?(address_for(path), "welcome")
    end

    test "and it is JSON, because courier renders no HTML at all", %{conn: conn, path: path} do
      response = get(conn, path)

      assert response.status == 200
      assert ["application/json" <> _rest] = Plug.Conn.get_resp_header(response, "content-type")
    end

    test "and it takes no body, because the parser reads none on a GET", %{
      conn: conn,
      path: path
    } do
      # The shape of the document is asserted in `openapi.yaml` and checked in
      # `openapi_error_responses_test.exs`: the `GET` declares no 400, and this
      # is the request that makes that true rather than a claim about a parser.
      assert send_request(conn, :get, path, "{not json", "application/json").status == 200
    end
  end

  describe "a token courier did not issue" do
    test "is a 404 in courier's envelope, and says nothing about the token" do
      response = post(build_conn(), "/unsubscribe/#{UnsubscribeToken.generate()}")

      assert response.status == 404
      assert problem_json?(response)
      assert body(response)["code"] == "not_found"
      assert body(response)["type"] == "https://docs.anywaye.com/errors/not_found"

      assert body(response)["trace_id"] ==
               response |> Plug.Conn.get_resp_header("x-trace-id") |> List.first()

      refute Map.has_key?(body(response), "errors"),
             "core reserves errors[] for a 422, and a 404 that carries one tells a " <>
               "client to look for a field that is not about their request"
    end

    test "and a token that is not a token's shape is the SAME answer" do
      # One answer, so the endpoint is not an oracle that can be used to test
      # tokens. Anything that distinguishes "no such token" from "not a token" is
      # a distinction a forger can use.
      for garbage <- ["nope", "x", String.duplicate("z", 43), "a/b", "1"] do
        response = post(build_conn(), "/unsubscribe/#{garbage}")

        assert response.status == 404
        assert body(response)["code"] == "not_found"
      end
    end

    test "and it is a 404 rather than a 401, because the token is an address" do
      # Asserted here as well as in the document, because the temptation to reach
      # for 401 is exactly what would make this endpoint's refusals legible: a 401
      # says "your credential is not acceptable" and there is no credential here.
      response = post(build_conn(), "/unsubscribe/#{UnsubscribeToken.generate()}")

      refute response.status == 401
    end
  end

  describe "the rest of the envelope" do
    test "406 for a client that will not take JSON, on both verbs", %{path: path} do
      for verb <- [:get, :post] do
        response = status_refusing_json(verb, path)

        assert response == 406,
               "#{verb} /unsubscribe answered #{inspect(response)} to Accept: text/html. " <>
                 "`openapi.yaml` declares a 406 on both, and the declaration is " <>
                 "provoked against the endpoint rather than written down."
      end
    end

    test "400 for a body the parser cannot read, on the POST only", %{conn: conn, path: path} do
      response = send_request(conn, :post, path, "{not json", "application/json")

      assert response.status == 400
      assert problem_json?(response)
      assert body(response)["code"] == "bad_request"
    end

    test "503 when courier could not write the answer, and nothing was written" do
      # The row's address is one the changeset refuses — which is what a deployment
      # gets after an address rule tightens under a token minted years ago. The
      # transaction unwinds, so there is no answer without its announcement and no
      # announcement about an answer courier does not hold.
      insert_token_for("welcome", @unusable_email)

      response = post(build_conn(), "/unsubscribe/#{stale_token()}")

      assert response.status == 503
      assert problem_json?(response)
      assert body(response)["code"] == "unavailable"

      # Scoped to this user's own rows rather than counted over the table: a
      # `Repo.aggregate(T, :count) == 0` is a claim about every other test in the
      # repository as much as about this one, which is the shape REPORT-courier-15
      # documents.
      assert Repo.all(from s in Suppression, where: s.email == @unusable_email) == []
      assert Repo.all(from event in OutboxEvent, where: event.subject == @user_id) == []
    end
  end

  describe "what it does to the next send" do
    test "the unsubscribed type is refused, with its own code", %{
      conn: conn,
      path: path,
      email: email
    } do
      assert post(conn, path).status == 200

      response =
        authenticated()
        |> post(
          "/v1/messages",
          Jason.encode!(%{"type" => "welcome", "user_id" => @user_id, "to" => email})
        )

      assert response.status == 422
      assert body(response)["code"] == "validation_failed"
      assert [%{"field" => "type", "code" => "unsubscribed"}] = body(response)["errors"]
    end

    test "and a different type still goes out, which is the whole point", %{
      conn: conn,
      path: path,
      email: email
    } do
      assert post(conn, path).status == 200

      for {type, extra} <- [
            {"password_reset", %{"url" => "https://anywaye.test/reset"}},
            {"team_invitation",
             %{
               "url" => "https://anywaye.test/join",
               "account_name" => "Acme",
               "invited_by" => "Kaka"
             }}
          ] do
        response =
          authenticated()
          |> post(
            "/v1/messages",
            Jason.encode!(
              Map.merge(%{"type" => type, "user_id" => @user_id, "to" => email}, extra)
            )
          )

        assert response.status == 200,
               "a one-click unsubscribe for welcome stopped a #{type}, and a person who " <>
                 "unsubscribed from one kind of mail must still get the mail they " <>
                 "asked for"
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  # A connection courier will authenticate: the header
  # `Courier.TestSupport.HeaderResolver` reads, named through the plug's own
  # accessor so a rename of it cannot leave this test sending a header nothing
  # looks at. The content type is set here rather than per call because
  # `Phoenix.ConnTest` refuses a binary body without one, and every request in
  # this file that has a body is JSON.
  defp authenticated do
    build_conn()
    |> Plug.Conn.put_req_header(CourierWeb.Plugs.Principal.account_header(), @account)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  # `Phoenix.NotAcceptableError` is raised by the `:accepts` plug and carries no
  # conn, so the response RenderErrors would send never reaches a caller — the
  # status is read off the exception's own `plug_status`, which is Phoenix
  # stating what it is about to answer. The same reading is in
  # `CourierWeb.OpenAPIErrorResponsesTest` and it is the only place a 406 is
  # visible at all.
  defp status_refusing_json(verb, path) do
    build_conn()
    |> Plug.Conn.put_req_header("accept", "text/html")
    |> send_request(verb, path, nil, "application/json")
  rescue
    error in Phoenix.NotAcceptableError -> error.plug_status
  end

  # `Phoenix.ConnTest` has no helper for a body with a content type, and the two
  # requests that matter here (RFC 8058's urlencoded example and the
  # parameter-injection attempt) both need one.
  defp send_request(conn, verb, path, body, content_type, opts \\ []) do
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", content_type)
      |> then(fn conn ->
        case Keyword.get(opts, :accept) do
          nil -> conn
          accept -> Plug.Conn.put_req_header(conn, "accept", accept)
        end
      end)

    case body do
      nil -> Phoenix.ConnTest.dispatch(conn, CourierWeb.Endpoint, verb, path, nil)
      bytes -> Phoenix.ConnTest.dispatch(conn, CourierWeb.Endpoint, verb, path, bytes)
    end
  end

  defp problem_json?(conn) do
    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()

    is_binary(content_type) and String.starts_with?(content_type, "application/problem+json")
  end

  # The address a token was minted for, read back out of the row rather than
  # carried beside the token — so an assertion about "the address this token
  # unsubscribed" cannot pass by agreeing with a local variable.
  defp address_for(token_or_path) do
    token = token_or_path |> to_string() |> String.split("/") |> List.last()
    {:ok, %UnsubscribeToken{email: email}} = Unsubscribes.find(token)
    email
  end

  defp stale_id, do: "3f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp stale_token, do: "stale" <> String.duplicate("0", 38)

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
end
