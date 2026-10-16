import Config

# TWO CREDENTIALS, AND THE ORDER THEY ARE WRITTEN IN IS THE POINT.
#
# THE FIRST IS THE RUNTIME CREDENTIAL, and it is `courier_app`: kit's app login
# role, which owns nothing, holds DML per table and is a subject of every
# row-level-security policy the substrate installed on `idempotency_keys`,
# `notification_preferences` and `webhook_endpoints`. **Every test in this suite
# therefore runs as a role the policies apply to**, which is the only way a suite
# can prove the boundary is on rather than installed.
#
# It used to be `postgres`, a superuser, and a superuser bypasses RLS whatever
# `force row level security` says — so a green suite could not tell an enforced
# boundary from an inert one. `Courier.Tenancy`'s moduledoc carries the
# measurement.
#
# THE SECOND IS THE BOOTSTRAP CREDENTIAL, and it is the only privileged one:
# `courier_app` is `NOCREATEDB` and owns no table, so `mix ecto.create` and
# `mix ecto.migrate` cannot run as it. `mix.exs`'s `test` alias points those two
# tasks at `Courier.OwnerRepo` and nothing else, which is what keeps the owner out
# of the run that matters.
#
# **THE OWNER CREDENTIAL MUST NEVER BE THE RUNTIME CREDENTIAL.** One repo key
# with an override would make `COURIER_OWNER_DATABASE_URL=… mix test` run the
# *tests* as the owner too, and the suite would go green with the boundary
# switched off. Two modules make the phase a compile-time fact — see
# `Courier.OwnerRepo`.
#
# WHY THE DEFAULT OWNER IS `postgres`, which is the superuser this packet is
# removing from the runtime path: a developer's plain local postgres and CI's
# `services: postgres` have EXACTLY ONE role, and creating the database is the
# one job a `NOSUPERUSER` owner role cannot do. On a cluster kit provisioned
# (`bin/dev`, `kit/templates/compose/postgres/initdb/10-cluster.sh`) the owner is
# the service's own `courier` role and this default is wrong by design — set
# `COURIER_DB_OWNER_USER`. Two variables, both optional, neither a secret worth
# keeping: a test fixture and a local development password.
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
port = String.to_integer(System.get_env("COURIER_TEST_PG_PORT", "5432"))
database = "courier_test#{System.get_env("MIX_TEST_PARTITION")}"

config :courier, Courier.Repo,
  username: "courier_app",
  # A fixture on the same terms as the `postgres` password this file committed
  # before: `courier_app` is created by
  # `priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs`, which
  # cannot set a password, so the password belongs to whoever provisioned the
  # cluster. kit's dev cluster gives every role the cluster password; a plain
  # local postgres is `bin/gate-db`'s, which is `postgres`.
  password: System.get_env("COURIER_APP_DB_PASSWORD", "postgres"),
  hostname: "localhost",
  port: port,
  database: database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# THE BOOTSTRAP CREDENTIAL. Never used by a test, by the endpoint, or by anything
# the supervision tree starts — see the paragraph above.
config :courier, Courier.OwnerRepo,
  # `priv/repo/migrations`, NAMED because Ecto derives it from the module name
  # instead — see `Courier.OwnerRepo` for what happens when it is left to guess.
  priv: "priv/repo",
  username: System.get_env("COURIER_DB_OWNER_USER", "postgres"),
  password: System.get_env("COURIER_DB_OWNER_PASSWORD", "postgres"),
  hostname: "localhost",
  port: port,
  database: database

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :courier, CourierWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "N0hG2os3k49qghyM9nsz+v7uuI6N8Msgch1e1YE9lmjC2n5bahmQKOrq2a5Up+aj",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Transactional email in test goes to `Swoosh.Adapters.Test`, which hands the
# message to the process that sent it. That is what makes `assert_email_sent/1`
# (Swoosh.TestAssertions) work without a provider, a relay, or a socket.
#
# `Swoosh.Adapters.Test` is NOT declared a provider courier supports — it is in
# `Courier.MailerAdapter.silent_adapters/0` and `COURIER_MAIL_ADAPTER=smtp` can
# never resolve to it. It is configured here, directly, because it is the right
# adapter for a suite and the wrong one for a deployment, and those are
# different questions. `Courier.MailerAdapterTest` asserts the two are not
# confused.
#
# The real SMTP adapter is exercised in the same environment by
# `test/courier/smtp_delivery_test.exs`, which overrides this configuration and
# points the adapter at a `gen_smtp` server it starts itself.
config :courier, Courier.Mailer, adapter: Swoosh.Adapters.Test

