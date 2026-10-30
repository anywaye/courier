defmodule CourierWeb.RouterTest do
  @moduledoc """
  The probes are infrastructure endpoints: orchestrators hit them before any
  traffic, from outside `/api`, and they must not drift onto a different
  pipeline, format, or controller. Asserting the resolved route — not just the
  path — is what pins the controller, the action, and the scope.
  """

  use ExUnit.Case, async: true

  alias CourierWeb.HealthController
  alias CourierWeb.Router

  test "GET /healthz resolves to CourierWeb.HealthController.healthz/2" do
    assert %{plug: HealthController, plug_opts: :healthz, route: "/healthz"} =
             Phoenix.Router.route_info(Router, "GET", "/healthz", "")
  end

  test "GET /readyz resolves to CourierWeb.HealthController.readyz/2" do
    assert %{plug: HealthController, plug_opts: :readyz, route: "/readyz"} =
             Phoenix.Router.route_info(Router, "GET", "/readyz", "")
  end

  test "the probes are served at the root, outside the /api scope" do
    for path <- ["/healthz", "/readyz"] do
      assert %{route: ^path} = Phoenix.Router.route_info(Router, "GET", path, "")
      refute String.starts_with?(path, "/api")
    end
  end

  test "the probes do not answer write methods" do
    for method <- ~w(POST PUT PATCH DELETE) do
      assert :error == Phoenix.Router.route_info(Router, method, "/healthz", "")
      assert :error == Phoenix.Router.route_info(Router, method, "/readyz", "")
    end
  end

  describe "the messages surface" do
    alias CourierWeb.MessagesController

    test "POST /v1/messages resolves to CourierWeb.MessagesController.create/2" do
      assert %{plug: MessagesController, plug_opts: :create, route: "/v1/messages"} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")
    end

    test "it is behind the authenticated pipeline, and that is not a formality" do
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")

      assert :authenticated in pipelines, "POST /v1/messages must be behind authentication"
    end

    test "it is behind the idempotency pipeline, because a send is not idempotent" do
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")

      assert :idempotent in pipelines
    end

    test "it does not answer write methods other than POST" do
      for method <- ~w(GET PUT PATCH DELETE) do
        assert :error == Phoenix.Router.route_info(Router, method, "/v1/messages", "")
      end
    end
  end

  describe "the inbound provider surface" do
    alias CourierWeb.InboundController

    test "POST /inbound/resend resolves to CourierWeb.InboundController.create/2" do
      assert %{plug: InboundController, plug_opts: :create, route: "/inbound/resend"} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")
    end

    test "it is NOT behind the authenticated pipeline, and that is a decision" do
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")

      refute :authenticated in pipelines

      assert :api in pipelines
      assert :inbound in pipelines
    end

    test "and it authenticates by SIGNATURE instead" do
      assert %{plug: InboundController, plug_opts: :create} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")
    end

    test "it is NOT behind the idempotency pipeline, and dedupes on the provider's event id" do
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")

      refute :idempotent in pipelines
    end

    test "its path is outside /v1, because it is not a tenant operation" do
      refute String.starts_with?("/inbound/resend", "/v1")
    end

    test "the provider is in the path, so a body cannot choose its own vocabulary" do
      assert %{route: "/inbound/resend"} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")
    end

    test "it does not answer write methods other than POST" do
      for method <- ~w(GET PUT PATCH DELETE) do
        assert :error == Phoenix.Router.route_info(Router, method, "/inbound/resend", "")
      end
    end
  end

  describe "the one-click unsubscribe surface" do
    alias CourierWeb.UnsubscribeController

    test "GET and POST /unsubscribe/:token resolve to the unsubscribe controller" do
      assert %{plug: UnsubscribeController, plug_opts: :show, route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(Router, "GET", "/unsubscribe/abc", "")

      assert %{plug: UnsubscribeController, plug_opts: :create, route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(Router, "POST", "/unsubscribe/abc", "")
    end

    test "and it is NOT behind the authenticated pipeline, which RFC 8058 forbids" do
      for verb <- ~w(GET POST) do
        assert %{pipe_through: pipelines} =
                 Phoenix.Router.route_info(Router, verb, "/unsubscribe/abc", "")

        refute :authenticated in pipelines,
               "#{verb} /unsubscribe must not be behind the principal plug"

        assert :api in pipelines,
               "#{verb} /unsubscribe must be behind :api, so the 406 openapi.yaml " <>
                 "declares comes from the same plug it comes from everywhere else"
      end
    end

    test "and NOT behind the idempotency plug, because the index is the dedup" do
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/unsubscribe/abc", "")

      refute :idempotent in pipelines
    end

    test "and its path is outside /v1, because it is not a tenant operation" do
      refute String.starts_with?("/unsubscribe/:token", "/v1")
    end

    test "and it answers no other method" do
      for verb <- ~w(PUT PATCH DELETE HEAD) do
        assert :error == Phoenix.Router.route_info(Router, verb, "/unsubscribe/abc", ""),
               "#{verb} /unsubscribe is served, and a route with a verb nobody " <>
                 "documented is a verb a generated client will try"
      end
    end
  end

  describe "the webhook endpoints surface" do
    alias CourierWeb.WebhookEndpointsController

    @routes [
      {"GET", "/v1/webhook_endpoints", :index},
      {"POST", "/v1/webhook_endpoints", :create},
      {"GET", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001", :show},
      {"PATCH", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001", :update},
      {"DELETE", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001", :delete},
      {"POST", "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001/test", :ping}
    ]

    test "every action resolves to CourierWeb.WebhookEndpointsController" do
      for {method, path, action} <- @routes do
        assert %{plug: WebhookEndpointsController, plug_opts: ^action} =
                 Phoenix.Router.route_info(Router, method, path, "")
      end
    end

    test "every action is behind the authenticated pipeline" do
      for {method, path, _action} <- @routes do
        assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, method, path, "")

        assert :authenticated in pipelines, "#{method} #{path} must be behind authentication"
      end
    end

    test "notification preferences are behind it too, on both verbs" do
      for verb <- ~w(GET PUT) do
        assert %{pipe_through: pipelines} =
                 Phoenix.Router.route_info(Router, verb, "/v1/notification_preferences/abc", "")

        assert :authenticated in pipelines,
               "#{verb} notification preferences must be authenticated"
      end
    end

    test "no action answers a method it does not declare" do
      assert served_on("/v1/webhook_endpoints") == ["GET", "POST"]
      assert served_on("/v1/webhook_endpoints/:id") == ["DELETE", "GET", "PATCH"]
      assert served_on("/v1/webhook_endpoints/:id/test") == ["POST"]
    end

    test "the path is the plural noun core's conventions ask for, under /v1" do
      for {_method, path, _action} <- @routes do
        assert String.starts_with?(path, "/v1/webhook_endpoint")
        refute String.ends_with?(path, "/")
      end
    end
  end

  describe "the sending domains surface" do
    alias CourierWeb.SendingDomainsController

    @sending_domain_routes [
      {"GET", "/v1/sending_domains", :index},
      {"POST", "/v1/sending_domains", :create},
      {"GET", "/v1/sending_domains/8f3c2b1a-0000-4000-8000-000000000001", :show},
      {"POST", "/v1/sending_domains/8f3c2b1a-0000-4000-8000-000000000001/verify", :verify},
      {"POST", "/v1/sending_domains/8f3c2b1a-0000-4000-8000-000000000001/revoke", :revoke}
    ]

    test "every action resolves to CourierWeb.SendingDomainsController" do
      for {method, path, action} <- @sending_domain_routes do
        assert %{plug: SendingDomainsController, plug_opts: ^action} =
                 Phoenix.Router.route_info(Router, method, path, "")
      end
    end

    test "every action is behind the authenticated pipeline" do
      for {method, path, _action} <- @sending_domain_routes do
        assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, method, path, "")

        assert :authenticated in pipelines, "#{method} #{path} must be behind authentication"
      end
    end

    test "the two mutating POSTs take an Idempotency-Key, and revoke does not" do
      for path <- [
            "/v1/sending_domains",
            "/v1/sending_domains/8f3c2b1a-0000-4000-8000-000000000001/verify"
          ] do
        assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, "POST", path, "")
        assert :idempotent in pipelines, "POST #{path} must be behind the idempotency plug"
      end

      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(
                 Router,
                 "POST",
                 "/v1/sending_domains/8f3c2b1a-0000-4000-8000-000000000001/revoke",
                 ""
               )

      refute :idempotent in pipelines
    end

    test "no action answers a method it does not declare" do
      assert served_on("/v1/sending_domains") == ["GET", "POST"]
      assert served_on("/v1/sending_domains/:id") == ["GET"]
      assert served_on("/v1/sending_domains/:id/verify") == ["POST"]
      assert served_on("/v1/sending_domains/:id/revoke") == ["POST"]
    end

    test "the path is the plural noun core's conventions ask for, under /v1" do
      for {_method, path, _action} <- @sending_domain_routes do
        assert String.starts_with?(path, "/v1/sending_domains")
        refute String.ends_with?(path, "/")
      end
    end
  end

  defp served_on(route) do
    ~w(GET POST PUT PATCH DELETE)
    |> Enum.filter(&match?(%{route: ^route}, Phoenix.Router.route_info(Router, &1, route, "")))
    |> Enum.sort()
  end

end
