import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/courier start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :courier, CourierWeb.Endpoint, server: true

  # **Both** endpoints, and the second one is not a copy-paste error. The error
  # endpoint declares `server: false` in `config/config.exs` so that a
  # `mix test` run and a `mix phx.server` run do not bind a second listener, which
  # is the right default; but a release that serves the customer API and does not
  # serve the ingest surface is a relay with no door.
  #
  # This is release-only breakage in the same family as the `Sentry` child-spec
  # mistake in `Courier.Application`: nothing in the suite runs a release, and the
  # symptom is a single log line —
  #
  #     Configuration :server was not enabled for CourierWeb.ErrorEndpoint,
  #     http/https services won't start
  #
  # — which reads like a notice and leaves the relay silently unreachable. It is
  # better than a boot crash and worse than a boot failure, which is the worst
  # combination to debug from a container log.
  config :courier, CourierWeb.ErrorEndpoint, server: true
end

config :courier, CourierWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ---------------------------------------------------------------------------
# OPENTELEMETRY. In every environment, and that is the point.
#
# A developer running `mix phx.server` exports into the collector that ships with
# the stack, and a deployer gets traces without assembling anything. Gating this
# to :prod would make the default a no-op everywhere it is actually used, which is
# backwards.
#
# The RULES are in `Courier.Telemetry` and this is four lines that call into it —
# not a second copy of them. The Erlang SDK is configured through the application
# environment and started by the application controller, which runs before
# `Courier.Application.start/2`, so there is no code path that could set this
# earlier; keeping the logic in a module is what makes it testable at all.
#
# `<SERVICE>_OTEL_ENDPOINT` is the only contract (core D16). Unset, it is the
# collector that ships with the stack. Set it to anything speaking OTLP and
# courier goes there instead — bring-your-own is a supported deployment, not a
# degraded mode.
#
# NOT IN TEST, and the guard is load-bearing rather than fussy. `runtime.exs` runs
# AFTER every environment's config file, including `test.exs` — so an unguarded
# line here would replace the suite's in-memory exporter with a real OTLP one.
# Every redaction test in this repository asserts the ABSENCE of a canary from the
# exported spans, and a real exporter in a suite with no collector exports
# nothing: all of them would go green, in about a second, having proved nothing.
# A guard whose absence produces a green suite is the worst kind of guard to
# leave to a reader.
if config_env() != :test do
  config :opentelemetry, Courier.Telemetry.sdk_config()
end

# ---------------------------------------------------------------------------
# WHO IS CALLING. The resolver, its address, and its credential.
#
# `Courier.Principal.Introspection` is the module `config :courier, :principal`
# names outside test, and it asks identity `POST /v1/introspections` about the
# token an inbound request carries. It replaced `Courier.Principal.Reject`, which
# authenticated nobody and therefore answered 401 to every authenticated request
# in a deployed courier.
#
# `Courier.Principal.Reject` IS STILL THE FALLBACK and is still correct for the
# case it answers: `CourierWeb.Plugs.Principal.resolver/0` defaults to it, so a
# deployment whose configuration lost this line locks rather than opens. The
# difference the packet makes is that a locked door is now a state you have to
# configure your way out of rather than the only state there is.
#
# IN EVERY ENVIRONMENT EXCEPT TEST, and the guard is the same one the
# OpenTelemetry block above uses and for the same reason: `runtime.exs` runs AFTER
# `config/test.exs`, so an unguarded line here would replace the suite's
# `HeaderResolver` with the real resolver, and every test in the authorization
# matrix — the ones that assert which account may do what to which endpoint — would
# be asserting against a dial to a service that is not running.
# ---------------------------------------------------------------------------
if config_env() != :test do
  config :courier, :principal, Courier.Principal.Introspection

  # WHERE identity is, and it has a default on purpose.
  #
  # The asymmetry with the token below is the whole decision. A wrong URL is a
  # 503 on every authenticated request: loud, diagnosable, retriable, and it does
  # not stop the process — so making a dependency's address a boot requirement
  # would turn "identity moved" into a stop-the-world upgrade gate for a service
  # that is otherwise fine. `http://identity:4000` is the compose-network name,
  # the same shape as `COURIER_OTEL_ENDPOINT`'s default.
  config :courier,
         :identity_url,
         System.get_env("COURIER_IDENTITY_URL", "http://identity:4000")
