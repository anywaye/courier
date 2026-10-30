
import Config

config :courier,
  ecto_repos: [Courier.Repo],
  generators: [timestamp_type: :utc_datetime],
  environment: config_env()

config :courier, :mailing,
  from: {"Anywaye", "no-reply@anywaye.com"},
  billing_url: nil,
  deployment_domain: "anywaye.com",
  subjects: %{
    welcome: "Welcome to Anywaye",
    password_reset: "Reset your Anywaye password",
    team_invitation: "%{invited_by} invited you to join %{account_name}",
    account_security: "Security notice for your Anywaye account",
    email_change_current: "Confirm an email address change on your Anywaye account",
    email_change_new: "Confirm your new Anywaye email address",
    receipt: "We received your Anywaye payment",
    payment_failed: "Your Anywaye payment did not go through",
  }

config :swoosh, api_client: false

config :courier, Oban,
  repo: Courier.Repo,
  queues: [outbox: 10, webhooks: 5, consumers: 10],
  plugins: [
    {Oban.Cron,
     crontab: [
       {"* * * * *", Courier.Workers.ProcessOutboxWorker},
       {"* * * * *", Courier.Workers.DispatchWebhooksWorker},
       {"* * * * *", Courier.Workers.DeliverWebhookWorker},
       {"* * * * *", Courier.Workers.ConsumeEventsWorker}
     ]}
  ]

config :courier, :outbox,
  batch_size: 50,
  max_attempts: 10

config :courier, :consumers, %{
  "identity.member.invited" => Courier.Consumers.MemberInvited,
  "billing.payment.succeeded" => Courier.Consumers.PaymentSucceeded,
  "billing.payment.failed" => Courier.Consumers.PaymentFailed,
  "identity.member.accepted" => Courier.Consumers.MemberAccepted,
  "identity.session.revoked" => Courier.Consumers.SessionsRevoked,
  "identity.user.created" => Courier.Consumers.UserCreated
}

config :courier, :consumer,
  batch_size: 50,
  max_attempts: 10

config :courier, :webhooks,
  max_attempts: 8,
  backoff_base_seconds: 300,
  backoff_cap_seconds: 21_600,
  jitter_divisor: 4,
  circuit_threshold: 5,
  timeout_ms: 15_000,
  connect_timeout_ms: 5_000,
  dispatch_batch_size: 100,
  delivery_batch_size: 25

config :courier, :dns_resolver, Courier.Webhooks.Dns.System

config :courier, :error_reporting,
  enabled: false,
  environment: "unknown",
  release: "unknown",
  dsn: nil

config :courier, :error_relay, []

config :sentry,
  dsn: nil,
  before_send: {Courier.ErrorReporting.Filter, :before_send},
  send_default_pii: false,
  request_timeout: 3_000,
  pool_size: 5,
  hackney: [recv_timeout: 3_000]

config :courier, CourierWeb.ErrorEndpoint,
  http: [ip: {0, 0, 0, 0}, port: 4003],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: CourierWeb.ErrorJSON], layout: false],
  pubsub_server: Courier.PubSub,
  server: false

config :courier, CourierWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CourierWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Courier.PubSub,
  live_view: [signing_salt: "hkUIdgF0"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
