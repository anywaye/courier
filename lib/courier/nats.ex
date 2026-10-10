defmodule Courier.Nats do
  @moduledoc """
  The connection to the event bus, and the only process that holds one.

  This is the shape identity's `cmd/identity/main.go:474-485` gives its broker:
  the connection is a process in the application's own supervision tree, so a
  shutdown cancels it, and **it exists only while `NATS_URL` does**
  (`supervised_child/0` answers `:ignored` otherwise). A courier with no broker
  configured holds no socket, opens no retry loop and marks nothing published,
  which is the honest accumulation identity's comment describes rather than the
  dark loop this packet is undoing.

  ## Why this is a wrapper and not `{Gnat, …}` in the child list

  Because `Gnat.start_link/1` is a `GenServer` whose `init/1` connects *inline*
  and answers `{:stop, reason}` when the broker is not there. Under a
  `:one_for_one` supervisor that is a boot failure, and identity's design is
  explicit that it must not be one:

      A broker that is DOWN when this runs is not a boot failure […] publishes
      made while it is down fail, the loop marks those rows failed, and the next
      pass retries them.

  The whole outbox exists so that "the state changed and nobody was told" is
  impossible, and a courier that refuses to start because the bus is briefly
  unreachable has coupled every request path to the bus's availability. So this
  process is what the supervisor owns: it dials the broker, records failure,
  and retries on a fixed interval without ever taking the application down.
  Rows stay claimable in the meantime and `Courier.NatsPublisher.Bus` refuses
  each publish with `{:error, :not_connected}` — which is what
  `Courier.Workers.ProcessOutboxWorker` records in `last_error`, leaving
  `published_at` alone.

  ## What it does not do

  It does not publish. `Courier.NatsPublisher.Bus` is the publisher; this is the
  connection it publishes through, and the split is deliberate — a publish needs
  a per-call budget and an ack to read, and a connection needs a lifecycle. One
  module holding both would make the retry loop the publisher's problem.

  It does not authenticate. kit's broker carries no credentials
  (`templates/substrate/manifests/data/nats.yaml`: "NATS carries no credentials
  on this substrate […] one box, the packet's explicit non-goal"), so there is no
  user, no password and no nkey to configure here. gnat accepts them if a future
  broker requires them, from this module's map and from nowhere else.
  """

  use GenServer

  require Logger

  # Every five seconds while the broker is away. Fixed rather than growing: the
  # event that arrives while the broker is down should not have to wait longer
  # the longer the broker has been away, and identity's outbox comment makes the
  # same argument about idle polling. The cost is one connect attempt every five
  # seconds, which is nothing against a broker nobody is watching.
  @reconnect_interval 5_000

  # The dial itself. gnat's `connection_timeout` bounds the TCP connect, and a
  # broker that accepts and then says nothing is bounded by gnat's own
  # one-second wait for `INFO` rather than by this.
  @connection_timeout 2_000

  defstruct [:settings, :connection, :last_error, :logged_failure]

  @doc """
  The broker `NATS_URL` names, or `nil` when it names none.

  Read from `config :courier, :nats`, which `config/runtime.exs` builds out of
  the environment. An empty string is treated as unset: `NATS_URL=` in a compose
  file produces `""`, and a URL that is present and empty is not present.
  """
  @spec url() :: String.t() | nil
  def url do
    case Application.get_env(:courier, :nats, [])[:url] do
      url when is_binary(url) -> if(String.trim(url) == "", do: nil, else: url)
      nil -> nil
    end
  end

  @doc """
  Whether a broker is configured — the whole of the boot-time condition.

  False means the application starts no connection, no relay of its own, and
  configures a publisher that refuses. `Courier.NatsPublisher.Unconfigured` is
  that refusal, and it is what keeps rows unpublished rather than draining them
  into nowhere.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(url())

  @doc """
  The child this module puts in the application's supervision tree, or nothing.

  A **list**, on purpose: the no-broker shape has to be an empty entry in the
  tree rather than a branch somewhere that has to remember not to add one, and
  Elixir's supervisor takes a bare atom as a module name — `:ignored` reaches
  `Supervisor.init_child/1` and is refused with "the module :ignored was given as
  a child to a supervisor but it does not exist". So the condition is bifurcated
  into an empty list, and `children ++ Courier.Nats.supervised_child()` is the one
  place the branch is read.
  """
  @spec supervised_child() :: [Supervisor.child_spec()]
  def supervised_child do
    if enabled?(), do: [child_spec([])], else: []
  end

  @doc """
  `{:ok, pid}` for a live connection, or `{:error, reason}` for one that is not
  there.

  Never raises, and that is a property rather than a hope: the caller is the
  relay's publisher, and a publisher that raises has turned an unreachable broker
  into a stuck queue. A `GenServer.call/3` to a name with no process exits, so
  the exit is caught here — where "not connected" is a meaningful answer — rather
  than left for the relay to discover.
  """
  @spec connection() :: {:ok, GenServer.server()} | {:error, :not_connected}
  def connection do
    try do
      GenServer.call(__MODULE__, :connection)
    catch
      :exit, _reason -> {:error, :not_connected}
    end
  end

  @doc "Starts the connection process, which is a supervised child or nothing."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The one line an operator reads to learn which half of the bus courier has.

  On the same terms as `Courier.MailerAdapter.describe/1`: what the setting is,
  never a credential. `NATS_URL` carries none on this substrate, but a future
  one could — and a startup line is not where a password belongs.
  """
  @spec log_startup() :: :ok
  def log_startup do
    Logger.info(
      if enabled?(),
        do: "bus: publishing to #{url()}",
        else:
          "bus: NATS_URL is not set; no connection is started and events will " <>
            "accumulate in outbox_events until a broker is configured"
    )
  end

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # A URL that does not parse is a boot failure, and `{:stop, _}` is the shape
    # GenServer gives it: the supervisor reports the child as refused to start,
    # which is a boot failure an operator reads. It is NOT a raise in `init/1`,
    # because a raise there escapes `start_link/1` as an exit signal in the
    # caller and takes out whatever asked for the connection — measured, and the
    # opposite of what a boot refusal is supposed to do.
    case connection_settings() do
      {:ok, settings} -> {:ok, %__MODULE__{settings: settings}, {:continue, :connect}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  @impl GenServer
  def handle_call(:connection, _from, state) do
    {:reply, answer(state), state}
  end

  @impl GenServer
  def handle_info(:retry, state) do
    {:noreply, connect(%{state | connection: nil})}
  end

  # The connection we owned died. Same answer as a dial the broker refused: back
  # to unconnected, one warning, one timer.
  @impl GenServer
  def handle_info({:EXIT, pid, reason}, state)
      when is_pid(state.connection) and pid == state.connection do
    unless state.logged_failure do
      Logger.warning(
        "bus: the connection to #{url()} went away (#{inspect(reason)}); " <>
          "it will be re-established on the next pass"
      )
    end

    Process.send_after(self(), :retry, @reconnect_interval)
    {:noreply, %{state | connection: nil, logged_failure: true}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Anything else — a socket closing under a connection we own, gnat's own
  # crash — is answered by nothing and survived. A process that dies on a broker
  # outage is a process the supervisor has to restart, and a restart storm during
  # an outage is the same outage with more log lines.
  @impl GenServer
  def handle_info(_message, state), do: {:noreply, state}

  # The gnat connection is stopped here rather than left to the supervisor's
  # shutdown, because a supervisor stopping a child stops the process running
  # this module and whatever it spawned is orphaned. That is the "shutdown
  # cancels it" identity ties its loop to the process context for.
  @impl GenServer
  def terminate(_reason, %{connection: connection}) when is_pid(connection) do
    GenServer.stop(connection, :normal, 5_000)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp answer(%__MODULE__{connection: nil}), do: {:error, :not_connected}
  defp answer(%__MODULE__{connection: pid}), do: {:ok, pid}

  # The connection process traps exits, and that is the whole of the resilience.
  #
  # Without it a gnat connection that dies takes this process with it (it is
  # linked), which takes the application with it, which is a broker outage
  # presented as a courier outage — measured: `** (EXIT from #PID<0.541.0>)
  # :econnrefused` killed the process that started the connection.
  #
  # With it, the exit is a message this module answers: the connection goes back
  # to `nil`, one warning is logged, and the same fixed retry timer that handles
  # a dial the broker refused picks the broker back up when it returns. Rows stay
  # claimable throughout, which is the entire point of publishing from a table.
  # The dial, and the branch that makes this module worth having.
  #
  # On failure the connection stays `nil` and a retry is scheduled. The state
  # keeps `logged_failure` so the reason is logged once rather than on every
  # five-second pass: an operator needs to know the broker is away, not to be
  # told forty times a minute.
  defp connect(%__MODULE__{settings: settings} = state) do
    case dial(settings) do
      {:ok, pid} ->
        # Linked, and trapped: see `init/1`. A connection that dies here is a
        # message this process answers rather than a signal that takes it down.
        if state.logged_failure do
          Logger.info("bus: connected to #{url()}")
        end

        %{state | connection: pid, logged_failure: false}

      {:error, reason} ->
        unless state.logged_failure do
          Logger.warning(
            "bus: could not connect to #{url()} (#{inspect(reason)}); events will " <>
              "stay in outbox_events and publish when the broker returns"
          )
        end

        Process.send_after(self(), :retry, @reconnect_interval)

        %{state | connection: nil, logged_failure: true}
    end
  end

  # The dial, and the `try/catch` that makes a refusing broker a refusal rather
  # than a crash.
  #
  # `Gnat.start_link/1` answers `{:error, reason}` when the connect is refused,
  # and it is not guaranteed to: a client whose `init/1` terminates abnormally
  # takes the linked caller with it. Both are a broker that is away, and neither
  # may take this process — or whatever asked it for a connection — down. So an
  # exit is caught and answered, which is the same answer `{:error, _}` gets.
  defp dial(settings) do
    try do
      Gnat.start_link(settings)
    catch
      :exit, reason -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  # `NATS_URL` parsed into gnat's own connection settings.
  #
  # A URL that does not parse is a boot failure, and it is answered as
  # `{:error, {:nats_url_does_not_name_a_broker, url}}` rather than raised —
  # identity refuses one for the same reason ("a typo is a deployment that
  # believes it has a bus and does not, and that belongs at boot where an operator
  # reads it, not at the first event where nobody does"), and `{:stop, _}` from
  # `init/1` is the shape GenServer gives a boot refusal.
  defp connection_settings do
    uri = URI.parse(url() || "")

    if uri.scheme in ~w(nats tls) do
      host = uri.host || "localhost"

      {:ok,
       %{
         host: host,
         port: uri.port || 4222,
         tls: uri.scheme == "tls",
         tcp_opts: [:binary],
         # The default is 3s, which is a long time for a supervisor to be blocked
         # on a dial when the same dial is retried on a timer anyway.
         connection_timeout: @connection_timeout,
         # What the monitoring endpoint reports this connection as. It is the
         # service, not the event type: a broker operator reading a connection
         # list wants to know who is connected, and the events are already named
         # by their subjects.
         name: "courier"
       }
       |> maybe_inbox_prefix()}
    else
      {:error, {:nats_url_does_not_name_a_broker, url()}}
    end
  end

  defp maybe_inbox_prefix(settings) do
    case Application.get_env(:courier, :nats, [])[:inbox_prefix] do
      nil -> settings
      inbox -> Map.put(settings, :inbox_prefix, inbox)
    end
  end
end
