defmodule CourierWeb.Plugs.ParseBodyTest do
  @moduledoc """
  The one thing this plug does that it did not used to, and the whole reason the
  inbound surface can exist.


  **An unauthenticated body reaches no decoder.** `Courier.Inbound.Signature`
  refuses anything but the bytes that arrived, and spec §Signature scheme names
  parse-then-re-serialize as "a very common failure mode" of verification — so
  that refusal is only the right refusal if nothing upstream has already decoded
  the body and written a different one.

  `CourierWeb.Plugs.ParseBody` is an **endpoint** plug, not a router one. It runs
  on every request courier serves, including `POST /inbound/resend`, and
  `Plug.Parsers` with the `:json` parser would decode the body of a request whose
  signature has not been checked. The route's own tests assert the consequence
  behaviourally — an unsigned but well-formed bounce records nothing — and this
  file asserts the mechanism, because a behavioural test cannot tell "the parser
  did not run" from "the parser ran and the controller ignored the result".


  Because its subject is two functions and a conn. `Plug.Parsers` reads bytes
  and `CourierWeb.Router.signed_body?/1` matches a string, and neither of those
  is a thing postgres can lie about. The rows are the *route's* subject and they
  are asserted in `CourierWeb.InboundControllerTest`.


  A skip that leaked onto another route would be a body courier stopped parsing
  on a path whose controller expects `conn.params` — a 500 on `POST /v1/messages`
  for every send, in production, with nothing in the failure naming the plug. So
  the last two tests here are the negative half: the skip is for `resend` and
  nothing else, and the other five operations still parse.
  """

  use ExUnit.Case, async: true

  import Plug.Conn

  alias CourierWeb.Plugs.ParseBody
  alias CourierWeb.Router

  @options [
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  ]

  @signed "/inbound/resend"
  @parsed "/v1/messages"

  defp request(path, body) do
    Plug.Test.conn(:post, path, body)
    |> put_req_header("content-type", "application/json")
  end

  defp parse(conn), do: ParseBody.call(conn, ParseBody.init(@options))

  defp call(path, body) do
    path |> request(body) |> parse()
  end

  defp bytes(conn) do
    {:ok, body, _conn} = read_body(conn)
    body
  end

  describe "a signed inbound body" do
    test "is left exactly as it arrived" do
      body = ~s({"type":"email.bounced","created_at":"2026-11-22T23:41:12.126Z","data":{}})

      assert call(@signed, body) |> bytes() == body
    end

    test "is not decoded, so there are no body_params for a controller to trust" do
      conn = call(@signed, ~s({"type":"email.bounced"}))

      assert %Plug.Conn.Unfetched{} = conn.body_params
      assert %Plug.Conn.Unfetched{} = conn.params
    end

    test "a malformed one is not answered 400 here either" do
      conn = call(@signed, "{not json")

      refute conn.halted
      assert %Plug.Conn.Unfetched{} = conn.body_params
      assert bytes(conn) == "{not json"
      assert conn.status == nil
    end

    test "and it is not halted, so the action runs" do
      conn = call(@signed, "{}")

      refute conn.halted
    end

    test "the trailing slash spelling is skipped too" do
      assert Router.signed_body?("/inbound/resend/")
      assert "/inbound/resend/" |> request("{}") |> parse() |> bytes() == "{}"
    end
  end

  describe "every other route" do
    test "is still parsed" do
      conn = call(@parsed, ~s({"type":"welcome"}))

      assert conn.body_params == %{"type" => "welcome"}
    end

    test "and a malformed body on it is still courier's 400" do
      conn = call(@parsed, "{not json")

      assert conn.halted
      assert conn.status == 400
      assert [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/problem+json")
    end
  end

  describe "the path list" do
    test "names only routes the router serves" do
      for path <- Router.signed_body_paths() do
        assert Enum.any?(Router.__routes__(), &(&1.path == path and &1.verb == :post)),
               "#{path} is in `signed_body_paths/0` and no POST route serves it. A " <>
                 "rename left the list behind, and this is the check that makes a rename " <>
                 "visible rather than a 401 with nothing naming the plug."
      end
    end

    test "and the inbound route is in it" do
      assert @signed in Router.signed_body_paths()
    end

    test "a path that is not one is not skipped" do
      refute Router.signed_body?("/v1/messages")
      refute Router.signed_body?("/healthz")
      refute Router.signed_body?("/inbound/resendx")
      refute Router.signed_body?("/")
      refute Router.signed_body?(nil)
    end
  end
end
