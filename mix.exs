defmodule Courier.MixProject do
  use Mix.Project

  def project do
    [
      app: :courier,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # MIT, and the `files:` list is what makes the grant travel. Without a
      # `package` block Hex refuses to publish, and without `files:` the LICENSE
      # file is not in the tarball even once it can — so the licence would be a
      # fact about the repository and not about the package a consumer installs.
      # MIT is fleet-wide: the platforms are consumed as a dependency graph
      # through a service registry, and copyleft would make every downstream
      # consumer inherit an obligation, which defeats the registry model.
      package: package(),
      # The coverage tool, named here rather than discovered at run time.
      # `mix test --cover` writes `cover/` and enforces nothing; this is what
      # makes `mix coveralls --minimum-coverage` work, which is the command both
      # this repository's CI gate and kit's shared Elixir job run.
      test_coverage: [tool: ExCoveralls],
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # The Hex package metadata.
  #
  # `licenses:` is the SPDX identifier and `files:` is the list that goes into
  # the tarball. Both are needed and neither is implied by the other: `licenses:`
  # without `files:` publishes a package carrying no licence text at all, which
  # is the state this whole change exists to end.
  #
  # `LICENSE` is in `files:` explicitly rather than by glob. A glob that stopped
  # matching would publish successfully and quietly drop the grant, and a licence
  # that goes missing at publish time is the one failure mode here that nothing
  # else would catch.
  defp package do
    [
      licenses: ["MIT"],
      files: [
        "lib",
        "priv",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        ".formatter.exs"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Courier.Application, []},
      # `:opentelemetry` is here because the SDK is an OTP application started by
      # the application controller, and it has to be started before
      # `Courier.Application.start/2` for its configuration (in
      # `config/runtime.exs`) to take effect. Adding it to `applications` instead
      # would start it after courier's own supervisor and the exporter would never
      # be built.
      extra_applications: [:logger, :runtime_tools, :opentelemetry]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # OpenTelemetry. The trace SDK and the OTLP exporter, and the reason each is
      # named here is in lib/courier/telemetry.ex: without them courier has no way
      # to emit a span at all, and kit's collector has nothing to redact.
      #
      # `only: [:dev, :test, :prod]` is deliberately not a restriction — it is
      # every environment courier has. The exporter is a real dependency in every
      # one because `<SERVICE>_OTEL_ENDPOINT` is ON BY DEFAULT (core D16): a
      # developer running `mix phx.server` exports into the collector that ships
      # with the stack, and that is the whole of "a deployer gets traces without
      # assembling them". Gating the exporter to :prod would make the default a
      # no-op everywhere it is actually used, which is backwards.
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Transactional email. `swoosh` is courier's mail composition and delivery
      # pipeline; `gen_smtp` is the socket `Swoosh.Adapters.SMTP` actually speaks
      # through, and swoosh declares it OPTIONAL, so naming swoosh alone compiles a
      # courier that has no provider adapter that can reach a provider at all.
      # That was the state before this packet: `Courier.Mailer` existed, the
      # Local adapter was configured in prod, and nothing was declared that could
      # open a connection — see lib/courier/mailer_adapter.ex.
      #
      # `gen_smtp` is in EVERY environment, and test is where it earns that: the
      # suite drives real sends through a real SMTP conversation on a real socket
      # (test/support/smtp_server.ex). An adapter that is `only: :prod` is an
      # adapter no test can exercise, which is the same silent default wearing a
      # different hat.
      {:swoosh, "~> 1.28"},
      {:gen_smtp, "~> 1.0"},
      {:oban, "~> 2.24"},
      # Webhook delivery needs an HTTP client. Req is the one this repository's own
      # generated rules name as preferred ("Use the already included and available
      # `:req` (`Req`) library for HTTP requests, avoid `:httpoison`, `:tesla`, and
      # `:httpc`"), so the webhook pipeline uses it rather than `:httpc` from OTP or
      # a second client library.
      {:req, "~> 0.5"},
      # Error reporting. The `sentry` hex package, which is the Sentry-protocol
      # client for Elixir and is **MIT** — verified at
      # `https://github.com/getsentry/sentry-elixir` (LICENSE: "The MIT License
      # (MIT)") and in the package's own `metadata.config`
      # (`{<<"licenses">>,[<<"MIT">>]}` in the 13.5.1 tarball). It is the client
      # library, not a server: it speaks the Sentry envelope protocol, and this
      # deployment points it at courier's own relay rather than at anybody's
      # SaaS. That distinction is the whole reason the licence question is clean
      # — Sentry's *server* is FSL-1.1-Apache-2.0 and is disqualified for a
      # commercial hosted offering, while the SDKs are permissively licensed and
      # are what this dependency is.
      #
      # Declared for **all** environments, unlike `excoveralls` below, and the
      # reason is the test requirement rather than tidiness: "reporting is off in
      # test" has to be a fact this repository can assert, and a dep that is not
      # in the test environment cannot be asserted about at all. What is off in
      # test is the *configuration* — `config/test.exs` sets no DSN and
      # `Courier.ErrorReporting.enabled?/0` is false — not the code being
      # compiled.
      {:sentry, "~> 13.5"},
      # `mix coveralls` — the coverage gate kit's shared Elixir job runs, and the
      # one this repository's own CI job runs. Two things about it are load
      # bearing and neither is guessable:
      #
      #   - The task ships in **excoveralls**. The hex package named `coveralls`
      #     is the Erlang one and has no Mix task at all, so declaring that
      #     leaves the gate dying on "the task coveralls could not be found".
      #   - `dev` is in the list on purpose. The job fetches dependencies with a
      #     plain `mix deps.get` (development) and then runs `mix coveralls`,
      #     which is `@preferred_cli_env :test`. A dep that is only in `:test` is
      #     never fetched by the first command, and the second one fails on a
      #     missing dependency rather than on a coverage number.
      #
      # `runtime: false`, and no `:prod`, so a measurement tool is neither
      # started nor shipped in the release.
      {:excoveralls, "~> 0.18.5", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  # TWO CREDENTIALS, SO EVERY TASK THAT NEEDS PRIVILEGES NAMES THE ONE THAT HAS
  # THEM. `Courier.Repo` is `courier_app` — the app login role, which owns nothing
  # and cannot create a database or a table — and `Courier.OwnerRepo` is the
  # owner. Each `ecto.*` task below says which.
  #
  # `-r Courier.OwnerRepo` is load-bearing on all of them, and the `test` alias is
  # where it matters most: create and migrate run as the owner, then **the suite
  # itself runs as `courier_app`**, because `test` starts the application and the
  # application starts `Courier.Repo`. That is what makes a green suite evidence
  # about the account boundary rather than about a superuser's exemptions.
  #
  # The version this replaces ran every one of these as `postgres`, which is a
  # superuser, and a superuser bypasses RLS whatever `force row level security`
  # says — see `Courier.Tenancy`'s moduledoc for the measurement.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": [
        "ecto.create -r Courier.OwnerRepo",
        "ecto.migrate -r Courier.OwnerRepo",
        "run priv/repo/seeds.exs"
      ],
      "ecto.reset": ["ecto.drop -r Courier.OwnerRepo", "ecto.setup"],
      # A developer typing `mix ecto.migrate` gets the OWNER because otherwise the
      # obvious command is the one that fails with a permission error naming a
      # role they have never heard of. There is deliberately no `ecto.migrate`
      # alias: an alias of the same name as a Mix task recurses, and the fix for
      # that is not worth the indirection.
      "ecto.migrate.owner": ["ecto.migrate -r Courier.OwnerRepo"],
      test: [
        "ecto.create --quiet -r Courier.OwnerRepo",
        "ecto.migrate --quiet -r Courier.OwnerRepo",
        "test"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
