defmodule Courier.Principal.IntrospectionTest do
  @moduledoc """
  The resolver: courier's door, and the key it turns.

  Everything asserted here is about the seam between an inbound request and
  identity's answer, and it is asserted over the whole `resolve/1` rather than
  over a stubbed private function — a resolver whose parts are right and whose
  composition is wrong authenticates nobody, and that failure looks exactly like
  a misconfigured identity.

  ## The transport is a double, and that is a deliberate boundary

  `Courier.Principal.Introspection.Transport` is the seam and
  `Courier.TestSupport.IntrospectionTransport` answers from a table a test
  writes. So nothing here opens a socket, and the suite's no-network rule holds.
  The transport that actually opens one is `Transport.Req`, and it is exercised
  against Req's own plug adapter in
  `test/courier/principal/introspection/transport_req_test.exs` — because a seam
  that is only ever tested from one side is a seam nobody checked.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Courier.Principal
  alias Courier.Principal.Introspection
  alias Courier.TestSupport.IntrospectionTransport

  @account "ab000000-0000-0000-0000-0000000000c1"
  @other_account "ab000000-0000-0000-0000-0000000000c2"
  @caller_token "anywaye_caller-token-for-the-suite"

  # The credential courier presents to ask about the caller's. A fixture and
  # never a default, on the same terms as `COURIER_SECRET_BOX_KEY` in
  # `config/test.exs`: `config/runtime.exs` requires a real one from the
  # environment and refuses to boot without it.
  @service_token "anywaye_couriers-own-service-credential"

  defp conn(token, headers \\ []) do
    Enum.reduce(headers, Plug.Test.conn(:get, "/v1/webhook_endpoints"), fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
    |> then(fn c ->
      if token, do: Plug.Conn.put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
  end

  defp live(overrides \\ %{}) do
    Map.merge(
      %{
        "active" => true,
        "sub" => "ab000000-0000-0000-0000-000000000001",
        "account_id" => @account,
        "scopes" => "accounts:read",
        "scope" => "accounts:read",
        "jti" => "ab000000-0000-0000-0000-0000000000a1"
      },
      overrides
    )
  end

  describe "a live token" do
    test "authenticates, on the account the answer names" do
      IntrospectionTransport.stub(200, live())

      assert {:ok, %Principal{account_id: @account} = principal} =
               Introspection.resolve(conn(@caller_token))

      assert principal.account_id == @account
    end

    test "and the scopes travel with it, from either claim name" do
      # Parsed and carried, deliberately not enforced — see `Courier.Principal`'s
      # moduledoc for why enforcing them today would refuse every credential
      # identity can mint. The assertion here is that the set is populated from
      # both names, so the day the check lands it is reading something.
      IntrospectionTransport.stub(200, live(%{"scopes" => "a:read", "scope" => "a:read"}))

      assert {:ok, %Principal{scopes: ["a:read"]}} = Introspection.resolve(conn(@caller_token))
    end

    test "and asks identity about the token it was given, not about anything else" do
      IntrospectionTransport.stub(200, live())

      assert {:ok, _principal} = Introspection.resolve(conn(@caller_token))

      assert [%{body: body}] = IntrospectionTransport.requests()
      assert Jason.decode!(body) == %{"token" => @caller_token}
    end

    test "and reaches identity at the documented path with its own credential" do
      IntrospectionTransport.stub(200, live())

      assert {:ok, _principal} = Introspection.resolve(conn(@caller_token))

      assert [request] = IntrospectionTransport.requests()
      assert request.method == "POST"
      assert request.url == "#{Introspection.url()}/v1/introspections"

      # courier's OWN credential, in the header, and the caller's only in the
      # body. Reversed, this is an endpoint where a customer's token is the thing
      # authenticating courier.
      assert {"authorization", "Bearer " <> @service_token} in request.headers
      assert {"authorization", "Bearer " <> @caller_token} not in request.headers
    end
  end

  describe "an unusable token is a 401-shaped refusal, and one of them" do
    test "`{\"active\": false}` is a refusal and nothing else" do
      IntrospectionTransport.stub(200, %{"active" => false})

      assert Introspection.resolve(conn(@caller_token)) == :error
    end

    test "the four reasons a token cannot be used are indistinguishable to courier" do
      # identity collapses them upstream on purpose. This asserts courier does not
      # re-expand them: a caller who can tell "revoked" from "never existed"
      # learns whether a leaked value is live, which is the second question an
      # attacker asks after "does this work".
      for body <- [
            %{"active" => false},
            Map.put(live(), "active", false),
            %{"active" => false, "exp" => 1_788_168_000},
            %{"active" => false, "sub" => "ab000000-0000-0000-0000-000000000001"}
          ] do
        IntrospectionTransport.stub(200, body)

        assert Introspection.resolve(conn(@caller_token)) == :error,
               "one of the four inactive cases produced a different answer"
      end
    end

    test "a token with no `account_id` is refused, and `sub` is never used instead" do
      no_account = live() |> Map.delete("account_id")

      IntrospectionTransport.stub(200, no_account)

      assert Introspection.resolve(conn(@caller_token)) == :error,
             "a document with `sub` and no `account_id` was accepted. `sub` is a " <>
               "USER; a tenancy key read from it turns a bug in one service into a " <>
               "cross-tenant read"
    end
  end

  describe "no credential, no call" do
    test "a request with no `Authorization` header is refused without asking identity" do
      # Not an optimisation. An unauthenticated endpoint that dials a dependency
      # per request is an unauthenticated load generator pointed at identity by
      # anybody who finds courier's URL — and it is the 401 that costs nothing.
      assert Introspection.resolve(conn(nil)) == :error

      assert IntrospectionTransport.requests() == []
    end

    test "and the same for a header that is not a bearer" do
      for header <- ["", "Bearer", "Bearer ", "Basic YWRtaW46YWRtaW4=", @caller_token] do
        c =
          Plug.Test.conn(:get, "/v1/webhook_endpoints")
          |> Plug.Conn.put_req_header("authorization", header)

        assert Introspection.resolve(c) == :error,
               "#{inspect(header)} was not refused without a call to identity"
      end

      assert IntrospectionTransport.requests() == []
    end

    test "the test-only account header does not authenticate anybody here" do
      # `x-courier-account` is `Courier.TestSupport.HeaderResolver`'s stand-in for
      # the verified claim. Asserting that this resolver ignores it is the
      # difference between "it is configured only in test" (a convention) and
      # "a request carrying it is refused" (a property) — and the property is what
      # stops somebody adding `x-courier-account` back as a fast path.
      IntrospectionTransport.stub(200, live())

      c =
        conn(@caller_token)
        |> Plug.Conn.put_req_header(CourierWeb.Plugs.Principal.account_header(), @other_account)

      assert {:ok, %Principal{account_id: @account}} = Introspection.resolve(c)

      assert Introspection.resolve(
               conn(nil, [{CourierWeb.Plugs.Principal.account_header(), @other_account}])
             ) == :error
    end
  end

  describe "identity unreachable, refusing or misbehaving is a closed door" do
    # Every one of these is the same answer, and the reason is the packet's: a
    # resolver that fails OPEN under load is worse than `Reject`, because it fails
    # silently. Nothing here is `:error`, because `:error` is a 401 and a 401
    # tells a caller with a good token that their token is the problem.
    test "a 5xx is `{:error, :unavailable}`, never a pass" do
      for status <- [500, 502, 503, 504] do
        IntrospectionTransport.stub(status, %{"error" => "boom"})

        assert capture_log(fn ->
                 assert Introspection.resolve(conn(@caller_token)) ==
                          {:error, :unavailable},
                        "identity answering #{status} was not a closed door"
               end) =~ "identity answered #{status}"
      end
    end

    test "identity's own 401 and 403 are courier's problem, so also a 503" do
      # The load-bearing correction. identity answers 401 when the CREDENTIAL
      # courier presented is not one it accepts, and 403 when that credential may
      # not ask about the token it named — both are facts about **courier**, not
      # about the caller. Reporting either as a 401 tells a customer to rotate a
      # token that was never the problem, and an operator reads a wall of "invalid
      # credentials" when the real fault is one environment variable.
      for status <- [401, 403, 404, 405, 422] do
        IntrospectionTransport.stub(status, %{"error" => "nope"})

        capture_log(fn ->
          assert Introspection.resolve(conn(@caller_token)) == {:error, :unavailable},
                 "identity answering #{status} was not a closed door"
        end)
      end
    end

    test "an unreachable identity is `{:error, :unavailable}`" do
      for reason <- [:econnrefused, :nxdomain, :timeout, :closed] do
        IntrospectionTransport.fail(reason)

        capture_log(fn ->
          assert Introspection.resolve(conn(@caller_token)) == {:error, :unavailable},
                 "#{inspect(reason)} was not a closed door"
        end)
      end
    end

    test "a body courier cannot read is `{:error, :unavailable}` rather than a 401" do
      # The whole reason `Document` has three answers. identity not answering in a
      # shape courier reads is courier's outage, and a 401 here is a lie that costs
      # a customer a credential rotation.
      #
      # Note what is NOT in this list: `{"active": true}` with no account is a
      # **401**, because that is a shape courier reads and the answer it reads is
      # "no account". Only the shapes it cannot read at all are here.
      for body <- [
            "",
            "not json",
            ~s({"active": "true"}),
            ~s([]),
            ~s({"active": true, "account_id": 42})
          ] do
        IntrospectionTransport.stub(200, body)

        capture_log(fn ->
          assert Introspection.resolve(conn(@caller_token)) == {:error, :unavailable},
                 "#{inspect(body)} was read as something courier could act on"
        end)
      end
    end

    test "and the reason is logged as a symbol, never as the token" do
      IntrospectionTransport.fail(:timeout)

      log = capture_log(fn -> Introspection.resolve(conn(@caller_token)) end)

      assert log =~ "identity"
      refute log =~ @caller_token
      refute log =~ @service_token
    end
  end

  describe "nothing here can put a token in a log" do
    test "a refused token and courier's own credential are both absent from the log" do
      # The assertion worth more than "it logged something": a boundary that
      # deletes everything passes that. So the pair is asserted together — the
      # failure line IS there, and neither secret is.
      IntrospectionTransport.stub(200, %{"active" => false})

      log = capture_log(fn -> Introspection.resolve(conn(@caller_token)) end)

      refute log =~ @caller_token
      refute log =~ @service_token
    end

    test "and a live token's document is not echoed either" do
      IntrospectionTransport.stub(200, live())

      log = capture_log(fn -> Introspection.resolve(conn(@caller_token)) end)

      refute log =~ @account
      refute log =~ @caller_token
    end
  end

  describe "the service credential courier presents" do
    test "is read from configuration, never from the request" do
      IntrospectionTransport.stub(200, live())

      # Two callers, two different service credentials would be a bug; the point
      # is that the header courier sends is the CONFIGURED one whatever the
      # caller sent, which is what makes a stolen `COURIER_IDENTITY_TOKEN` the only
      # thing an operator has to rotate.
      assert {:ok, _principal} = Introspection.resolve(conn(@caller_token))
      assert [%{headers: headers}] = IntrospectionTransport.requests()

      assert headers == [
               {"accept", "application/json"},
               {"content-type", "application/json"},
               {"authorization", "Bearer " <> @service_token}
             ]
    end
  end
end
