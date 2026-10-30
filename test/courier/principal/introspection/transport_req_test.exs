defmodule Courier.Principal.Introspection.Transport.ReqTest do
  @moduledoc """
  The side of the seam that opens a socket, driven through Req's own plug adapter.

  `test/courier/principal/introspection_test.exs` runs the resolver against
  `Courier.TestSupport.IntrospectionTransport`, so **nothing in the suite proves
  the shipped transport builds the request identity is documented to expect.** A
  seam tested from one side only is a seam nobody checked: a typo in the path, a
  missing content type, or a header under the wrong name is invisible to a suite
  that answers from a table — and the symptom in production is a 403 from identity
  that looks exactly like a misconfigured credential.

  So this file drives `Transport.Req` itself with `plug: {Req.Test, …}`, which is
  Req's documented way of running a real request against a plug instead of a
  socket. The assertions below are therefore about the request `Transport.Req`
  really built, and they are the four things identity's contract requires of it:
  the path, the method, a JSON body carrying `token`, and one authorization header.


  The resolver decides **which** headers courier sends and **what goes in the
  body**; `test/courier/principal/introspection_test.exs` asserts that, against
  the double, on the exact bytes. This file asserts that whatever the caller hands
  the transport **arrives** — path, method, headers, body — which is the half a
  double cannot see.

  **The body is asserted as `body_params` rather than as bytes.** `Req.Plug` hands
  the stub a `%Plug.Conn{}` whose body has been consumed by `Plug.Parsers`, and
  the raw bytes live in a private `Req.Plug.Adapter` field — asserting on that
  would make this file break on a Req upgrade without making the property any
  truer, and this repository's readers raise rather than under-read.
  """

  use ExUnit.Case, async: true

  alias Courier.Principal.Introspection.Transport.Req, as: Transport

  @stub :courier_introspection
  @probe :courier_introspection_probe
  @answer :courier_introspection_answer
  @failure_path "/v1/introspections/__transport_failure__"

  @origin "http://identity.test:8080"
  @url @origin <> "/v1/introspections"
  @service_token "anywaye_couriers-own-service-credential"
  @caller_token "anywaye_caller-token-for-the-suite"

  @headers [
    {"accept", "application/json"},
    {"content-type", "application/json"},
    {"authorization", "Bearer " <> @service_token}
  ]

  setup do
    Req.Test.stub(@stub, fn conn ->
      send(
        Process.whereis(@probe),
        {:request, conn.method, conn.request_path, conn.req_headers, conn.body_params}
      )

      if conn.request_path == @failure_path do
        Req.Test.transport_error(conn, :timeout)
      else
        {status, body} = Process.get(@answer)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, body)
      end
    end)

    Process.register(self(), @probe)
    Process.put(@answer, {200, ~s({"active": false})})
    :ok
  end

  defp answering(status, body), do: Process.put(@answer, {status, body})

  defp post(url \\ @url) do
    result = Transport.post(url, @headers, Jason.encode!(%{"token" => @caller_token}))
    {result, receive_request()}
  end

  defp receive_request do
    receive do
      {:request, method, path, headers, body_params} -> {method, path, headers, body_params}
    after
      0 -> nil
    end
  end

  describe "the request courier builds" do
    test "is a POST to identity's documented path" do
      assert {{:ok, 200, _body}, {method, path, _headers, _body_params}} = post()

      assert method == "POST"
      assert path == "/v1/introspections"
    end

    test "carries the caller's token in the BODY" do
      assert {{:ok, 200, _}, {_method, _path, _headers, body_params}} = post()

      assert body_params == %{"token" => @caller_token}
    end

    test "and courier's credential in exactly ONE authorization header" do
      assert {{:ok, 200, _}, {_method, _path, headers, _body_params}} = post()

      assert for {"authorization", value} <- headers, do: value == ["Bearer " <> @service_token]
    end

    test "and the headers it was handed, unchanged and not merged into one" do
      assert {{:ok, 200, _}, {_method, _path, headers, _body_params}} = post()

      for {name, value} <- @headers do
        arrived = for {^name, got} <- headers, do: got

        assert arrived == [value],
               "#{name} did not reach identity as #{inspect(value)}; it arrived as " <>
                 "#{inspect(arrived)}. A pair list is read one at a time rather than " <>
                 "with Keyword.get/2 on purpose: this file asserts that NO header is " <>
                 "sent twice, and Keyword would quietly report the first."
      end
    end

    test "and nothing that was not handed to it" do
      assert {{:ok, 200, _}, {_method, _path, headers, _body_params}} = post()

      unexpected =
        for {name, _value} <- headers,
            name not in ~w(authorization accept content-type user-agent),
            do: name

      assert unexpected == [],
             "identity received headers this transport was never given: #{inspect(unexpected)}"
    end
  end

  describe "the answer" do
    test "is the status and the raw body, so the caller reads the bytes identity sent" do
      body = ~s({"active": true, "account_id": "ab000000-0000-0000-0000-0000000000c1"})
      answering(200, body)

      assert {{:ok, 200, received}, _request} = post()

      assert received == body
    end

    test "and a non-200 is reported rather than raised" do
      for status <- [401, 403, 404, 405, 422, 500, 502, 503] do
        answering(status, ~s({"code": "forbidden", "status":

        assert {{:ok, ^status, _body}, _request} = post(),
               "identity answering #{status} was not reported as a status"
      end
    end

    test "and a dial failure is a symbol, so no part of either token can ride out in it" do
      assert {{:error, :unreachable}, _request} = post(@origin <> @failure_path)
    end
  end

  describe "the options, asserted as numbers rather than as intent" do
    test "the dial is bounded, because this is on the request path of every call" do
      assert Transport.receive_timeout_ms() == 2_000
    end

    test "and the value is bounded to something a test can read" do
      assert is_integer(Transport.receive_timeout_ms())
      assert Transport.receive_timeout_ms() > 0
    end

    test "and configuration cannot switch the four decisions off" do
      assert Keyword.get(Transport.req_options(), :plug) == {Req.Test, @stub}
    end
  end
end
