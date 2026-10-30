import Config

dev_port = String.to_integer(System.get_env("COURIER_DEV_PG_PORT", "5432"))

config :courier, Courier.Repo,
  username: "courier_app",
  password: System.get_env("COURIER_APP_DB_PASSWORD", "postgres"),
  hostname: "localhost",
  port: dev_port,
  database: "courier_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :courier, Courier.OwnerRepo,
  priv: "priv/repo",
  username: System.get_env("COURIER_DB_OWNER_USER", "postgres"),
  password: System.get_env("COURIER_DB_OWNER_PASSWORD", "postgres"),
  hostname: "localhost",
  port: dev_port,
  database: "courier_dev"

config :courier, CourierWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "AmMyfvysE7S6XSLMEx5pqbOxk5KgHTcZJK8OtDEPbNwpuqQDoGBdCeCHmvmDTuLj",
  watchers: []


config :courier, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