end

if config_env() == :prod do
  # courier's OWN credential for asking identity about callers, and it is
  # **required**. A scoped API token, minted by an operator in an identity
  # account that belongs to courier and to nothing else:
  #
  #     POST /v1/accounts/{account_id}/api-keys
  #
  # Rotation is identity's, and it is three steps rather than a feature: mint a
  # new key, redeploy with the new value, revoke the old one. There is no cache
  # to invalidate — see `Courier.Principal.Introspection`'s moduledoc for why
  # there is not one, which is a security property and not an oversight.
  #
  # IT IS A SECRET AND IT IS HERE, not in `config/config.exs`: a committed
  # credential is a credential in git, and every deployment which forgot to set
  # one would authenticate callers with it.
  #
  # Required rather than defaulted, for the same reason `COURIER_SECRET_BOX_KEY`
  # above is: unset, courier cannot authenticate anybody, and a courier that
  # cannot authenticate anybody is a service that cannot serve — which is the
  # state this whole packet exists to end. Discovering it at boot is the cheapest
  # possible way to find out, and it happens before the first customer request
  # rather than after a support ticket.
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

# The From address of every transactional email is deployment configuration:
# an operator sets MAIL_FROM / MAIL_FROM_NAME and redeploys, nobody commits a
# changed address. Subjects stay in config/config.exs — they are product copy,
# not infrastructure. Reading the address from the environment here (rather than
# in `Courier.Mailers`) is deliberate: runtime.exs runs once at boot.
#
# This block, and the adapter below it, are prod-only on purpose. runtime.exs
# runs in every environment *after* the env-specific files, so anything set
# outside `if config_env() == :prod` here would silently override test.exs — and
# a developer's stray MAIL_FROM would change what `mix test` mails.
if config_env() == :prod do
  mailing = Application.get_env(:courier, :mailing, [])
  {from_name, from_address} = mailing[:from]

  config :courier,
         :mailing,
         Keyword.merge(mailing,
           from:
             {System.get_env("MAIL_FROM_NAME", from_name),
              System.get_env("MAIL_FROM", from_address)}
         )

  # THE PROVIDER ADAPTER, and the refusal is the point.
  #
  # This line used to be:
  #
  #     config :courier, Courier.Mailer, adapter: Swoosh.Adapters.Local
  #
  # which is the failure this packet exists to end. `Local` renders a message
  # into memory and returns a provider-shaped id without opening a socket, so a
  # released courier accepted every send, recorded an outbox row for each one,
  # published a `delivered` event, and mailed nobody. No error and no warning —
  # the worst failure a paid product can have, because it looks like it works.
  #
  # What replaced it is `Courier.MailerAdapter.adapter!/1`, which reads
  # COURIER_MAIL_ADAPTER and the COURIER_SMTP_* variables and RAISES if they are
  # unset, if they name an adapter courier does not ship, or if they name one
  # that cannot deliver. A raise here stops the boot. `Courier.Application`
  # re-checks the resolved adapter as a second, independent gate.
  #
  # Nothing is defaulted. An adapter with a default is an adapter that is wrong
  # for exactly the deployments nobody is watching, and a required setting is the
  # only version of this that cannot be forgotten.
  #
  # Bound to a variable and called ONCE: `adapter!/1` raises on a misconfigured
  # deployment, and calling it twice would mean a boot that raised after the
  # config had already been applied — leaving the process half-configured rather
  # than cleanly stopped.
  mailer_adapter = Courier.MailerAdapter.adapter!(:prod)

  config :courier, Courier.Mailer, mailer_adapter

  # The one startup line an operator reads to confirm which relay courier is
  # pointed at. It names the host, the port and whether auth is on — never the
  # username and never the password, because at SMTP a "username" is very often
  # the API key. See `Courier.MailerAdapter.describe/1` and the credential tests
  # that assert the absence rather than trusting this comment.
  require Logger

  Logger.info("mailer: #{Courier.MailerAdapter.describe(mailer_adapter)}")

  # The key every webhook signing secret is sealed under (`Courier.SecretBox`).
  # It is required rather than defaulted, because a default would be a key in
  # version control and every deployment that forgot to set one would seal its
  # customers' credentials under it. 32 bytes, base64:
  #
  #     openssl rand -base64 32
  #
  # Rotating it means every stored secret has to be re-sealed under the new key,
  # which is why it is a deployment concern and not a courier feature: see
  # `Courier.SecretBox` for the consequences of losing it.
  config :courier,
         :secret_box_key,
         System.get_env("COURIER_SECRET_BOX_KEY") ||
           raise("""
           environment variable COURIER_SECRET_BOX_KEY is missing.

           It is the 32-byte key every webhook signing secret is sealed under.
           Generate one with: openssl rand -base64 32
           """)

  # The signing secrets courier VERIFIES inbound provider webhooks with, and the
  # refusal is the point — see `Courier.InboundConfig` for the argument.
  #
  # One variable per provider, named for the provider. A single shared variable
  # would make adding a second provider an edit to the first one's configuration,
  # and a deployment one keystroke from verifying Postmark's traffic with
  # Resend's key.
  #
  # NOT the outbound secret. Those are generated by courier per endpoint, sealed
  # under `COURIER_SECRET_BOX_KEY` and stored in the database; this one is
  # generated by the PROVIDER and pasted here, and the two are for opposite
  # directions. A deployment that leaked a customer's outbound signing secret
  # through it must not thereby be able to forge inbound suppressions.
  #
  # Required rather than defaulted, and the reason is specific rather than
  # general. Unset, `Courier.Inbound.Signature.verify/4` refuses every request and
  # every hard bounce and every complaint is DISCARDED — while `POST /v1/messages`
  # goes on mailing addresses that have permanently refused them, and a sending
  # domain's reputation dies of a cause no dashboard names. A default would be
  # worse: a secret in version control that every deployment which forgot to set
  # one would accept forged suppressions under.
  #
  # In Resend's dashboard this is the webhook endpoint's **Signing Secret**,
  # copied from the endpoint's page. It is a Svix secret and carries the `whsec_`
  # prefix, which `Courier.Inbound.Signature` requires — a bare base64 key is
  # `:invalid_secret` and the route answers 500 naming this variable.
  #
  # The `%{…}` and the **string** key are both deliberate, and each for a reason a
  # test holds. `Courier.InboundConfigTest` asserts the stored shape, because
  # neither difference is visible in a config file and both are total in
  # production:
  #
  #   * `config :courier, :inbound_secrets, resend: "…"` — the keyword shorthand
  #     — stores a **keyword list**, and `Application.get_env/2` hands that back
  #     looking nothing like the map the lookup reads. The route would raise
  #     `BadMapError` on the request path, which is the one place that must never
  #     raise: its whole vocabulary is a 401, a 400, a 422 and a 500.
  #   * the key is a **string** because the lookup key comes from the request's
  #     path. An atom there would be `String.to_existing_atom/1` on the request
  #     path of a route, and with `to_atom/1` an unbounded atom table fed by
  #     whoever finds the URL.
  config :courier, :inbound_secrets, %{
    "resend" =>
      System.get_env("COURIER_INBOUND_RESEND_SECRET") ||
        raise("""
        environment variable COURIER_INBOUND_RESEND_SECRET is missing.

        It is the signing secret courier verifies inbound webhooks WITH, copied
        from the provider's dashboard (Resend: the webhook endpoint's Signing
        Secret). It is not the secret courier signs outbound deliveries with.

        Unset, courier refuses every inbound report, so a hard bounce or a spam
        complaint is discarded and courier goes on mailing an address that has
        said it is gone. See Courier.InboundConfig.
        """)
  }

  require Logger

  # Which inbound surfaces are live, and never the secrets themselves — the same
  # rule as the mailer line above, and for a sharper reason: the inbound secret IS
  # the key.
  Logger.info(
    "inbound: verifying #{Enum.join(Courier.InboundConfig.configured_providers(), ", ")}"
  )
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :courier, Courier.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # THE OWNER, FOR `bin/migrate` AND NOTHING ELSE.
  #
  # `DATABASE_URL` above names `courier_app` — the app login role, which owns
  # nothing and is a subject of the row-level-security policies. A migration is
  # DDL, and `courier_app` cannot run one, so `rel/overlays/bin/migrate` needs the
  # OWNER's DSN. This is a separate variable rather than a flag on
  # `DATABASE_URL` because one variable cannot be two credentials, and the release
  # reads `DATABASE_URL` to start the application.
  #
  # NOT REQUIRED AT BOOT, and deliberately: the running application never needs
  # it, and a service that refuses to start because a *migration* credential is
  # missing has turned an incomplete deploy into an outage. `bin/migrate` is the
  # thing that fails instead, and it fails by name. That asymmetry is the point
  # — a boot refusal here would take down a healthy release over a credential
  # nothing in the request path reads.
  #
  # `Courier.OwnerRepo` is not in `:ecto_repos` and not in the supervision tree,
  # so no running process holds a connection that bypasses every policy courier
  # installs. See that module.
  if owner_database_url = System.get_env("COURIER_OWNER_DATABASE_URL") do
    config :courier, Courier.OwnerRepo,
      url: owner_database_url,
      priv: "priv/repo",
      socket_options: maybe_ipv6
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :courier, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # ---------------------------------------------------------------------------
  # Error reporting and the error relay. Both are read here, out of the
  # environment, and **neither is required** — see the reasoning, because a
  # required-looking omission is the thing that surprises an operator.
  #
  # `COURIER_ERROR_REPORTING_DSN` — courier's **own** failures, to its own relay.
  # Unset, courier does not report its own errors and says nothing at boot; that
  # is a diagnosable state (`ErrorReporting.enabled?/0` is false, and
  # `Courier.ErrorRelay.stats/1` shows `forwarded: 0` with nothing arriving
  # anywhere). It is not required because the error store is an *observability*
  # control, and a courier that refuses to boot because its error store is
  # unreachable has turned a missing integration into an outage — see
  # `Courier.ErrorRelay.Sink.Noop`, which documents the same decision at length.
  #
  # `COURIER_ERROR_RELAY_TOKEN` — the shared secret on the **ingest** surface,
  # and this one **is** required, because with no token the surface has no way to
  # tell a service from anybody else, and a default would be a shared secret in
  # version control that every deployment which forgot to set one would accept
  # error reports from. The same rule as `COURIER_SECRET_BOX_KEY` above, and for
  # the same reason: a default is a key in git.
  #
  # `COURIER_ERROR_SINK_DSN` — the relay's own destination, a GlitchTip DSN. This
  # is a **credential** (it carries the project's public ingest key) and is never
  # logged: `Courier.ErrorRelay.Sink.Req` parses it at boot and every refusal it
  # reports is a symbol. Unset, the relay runs with `Sink.Noop` and counts what it
  # discards, which is the same diagnosable-not-fatal shape as above.
  #
  # `COURIER_RELEASE` and `DEPLOYMENT_ENVIRONMENT` are **not** invented here. The
  # release is the build's own identity and the environment is deployment
  # configuration; an operator sets them, and the same value has to reach the
  # traces, so it is read once and stamped on both. Auto-resolution on deploy
  # (GlitchTip resolves an issue when a release that contains the fix ships) is
  # the reason the release is on the event at all: without it the store has no way
  # to know a crash stopped, and an issue stays open for ever.
  # ---------------------------------------------------------------------------
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

    # The SDK's own configuration, and the DSN is courier's **relay** and not a
    # third party. `before_send` is the second redaction barrier and it is what
    # makes a DSN misconfiguration survivable: see
    # `Courier.ErrorReporting.Filter`, whose moduledoc is the argument.
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

  if is_nil(error_relay_token) do
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
    # A burst of five then one per class per minute. The defaults are small on
    # purpose: Sentry does not sample errors by design, so this is the volume
    # control the SDK deliberately does not provide, and the same numbers are set
    # in each of the three services so one config file describes the fleet.
    burst: 5,
    per_minute: 60,
    capacity: 4_096,
    queue_size: 256

  config :courier, CourierWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :courier, CourierWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :courier, CourierWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
