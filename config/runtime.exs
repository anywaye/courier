import Config


serving? = System.get_env("RELEASE_COMMAND") != "eval"

if System.get_env("PHX_SERVER") do
  config :courier, CourierWeb.Endpoint, server: true

  config :courier, CourierWeb.ErrorEndpoint, server: true
end

config :courier, CourierWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :courier,
       :force_ssl_enabled,
       System.get_env("COURIER_FORCE_SSL") in ~w(true 1)

if config_env() != :test do
  config :opentelemetry, Courier.Telemetry.sdk_config()
end

if config_env() != :test do
  nats_url = System.get_env("NATS_URL")

  config :courier,
         :nats,
         Keyword.merge(Application.get_env(:courier, :nats) || [], url: nats_url)

  config :courier,
         :nats_publisher,
         if(is_nil(nats_url) or String.trim(nats_url) == "",
           do: Courier.NatsPublisher.Unconfigured,
           else: Courier.NatsPublisher.Bus
         )
end

if config_env() != :test do
  config :courier, :principal, Courier.Principal.Introspection

  config :courier,
         :identity_url,
         System.get_env("COURIER_IDENTITY_URL", "http://identity:8080")
end

if config_env() == :prod and serving? do
  config :courier,
         :identity_token,
         System.get_env("COURIER_IDENTITY_TOKEN") ||
           raise("""
           environment variable COURIER_IDENTITY_TOKEN is missing.

           It is courier's own credential for identity's introspection endpoint —
           the scoped API token an operator mints with
           POST /v1/accounts/{account_id}/api-keys — and courier presents it as the
           Authorization header when it asks "who is calling?".

           Unset, courier answers 503 to every authenticated request: courier is
           fine, its credential is not, and a 503 says so where a 401 would tell a
           customer to rotate a token that was never the problem.
           """)
end


if config_env() == :prod and serving? do
  mailing = Application.get_env(:courier, :mailing, [])
  {from_name, from_address} = mailing[:from]

  resolved_from =
    {System.get_env("MAIL_FROM_NAME", from_name), System.get_env("MAIL_FROM", from_address)}

  config :courier,
         :mailing,
         Keyword.merge(mailing,
           from: resolved_from,
           deployment_domain: Courier.Mailers.domain_of(resolved_from),
           billing_url: System.get_env("COURIER_BILLING_URL") || mailing[:billing_url]
         )

  mailer_adapter = Courier.MailerAdapter.adapter!(:prod)

  config :courier, Courier.Mailer, mailer_adapter

  config :swoosh,
    api_client: Courier.MailerAdapter.api_client(mailer_adapter[:adapter]) || false

  mailer_notice = "mailer: #{Courier.MailerAdapter.describe(mailer_adapter)}"

  config :courier,
         :secret_box_key,
         System.get_env("COURIER_SECRET_BOX_KEY") ||
           raise("""
           environment variable COURIER_SECRET_BOX_KEY is missing.

           It is the 32-byte key every webhook signing secret is sealed under.
           Generate one with: openssl rand -base64 32
           """)

  inbound_resend_secret =
    case System.get_env("COURIER_INBOUND_RESEND_SECRET") do
      nil ->
        nil

      "" ->
        nil

      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed
    end

  config :courier,
         :inbound_secrets,
         if(inbound_resend_secret, do: %{"resend" => inbound_resend_secret}, else: %{})

  inbound_notice =
    case inbound_resend_secret do
      nil ->
        {:warning,
         "inbound: no provider configured — a hard bounce or a spam complaint is discarded and courier goes on mailing an address that has said it is gone; set COURIER_INBOUND_RESEND_SECRET to enable Resend inbound reports"}

      _secret ->
        {:info,
         "inbound: verifying #{Enum.join(Courier.InboundConfig.configured_providers(), ", ")}"}
    end

  config :courier, :startup_notices, [{:info, mailer_notice}, inbound_notice]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      if serving? do
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """
      end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :courier, Courier.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  if owner_database_url = System.get_env("COURIER_OWNER_DATABASE_URL") do
    config :courier, Courier.OwnerRepo,
      url: owner_database_url,
      priv: "priv/repo",
      socket_options: maybe_ipv6
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if serving? do
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
      end

  host = System.get_env("PHX_HOST") || "example.com"

  config :courier, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  error_reporting_dsn = System.get_env("COURIER_ERROR_REPORTING_DSN")
  error_relay_token = System.get_env("COURIER_ERROR_RELAY_TOKEN")
  error_sink_dsn = System.get_env("COURIER_ERROR_SINK_DSN")
  release = System.get_env("COURIER_RELEASE") || "unknown"
  environment_name = System.get_env("DEPLOYMENT_ENVIRONMENT") || "production"

  if error_reporting_dsn do
    config :courier, :error_reporting,
      enabled: true,
      dsn: error_reporting_dsn,
      release: release,
      environment: environment_name

    config :sentry,
      dsn: error_reporting_dsn,
      environment_name: environment_name,
      release: release,
      before_send: {Courier.ErrorReporting.Filter, :before_send},
      send_default_pii: false,
      request_timeout: 3_000,
      pool_size: 5,
      hackney: [recv_timeout: 3_000]
  end

  if serving? and is_nil(error_relay_token) do
    raise """
    environment variable COURIER_ERROR_RELAY_TOKEN is missing.

    It is the shared secret every service presents when it reports an unhandled
    error. Generate one with: openssl rand -hex 32

    Unset, the relay refuses every envelope, which is the safe direction — but a
    deployment that means to run the relay and does not have one is silently
    reporting nothing, so this is refused at boot rather than discovered by an
    operator reading a dashboard.
    """
  end

  config :courier, :error_relay_token, error_relay_token

  config :courier, :error_relay,
    name: Courier.ErrorRelay,
    sink: Courier.ErrorRelay.Sink.Req,
    sink_dsn: error_sink_dsn,
    burst: 5,
    per_minute: 60,
    capacity: 4_096,
    queue_size: 256

  config :courier, CourierWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

end
