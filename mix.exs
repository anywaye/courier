defmodule Courier.MixProject do
  use Mix.Project

  def project do
    [
      app: :courier,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Courier's licence is the Business Source License 1.1 — see LICENSE. It
      # replaced a closed "all rights reserved" grant that allowed nothing
      # beyond viewing (OPS-D2), and it is not an open-source licence: BSL's
      # own Notice says so. So `package/0` now names `licenses:` as `BUSL-1.1`,
      # the SPDX identifier for it. Without a `package` block Hex refuses to
      # publish, and without `files:` the LICENSE file is not in the tarball
      # even once it can — so the notice would be a fact about the repository
      # and not about the package a consumer installs.
      package: package(),
      test_coverage: [tool: ExCoveralls],
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # The Hex package metadata.
  #
  # `licenses:` is `BUSL-1.1`, the SPDX identifier for the Business Source
  # License 1.1 that `LICENSE` carries as of OPS-D2. It was absent before on
  # purpose: courier was closed, and an identifier naming a grant the
  # repository did not carry would have been a lie in the metadata a consumer's
  # tooling reads. `files:` is the list that goes into the tarball, and it
  # still carries the LICENSE file, so the licence travels with the package
  # rather than living only in the repository. A BSL is not an open-source
  # licence, and the identifier does not pretend it is.
  #
  # `LICENSE` is in `files:` explicitly rather than by glob. A glob that stopped
  # matching would publish successfully and quietly drop the licence, and a
  # licence that goes missing at publish time is the one failure mode here that
  # nothing else would catch.
  defp package do
    [
      licenses: ["BUSL-1.1"],
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

  def application do
    [
      mod: {Courier.Application, []},
      extra_applications: [:logger, :runtime_tools, :opentelemetry]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.11"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:prometheus_ex, "~> 3.0"},
      {:prometheus_plugs, "~> 1.1"},
      {:swoosh, "~> 1.28"},
      {:gen_smtp, "~> 1.0"},
      {:oban, "~> 2.24"},

      # The event bus client. `Courier.NatsPublisher.Bus` is the half of
      # `Courier.NatsPublisher` that actually reaches the broker, and it needs a
      # NATS client to reach it with: "ack, then mark" is only a rule if some
      # transport can answer.
      #
      # The published alternative is `gnat` (nats.ex), which is **MIT** —
      # verified in the 1.18.1 tarball's own `metadata.config`
      # (`{<<"licenses">>,[<<"MIT">>}`) and in the package's `LICENSE.txt`. It is
      # the Elixir client the fleet's other publisher's design was written
      # against: identity's `internal/outbox/nats.go` uses `nats.go`'s JetStream
      # `PublishMsg`, which blocks until the broker acks, and the reason that
      # matters is `published_at` — see `Courier.NatsPublisher.Bus`.
      #
      # `nkeys` arrives with it as a transitive half of NATS authentication
      # (nkey_seed signing) and of nothing else: it is not a second client, and
      # courier declares no credentials because kit's broker carries none
      # (`templates/substrate/manifests/data/nats.yaml`: "one box, the packet's
      # explicit non-goal").
      #
      # Declared for **every** environment, and test is where it earns that the
      # way `gen_smtp` earned it: `test/support/nats_server.ex` drives real
      # publishes through the real client to a real socket on a kernel-assigned
      # loopback port. A client that is `only: :prod` is a client no test can
      # exercise, which is the same silent default wearing a different hat.
      {:gnat, "~> 1.18"},

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
      {:excoveralls, "~> 0.18.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": [
        "ecto.create -r Courier.OwnerRepo",
        "ecto.migrate -r Courier.OwnerRepo",
        "run priv/repo/seeds.exs"
      ],
      "ecto.reset": ["ecto.drop -r Courier.OwnerRepo", "ecto.setup"],
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
