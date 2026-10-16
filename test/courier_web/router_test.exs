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
      # An unauthenticated POST to a mail egress is an open relay. This is the one
      # route in courier where that is true rather than theoretical, so the pipeline
      # is asserted here rather than left to the controller's own tests — which go
      # through the same router and would agree with a router that did not have it.
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/v1/messages", "")

      assert :authenticated in pipelines, "POST /v1/messages must be behind authentication"
    end

    test "it is behind the idempotency pipeline, because a send is not idempotent" do
      # A caller that timed out and retried without the header mails somebody
      # twice, and no row afterwards can tell the two messages apart.
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
      # The assertion that would look wrong here is the point. A provider is not
      # a tenant: Resend signs its webhook with Svix and sends no bearer token, so
      # behind `CourierWeb.Plugs.Principal` every delivery would be a 401.
      #
      # The reason this is safe is the next test, and the reason it is here at all
      # is that "not behind the auth plug" is a sentence a later reader should have
      # to read the tests to believe.
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")

      refute :authenticated in pipelines

      # And the 406 every operation in `openapi.yaml` declares comes from `:api`,
      # listed beside `:inbound` rather than folded into it — so there is one
      # `:accepts` in this file and not two to keep in step.
      assert :api in pipelines
      assert :inbound in pipelines
    end

    test "and it authenticates by SIGNATURE instead" do
      # The claim, asserted about the route rather than about a helper: an
      # unsigned body is refused and records nothing. See
      # `CourierWeb.InboundControllerTest` for the rows and
      # `CourierWeb.Plugs.ParseBodyTest` for the mechanism — a route with no auth
      # plug whose only authentication is a helper is a route whose authentication
      # is a convention, and this is the assertion that says it is not.
      assert %{plug: InboundController, plug_opts: :create} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")
    end

    test "it is NOT behind the idempotency pipeline, and dedupes on the provider's event id" do
      # A provider retries a webhook it got no answer for, and that is normal. The
      # `Idempotency-Key` header it would have to send is one no provider sends,
      # and `CourierWeb.Plugs.Idempotency` is scoped to a principal this route has
      # none of. The deduplication that answers the retry is
      # `email_suppressions`'s unique index on `(provider, provider_event_id)`,
      # which `Courier.Inbound.Resend` derives from the report's own content — a
      # stronger key than the header, because one delivery can name many
      # recipients and keying on the header would collapse them into one row.
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/inbound/resend", "")

      refute :idempotent in pipelines
    end

    test "its path is outside /v1, because it is not a tenant operation" do
      # `/v1` is courier's versioned contract with a tenant, and every operation
      # under it is authenticated with a bearer token. `PLAN.md` MD6 has the
      # platform generating client SDKs from `openapi.yaml`, so an operation filed
      # under `/v1` that cannot take a bearer token is a method a generated client
      # will call wrongly.
      refute String.starts_with?("/inbound/resend", "/v1")
    end

    test "the provider is in the path, so a body cannot choose its own vocabulary" do
      # A body naming the provider would be a caller choosing which parser reads
      # its own payload. The path is chosen by whoever configured the webhook, in
      # the provider's dashboard, so courier does not get to disagree with it.
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
      # Both verbs, on one path, and that is RFC 8058 §3.2's own sentence: "The
      # target of the POST action is the same as the one in the GET action for a
      # manual unsubscription." A bulk sender whose header points at a 405 has not
      # met the requirement by the clients people actually use.
      assert %{plug: UnsubscribeController, plug_opts: :show, route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(Router, "GET", "/unsubscribe/abc", "")

      assert %{plug: UnsubscribeController, plug_opts: :create, route: "/unsubscribe/:token"} =
               Phoenix.Router.route_info(Router, "POST", "/unsubscribe/abc", "")
    end

    test "and it is NOT behind the authenticated pipeline, which RFC 8058 forbids" do
      # §3.1: "The POST request MUST NOT include cookies, HTTP authorization, or
      # any other context information." A mail client holds no bearer token, sends
      # no cookie, and is not allowed to send either — so behind
      # `CourierWeb.Plugs.Principal` **every one-click unsubscribe in the world
      # would be a 401**, and Gmail and Yahoo require the button to work.
      #
      # This is the same claim `receiveResendReport` makes for a different reason,
      # and the assertion is here rather than left to the controller's own tests
      # because those go through the same router and would agree with a router that
      # did not have the pipeline.
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
      # `CourierWeb.Plugs.Idempotency` is scoped to a principal, which this route
      # has none of, and the header a mail client would have to send is one RFC 8058
      # forbids it from sending. The deduplication that answers a retry is
      # `email_suppressions`' unique index on `(provider, provider_event_id)` with
      # the token's id as the key — the same answer a redelivered provider report
      # gets, from the same index.
      assert %{pipe_through: pipelines} =
               Phoenix.Router.route_info(Router, "POST", "/unsubscribe/abc", "")

      refute :idempotent in pipelines
    end

    test "and its path is outside /v1, because it is not a tenant operation" do
      # Every operation under `/v1` is behind a bearer token in `openapi.yaml`, so
      # an operation filed there that cannot take one is a method a generated
      # client will call wrongly — `PLAN.md` MD6 builds those clients from the
      # document.
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
      # Not one of them: a single action outside the pipeline is an endpoint that
      # serves whoever asks, and the controller's own matrix would not catch it,
      # because that matrix goes through the same router.
      for {method, path, _action} <- @routes do
        assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, method, path, "")

        assert :authenticated in pipelines, "#{method} #{path} must be behind authentication"
      end
    end

    test "notification preferences are behind it too, on both verbs" do
      # The same claim about the same pipeline, asserted over the resource that
      # used to be the exception. It lives beside the webhook assertion rather
      # than in a describe of its own because there is nothing left to say about
      # it that is not said there: a route courier does not authenticate is a
      # route that serves whoever asks, and the two surfaces now differ only in
      # what they hold.
      for verb <- ~w(GET PUT) do
        assert %{pipe_through: pipelines} =
                 Phoenix.Router.route_info(Router, verb, "/v1/notification_preferences/abc", "")

        assert :authenticated in pipelines,
               "#{verb} notification preferences must be authenticated"
      end
    end

    test "no action answers a method it does not declare" do
      # `POST /v1/webhook_endpoints` is create and nothing else. A `PUT` on the
      # same path would be a second way to do the same thing with different
      # semantics, which is what core's conventions are there to prevent.
      assert served_on("/v1/webhook_endpoints") == ["GET", "POST"]
      assert served_on("/v1/webhook_endpoints/:id") == ["DELETE", "GET", "PATCH"]
      assert served_on("/v1/webhook_endpoints/:id/test") == ["POST"]
    end

    test "the path is the plural noun core's conventions ask for, under /v1" do
      # core/docs/openapi-conventions.md: "Path under `/v1`, no trailing slash,
      # plural nouns, kebab-case for multi-word."
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
      # A `tenant_sending_domains` row carries a sealed provider credential and a
      # domain courier signs outbound mail with; a surface that served whoever
      # asked would hand out the ability to send as somebody else's domain.
      for {method, path, _action} <- @sending_domain_routes do
        assert %{pipe_through: pipelines} = Phoenix.Router.route_info(Router, method, path, "")

        assert :authenticated in pipelines, "#{method} #{path} must be behind authentication"
      end
    end

    test "the two mutating POSTs take an Idempotency-Key, and revoke does not" do
      # Registration and verification are both retried by a caller that timed
      # out, and neither is free on a second run — a registration is refused as a
      # duplicate, and a verification re-dials the provider. Revocation is
      # idempotent by construction (a repeat is the same row with the same
      # status), so it carries no key, the same rule the notification marks
      # follow.
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
      # core/docs/openapi-conventions.md: "Path under `/v1`, no trailing slash,
      # plural nouns, kebab-case for multi-word."
      for {_method, path, _action} <- @sending_domain_routes do
        assert String.starts_with?(path, "/v1/sending_domains")
        refute String.ends_with?(path, "/")
      end
    end
  end

  # Which methods the router answers for a route pattern, discovered rather than
  # declared, so a route serving more than it documents shows up here. The pattern
  # has to be the router's own — `route_info/4` matches the route as written, not
  # a path that would reach it.
  defp served_on(route) do
    ~w(GET POST PUT PATCH DELETE)
    |> Enum.filter(&match?(%{route: ^route}, Phoenix.Router.route_info(Router, &1, route, "")))
    |> Enum.sort()
  end

  # No `describe "in the production environment"` block, and the absence is
  # deliberate rather than forgotten. It used to read `config/prod.exs` and
  # assert the probes were exempt from its compile-time `force_ssl` — but that
  # key is gone: `force_ssl` is compile-time endpoint configuration no env var
  # can switch, so the redirect moved to `CourierWeb.Plugs.ForceSSL`, gated on
  # the `COURIER_FORCE_SSL` runtime opt-in. The probe exemption is asserted
  # there (`test/courier_web/plugs/force_ssl_test.exs`), over the plug that
  # enforces it, rather than over a config file that no longer decides it.
end