# Oban in `:manual` testing mode: jobs land in the database, nothing executes in
# the background. Both modes also silence plugin queries, which is what keeps the
# Ecto sandbox usable (guides/testing/testing.md).
config :courier, Oban, testing: :manual

# The relay publishes to a stand-in that hands each envelope back to the calling
# process, so a test can assert on what would have gone to NATS. The Gnat
# connection is a later packet.
config :courier, :nats_publisher, Courier.NatsPublisher.Noop

# A fixed sealing key, so a test can assert that a secret is *not* readable from
# the column without the assertion depending on which key the process booted
# with. Test-only: `config/runtime.exs` requires a real one from the environment
# and refuses to boot without it, and this value is in the repository.
config :courier, :secret_box_key, "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE="

# The signing secret the inbound route VERIFIES with, in test.
#
# Test-only in the same sense as `COURIER_SECRET_BOX_KEY` above, and on the same
# terms: it is a fixture, never a default, and no production deployment reads it
# — `config/runtime.exs` requires a real one from the environment and refuses to
# boot without it. It is the SAME string `Courier.TestSupport.FakeResend.secret/0`
# signs with, so the suite needs no provider, no network and no real secret to
# drive a signed report all the way through the route.
#
# The value is written out rather than calling `FakeResend.secret/0`, because
# `config/test.exs` is evaluated by the config reader before the application's
# modules are loaded and a module call here is an `:undef` at boot.
# `test/courier_web/inbound_config_test.exs` asserts the two are the same string,
# so the duplication cannot become a fixture the suite signs with and the
# application does not verify with — which would turn every positive test in the
# inbound suite green for the wrong reason.
config :courier, :inbound_secrets, %{"resend" => "whsec_cHViNGlzaGVhZGZha2VzZWNyZXRmb3J0ZXN0cw=="}

# The SSRF guard's resolver in test. `Courier.TestSupport.TestDns` answers from
# a table a test writes, so every URL in the suite — including ones pointing at
# `127.0.0.1` — is checked without a DNS lookup whose answer could differ
# between a laptop and CI. `{module, argument}` is the guard's convention for a
# resolver that needs to be told something.
config :courier, :dns_resolver, {Courier.TestSupport.TestDns, {:canned, ["93.184.216.34"]}}

# The sending-domain proof's resolver in test. `Courier.TestSupport.SendingDomainDns`
# answers from a table a test writes, so the proof is tested against the record
# sets it exists for — Cloudflare's onboarding footprint, a partial set, a
# foreign set — without a network. The shipped `Courier.SendingDomains.Dns.System`
# (`:inet_res`) is what every other environment runs; it is exercised against a
# real resolver by the same rule that says a seam is tested from both sides.
config :courier, :sending_domain_resolver, Courier.TestSupport.SendingDomainDns

# Where a tenant's provider posts mail in test: the base_url the tenant adapter
# configuration carries. `nil` means the production API host, which is correct
# for a deployment and wrong for a suite whose rule is no sockets — so a test
# that sends as a tenant sets this to its own listener's URL and puts it back.
config :courier, :tenant_sending, base_url: nil

# Webhook delivery in test goes to a double that records the request instead of
# opening a socket, so the assertions about what courier signs and sends are
# assertions about courier and not about a listener's timing. See
# `test/support/recording_sender.ex`.
config :courier, :webhook_sender, Courier.TestSupport.RecordingSender

# The principal resolver in test. It reads the account from a request header so
# the authorization matrix can be asserted over real requests; it is a stand-in
# for identity's verifier and is only ever configured here. The shipped default,
# `Courier.Principal.Reject`, authenticates nobody, and
# `Courier.Principal.Introspection` is what every other environment gets — see
# `lib/courier_web/plugs/principal.ex`.
config :courier, :principal, Courier.TestSupport.HeaderResolver

# The introspection transport, and it is a table rather than a socket so the
# resolver's tests assert courier's DECISION — what it sends, and what it does
# with each answer — rather than that `Req` can open a connection.
# `Courier.Principal.Introspection.Transport.Req`, the one that actually dials, is
# exercised against Req's own plug adapter in
# `test/courier/principal/introspection/transport_req_test.exs`, because a seam
# tested from one side only is a seam nobody checked.
config :courier, :introspection_transport, Courier.TestSupport.IntrospectionTransport

