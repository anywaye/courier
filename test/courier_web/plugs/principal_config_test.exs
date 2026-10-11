defmodule CourierWeb.Plugs.PrincipalConfigTest do
  @moduledoc """
  The plug's two refusals, driven over real requests with the introspection
  resolver configured.

  ## Why this file changes application environment, and why it is its own file

  `config :courier, :principal` is read per request by
  `CourierWeb.Plugs.Principal.resolver/0`, and the whole VM shares the application
  environment — so a test that swaps it is `async: false` and lives alone in a
  file named `*ConfigTest`, exactly as `ProcessOutboxWorkerConfigTest`,
  `WebhookEndpointsConfigTest` and `DeliverWebhookWorkerBudgetTest` do. The
  previous value is restored in `on_exit`.

  ## What is asserted here that `introspection_test.exs` cannot be

  The other file proves courier's DECISION — `:ok`, `:error`,
  `{:error, :unavailable}`. This one proves the plug's three RESPONSES: a 401 that
  is byte for byte the 401 courier has always sent, a 503 in
  `CourierWeb.Problem`'s envelope carrying the media type, the `instance` and the
  `trace_id` a client correlates on, and a request that actually reaches a
  controller once identity says the token is live.
  """

  # `async: false` because this file changes `config :courier, :principal`, and
  # every other test in the suite reads it per request.
  use CourierWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Courier.Principal.Introspection
  alias Courier.TestSupport.IntrospectionTransport
  alias Courier.TestSupport.OpenAPIPaths

  @account "ab000000-0000-0000-0000-0000000000c1"
  @other_account "ffffffff-ffff-ffff-ffff-ffffffffffff"
  @caller_token "cafaye_caller-token-for-the-suite"

  # Read as a module attribute rather than spelled at each use, so a reader
  # looking for the document this file holds to the router finds the name once.
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

  # The media type a client switches on. `String.starts_with?/2` rather than `==`
  # because Plug appends the charset, and an assertion of exact equality against a
  # header nobody controls is an assertion about Plug's formatting.
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
        # The test resolver's stand-in header, asserted to be worth nothing here.
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
      # The account is not the only fact a controller needs about the caller. The
      # notifications reader addresses a recipient by the principal's `subject` —
      # the user the token names — and that field is discarded if only the account
      # is kept. This is the assertion that the plug change is load-bearing: the
      # struct is on the conn, with the subject the introspection answer carried.
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
      # A header that becomes a fast path is an authentication bypass with a
      # config file attached, so this is a property rather than a convention: the
      # header is set, no `Authorization` is, and the answer is still a 401.
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
      assert body(conn)["type"] == "https://docs.cafaye.com/errors/unauthorized"
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
      # The strongest form of "the 401 did not change": the same request through
      # two resolvers, refusing for two different reasons, must produce the same
      # body. A resolver that gained an answer must not have altered the answer
      # that was already there.
      IntrospectionTransport.stub(200, %{"active" => false})
      through_identity = build_conn() |> bearer(@caller_token) |> get(~p"/v1/webhook_endpoints")

      Application.put_env(:courier, :principal, Courier.Principal.Reject)
      through_reject = build_conn() |> bearer(@caller_token) |> get(~p"/v1/webhook_endpoints")

      assert through_identity.status == through_reject.status

      # `trace_id` is dropped and ONLY `trace_id`, because it is per request by
      # design — `CourierWeb.Plugs.Trace` mints one per connection — so including
      # it would compare two different requests' identities and fail for a reason
      # that has nothing to do with the plug. The dropped key is named rather than
      # filtered by a rule, so a second per-request field cannot slip through.
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
      assert body(conn)["type"] == "https://docs.cafaye.com/errors/unavailable"
      assert body(conn)["code"] == "unavailable"
      assert body(conn)["title"] == "Service unavailable"
      assert body(conn)["status"] == 503
      assert is_binary(body(conn)["detail"])
    end

    test "and the detail says nothing about identity, the token, or the account" do
      # A 503 is the answer to a request anybody can send, so it is a cheap place
      # to leak: courier's own credential, the shape of identity's answer, and the
      # account the caller was trying to reach are all things a caller must not be
      # able to read off a status they provoked. identity's own 403 sentence is
      # quoted here on purpose — "an api key may only introspect itself" is exactly
      # the string that must not reach a customer.
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
      # A 503 that arrived after a controller had written a row would be a lie
      # about the request's effect. The plug halts; the consequence asserted here
      # is that no account was assigned, because nothing downstream could have
      # used one.
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
      # The log line is where the operator looks and the response is where the
      # caller looks, and the split is the property: the response carries neither,
      # the log carries the status, and neither carries a credential.
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

  # --- the document, held to the router in both directions --------------------

  describe "openapi.yaml and the plug" do
    # This check lives here and not in `openapi_error_responses_test.exs` because
    # that file is `async: true` and this one changes
    # `config :courier, :principal` — and because the ability to PROVOKE the status
    # is here, which is what makes the assertion a measurement rather than a
    # reading of the document.
    #
    # The set of operations comes from the ROUTER, never from a list, for the
    # reason `openapi_error_responses_test.exs`'s moduledoc gives: a table of
    # statuses per operation is a check that can only fail for a case somebody
    # remembered to type.

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
      # The `Unavailable` **component**, not the status: `POST /inbound/resend`
      # declares a 503 of its own (`ReportNotRecorded` — a report courier read
      # and could not record), which is reachable, and a check written on the bare
      # status would call it a document that promises something it cannot send.
      # What has to hold is narrower and more useful: the resolver's 503 is the
      # resolver's alone.
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

      # And the assertion is not vacuous: the inbound surface's own 503 survives.
      assert Map.get(responses[{"POST", "/inbound/resend"}]["503"] || %{}, :ref) ==
               "ReportNotRecorded"
    end

    test "and every 503 it declares is courier's envelope with the reserved code" do
      responses = OpenAPIPaths.document_responses!(@document)

      for operation <- authenticated_operations() do
        # `OpenAPIPaths.document_responses!/1` follows a `$ref` into
        # `components.responses` and RAISES on one that names a component the
        # document does not define, so reaching this line at all means the 503 is
        # wired to something. What is left to assert is that the thing it is wired
        # to is the envelope and the Problem schema.
        response = responses[operation]["503"]

        assert response.problem_json,
               "#{label(operation)}'s 503 does not name application/problem+json"

        assert response.ref_schema,
               "#{label(operation)}'s 503 does not carry the Problem schema"
      end
    end

    test "and the header says why an authenticated operation can be unavailable" do
      # The header is the only prose a client author reads. A 503 that appeared in
      # the document with no explanation would be a client branch nobody knows when
      # to take — the same failure `openapi_error_responses_test.exs` catches for
      # a status the document forgets to declare.
      header = @document |> File.read!() |> String.split("openapi: 3.1.0") |> List.first()

      assert header =~ "introspections",
             "#{@document}'s header does not mention the introspection hop, so a reader " <>
               "is told nothing about why an authenticated operation can be unavailable"
    end
  end

  # `capture_log/1` returns the LOG, not the function's return value, so a request
  # whose warnings are expected cannot be written as
  # `conn = capture_log(fn -> get(conn, path) end)`. The request runs inside the
  # capture and the conn comes back as a message, which keeps the suppression and
  # the value in one expression.
  defp quietly(fun) do
    capture_log(fn -> send(self(), {:conn, fun.(build_conn() |> bearer(@caller_token))}) end)

    receive do
      {:conn, conn} -> conn
    after
      0 -> flunk("the request did not run inside the log capture")
    end
  end

  # --- the router, read rather than written down -------------------------------

  # The operations `CourierWeb.Plugs.Principal` guards, read from the router.
  #
  # `Phoenix.Router.Route` carries no pipelines, so each route's pipeline is asked
  # of the router itself through `route_info/4` — the same call
  # `test/courier_web/router_test.exs` makes, and the reason a pipeline removed
  # from `router.ex` cannot leave this file green.
  #
  # The keys go through `OpenAPIPaths.normalise_operation/2` rather than a
  # hand-rolled spelling, because they are compared against a map that reader
  # keyed with ITS normaliser. Two normalisers is how a check ends up asserting
  # over nothing.
  defp authenticated_operations do
    for route <- CourierWeb.Router.__routes__(),
        method = OpenAPIPaths.normalise_method(route.verb),
        %{} = info = Phoenix.Router.route_info(CourierWeb.Router, method, route.path, ""),
        :authenticated in Map.get(info, :pipe_through, []),
        do: OpenAPIPaths.normalise_operation(method, route.path)
  end

  defp label({method, path}), do: "#{method} #{path}"
end
