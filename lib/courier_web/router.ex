defmodule CourierWeb.Router do
  use CourierWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :inbound do
    plug :inbound_provider
  end

  pipeline :authenticated do
    plug CourierWeb.Plugs.Principal
  end

  pipeline :idempotent do
    plug CourierWeb.Plugs.Idempotency
  end

  @signed_body_paths ["/inbound/resend"]

  @doc """
  Whether a request to `path` is a signed inbound body courier must not decode.

  Trailing-slash insensitive, because `Phoenix.Router` matches `/inbound/resend/`
  to the same route: a check that only knew the spelling without the slash would
  parse exactly the request a copy-pasted URL produces.
  """
  @spec signed_body?(term()) :: boolean()
  def signed_body?(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" -> false
      trimmed -> trimmed in @signed_body_paths
    end
  end

  def signed_body?(_other), do: false

  @doc "The paths `signed_body?/1` answers for, so a test can hold them to the router."
  @spec signed_body_paths() :: [String.t()]
  def signed_body_paths, do: @signed_body_paths

  scope "/", CourierWeb do
    pipe_through :api

    get "/healthz", HealthController, :healthz
    get "/readyz", HealthController, :readyz
  end

  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated]

    get "/notification_preferences/:user_id", NotificationPreferencesController, :show
    put "/notification_preferences/:user_id", NotificationPreferencesController, :update

    get "/webhook_endpoints", WebhookEndpointsController, :index
    get "/webhook_endpoints/:id", WebhookEndpointsController, :show
    patch "/webhook_endpoints/:id", WebhookEndpointsController, :update
    delete "/webhook_endpoints/:id", WebhookEndpointsController, :delete

    get "/notifications", NotificationsController, :index
    get "/notifications/unread_count", NotificationsController, :unread_count
    post "/notifications/:id/seen", NotificationsController, :mark_seen
    post "/notifications/:id/read", NotificationsController, :mark_read

    get "/sending_domains", SendingDomainsController, :index
    get "/sending_domains/:id", SendingDomainsController, :show
    post "/sending_domains/:id/revoke", SendingDomainsController, :revoke

    get "/notification_types", NotificationTypesController, :index
    get "/notification_types/:type", NotificationTypesController, :show
    post "/notification_types", NotificationTypesController, :create
    patch "/notification_types/:type", NotificationTypesController, :update
    delete "/notification_types/:type", NotificationTypesController, :delete
  end

  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated, :idempotent]

    post "/webhook_endpoints", WebhookEndpointsController, :create
    post "/webhook_endpoints/:id/test", WebhookEndpointsController, :ping

    post "/sending_domains", SendingDomainsController, :create
    post "/sending_domains/:id/verify", SendingDomainsController, :verify

    post "/messages", MessagesController, :create
  end

  scope "/inbound", CourierWeb do
    pipe_through [:api, :inbound]

    post "/resend", InboundController, :create
  end

  scope "/unsubscribe", CourierWeb do
    pipe_through :api

    get "/:token", UnsubscribeController, :show
    post "/:token", UnsubscribeController, :create
  end

  scope "/api", CourierWeb do
    pipe_through :api
  end

  defp inbound_provider(conn, _opts) do
    assign(conn, :inbound_provider, provider_for(conn.request_path))
  end

  defp provider_for(path) when is_binary(path) do
    path
    |> String.split("/")
    |> List.last()
    |> case do
      "resend" -> "resend"
      _unknown -> nil
    end
  end
end
