defmodule Courier.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The SECOND gate on the provider adapter, and it is deliberately not a
    # re-run of the first.
    #
    # `config/runtime.exs` resolves the adapter from the environment and raises
    # on an unset or silent one. That gate runs first and, in this tree, is
    # sufficient on its own — being honest about that is the point, because a
    # comment claiming this gate catches more than it does would be the same
    # sin as an overclaimed test.
    #
    # What it adds is that it reads the EFFECTIVE configuration
    # (`Application.get_env/2`) rather than the environment. So it is no longer
    # checking an intention, it is checking what courier will actually send
    # through, and it holds when the first gate is bypassed or removed:
    #
    #   * `config/runtime.exs` edited to name `Swoosh.Adapters.Local` directly —
    #     one line, no environment variable, and the previous state of this
    #     repository was exactly that;
    #   * any future path that configures the mailer without going through
    #     `Courier.MailerAdapter` — a release overlay, a runtime config hook, a
    #     generator. This gate does not care where the value came from.
    #
    # Re-checking the environment twice would catch nothing this does not.
    Courier.MailerAdapter.verify_boot!()

    # The bus's own startup line, and the two halves are on the same terms as
    # `Courier.MailerAdapter`'s: what the setting is, never a credential. On the
    # no-broker half it says what accumulates rather than failing quietly into a
    # publisher nobody configured.
    Courier.Nats.log_startup()

    # One line, and only ever on the DISABLED path. It is here rather than in
    # `config/runtime.exs` because configuration cannot log into the store an
    # operator reads. See Courier.Telemetry for the contract this reports on.
    Courier.Telemetry.log_startup()

    # The operator-facing notices `config/runtime.exs` COMPOSED — the resolved
    # mail adapter and, when it is missing, the cost of an unconfigured inbound
    # surface. They cannot be logged there for the same reason as the two lines
    # above: the release's boot script evaluates that file BEFORE `:logger` is
    # up, so a `Logger.*` call in it has no handler and is dropped silently —
    # measured, 0 of 544 lines on a box that had been serving for days. This is
    # the call that reaches the log. See `Courier.StartupNotices`.
    Courier.StartupNotices.log_startup()

    children = [
      # The request-span instrumentation. A child rather than an endpoint plug
      # because it owns a `:telemetry` handler for the exception path, and a
      # handler attached from a plug's `init/1` is re-attached on every reload.
      Courier.Telemetry,
      Courier.Repo,
      # The connection to the event bus, and an EMPTY LIST when `NATS_URL` is not
      # set — so a courier with no broker holds no socket, starts no retry loop
      # and marks nothing published. See `Courier.Nats.supervised_child/0` for why
      # this is a list and not a child the supervisor ignores, which Elixir 1.20
      # refuses; the publisher is `Courier.NatsPublisher.Bus`, configured by
      # `config/runtime.exs` on the same condition.
      Courier.Nats.supervised_child(),
      # The subscription that fills `consumed_events` — the consumer's
      # delivery half, and the piece that turns the bus from one-ended into a
      # loop. It is a LIST on the same terms as the connection above: a
      # courier with no `NATS_URL` holds no subscription and starts no
      # process, which is the same harness `not_wired_test.exs` kept before
      # this packet — the difference is that the harness now exists rather
      # than being the whole story. AFTER the connection, because it asks
      # that process for the connection it subscribes on.
      Courier.Consumers.Subscriber.supervised_child(),
      {DNSCluster, query: Application.get_env(:courier, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Courier.PubSub},
      # courier's only queue: the outbox relay. It needs the repo, so it comes
      # after it, and in test it runs in `:manual` mode (config/test.exs) —
      # jobs land in the database and nothing executes in the background, which
      # is what keeps the Ecto sandbox usable.
      {Oban, Application.fetch_env!(:courier, Oban)},
      # The error relay: the fleet's single redaction chokepoint for the error
      # path, and the sink to GlitchTip behind it.
      #
      # After `Oban` and before either endpoint, and the order is not
      # incidental. Another service can report an error while the relay is still
      # starting, and that report is a POST arriving at a listener which is not
      # up yet — a dropped envelope, counted by the sender, invisible in courier.
      # Starting the relay first closes the window rather than narrowing it.
      #
      # It needs no database, which is the point: `Courier.ErrorRelay` opens no
      # `Repo` and adds no migration, so the error store is GlitchTip's own
      # Postgres and nothing about a store outage can reach `Courier.Repo`.
      # `CourierWeb.ErrorReportingTest` asserts the migration list is unchanged,
      # because "we added no table" is otherwise a claim that is only true by
      # inspection.
      {Courier.ErrorRelay, relay_child_spec()},
      # To serve requests: the customer API, and then the error endpoint on
      # its own port. See `CourierWeb.ErrorEndpoint` for why the ingest
      # surface is a separate listener rather than a route on the first one.
      #
      # Both after the relay, so a report arriving during startup finds a relay
      # already listening rather than a connection to a closed port.
      CourierWeb.Endpoint,
      CourierWeb.ErrorEndpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Courier.Supervisor]

    # Flattened, so the one conditional entry in the list is a list rather than a
    # nested list the supervisor would take for a child.
    Supervisor.start_link(List.flatten(children), opts)
  end

  # The relay reads its own options rather than the whole application env, so a
  # test can start one with a recording sink and a different throttle without
  # changing what the running relay was told. `config/runtime.exs` builds the same
  # shape in prod, out of the environment.
  defp relay_child_spec do
    :courier
    |> Application.get_env(:error_relay, [])
    |> Keyword.put_new(:name, Courier.ErrorRelay)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CourierWeb.Endpoint.config_change(changed, removed)
    CourierWeb.ErrorEndpoint.config_change(changed, removed)
    :ok
  end
end