# Req's own testing seam, pointed at a stub, so `Transport.Req` — the one that
# really builds the request — is driven without a socket. Merged FIRST inside
# `Transport.Req.post/3`, so the four decisions there (`retry: false`,
# `redirect: false`, the 2s dial, `max_redirects: 0`) cannot be switched off by
# anything a test or a deployment writes here.
config :courier, :introspection_req_options, plug: {Req.Test, :courier_introspection}

# Where identity is, for the resolver's own assertions. Never dialled in this
# environment — the transport above answers instead — so a test that reached the
# network would fail rather than pass quietly. The port is identity's own
# (8080), the same fact `config/runtime.exs` defaults; a test holds the two
# together.
config :courier, :identity_url, "http://identity.test:8080"

# courier's OWN credential for introspection, and this is a FIXTURE and not a
# default, on the same terms as `COURIER_SECRET_BOX_KEY` above: `config/runtime.exs`
# requires a real one from the environment in prod and refuses to boot without it.
# It is in the repository because the suite has to be able to assert that courier
# presents THIS value and never the caller's — which is a claim nothing can check
# without a value to check.
config :courier, :identity_token, "cafaye_couriers-own-service-credential"

# OpenTelemetry in test, and it is ON.
#
# The suite is where courier's redaction boundary is proved, so telemetry has to be
# on for the proof to mean anything: an allowlist that was never exercised because
# nothing was recorded is an allowlist nobody has checked.
#
# The exporter is `Courier.TestSpanExporter`, which writes into an ETS table
# instead of dialling a collector. Three reasons, and all three are the fleet's
# rules rather than preferences:
#
#   1. Nothing leaves the process. A test that dialled a collector would be a
#      network call in a suite whose rule is no sockets, and a suite that phones an
#      observability backend is a suite that phones an observability backend.
#   2. It is the REAL SDK with a REAL exporter swapped in, so a test reads the
#      payload a collector would have received rather than the test's idea of it.
#   3. `:otel_simple_processor` rather than the batch processor, so a span is
#      finished and exported by the time the request returns. A test that had to
#      wait for a flush timer would need a sleep, and a sleep is a guess about
#      someone else's interval that is wrong on the machine where it matters.
#
# The propagators and the sampler are set because the propagation tests need them
# to be the same two a deployment gets. `root: :always_on` and not
# `{:always_on, []}` — the latter is what kit's Elixir snippet says, it does not
# match this SDK's `otel_sampler:new/1`, and the resulting `:undef` takes the whole
# tracer provider down while its start result is discarded with `_ =`.
config :courier, :otel_exporter, Courier.TestSpanExporter

config :opentelemetry,
  text_map_propagators: [:trace_context, :baggage],
  sampler: {:parent_based, %{root: :always_on}},
  register_loaded_applications: false,
  create_application_tracers: false

# ---------------------------------------------------------------------------
# Error reporting is OFF in test, and that is a fact this repository asserts.
#
# Two things are switched off and they are switched off in different places on
# purpose:
#
#   * `:sentry`'s DSN is unset (config/config.exs, inherited), so
#     `Sentry.capture_exception/2` builds nothing and sends nothing. The SDK
#     treats a nil DSN as "do not report", so this is the switch that matters.
#   * `Courier.ErrorReporting.enabled?/0` is false, so courier does not even call
#     the SDK.
#
# `CourierWeb.ErrorReportingTest` asserts both, and asserts that capturing an
# error in the suite puts nothing in any mailbox and opens no socket. "Reporting
# is off in test" is a requirement in the brief, and a requirement nobody checks
# is a requirement that holds until somebody adds a DSN to `test.exs` on a Friday
# afternoon — at which point every test that raises an expected exception
# reports it, and the suite takes minutes and a network.
#
# The relay is configured too, so the *receiving* half of the packet is exercised
# in the suite — `Courier.TestSupport.RecordingSink` stands in for GlitchTip, and
# `COURIER_ERROR_RELAY_TOKEN` is a test-only value in the repository on the same
# terms as `COURIER_SECRET_BOX_KEY` above: a fixture, not a default, and
# `config/runtime.exs` requires a real one in prod and refuses to boot without it.
config :courier, :error_reporting, enabled: false
config :sentry, dsn: nil

config :courier, :error_relay_token, "test-error-relay-token-not-a-secret"

config :courier, CourierWeb.ErrorEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  server: false
