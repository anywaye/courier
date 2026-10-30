defmodule CourierWeb.Plugs.PrincipalConfigTest do
  @moduledoc """
  The plug's two refusals, driven over real requests with the introspection
  resolver configured.


  `config :courier, :principal` is read per request by
  `CourierWeb.Plugs.Principal.resolver/0`, and the whole VM shares the application
  environment — so a test that swaps it is `async: false` and lives alone in a
  file named `*ConfigTest`, exactly as `ProcessOutboxWorkerConfigTest`,
  `WebhookEndpointsConfigTest` and `DeliverWebhookWorkerBudgetTest` do. The
  previous value is restored in `on_exit`.


  The other file proves courier's DECISION — `:ok`, `:error`,
  `{:error, :unavailable}`. This one proves the plug's three RESPONSES: a 401 that
  is byte for byte the 401 courier has always sent, a 503 in
  `CourierWeb.Problem`'s envelope carrying the media type, the `instance` and the
  `trace_id` a client correlates on, and a request that actually reaches a
  controller once identity says the token is live.
  """

  use CourierWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Courier.Principal.Introspection
  alias Courier.TestSupport.IntrospectionTransport
  alias Courier.TestSupport.OpenAPIPaths

  @account "ab000000-0000-0000-0000-0000000000c1"
  @other_account "ffffffff-ffff-ffff-ffff-ffffffffffff"
  @caller_token "anywaye_caller-token-for-the-suite"

  @document "openapi.yaml"

  setup do
    previous = Application.get_env(:courier, :principal)

    Application.put_env(:courier, :principal, Introspection)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:courier, :principal)
        value -> Application.put_env(:courier, :principal, value)
      end
    end)

    :ok
  end

  defp live(overrides \\ %{}) do
    IntrospectionTransport.stub(
      200,
      Map.merge(
        %{
          "active" => true,
          "sub" => "ab000000-0000-0000-0000-000000000001",
          "account_id" => @account,
          "scopes" => "accounts:read",
          "scope" => "accounts:read"
        },
        overrides
      )
    )
  end

  defp bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp problem_json?(conn) do
    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()

    is_binary(content_type) and String.starts_with?(content_type, "application/problem+json")
  end

  describe "a request the plug authenticates" do
    test "reaches the controller, on the account identity named" do
      live()

      conn =
        build_conn()
        |> bearer(@caller_token)
        |> Plug.Conn.put_req_header(CourierWeb.Plugs.Principal.account_header(), @other_account)
        |> get(~p"/v1/webhook_endpoints")

      assert conn.status in [200, 304],
             "an authenticated request did not reach the controller: #{conn.status} " <>
               "#{inspect(conn.resp_body)}"

      assert conn.assigns[:current_account] == @account,
             "the account came from #{inspect(conn.assigns[:current_account])} while the " <>
               "#{CourierWeb.Plugs.Principal.account_header()} header said #{@other_account}"
    end

    test "and assigns the whole principal, so a controller can read the subject" do
      live()

      conn =
        build_conn()
        |> bearer(@caller_token)
        |> get(~p"/v1/webhook_endpoints")

      assert conn.status in [200, 304]

      assert %Courier.Principal{
               account_id: @account,
               subject: "ab000000-0000-0000-0000-000000000001",
               scopes: ["accounts:read"]
             } = conn.assigns[:current_principal]
    end

    test "and `x-courier-account` alone authenticates nobody in this configuration" do
      IntrospectionTransport.stub(200, %{"active" => false})

      conn =
        build_conn()
        |> Plug.Conn.put_req_header(CourierWeb.Plugs.Principal.account_header(), @other_account)
        |> get(~p"/v1/webhook_endpoints")

      assert conn.status == 401

      assert IntrospectionTransport.requests() == [],
             "the test header sent a request to identity, so it is being read as a claim"
    end
  end

  describe "a request nobody is authenticated for" do
    test "is a 401, and it is the 401 courier has always sent" do
      IntrospectionTransport.stub(200, %{"active" => false})

      conn = build_conn() |> bearer(@caller_token) |> get(~p"/v1/webhook_endpoints")

      assert conn.status == 401
      assert problem_json?(conn)
      assert body(conn)["type"] == "https://docs.anywaye.com/errors/unauthorized"
      assert body(conn)["code"] == "unauthorized"
      assert body(conn)["title"] == "Unauthorized"
      assert body(conn)["status"] == 401
      assert body(conn)["detail"] == "This request needs an authenticated caller."
      refute Map.has_key?(body(conn), "errors")
    end

    test "with no credential at all, and without calling identity" do
      conn = get(build_conn(), ~p"/v1/webhook_endpoints")

      assert conn.status == 401
      assert IntrospectionTransport.requests() == []
    end

    test "and the plug's 401 is the SAME envelope the default resolver produces" do
      IntrospectionTransport.stub(200, %{"active" => false})
      through_identity = build_conn() |> bearer(@caller_token) |> get(~p"/v1/webhook_endpoints")

      Application.put_env(:courier, :principal, Courier.Principal.Reject)
      through_reject = build_conn() |> bearer(@caller_token) |> get(~p"/v1/webhook_endpoints")

      assert through_identity.status == through_reject.status

      assert Map.drop(body(through_identity), ["trace_id"]) ==
               Map.drop(body(through_reject), ["trace_id"])

      for conn <- [through_identity, through_reject] do
        assert is_binary(body(conn)["trace_id"])
        assert body(conn)["trace_id"] == conn |> Plug.Conn.get_resp_header("x-trace-id") |> hd()
      end
    end

    test "and an account in the body changes nothing, because the plug never reads one" do
      IntrospectionTransport.stub(200, %{"active" => false})

      conn =
        build_conn()
        |> bearer(@caller_token)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/v1/webhook_endpoints", Jason.encode!(%{"account_id" => @other_account}))

      assert conn.status == 401
    end
  end

  describe "a request courier cannot check" do
    test "is a 503 in courier's envelope, not a 401" do
      IntrospectionTransport.stub(503, %{"code" => "unavailable"})

      conn = quietly(&get(&1, ~p"/v1/webhook_endpoints"))

      assert conn.status == 503
      assert problem_json?(conn)
      assert body(conn)["type"] == "https://docs.anywaye.com/errors/unavailable"
      assert body(conn)["code"] == "unavailable"
      assert body(conn)["title"] == "Service unavailable"
      assert body(conn)["status"] == 503
      assert is_binary(body(conn)["detail"])
    end

    test "and the detail says nothing about identity, the token, or the account" do
      for {status, from_identity} <- [
            {503, %{"code" => "unavailable"}},
            {401, %{"code" => "unauthenticated"}},
            {403, %{"code" => "forbidden", "detail" => "an api key may only introspect itself"}},
            {500, %{"error" => "identity is on fire"}}
          ] do
        IntrospectionTransport.stub(status, from_identity)

        conn = quietly(&get(&1, ~p"/v1/webhook_endpoints"))
        rendered = Jason.encode!(body(conn))

        assert conn.status == 503, "identity answering #{status} produced #{conn.status}"
        refute rendered =~ @caller_token
        refute rendered =~ @account
        refute rendered =~ Introspection.service_token()
        refute rendered =~ "forbidden"
        refute rendered =~ "introspect"
        refute rendered =~ "identity"
      end
    end

    test "and the trace id is present, so it correlates with courier's log line" do
      IntrospectionTransport.stub(503, %{"code" => "unavailable"})

      conn = quietly(&get(&1, ~p"/v1/webhook_endpoints"))

      assert [trace_header] = Plug.Conn.get_resp_header(conn, "x-trace-id")
      assert body(conn)["trace_id"] == trace_header
    end

    test "and the request is halted, so no controller ran" do
      IntrospectionTransport.stub(503, %{"code" => "unavailable"})

      conn = quietly(&get(&1, ~p"/v1/webhook_endpoints"))

      assert conn.halted
      refute conn.assigns[:current_account]
    end

    test "and an unreachable identity is the same 503" do
      IntrospectionTransport.fail(:timeout)

      conn = quietly(&get(&1, ~p"/v1/webhook_endpoints"))

      assert conn.status == 503
      assert body(conn)["code"] == "unavailable"
    end

    test "and the reason courier could not answer is in the log, under no request's answer" do
      IntrospectionTransport.stub(403, %{"code" => "forbidden"})

      log =
        capture_log(fn ->
          send(
            self(),
            {:conn, build_conn() |> bearer(@caller_token) |> get(~p"/v1/webhook_endpoints")}
          )
        end)

      assert_received {:conn, conn}
      assert conn.status == 503
      assert log =~ "403"
      refute log =~ @caller_token
      refute log =~ Introspection.service_token()
    end
  end


  describe "openapi.yaml and the plug" do

    test "every operation behind the principal plug declares a 503" do
      responses = OpenAPIPaths.document_responses!(@document)

      authenticated = authenticated_operations()

      assert authenticated != [],
             "no operation is behind the principal plug, so this test proved nothing"

      undeclared =
        for operation <- authenticated,
            not Map.has_key?(responses[operation], "503"),
            do: label(operation)

      assert undeclared == [],
             "these operations sit behind a resolver that can answer 503 when identity " <>
               "cannot be reached, and do not declare it. A client generated from " <>
               "#{@document} has no branch for a dependency outage: #{inspect(undeclared)}"
    end

    test "and no operation outside it claims THIS 503" do
      responses = OpenAPIPaths.document_responses!(@document)
      authenticated = MapSet.new(authenticated_operations())

      claimed =
        for {{_method, _path} = operation, statuses} <- responses,
            Map.get(statuses["503"] || %{}, :ref) == "Unavailable",
            not MapSet.member?(authenticated, operation),
            do: label(operation)

      assert claimed == [],
             "these operations declare `components.responses.Unavailable` — the 503 a " <>
               "resolver that cannot reach identity sends — and are not behind the " <>
               "resolver: #{inspect(claimed)}"

      assert Map.get(responses[{"POST", "/inbound/resend"}]["503"] || %{}, :ref) ==
               "ReportNotRecorded"
    end

    test "and every 503 it declares is courier's envelope with the reserved code" do
      responses = OpenAPIPaths.document_responses!(@document)

      for operation <- authenticated_operations() do
        response = responses[operation]["503"]

        assert response.problem_json,
               "#{label(operation)}'s 503 does not name application/problem+json"

        assert response.ref_schema,
               "#{label(operation)}'s 503 does not carry the Problem schema"
      end
    end

    test "and the header says why an authenticated operation can be unavailable" do
      header = @document |> File.read!() |> String.split("openapi: 3.1.0") |> List.first()

      assert header =~ "introspections",
             "#{@document}'s header does not mention the introspection hop, so a reader " <>
               "is told nothing about why an authenticated operation can be unavailable"
    end
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:conn, fun.(build_conn() |> bearer(@caller_token))}) end)

    receive do
      {:conn, conn} -> conn
    after
      0 -> flunk("the request did not run inside the log capture")
    end
  end


  defp authenticated_operations do
    for route <- CourierWeb.Router.__routes__(),
        method = OpenAPIPaths.normalise_method(route.verb),
        %{} = info = Phoenix.Router.route_info(CourierWeb.Router, method, route.path, ""),
        :authenticated in Map.get(info, :pipe_through, []),
        do: OpenAPIPaths.normalise_operation(method, route.path)
  end

  defp label({method, path}), do: "#{method} #{path}"
end
