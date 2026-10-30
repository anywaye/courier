import Config

port = String.to_integer(System.get_env("COURIER_TEST_PG_PORT", "5432"))
database = "courier_test#{System.get_env("MIX_TEST_PARTITION")}"

config :courier, Courier.Repo,
  username: "courier_app",
  password: System.get_env("COURIER_APP_DB_PASSWORD", "postgres"),
  hostname: "localhost",
  port: port,
  database: database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :courier, Courier.OwnerRepo,
  priv: "priv/repo",
  username: System.get_env("COURIER_DB_OWNER_USER", "postgres"),
  password: System.get_env("COURIER_DB_OWNER_PASSWORD", "postgres"),
  hostname: "localhost",
  port: port,
  database: database

config :courier, CourierWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "N0hG2os3k49qghyM9nsz+v7uuI6N8Msgch1e1YE9lmjC2n5bahmQKOrq2a5Up+aj",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix,
  sort_verified_routes_query_params: true

config :courier, Courier.Mailer, adapter: Swoosh.Adapters.Test

config :courier, Oban, testing: :manual

config :courier, :nats_publisher, Courier.NatsPublisher.Noop

config :courier, :secret_box_key, "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE="

config :courier, :inbound_secrets, %{"resend" => "whsec_cHViNGlzaGVhZGZha2VzZWNyZXRmb3J0ZXN0cw=="}

config :courier, :dns_resolver, {Courier.TestSupport.TestDns, {:canned, ["93.184.216.34"]}}

config :courier, :sending_domain_resolver, Courier.TestSupport.SendingDomainDns

config :courier, :tenant_sending, base_url: nil

config :courier, :webhook_sender, Courier.TestSupport.RecordingSender

config :courier, :principal, Courier.TestSupport.HeaderResolver

config :courier, :introspection_transport, Courier.TestSupport.IntrospectionTransport

config :courier, :introspection_req_options, plug: {Req.Test, :courier_introspection}

config :courier, :identity_url, "http://identity.test:8080"

config :courier, :identity_token, "anywaye_couriers-own-service-credential"

config :courier, :otel_exporter, Courier.TestSpanExporter

config :opentelemetry,
  text_map_propagators: [:trace_context, :baggage],
  sampler: {:parent_based, %{root: :always_on}},
  register_loaded_applications: false,
  create_application_tracers: false

config :courier, :error_reporting, enabled: false
config :sentry, dsn: nil

config :courier, :error_relay_token, "test-error-relay-token-not-a-secret"

config :courier, CourierWeb.ErrorEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  server: false
