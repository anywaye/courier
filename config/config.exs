# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :courier,
  ecto_repos: [Courier.Repo],
  generators: [timestamp_type: :utc_datetime],
  # The environment name, as data, because `Mix.env/0` is not available inside a
  # RELEASE and `System.get_env("MIX_ENV")` is not set there either. `config_env/0`
  # here runs at compile time and the value is baked into the release.
  #
  # `Courier.MailerAdapter` reads this rather than guessing: without it the
  # adapter boot gate would have no way to tell a production boot from a test
  # one, and its default has to be `:prod` — the safe direction, since guessing
  # `:dev` would let a release configure the silent adapter.
  environment: config_env()

# Transactional email.
#
# Courier composes mail and hands it to Swoosh; it never speaks to a provider
# protocol itself, so swapping providers is a config change and not a code
# change. The From address and the subject templates are here because they are
# the two things an operator should be able to reword without touching a
# module. config/runtime.exs overrides `from` from the environment at boot.
#
# Subjects are templates with `%{key}` placeholders, filled from the payload
# the platform hands courier (see `Courier.Mailers.subject/2`). A template that
# names a key the payload does not carry is a configuration error, not a mail
# with a hole in it.
config :courier, :mailing,
  from: {"caFaye", "no-reply@cafaye.com"},
  subjects: %{
    welcome: "Welcome to caFaye",
    password_reset: "Reset your caFaye password",
    team_invitation: "%{invited_by} invited you to join %{account_name}",
    # Reason-agnostic on purpose: the subject is one line per TYPE in this
    # configuration, and `account_security` covers two reasons. The body is
    # where the reason-specific wording lives; a subject that tried to branch
    # would need a `%{reason}` placeholder the two values would fill clumsily
    # ("…: password reset"). A label that names the fact's kind is the honest
    # subject for a type that is one shape with two renderings.
    account_security: "Security notice for your caFaye account",
    email_change_current: "Confirm an email address change on your caFaye account",
    email_change_new: "Confirm your new caFaye email address"
  }

# `api_client: false` is still correct, and now for a real reason rather than
# because no provider had landed. SMTP is the adapter courier ships, and
# `Swoosh.Adapters.SMTP` speaks the protocol over `gen_smtp` — it never calls
# Swoosh's HTTP client, so leaving this false keeps a dependency courier does not
# use out of the release. It would only need to change for an HTTP-API provider
# (Postmark, SendGrid, Resend), and none of those is configured: they all have an
# SMTP front, and one adapter is one fewer credential path to keep out of logs.
config :swoosh, api_client: false

# Job queue, and the crontab that is the FLOOR under it.
#
# The fast path is the write: `Courier.Outbox.insert/1` enqueues the relay in the
# same transaction as the row, so a send's event is on the bus in milliseconds.
# The crontab is what makes that fast path an optimisation rather than a
# dependency — every row is unpublished until somebody publishes it, and anything
# that can write a row without enqueueing (a repair, a future call site, a
# restored backup) has to be recoverable without a code change.
#
# Every minute, for all three workers, and the reason differs per worker:
#
#   ProcessOutboxWorker    the outbox's own contract. Its fast path is one call
#                          away from every writer, and a caller that forgets it
#                          strands a row forever — which is the failure the outbox
#                          pattern exists to prevent, reached from the other side.
#   DispatchWebhooksWorker claims rows whose account courier cannot ask about,
#                          and its own moduledoc has always said it runs on a
#                          timer. A row can become eligible without any courier
#                          write at all.
#   DeliverWebhookWorker   a delivery becomes due BY THE CLOCK. `next_attempt_at`
#                          is written by the failure that set it, five minutes
#                          into the future, and nothing happens at that moment —
#                          so there is no write to hang an enqueue on and a timer
#                          is not a choice here, it is the only shape.
#   ConsumeEventsWorker    the same argument from the other direction, and the
#                          strongest form of it: a DELIVERED EVENT has no write
#                          in courier's code behind it at all. Nothing courier
#                          does causes an event to arrive, so there is nothing to
#                          hang an enqueue on and a timer is the only shape.
#
# One minute is the ceiling on how long an unpublished row can sit, which is also
# the number an alert would use. `Oban.Cron` is part of the `oban` package (no
# extra dependency, no table of its own), and `config/test.exs` sets
# `testing: :manual`, under which Oban starts no plugins at all — so in the suite
# this crontab is inert by construction and `Courier.OutboxEnqueueTest` starts
# `Oban.Cron` itself to prove the path rather than reading this comment.
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

