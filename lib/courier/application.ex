defmodule Courier.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Courier.MailerAdapter.verify_boot!()

    Courier.Nats.log_startup()

    Courier.Telemetry.log_startup()

    CourierWeb.MetricsExporter.setup()

    Courier.StartupNotices.log_startup()

    children = [
      Courier.Telemetry,
      Courier.Repo,
      Courier.Nats.supervised_child(),
      Courier.Consumers.Subscriber.supervised_child(),
      {DNSCluster, query: Application.get_env(:courier, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Courier.PubSub},
      {Oban, Application.fetch_env!(:courier, Oban)},
      {Courier.ErrorRelay, relay_child_spec()},
      CourierWeb.Endpoint,
      CourierWeb.ErrorEndpoint
    ]

    opts = [strategy: :one_for_one, name: Courier.Supervisor]

    result = Supervisor.start_link(List.flatten(children), opts)

    case result do
      {:ok, _pid} -> Courier.NotificationTypes.seed_defaults()
      _ -> :ok
    end

    result
  end

  defp relay_child_spec do
    :courier
    |> Application.get_env(:error_relay, [])
    |> Keyword.put_new(:name, Courier.ErrorRelay)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CourierWeb.Endpoint.config_change(changed, removed)
    CourierWeb.ErrorEndpoint.config_change(changed, removed)
    :ok
  end
end
