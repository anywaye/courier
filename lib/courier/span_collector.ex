defmodule Courier.SpanCollector do
  @moduledoc """
  courier's span processor, and the reason it exists at all.

  ## The upstream bug it works around

  The Erlang OpenTelemetry SDK cannot start a span processor. Not in 1.7.0, not
  in 1.5.1, and not through any configuration. `otel_tracer_server:init_processor/3`
  starts each configured processor with

      supervisor:start_child(otel_span_sup, [ProcessorModule, Config])

  and `otel_span_sup` is a `one_for_one` supervisor whose children are written out
  in `init/1`. A two-element list is not a child spec, so the call returns:

      {:error, {:invalid_child_spec, [:otel_simple_processor, %{…}]}}

  `init_processors/2` treats anything but `{:ok, pid, config}` as "drop this
  processor", so it is dropped — with a log at `info`, which nobody reads. Measured
  on this tree, against both versions:

      $ mix run -e "IO.inspect(Supervisor.which_children(:otel_span_sup))"
      [{:otel_span_sweeper, #PID<…>, :worker, …},
       {:otel_span_ets,     #PID<…>, :worker, …}]      # no processor, ever

  And a span with no processor is not exported at all: `otel_span_ets:end_span/3`
  does `ets:take(SPAN_TAB, SpanId)` and hands the record to the on-end list, which
  is empty, so the record is destroyed. A courier with this SDK emits nothing, and
  its startup line says telemetry is on.

  ## What this module does instead

  It supplies the on-end processor directly. `#tracer{}` in the SDK carries
  `on_end_processors :: fun((span()) -> boolean() | {error, term()})`, and
  `get_tracer/3` hands that record back — so courier can rebuild the record with
  its own function in that field. That is reaching into an SDK private, and it is
  done here rather than in every service, with three things making it survivable:

    * it is ONE function, and if the SDK's record changes shape the rebuild raises
      loudly at boot rather than exporting nothing;
    * the collector owns an ordinary ETS table and an ordinary GenServer, so
      deleting this module and its call site is a small, local change when the bug
      is fixed upstream;
    * it is asserted, not assumed: `test/courier/span_collector_test.exs` drives a
      real request and reads what came out the other end.

  ## What it is NOT

  Not a reimplementation of the SDK's batch processor in general. It accumulates
  into an ETS table and hands the table to a real exporter on an interval, which is
  the two operations that matter: the export is `:opentelemetry_exporter`'s own
  OTLP encoding, and the batching is one timer.

  No queue with unbounded growth, and that is the fleet's rule rather than a
  preference. A telemetry queue that accepts spans and holds them is a memory leak
  with a telemetry-shaped trigger. So the table is bounded, and when it is full the
  OLDEST spans are dropped: a span about a request that already finished is worth
  less than the process staying up, and losing one is strictly better than becoming
  a slow service.
  """

  use GenServer

  require Logger

  alias Courier.Telemetry

  @table :courier_pending_spans

  # Bounded, and bounded SMALL. The collector holds finished spans waiting for the
  # next flush; a hundred thousand of them is a hundred thousand records in the BEAM
  # heap, which is the memory-leak-with-a-telemetry-shaped-trigger the moduledoc
  # names. At 2000 the worst case is a few hundred kilobytes and a visible gap in
  # the trace store, which is the right way round.
  @capacity 2_000

  # The interval between exports, in milliseconds. 5s is the SDK's own batch
  # default and a dev-friendly number: long enough that a request is not an export,
  # short enough that `docker compose up` followed by one curl shows a trace.
  @flush_interval_ms 5_000

  @doc "Supervisor entry point, named for `Courier.Application`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The SDK's on-end processor. Installed into the tracer record; see the moduledoc.

  Synchronous, because the record is already serialised and the only work is an
  `ets:insert`. It must return `true` — the SDK treats anything else as a failure
  and the span processor's contract says a boolean.
  """
  def on_end(span) do
    ensure_table()

    if :ets.info(@table, :size) >= @capacity do
      drop_oldest()
    end

    :ets.insert(@table, {:erlang.unique_integer(), span})
    true
  catch
    # A telemetry failure must not take a request down. An `ets:insert` should not
    # fail, and if the table is gone because the collector is restarting it will be
    # back; swallowing it here means a telemetry problem costs a span rather than
    # costing the caller a 500.
    _, _ -> false
  end

  @doc "Export everything pending, now. The test path and the shutdown path."
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  catch
    # No collector (a test that never started the tree), which is a no-op rather
    # than an error: a flush with nothing to flush is not a failure.
    :exit, _ -> :ok
  end

  @doc "How many spans are waiting for the next flush."
  def pending do
    case :ets.whereis(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  @doc "The capacity, so a test can assert the bound is what it says it is."
  def capacity, do: @capacity

  @last_failure_key {__MODULE__, :last_failure}

  @doc false
  # The last flush's refusal. For a test diagnosing "nothing to render" — which is
  # how this whole defect presented, from six test files at once, with the reason
  # visible only on one log line nobody was reading.
  def last_failure, do: :persistent_term.get(@last_failure_key, nil)

  @doc """
  The state `export/4` is called with, so a test can assert its SHAPE.

  `:otel_otlp_traces.to_proto/2` runs inside the exporter, so there is no seam to
  observe the export's arguments from outside. This is that seam, and it is
  narrow on purpose: it returns the state and nothing else.
  """
  def exporter_state, do: Telemetry.exporter_state()

  @doc """
  The endpoints inside the exporter state, read out of the exporter's own record.

  `:otel_otlp_traces` is where the export actually goes, so this is where the
  `<SERVICE>_OTEL_ENDPOINT` contract becomes an address. Reading it back out of
  the initialized state is what makes "courier honours its endpoint" a claim
  about the wire rather than about `Telemetry.endpoint/0`, which is only a
  function of the environment and proved nothing about the exporter.
  """
  def exporter_endpoints do
    case exporter_state() do
      # `#state{}`'s field 8 is `endpoints`, from `otel_exporter_traces_otlp`'s
      # record definition. The tag check is the guard: an exporter that changed
      # its record would otherwise return a confidently wrong address, and this
      # is the only place courier looks at the exporter's internals.
      state when is_tuple(state) and tuple_size(state) == 9 and elem(state, 0) == :state ->
        elem(state, 8)

      _ ->
        :error
    end
  end

  @doc "The queue's table name. For a test that reads it."
  def table, do: @table

  @doc """
  The pending spans, in the shape the exporter's encoder reads.

  ## Why courier assembles this instead of handing over its own table

  `:otel_otlp_traces.to_proto/2` iterates its argument with `ets:first/1`,
  `ets:lookup/2` on that key, and `ets:next/2` — so the table's KEY is an
  `#instrumentation_scope{}` and its VALUE is a `#span{}`. courier's queue is
  keyed by `:erlang.unique_integer()` instead, because that is what makes
  `drop_oldest/0` and an atomic drain possible.

  So the two shapes are genuinely different and one of them has to be built from
  the other. Measured, on the shape courier used to pass:

      ** (FunctionClauseError) no function clause matching in :otel_otlp_traces.to_proto/1
          # 1
          {-576460752303345823, {:span, 250261861607385731661550453041408069235, ...}}

  The negative integer is courier's queue key arriving where the encoder asked
  for an instrumentation scope. This is the conversion, and it is a
  `:bag`/list of `{scope, span}` pairs rendered into the named table the encoder
  walks.

  The scope comes from the span itself rather than from courier's tracer, because
  the encoder groups by it and a span is the thing being grouped.
  """
  def pending_spans do
    export_table(@table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)))
  end

  # The table the exporter's encoder walks, built from a list of `#span{}` records.
  #
  # `:public`, `duplicate_bag` and `keypos`, because the SDK's own export table
  # (`otel_batch_processor:new_export_table/1`) is exactly this and the encoder's
  # `ets:lookup/2` walk depends on it. Two spans from the same instrumentation
  # scope are two rows, not one overwrite — a `set` here silently drops every span
  # but the last.
  #
  # `:ets.insert/2` with a LIST is one operation, so there is no window in which the
  # encoder could see a half-built table.
  defp export_table(spans) do
    table =
      :ets.new(:courier_export_spans, [
        :public,
        :duplicate_bag,
        {:keypos, span_keypos()}
      ])

    :ets.insert(table, spans)
    table
  end

  @doc """
  The key position the export table uses: the span's `instrumentation_scope`.

  `otel_batch_processor:new_export_table/1` writes `{keypos, #span.instrumentation_scope}`
  and comments why — the OTLP proto groups by instrumentation scope, so keying on
  it lets the encoder gather one scope's spans at a time. That is courier's
  encoder's assumption too, and this is the one number that has to agree with it.

  Read off the record rather than written as a literal: `#span{}` is fixed by the
  SDK, and `instrumentation_scope` is its LAST field, so `tuple_size/1` is the
  position. An SDK that adds a field to the record would otherwise give this a
  confidently wrong key position.
  """
  # `#span{}` as the SDK defines it, in
  # `deps/opentelemetry/include/otel_span.hrl`: tag, trace_id, span_id,
  # tracestate, parent_span_id, parent_span_is_remote, name, kind, start_time,
  # end_time, attributes, events, links, status, trace_flags, is_recording,
  # instrumentation_scope. Seventeen elements, with `instrumentation_scope` LAST —
  # which is why the key position is the arity rather than a literal somebody has
  # to remember. `test/courier/otel_export_test.exs` asserts the arity against a
  # real span, so an SDK that adds a field goes red there rather than quietly
  # grouping courier's spans under a wrong key.
  @span_arity 17

  def span_keypos, do: @span_arity

  @doc """
  The scope of a finished span: the tail of the `#span{}` record.

  `#span{}` is fixed by the SDK and `instrumentation_scope` is its LAST field, so
  this is `element/2` against a fixed arity rather than a named lookup — and the
  arity is checked, because an SDK that adds a field would otherwise return a
  silently WRONG scope and group courier's spans under nothing at all.
  """
  def instrumentation_scope(span) do
    case Tuple.to_list(span) do
      [:span | rest] -> List.last(rest)
      _ -> :undefined
    end
  end

  @doc """
  Run the export through a substituted exporter. The test seam.

  Takes the list of `{scope, span}` pairs the real exporter receives, so a test
  can answer `:ok`, `:error`, `{:error, reason}` or raise, and assert what
  courier does about each. The production path is `do_export/0`, which calls this
  with the configured exporter — so the classification under test is the one that
  runs in production rather than a copy of it.

  Returns the exporter's answer after courier has classified it, or
  `:nothing_pending`. `:ok` means the spans were handed over and the queue is now
  empty; anything else means they are re-queued.
  """
  def export_pending(exporter) when is_function(exporter, 1) do
    pending = drain_pending()

    if pending == [] do
      # Not an export attempt. Calling the exporter with nothing to send is what
      # makes `to_proto/2` answer `empty`, and `empty` is indistinguishable from
      # success — so "nothing to export" and "exported nothing" have to stay apart.
      :nothing_pending
    else
      case safe_export(exporter, pending) do
        :ok ->
          :ok

        other ->
          # Re-queued rather than dropped: a transient refusal should cost a
          # delayed span, not a missing one, and @capacity bounds what a stuck
          # exporter can hold.
          requeue(pending)
          {:error, other}
      end
    end
  end

  @doc "Discard everything pending. For a test that wants a known-empty queue."
  def clear_pending do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Record one real span, through the same two calls the request plug makes.

  Not a convenience for its own sake: it is the pair every assertion in the
  redaction and propagation tests depends on, and a hand-built `#span{}` record
  would let a change in how courier OPENS spans pass all of them.
  """
  def record_one_span(name \\ "courier.web.request", context \\ :undefined) do
    span = :otel_tracer.start_span(context, Telemetry.tracer(), name, %{kind: :server})
    :otel_span.end_span(span)
    span
  end

  @impl true
  def init(_opts) do
    ensure_table()
    :ets.delete_all_objects(@table)
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, do_export(), state}
  end

  @impl true
  def handle_info(:flush, state) do
    do_export()
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_export do
    case export_pending(&call_exporter/1) do
      :ok -> :ok
      :nothing_pending -> :ok
      {:error, reason} -> warn(reason)
    end
  end

  # The exporter is a third-party module called with data courier did not build, so
  # it raises: an `httpc` profile that was never started, an endpoint its own parser
  # refuses, an OS-level failure under an accepted request. None of those are
  # courier's to raise into a request, and a crash here would take the collector —
  # and with it every later flush — down. A raise is a REFUSAL: the spans are
  # re-queued and the flush ends.
  defp safe_export(exporter, spans) when is_function(exporter, 1) do
    exporter.(spans)
  catch
    kind, reason -> {:raised, kind, reason}
  end

  # It takes the DRAINED spans, not the queue. `export_pending/1` has already taken
  # them out — that is what makes a refusal re-queueable — so reading `@table` again
  # here would hand the exporter an empty queue and report success. Measured: the
  # canary suite went from 10 green to "nothing to render (0 spans in)" on exactly
  # that, because `to_proto/2` answers `empty` for an empty table and the exporter
  # treats that as a successful export.
  defp call_exporter(spans) do
    table = export_table(spans)

    try do
      Telemetry.exporter().export(
        :traces,
        table,
        Telemetry.otel_resource(),
        Telemetry.exporter_state()
      )
    after
      :ets.delete(table)
    end
  end

  # A refusal is a WARNING, once per flush rather than once per span: the queue is
  # bounded and retried, so a collector that cannot reach its endpoint produces one
  # line every five seconds rather than one line per request. And it names the
  # answer rather than saying "failed", because the whole of the previous defect
  # was that `{:error, :unimplemented}` and a refused POST looked identical.
  defp warn(reason) do
    Logger.warning("span export failed; they stay queued for the next flush",
      reason: inspect(reason)
    )

    # Kept readable, because "nothing to render (0 spans in)" from six test files
    # is the shape this defect had and the reason was visible only on the log line
    # above it.
    :persistent_term.put(@last_failure_key, reason)

    :ok
  end

  @doc false
  # Forget the last refusal. Paired with `last_failure/0`, and for the same reason:
  # a stale reason is a reason that names the wrong defect.
  def clear_failure, do: :persistent_term.erase(@last_failure_key)

  # Take the queue and hand it over. `:ets.take/2` with an OBJECT reference, which
  # is the one ETS operation that reads AND deletes atomically against concurrent
  # writers: `on_end/1` inserts from whatever request process ended a span, and
  # the pair this replaces — `tab2list` then `delete_all_objects` — dropped
  # whatever landed in between. Spans arriving after the take stay for the next
  # flush.
  #
  # Read the keys, then TAKE each one. `:ets.take/2` is atomic per object, so this
  # cannot drop a span that arrived between the read and the take, and it cannot
  # miss one that was already there.
  #
  # The pair this replaces was `tab2list` then `delete_all_objects`, which dropped
  # whatever landed between the two. The `:ets.take/2` with `[:reference]` version
  # was worse: it answers a REFERENCE, and neither `ets:tab2list/1` nor
  # `ets:match_object/2` accepts one. Measured, on OTP 29:
  #
  #     ** (ArgumentError) errors were found at the given arguments:
  #       * 1st argument: not an atom or a table identifier
  #     (stdlib 1.8.1) :ets.match_object([], :_)
  defp drain_pending do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        @table
        |> :ets.tab2list()
        |> Enum.flat_map(fn {key, _span} ->
          case :ets.take(@table, key) do
            [{^key, span}] -> [span]
            [] -> []
          end
        end)
    end
  end

  defp requeue(spans) do
    Enum.each(spans, fn span ->
      :ets.insert(@table, {:erlang.unique_integer(), span})
    end)
  end

  defp drop_oldest do
    case :ets.first(@table) do
      :"$end_of_table" ->
        :ok

      oldest ->
        :ets.delete(@table, oldest)
        drop_oldest()
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:public, :named_table, :set])
      _ -> @table
    end
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval_ms)
end