# Outbox relay tuning. Read at runtime, not compiled in, so a deployment can
# change batch size without a rebuild.
config :courier, :outbox,
  batch_size: 50,
  max_attempts: 10

# What courier SUBSCRIBES to, and the module that handles each type. This is the
# fleet's first non-empty `consumes:`, and the keys are held to `cafaye.yml`'s
# `consumes:` list by `Courier.ConsumersTest` — a subscription declared in one
# and absent from the other is a message courier receives and drops, which is the
# same outcome as no subscription and one step harder to see.
#
# A handler is a module with `handle/1` returning `{:ok, _}` or `{:error, reason}`.
# It must NOT raise: `Courier.Consumers` wraps every call anyway, because a
# subscriber callback runs in the process that owns the subscription and an
# uncaught raise there is a denial of service on the whole event stream — but a
# handler that raises has still cost the event a delivery.
config :courier, :consumers, %{
  "identity.member.invited" => Courier.Consumers.MemberInvited,
  # The second subscription, and the first one courier can ACT on: the payload
  # carries `user_id`, which is a real person, so the handler records an in-app
  # notification through `Courier.Notifications` — that context's first
  # production caller. The invited handler refuses by design (the accept URL is
  # unrecoverable from any event); this one needs no refusal, because the
  # payload's three fields are exactly what the notification surface takes.
  "identity.member.accepted" => Courier.Consumers.MemberAccepted,
  # The third subscription, and the first one that sends MAIL. The payload
  # carries `user_id`, `email` and `reason` — the recipient and the fact — so
  # the handler sends the account-security notice through `Courier.Deliver`
  # and nothing is looked up. The reason is validated against its closed set
  # (`password reset`, `email address changed`) before anything is dialled, and
  # an unknown reason is a refusal, never a default.
  "identity.session.revoked" => Courier.Consumers.SessionsRevoked
}

# The consumer's own tuning, in `:consumer` and not `:consumers` — the registry
# above and the numbers below are unrelated things and one key meaning both is
# how a deployment ends up reading a batch size out of a handler map. Same split
# as `:outbox` beside `:nats_publisher`.
config :courier, :consumer,
  batch_size: 50,
  max_attempts: 10

# Outbound webhooks. Everything here is read at runtime, not compiled in, because
# all of it is a decision an operator has to be able to see and change without a
# rebuild — and PLAN.md §7 requires the budget to be bounded, which is only true
# if the bound is a number somebody can point at.
config :courier, :webhooks,
  # Eight attempts, five minutes apart at first, doubling, capped at six hours,
  # plus up to 25% jitter. A full budget spans roughly sixteen hours: the spec's
  # §Deliverability asks for "a retry schedule spanning multiple days", and this
  # is the same shape at a scale one courier-sized service can defend, without
  # keeping a dead endpoint's deliveries alive for a week.
  max_attempts: 8,
  backoff_base_seconds: 300,
  backoff_cap_seconds: 21_600,
  jitter_divisor: 4,
  # Consecutive failures before the circuit opens and the endpoint is disabled
  # with a reason. The spec §Deliverability says a consumer failing "consistently
  # over a long period of time" should have future delivery disabled; five is
  # courier's answer to "consistently", with the retry budget above deciding how
  # long that takes per delivery.
  circuit_threshold: 5,
  # The attempt timeout. Spec §Request timeouts asks for 15–30s; the low end,
  # because a delivery holding a worker is a delivery nobody else gets.
  timeout_ms: 15_000,
  connect_timeout_ms: 5_000,
  # How many outbox events one dispatch run fans out. Bounded so a large backlog
  # is worked through in batches rather than in one transaction that holds row
  # locks across the whole table.
  dispatch_batch_size: 100,
  # How many due deliveries one send run attempts. Bounded for the same reason,
  # and smaller than the dispatch batch because each of these makes a network call
  # and a hundred concurrent requests to a hundred different customers is a burst
  # courier's own egress gets shaped for.
  delivery_batch_size: 25

# The resolver the SSRF guard checks addresses with. Overridden in test so a URL
# check never depends on what a real resolver says about a real name.
config :courier, :dns_resolver, Courier.Webhooks.Dns.System

