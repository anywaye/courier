defmodule Courier.ErrorRelay.Sender do
  @moduledoc """
  The bounded queue between the relay's decision and the store's socket.


  Because the two things the brief asks to be true are in tension, and a process
  boundary is what resolves them:

    * a failure in the error path must never **crash** the main request path;
    * a failure in the error path must never **block** it either.

  Calling the sink inline satisfies neither past the first `try`. A sink that
  takes thirty seconds to time out holds the relay for thirty seconds, the
  relay's mailbox grows behind it, and the HTTP endpoint that received the
  envelope — in *another* service — is meanwhile retrying. So the forward happens
  in a supervised `Task` with a deadline, and a sink that overruns it is
  `Task.shutdown(:brutal_kill)`ed and counted.

  A task that hangs forever is a thread that never comes back, and a supervisor
  whose child is killed is a supervisor that is still running. `brutal_kill` is
  the right violence here: the task holds a socket to a store that has already
  stopped answering, and there is nothing in it worth a graceful shutdown.


  The queue holds envelopes that have been **accepted while a forward is already
  in flight**. One forward is in flight at a time, and everything accepted while
  it runs accumulates; when it finishes, the next drain takes the lot. So `size`
  is a bound on work the store has not yet been given, which is the only reading
  under which "full means drop" is a real state rather than a formality — and it
  is why `queue_size: 0` refuses everything, which is how the test that exercises
  the full path reaches it without a slow sink and a sleep.


  A sink that raises and a sink that returns `{:error, _}` both land in
  `sink_failures`. They are not the same problem, but they have the same response
  — the error path is not reaching the store, and nothing inside the request path
  can fix that — and a counter that distinguishes them is a counter somebody has
  to remember to look at. The distinction is in the log level: a raise is logged
  at `:error` with the exception, an error tuple at `:warning`.


  Every clause is wrapped. An error store that crashes itself stops working at
  exactly the moment it is needed, and a sender that could be crashed by a
  malformed envelope would be a sender a service could switch off by sending one.
  """

  use GenServer

  require Logger

  alias Courier.ErrorRelay

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Offer an envelope. A cast, so the relay is never waiting on the store.
  """
  @spec enqueue(GenServer.server(), binary()) :: :ok
  def enqueue(server, envelope) when is_binary(envelope) do
    GenServer.cast(server, {:enqueue, envelope})
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    {:ok, tasks} = Task.Supervisor.start_link(name: :"#{name}.tasks")

    {:ok,
     %{
       relay: Keyword.fetch!(opts, :relay),
       sink: Keyword.fetch!(opts, :sink),
       sink_opts: Keyword.get(opts, :sink_opts, []),
       size: Keyword.get(opts, :size, 256),
       timeout: Keyword.get(opts, :timeout, 5_000),
       queue: %{},
       in_flight: false,
       tasks: tasks
     }}
  end

  @impl GenServer
  def handle_cast({:enqueue, envelope}, state) when is_binary(envelope) do
    if map_size(state.queue) < state.size do
      state
      |> Map.update!(:queue, &Map.put(&1, System.unique_integer([:positive]), envelope))
      |> maybe_drain()
    else
      dropped = ErrorRelay.count_stat(state.relay, :queue_full, 1)

      if dropped == 1 or rem(dropped, 100) == 0 do
        Logger.warning(
          "[error-relay] queue full at #{state.size}, dropped #{dropped} so far. " <>
            "The store is not keeping up with the error path."
        )
      end

      {:noreply, state}
    end
  end

  def handle_cast(:drained, state) do
    maybe_drain(Map.put(state, :in_flight, false))
  end

  def handle_cast(other, state) do
    Logger.error("[error-relay] the sender received an unrecognised cast: #{inspect(other)}")
    {:noreply, state}
  end


  defp maybe_drain(%{in_flight: false, queue: queue} = state) when map_size(queue) > 0 do
    batch = queue

    case drain_async(state, batch, self()) do
      {:ok, _pid} ->
        {:noreply, %{state | queue: %{}, in_flight: true}}

      {:error, reason} ->
        ErrorRelay.count_stat(state.relay, :queue_full, map_size(batch))

        Logger.error(
          "[error-relay] the drain supervisor refused a batch of #{map_size(batch)}: " <>
            inspect(reason)
        )

        {:noreply, %{state | queue: %{}, in_flight: true}}
    end
  end

  defp maybe_drain(state), do: {:noreply, state}

  defp drain_async(state, batch, owner) do
    Task.Supervisor.start_child(state.tasks, fn -> drain(state, batch, owner) end)
  end

  @doc false
  def drain(state, batch, owner) do
    Enum.each(batch, fn {_key, envelope} -> forward(state, envelope) end)

    GenServer.cast(owner, :drained)
    :ok
  end

  defp forward(state, envelope) do
    task =
      Task.async(fn ->
        try do
          state.sink.forward(envelope, state.sink_opts)
        rescue
          exception ->
            Logger.error(
              "[error-relay] the sink raised and the envelope is lost: " <>
                Exception.message(exception)
            )

            :raised
        catch
          kind, reason ->
            Logger.error("[error-relay] the sink exited #{kind}: #{inspect(reason)}")
            :caught
        end
      end)

    case Task.yield(task, state.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("[error-relay] the store refused an envelope: #{inspect(reason)}")
        ErrorRelay.count_stat(state.relay, :sink_failures, 1)
        :ok

      {:exit, reason} ->
        Logger.error("[error-relay] the sink exited: #{inspect(reason)}")
        ErrorRelay.count_stat(state.relay, :sink_failures, 1)
        :ok

      other ->
        Logger.error("[error-relay] the sink did not forward: #{inspect(other)}")
        ErrorRelay.count_stat(state.relay, :sink_failures, 1)
        :ok
    end
  end
end
