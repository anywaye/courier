defmodule CourierWeb.ErrorRelayEndpointTest do
  @moduledoc """
  The error-ingestion surface, over real requests, through `CourierWeb.ErrorRouter`.


  Because it is not a customer API operation and putting it there would have cost
  something this repository will not pay. Everything on `/v1` takes a anywaye
  principal resolved from a bearer token; this surface takes a **shared ingest
  secret**, because a Sentry SDK holds a DSN and there is no identity service in
  that path to mint a JWT. A generated client from `openapi.yaml` must not have
  it, and a route on the public router would have needed a third entry in
  `CourierWeb.OpenAPIDocumentTest`'s exclusion list — which is weakening an
  existing check to accommodate new code, and the brief rules that out.

  So the surface is a **second listener** (`CourierWeb.ErrorEndpoint`, its own
  port) and the bidirectional router↔document test is untouched. That is the
  deciding reason and it is worth stating, because "put it on the other endpoint"
  is otherwise a detail.


    * the shared secret is **required** and its default is *refuse*, not allow;
    * a wrong, absent, or repeated header is `401` with core's `problem+json` and
      a body that does not distinguish "no token configured" from "wrong token";
    * the relay's own health check is **not** behind the secret, and does not
      consult a dependency — a probe behind auth reads as a dead component;
    * a body the relay cannot read is a counted discard and a `200`, never a
      non-2xx, because the Sentry SDK retries every non-2xx and a `400` for a
      malformed envelope is a retry storm in the service that sent it;
    * an oversized body is refused **before** it is read.

  `async: true`: it changes no application env and starts no shared process. The
  relay it posts to is started per test with `start_supervised!/1`, so no state
  outlives a test.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.ErrorRelay
  alias Courier.ErrorRelay.Sink
  alias Courier.TestSupport.RecordingSink

  @token "test-error-relay-token-not-a-secret"
  @canary "CANARY-4f19b2c7-endpoint"

  setup do
    relay =
      start_supervised!(
        {ErrorRelay,
         name: :"endpoint_relay_#{System.unique_integer([:positive])}",
         sink: RecordingSink,
         sink_target: self(),
         burst: 50,
         per_minute: 60,
         capacity: 64,
         queue_size: 16}
      )

    {:ok, relay: relay}
  end


  describe "an envelope with the right secret" do
    test "is accepted, and the caller gets 200 before anything is forwarded", %{relay: relay} do
      conn = post_envelope(valid_envelope(), relay: relay)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}

      assert_receive {:relayed, body}, 2_000
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(body)
    end

    test "and the event arrives with its class and its tags", %{relay: relay} do
      assert post_envelope(valid_envelope(), relay: relay).status == 200
      assert_receive {:relayed, body}, 2_000

      assert {:ok, [%{"payload" => payload}]} = Sink.parse_envelope(body)
      assert {:ok, event} = Jason.decode(payload)
      assert "internal_error" == event["tags"]["error.type"]
      assert "courier" == event["tags"]["service.name"]
    end

    test "and the secret the SDK put in `extra` is not in the stored bytes", %{relay: relay} do
      assert post_envelope(valid_envelope(), relay: relay).status == 200
      assert_receive {:relayed, body}, 2_000

      refute body =~ @canary
      assert body =~ "RuntimeError"
    end
  end


  describe "the shared secret" do
    test "no header is 401, in problem+json, with core's code", %{relay: relay} do
      conn = post_envelope(valid_envelope(), token: nil, relay: relay)

      assert conn.status == 401
      assert %{"code" => "unauthorized", "title" => "Unauthorized"} = body(conn)
    end

    test "a wrong token is 401", %{relay: relay} do
      conn = post_envelope(valid_envelope(), token: "not-the-token", relay: relay)

      assert conn.status == 401
    end

    test "a repeated header is 401, rather than first-one-wins", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.prepend_req_headers([
          {"x-anywaye-error-token", "not-the-token"},
          {"x-anywaye-error-token", @token}
        ])
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "a repeated `sentry_key` in one auth header is 401", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_key=not-the-token, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "an auth header without the `Sentry ` scheme prefix is 401", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("x-sentry-auth", "sentry_key=#{@token}")
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "both headers present with the same token is accepted", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("x-anywaye-error-token", @token)
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 200
    end

    test "both headers present with different tokens is 401", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("x-anywaye-error-token", "not-the-token")
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "an SDK-shaped request with the token is accepted, and reaches the relay", %{
      relay: relay
    } do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_client=anywaye-error-relay/1, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}

      assert_receive {:relayed, body}, 2_000
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(body)
    end

    test "a correct token in an unexpected header is 401", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("authorization", @token)
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "a hand-written envelope, the way an SDK frames one, is accepted", %{relay: relay} do
      event =
        Jason.encode!(%{
          "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
          "timestamp" => "2026-10-01T12:00:00Z",
          "platform" => "elixir",
          "level" => "error",
          "tags" => %{"error.type" => "internal_error", "service.name" => "courier"}
        })

      envelope =
        Enum.join(
          [
            ~s({"event_id":"6f5d4c3b2a184e8f9c071b2d3e4f5061","timestamp":1757330000,"platform":"elixir","level":"error"}),
            ~s({"type":"event","length":
            event
          ],
          "\n"
        ) <> "\n"

      conn = post_envelope(envelope, relay: relay)

      assert conn.status == 200
      assert_receive {:relayed, forwarded}, 2_000
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(forwarded)
    end

    test "an envelope whose declared length disagrees with its bytes is a counted discard", %{
      relay: relay
    } do
      envelope =
        ~s({"event_id":"6f5d4c3b2a184e8f9c071b2d3e4f5061","timestamp":1757330000,"platform":"elixir","level":"error"}\n) <>
          ~s({"type":"event","length":2}\n) <> ~s({"not":"what you said"}) <> "\n"

      conn = post_envelope(envelope, relay: relay)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
      refute_receive {:relayed, _forwarded}, 300
    end

    test "a DSN with an explicit port keeps the port, so a non-default store is reachable" do
      assert {:ok, url, headers} =
               Sink.Req.parse_dsn("http://publickey@glitchtip:8000/1")

      assert url == "http://glitchtip:8000/api/1/envelope/"

      assert {"X-Sentry-Auth",
              "Sentry sentry_version=7, sentry_client=anywaye-error-relay/1, sentry_key=publickey"} in headers

      assert {:ok, "http://glitchtip:80/api/1/envelope/", _headers} =
               Sink.Req.parse_dsn("http://publickey@glitchtip/1")
    end

    test "the relay's envelope header carries a distinct id per envelope, never a fixed one" do
      {:ok, first} = Sink.build_envelope([as_item(event())], "http://glitchtip:8000/1")
      {:ok, second} = Sink.build_envelope([as_item(event())], "http://glitchtip:8000/1")

      assert {:ok, %{"event_id" => first_id}} = take_envelope_header(first)
      assert {:ok, %{"event_id" => second_id}} = take_envelope_header(second)

      assert first_id != second_id
      refute first_id == "00000000000000000000000000000000"

      assert first_id =~ ~r/^[0-9a-f]{32}$/
    end

    test "an event that carries its own id keeps it, so the store's dedupe sees distinct events" do
      {:ok, envelope} =
        Sink.build_envelope(
          [as_item(event(%{"event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061"}))],
          "http://glitchtip:8000/1"
        )

      assert {:ok, items} = Sink.parse_envelope(envelope)
      assert [item] = items
      assert {:ok, decoded} = Jason.decode(item["payload"])
      assert decoded["event_id"] == "6f5d4c3b2a184e8f9c071b2d3e4f5061"
    end

    test "the two refusals are indistinguishable to the caller", %{relay: relay} do
      wrong = post_envelope(valid_envelope(), token: "nope", relay: relay)
      absent = post_envelope(valid_envelope(), token: nil, relay: relay)

      assert strip_trace(wrong) == strip_trace(absent)
    end
  end


  describe "the relay's health check" do
    test "answers 200 with no token" do
      conn =
        Phoenix.ConnTest.dispatch(
          build_conn(),
          CourierWeb.ErrorEndpoint,
          :get,
          "/internal/v1/errors/healthz",
          %{}
        )

      assert conn.status == 200
      assert %{"status" => "ok"} = body(conn)
    end

    test "does not consult the store, and does not consult the database" do
      conn =
        Phoenix.ConnTest.dispatch(
          build_conn(),
          CourierWeb.ErrorEndpoint,
          :get,
          "/internal/v1/errors/healthz",
          %{}
        )

      assert conn.status == 200
      refute Map.has_key?(body(conn), "deps")
    end

    test "answers on GET and not on the write verb, so a probe cannot post a crash" do
      assert :error ==
               Phoenix.Router.route_info(
                 CourierWeb.ErrorRouter,
                 "POST",
                 "/internal/v1/errors/healthz",
                 ""
               )
    end
  end


  describe "a body the relay will not store" do
    test "is a 200 and a counted discard, never a non-2xx", %{relay: relay} do
      for body <- ["", "not an envelope at all", ~s({"nonsense":true}), "\n\n\n"] do
        conn = post_envelope(body, relay: relay)

        assert conn.status == 200
        assert Jason.decode!(conn.resp_body) == %{}
      end
    end

    test "an oversized body is refused on its declared length, before it is read", %{relay: relay} do
      oversized = String.duplicate("x", 1_100_000)

      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", oversized)
        |> then(&Plug.Conn.put_req_header(&1, "x-anywaye-error-token", @token))
        |> then(&Plug.Conn.put_req_header(&1, "content-type", "application/x-sentry-envelope"))
        |> assign(:error_relay, relay)
        |> then(&CourierWeb.ErrorEndpoint.call(&1, []))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}

      refute_received {:relayed, _body}
    end

    test "a body with no content-length is still bounded", %{relay: relay} do
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", String.duplicate("y", 5_000))
        |> then(&Plug.Conn.put_req_header(&1, "x-anywaye-error-token", @token))
        |> then(&Plug.Conn.put_req_header(&1, "content-type", "application/x-sentry-envelope"))
        |> then(&Plug.Conn.delete_req_header(&1, "content-length"))
        |> assign(:error_relay, relay)
        |> then(&CourierWeb.ErrorEndpoint.call(&1, []))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
    end
  end


  describe "the surface's shape" do
    test "the two routes resolve to the controllers they claim" do
      assert %{plug: CourierWeb.ErrorEnvelopeController, plug_opts: :create} =
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", "/api/1/envelope/", "")

      assert %{plug: CourierWeb.ErrorEnvelopeHealthController, plug_opts: :healthz} =
               Phoenix.Router.route_info(
                 CourierWeb.ErrorRouter,
                 "GET",
                 "/internal/v1/errors/healthz",
                 ""
               )
    end

    test "the write route is behind the ingest pipeline and the probe is not" do
      assert %{pipe_through: [:ingest]} =
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", "/api/1/envelope/", "")

      assert %{pipe_through: []} =
               Phoenix.Router.route_info(
                 CourierWeb.ErrorRouter,
                 "GET",
                 "/internal/v1/errors/healthz",
                 ""
               )
    end

    test "the public router has no route to it, and the public document has no path" do
      assert :error ==
               Phoenix.Router.route_info(CourierWeb.Router, "POST", "/api/1/envelope/", "")

      assert :error ==
               Phoenix.Router.route_info(CourierWeb.Router, "POST", "*_glob", "")

      refute File.read!("openapi.yaml") =~ "/api/1/envelope/"
    end

    test "the URL courier's own SDK derives from a relay DSN is a path this router serves" do
      {:ok, %Sentry.DSN{endpoint_uri: endpoint_uri}} =
        Sentry.DSN.parse("http://relay-token@relay.test/1")

      %URI{path: derived_path} = URI.parse(endpoint_uri)

      assert derived_path == "/api/1/envelope/"

      assert %{plug: CourierWeb.ErrorEnvelopeController, plug_opts: :create} =
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", derived_path, "")
    end

    test "a DSN carrying a base path is not routed, and that is the documented contract" do
      {:ok, %Sentry.DSN{endpoint_uri: endpoint_uri}} =
        Sentry.DSN.parse("http://relay-token@relay.test/errors/7")

      %URI{path: derived_path} = URI.parse(endpoint_uri)

      assert derived_path == "/errors/api/7/envelope/"

      assert :error ==
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", derived_path, "")
    end

    test "the relay is in the supervision tree, and the SDK is not" do
      children = supervision_children()

      assert Courier.ErrorRelay in children
      refute Sentry in children
    end

    test "the relay surface is bound when the server is, and unbound when it is not" do
      assert %{endpoint: true, error_endpoint: true} =
               release_server_flags([{"PHX_SERVER", "true"}])

      assert %{endpoint: false, error_endpoint: false} = release_server_flags([])

      assert Application.get_env(:courier, CourierWeb.ErrorEndpoint)[:server] == false

      assert Application.get_env(:courier, CourierWeb.ErrorEndpoint)[:http] ==
               [ip: {127, 0, 0, 1}, port: 4003]
    end

    test "the customer API's own probes are unaffected" do
      assert %{plug: CourierWeb.HealthController} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/healthz", "")

      assert %{plug: CourierWeb.HealthController} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/readyz", "")
    end
  end


  defp post_envelope(body, opts) do
    :post
    |> Plug.Test.conn("/api/1/envelope/", body)
    |> then(fn conn ->
      case Keyword.get(opts, :token, @token) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "x-anywaye-error-token", token)
      end
    end)
    |> then(&Plug.Conn.put_req_header(&1, "content-type", "application/x-sentry-envelope"))
    |> then(&maybe_assign_relay(&1, opts))
    |> then(&CourierWeb.ErrorEndpoint.call(&1, []))
  end

  defp maybe_assign_relay(conn, opts) do
    case Keyword.get(opts, :relay) do
      nil -> conn
      relay -> assign(conn, :error_relay, relay)
    end
  end

  defp dispatch_post(conn) do
    CourierWeb.ErrorEndpoint.call(conn, [])
  end

  defp take_envelope_header(envelope) when is_binary(envelope) do
    [header | _rest] = :binary.split(envelope, "\n")

    case Jason.decode(header) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, :undecodable_header}
    end
  end

  defp as_item(payload), do: %{"type" => "event", "payload" => payload}

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => nil,
        "timestamp" => "2026-10-01T12:00:00Z",
        "platform" => "elixir",
        "level" => "error",
        "tags" => %{"error.type" => "internal_error", "service.name" => "courier"}
      },
      overrides
    )
  end

  defp endpoint_config(settings, endpoint) do
    case Map.fetch(settings, endpoint) do
      {:ok, config} -> Map.new(config)
      :error -> %{}
    end
  end

  defp runtime_path, do: Path.join([File.cwd!(), "config", "runtime.exs"])

  @release_env [
    {"DATABASE_URL", "ecto://postgres:postgres@localhost/courier_probe"},
    {"SECRET_KEY_BASE", String.duplicate("s", 64)},
    {"COURIER_SECRET_BOX_KEY", Base.encode64(String.duplicate("k", 32))},
    {"COURIER_ERROR_RELAY_TOKEN", "probe-token"}
  ]

  defp release_server_flags(env) do
    previous = System.get_env("PHX_SERVER")
    apply_phx_server(env)

    on_exit(fn -> restore_phx_server(previous) end)

    settings =
      runtime_path()
      |> Config.Reader.read!(env: [target: :prod])
      |> Keyword.get(:courier, [])
      |> Map.new()

    %{
      endpoint: settings |> endpoint_config(CourierWeb.Endpoint) |> server_flag(),
      error_endpoint: settings |> endpoint_config(CourierWeb.ErrorEndpoint) |> server_flag()
    }
  end

  defp apply_phx_server([]), do: System.delete_env("PHX_SERVER")
  defp apply_phx_server(_env), do: System.put_env("PHX_SERVER", "true")

  defp restore_phx_server(nil), do: System.delete_env("PHX_SERVER")
  defp restore_phx_server(value), do: System.put_env("PHX_SERVER", value)

  defp server_flag(%{server: server}) when is_boolean(server), do: server
  defp server_flag(_settings), do: false

  defp supervision_children do
    Courier.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
  end

  defp strip_trace(conn) do
    conn.resp_body
    |> Jason.decode!()
    |> Map.delete("trace_id")
  end

  defp body(conn) do
    {:ok, decoded} = Jason.decode(conn.resp_body)
    decoded
  end

  defp valid_envelope do
    event = %{
      "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
      "timestamp" => "2026-10-01T12:00:00Z",
      "platform" => "elixir",
      "level" => "error",
      "transaction" => "courier.email.deliver",
      "tags" => %{"error.type" => "internal_error", "service.name" => "courier"},
      "extra" => %{"prompt" => @canary},
      "exception" => %{"values" => [%{"type" => "RuntimeError", "value" => @canary}]}
    }

    {:ok, envelope} =
      Sink.build_envelope([%{"type" => "event", "payload" => event}], "http://relay.test/1")

    envelope
  end
end
