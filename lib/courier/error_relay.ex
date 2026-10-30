defmodule Courier.ErrorRelay do
  @moduledoc """
  The error path's chokepoint: classify, fingerprint, throttle, re-frame, hand on.


  It is the one place in the fleet where a Sentry envelope is allowed to become
  a stored error, and the only place the redaction policy is applied — because
  core's `redaction.schema.json` says enforcement happens at **one** chokepoint,
  and the OTel collector cannot reach the error path (GlitchTip speaks the
  Sentry protocol; it has no OTLP receiver for errors).


      SDK  ──envelope──▶  [ ingest/2, a cast ]  ──▶  Sender   ──bytes──▶  Sink
                             │                      (bounded queue,     (Req → GlitchTip)
                             │                       async drain)
                             └──▶ Policy.redact/1  ──▶ classify/1
                                  Policy.fingerprint/1
                                  token bucket, in ETS

  Three properties fall out of that shape and each is a requirement rather than
  a nicety:

    * **`ingest/2` is a cast.** It returns `:ok` immediately. The HTTP endpoint
      that receives an envelope answers `200` before anything is forwarded, so a
      GlitchTip that is down, slow, or absent cannot add latency to a request in
      another service. Losing an error is strictly better than becoming a slow
      service, and it is the same rule the collector's exporters follow with
      `sending_queue: {enabled: false}`.

    * **The queue is bounded and full means drop.** An unbounded queue in front
      of a slow sink is a memory leak with an observability-shaped trigger. A
      full queue is counted in `queue_full` and the envelope is discarded.

    * **The throttle table is bounded and prunes itself.** One bug in a hot loop
      must not become ten thousand stored errors, and ten thousand *distinct*
      errors must not become ten thousand table entries. Sentry does not sample
      errors by design, so this is the volume control the SDK deliberately does
      not provide.


  Sentry's protocol lets a client choose its own grouping via a `fingerprint`
  field. The relay **ignores and drops** it. If it were honoured, a caller could
  defeat the throttle completely by sending a fresh value per event, and — in
  the other direction — could collapse every error in the whole fleet into one
  group. `Courier.ErrorRelay.Policy.fingerprint/1` computes the key from the
  *redacted* event instead: service, `error.type`, operation, exception classes,
  and the application frames' module/function/line. `release` is deliberately
  excluded, so a deploy does not open a second group for a bug that was never
  fixed.


  `stats/1` reads a table both this process and `Courier.ErrorRelay.Sender`
  write, because `sink_failures` and `queue_full` are the *sender's* facts and
  making the sender report them by casting to the relay would put a message
  behind a message. The table is `:public` so the sender can write it without
  either process being able to stop the other; nothing in it is a secret and it
  is bounded to a fixed set of keys.


  The throttle lives in memory, so a relay restart empties every bucket and the
  first `@burst` occurrences of a hot bug get through again. The alternative —
  persisting buckets — would put the error path's state in a database, and the
  brief is explicit that the error store is separate from the application's
  primary database. An operator who sees a burst after a deploy has seen a
  restarted relay, which is a sentence they can act on.
  """

  use GenServer

  alias Courier.ErrorRelay.Policy
  alias Courier.ErrorRelay.Sender
  alias Courier.ErrorRelay.Sink

  @counters ~w(received forwarded throttled malformed unclassified undeclared
               queue_full sink_failures)a

  @default_burst 5
  @default_per_minute 60
  @default_capacity 4_096
  @default_queue_size 256


  @doc """
  Hand a list of decoded envelope items to the relay. Returns `:ok`, always.

  A cast, deliberately. See the moduledoc: the caller is an HTTP endpoint in
  another service that must not wait on anything to do with error reporting, and
  the return value is `:ok` whether the event was forwarded, throttled, dropped
  or never readable.
  """
  @spec ingest(GenServer.server(), [map()]) :: :ok
  def ingest(server \\ __MODULE__, items) when is_list(items) do
    GenServer.cast(server, {:ingest, items})
  end

  @doc """
  Every counter, as a map with all of `

  Read from the **stats** table, which is a *different* table from `table/1`.
  Reading the throttle table here looks right — both are named after the relay
  and both are ETS — and returns zero for every counter forever, because the
  counters are never written to it. That is the failure this clause's comment
  exists to prevent: a `stats/1` that is uniformly zero is indistinguishable
  from a relay that is genuinely receiving nothing, which is exactly the state
  an operator most needs to tell apart.
  """
  @spec stats(GenServer.server()) :: %{atom() => non_neg_integer()}
  def stats(server \\ __MODULE__) do
    Map.new(@counters, fn key ->
      case :ets.lookup(stats_table(server), {:stat, key}) do
        [{_key, value}] -> {key, value}
        [] -> {key, 0}
      end
    end)
  end

  @doc "The throttle table, for `:ets.info/2` and for a test asserting the bound."
  @spec table(GenServer.server()) :: atom() | reference()
  def table(server \\ __MODULE__), do: server


  @doc false
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])

    :ets.new(stats_table(name), [:set, :public, :named_table, write_concurrency: true])

    sender =
      Keyword.get_lazy(opts, :sender, fn ->
        {:ok, pid} =
          Sender.start_link(
            name: sender_name(name),
            relay: name,
            sink: Keyword.get(opts, :sink, Courier.ErrorRelay.Sink.Req),
            sink_opts: Keyword.take(opts, [:sink_target, :sink_dsn, :sink_timeout, :sink_mode]),
            size: Keyword.get(opts, :queue_size, @default_queue_size),
            timeout: Keyword.get(opts, :sink_timeout, 5_000)
          )

        pid
      end)

    {:ok,
     %{
       name: name,
       sender: sender,
       burst: Keyword.get(opts, :burst, @default_burst),
       per_minute: Keyword.get(opts, :per_minute, @default_per_minute),
       capacity: Keyword.get(opts, :capacity, @default_capacity),
       now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
       dsn: Keyword.get(opts, :sink_dsn)
     }}
  end

  @impl GenServer
  def handle_cast({:ingest, items}, state) do
    state = count(state, :received, length(items))
    {state, admitted} = forward(state, items, [])

    enqueue(state, admitted)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:count, key, by}, state) do
    {:noreply, count(state, key, by)}
  end


  defp forward(state, items, admitted) do
    now = state.now.()

    Enum.reduce(items, {state, admitted}, fn item, {acc, kept} ->
      if event?(item) do
        {acc, event} = handle(acc, item["payload"], now)
        {acc, if(event, do: [event | kept], else: kept)}
      else
        {acc, kept}
      end
    end)
  end

  defp event?(%{"type" => "event"}), do: true
  defp event?(_other), do: false

  defp handle(state, payload, now) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> admit_or_discard(state, decoded, now)
      _not_json -> {count(state, :malformed, 1), nil}
    end
  end

  defp handle(state, decoded, now) when is_map(decoded) do
    admit_or_discard(state, decoded, now)
  end

  defp handle(state, _neither, _now), do: {count(state, :malformed, 1), nil}

  defp admit_or_discard(state, decoded, now) do
    case Policy.redact(decoded) do
      {:error, :not_an_event} ->
        {count(state, :malformed, 1), nil}

      {:ok, redacted} ->
        admit(classify(state, redacted), redacted, now)
    end
  end

  defp classify(state, redacted) do
    case Policy.classify(redacted) do
      {:ok, _class} ->
        {state, redacted}

      {:error, :unclassified} ->
        {count(state, :unclassified, 1), nil}

      {:error, :undeclared} ->
        {count(state, :undeclared, 1), redacted}
    end
  end

  defp admit({state, nil}, _redacted, _now), do: {state, nil}

  defp admit({state, redacted}, redacted, now) do
    if allow?(state, Policy.fingerprint(redacted), now) do
      {count(state, :forwarded, 1), redacted}
    else
      {count(state, :throttled, 1), nil}
    end
  end

  defp enqueue(state, []), do: state

  defp enqueue(state, admitted) do
    items = Enum.map(admitted, &%{"type" => "event", "payload" => &1})

    case Sink.build_envelope(items, state.dsn) do
      {:ok, envelope} ->
        Sender.enqueue(state.sender, envelope)
        state

      {:error, _reason} ->
        count(state, :malformed, length(admitted))
    end
  end


  defp allow?(state, fingerprint, now) do
    table = state.name

    case :ets.lookup(table, fingerprint) do
      [{^fingerprint, tokens, last, dropped}] ->
        refilled = min(state.burst, tokens + rate(state) * (now - last))
        available = floor(refilled)

        if available >= 1 do
          :ets.insert(table, {fingerprint, refilled - 1, now, dropped})
          true
        else
          :ets.insert(table, {fingerprint, refilled, last, dropped + 1})
          false
        end

      [] ->
        evict(table, state.capacity)
        :ets.insert(table, {fingerprint, state.burst * 1.0 - 1, now, 0})
        true
    end
  end

  defp rate(%{per_minute: per_minute}), do: per_minute / 60_000

  defp evict(table, capacity) do
    if :ets.info(table, :size) >= capacity do
      case oldest(table) do
        nil -> :ok
        key -> :ets.delete(table, key)
      end
    end

    :ok
  end

  defp oldest(table) do
    {key, _last} =
      :ets.foldl(
        fn {fingerprint, _tokens, last, _dropped}, {_best, best_last} = acc ->
          if last < best_last, do: {fingerprint, last}, else: acc
        end,
        {nil, :infinity},
        table
      )

    key
  end


  defp count(state, key, by) do
    :ets.update_counter(stats_table(state.name), {:stat, key}, {2, by}, {{:stat, key}, 0})
    state
  end

  defp stats_table(name), do: :"#{name}.stats"

  @doc false
  def sender_name(name), do: :"#{name}.sender"

  @doc false
  def tasks_name(name), do: :"#{sender_name(name)}.tasks"

  @doc false
  def count_stat(name, key, by) do
    :ets.update_counter(stats_table(name), {:stat, key}, {2, by}, {{:stat, key}, 0})
  end
end