# ---------------------------------------------------------------------------
# Error reporting and the error relay. Both OFF by default here; the environment
# files and `runtime.exs` decide.
#
# WHY BOTH ARE OFF IN `config.exs` RATHER THAN IN `dev.exs`
#
# Because "off" is the safe default for the *whole* tree, and a reader who opens
# this file should not have to know which of three files to check. A courier that
# starts and silently reports nothing is a diagnosable state; a courier that
# starts in dev and reports to a developer's machine is not, and the difference
# between the two is one line of configuration.
#
# `:error_reporting` is courier reporting **its own** failures. Its DSN points at
# courier's own relay and at nothing else — see the licence argument in `mix.exs`
# and the misconfiguration argument in `Courier.ErrorReporting.Filter`, which is
# why the SDK filters its own events even though the relay filters them again.
#
# `:error_relay` is courier **receiving** the other two services' failures. Its
# token is required rather than defaulted, for the same reason
# `COURIER_SECRET_BOX_KEY` is: a default would be a shared secret in version
# control that every deployment which forgot to set one would accept error
# reports from.
# ---------------------------------------------------------------------------
config :courier, :error_reporting,
  enabled: false,
  environment: "unknown",
  release: "unknown",
  dsn: nil

config :courier, :error_relay, []

# The Sentry SDK's own configuration.
#
# `before_send` is the second redaction barrier, and it is the reason this
# deployment is safe from its own misconfiguration:
# `Courier.ErrorReporting.Filter` applies the same allowlist the relay does,
# before the envelope exists, so a DSN pointed at a third party by mistake still
# cannot ship an exception message or a request URL.
#
# `send_default_pii` is off in every Sentry SDK by default and is **stated**
# rather than assumed, because it is the one line whose default an SDK upgrade
# could plausibly change and whose change is invisible in a diff.
#
# No `sample_rate`. Sentry does not sample errors by design, and volume control is
# built in two places this repository owns instead — the client-side limiter and
# `Courier.ErrorRelay`'s fingerprint throttle. A sample rate here would silently
# discard the one crash that mattered.
#
# The transport is the SDK's own business and is left alone: this repository has a
# rule about HTTP clients (`AGENTS.md`: Req, not httpoison/tesla/httpc) and that
# rule is about code *this* repository writes. The SDK's traffic goes to
# courier's relay on the compose network; the relay's traffic to GlitchTip goes
# through Req, which is this repository's client. The two timeouts are set because
# a hung ingest socket must not be able to hold a request open — the relay
# answers before anything is forwarded, and this is the second place that has to
# be true.
config :sentry,
  dsn: nil,
  before_send: {Courier.ErrorReporting.Filter, :before_send},
  send_default_pii: false,
  request_timeout: 3_000,
  pool_size: 5,
  hackney: [recv_timeout: 3_000]

# The error endpoint's listener. A separate port from the customer API, and not
# published by `docker-compose.yml`, for the reason
# `CourierWeb.ErrorEndpoint` gives: the ingest surface is authenticated by a
# shared secret rather than by a per-caller principal, so it does not belong on
# the port a customer's ingress publishes.
config :courier, CourierWeb.ErrorEndpoint,
  http: [ip: {0, 0, 0, 0}, port: 4003],
  adapter: Bandit.PhoenixAdapter,
  # `formats: []` and the endpoint then **cannot render an error at all**:
  # `Phoenix.Endpoint.RenderErrors.put_formats/2` raises `MatchError` on the empty
  # list, and the request answers with a bare 500 that carries no body and no
  # content-type. A surface that swallows its own failures is the one thing an
  # error-reporting endpoint must not be — the exception is logged by the handler
  # and the caller learns only that something failed.
  #
  # `CourierWeb.ErrorJSON` is therefore configured, exactly as the customer API's
  # endpoint is, and the controller's own refusals use `CourierWeb.Problem` so the
  # shape a caller sees is the same `problem+json` it gets everywhere else in
  # courier. One envelope renderer for the whole service, not one per endpoint.
  render_errors: [formats: [json: CourierWeb.ErrorJSON], layout: false],
  pubsub_server: Courier.PubSub,
  # OFF here, and ON in `config/runtime.exs` when `PHX_SERVER` is set — the same
  # arrangement the customer endpoint uses, and for the same reason: `mix test` and
  # `mix phx.server` must not bind a second listener. The asymmetry to watch is
  # that the customer's port is published by compose and this one is not, so a
  # missing `server: true` here does not show up as a refused connection on
  # localhost: it shows up as a relay nothing can reach, plus one log line that
  # reads like a notice. `runtime.exs` sets both in the same block on purpose.
  server: false

# Configure the endpoint
config :courier, CourierWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: CourierWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Courier.PubSub,
  live_view: [signing_salt: "hkUIdgF0"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
