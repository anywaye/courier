defmodule Courier.TestSpanExporter do
  @moduledoc """
  An in-memory OTLP exporter, so a test can read the spans courier produced.

  NOT A MOCK. This is the real OpenTelemetry SDK with its real exporter replaced
  by one that copies the finished spans into a table the test owns. What the test
  reads is the payload an operator's collector would have received — span names,
  attribute names, attribute values, statuses, resources and all. Asserting on a
  hand-built map would prove the TEST's idea of the payload is correct, which is
  not the property under test.

  In a table rather than in the test process, and that is not tidiness: the SDK
  exports on the process that ended the span, which in a Phoenix endpoint is a
  Bandit connection process, not the test. A message to the test process would
  need a registered owner per test, and an owner that outlives its test is a
  message to a dead pid.

  ## Why this file is fussier than it looks

  Three things about the SDK's exporter interface are not guessable, and each was
  got wrong first. All three fail in the SAME way — silently — and that is what
  makes them worth writing down.

    1. `init/1` must return `{:ok, state}` or `:ignore`. `otel_exporter:init/1`
       matches `try ExporterModule:init(Config) of {ok, State} -> …; ignore -> …
       end` with NO catch-all, so a bare `:ok` is a TryClauseError inside a
       gen_statem. The processor is then dropped by
       `otel_tracer_server:init_processor/3` with a log at `info`.
    2. `export/4`, not `export/3`. The callback is
       `export(signal, table, resource, config)`; an `export/3` is not a callback
       at all, so it is never called and every span is discarded.
    3. The second argument is an ETS TABLE the processor owns, not a list of
       spans, and the rows are still in it at that moment.

  Each of those leaves the suite GREEN. "No canary reached a span" is true of a
  span that was never exported, so a broken exporter makes every redaction
  assertion in this repository pass, in about a second, having proved nothing.
  That is why every canary test here pairs its absence assertion with a PRESENCE
  assertion, and why `rendered!/0` refuses to return an empty string.

  The error that gives it away is at `info` and names the module:

      [warning] Exporter module Courier.TestSpanExporter not found.
  """

  @behaviour :otel_exporter

  @table :courier_test_spans

  @impl true
  def init(_config), do: {:ok, %{}}

  # One row, in whichever of the two shapes the table holds.
  #
  # The SDK's own export table is `duplicate_bag` with
  # `{keypos, #span.instrumentation_scope}`, and `ets:tab2list/1` on a table with
  # a `keypos` returns the OBJECT — the bare `#span{}` — with the key left in
  # place at its own field position. The shape courier's queue used was a `set`
  # keyed by `:erlang.unique_integer()`, where the same call returns
  # `{span_id, span}` pairs.
  #
  # Matching only the second shape raised FunctionClauseError inside this exporter
  # the moment courier started building the table the REAL exporter reads, and the
  # symptom was the whole canary suite reporting "nothing to render (0 spans in)":
  # the spans were there and the exporter could not see them.
  defp span_record(fields) when is_list(fields), do: List.to_tuple(fields)
  defp span_record(record), do: record

  @impl true
  def export(:traces, sdk_table, _resource, _config) do
    ensure_table()

    spans =
      sdk_table
      |> :ets.tab2list()
      |> Enum.map(&span_record/1)
      |> Enum.map(&Courier.TestSpans.readable/1)
      |> Enum.sort_by(& &1.start_time)

    # The row key is an id from the SAME SEQUENCE `mark/0` draws from, and that is
    # the whole reason `mark/0` works at all.
    #
    # It used to be a plain `:erlang.unique_integer()` here and a
    # `[:monotonic, :positive]` one in `mark/0`, on the reasonable assumption that
    # they were two draws from one counter. They are not two draws from one counter;
    # they are two DIFFERENT sequences, and on OTP 29 they do not even overlap:
    #
    #     iex> {m, r} = {erlang.unique_integer([:monotonic, :positive]),
    #     ...>           erlang.unique_integer()}
    #     iex> {m, r, r > m}
    #     {1, -576460752303422142, false}
    #
    # The monotonic sequence counts up from 1; the plain one counts DOWN from
    # -576460752303423488. So `id > mark` was false for every row, always, and
    # `take_since/1` returned `[]` for every caller on every run.
    #
    # Nothing caught it because nothing called it: `mark/0` and `take_since/1` had
    # no callers anywhere in the suite, which is also how a canary test can rely on
    # them and read nothing without anything going red. `[:monotonic, :positive]` on
    # BOTH sides is the fix, and monotonic rather than plain is the point — it is
    # the only one of the two the OTP documentation guarantees to be strictly
    # increasing, and a watermark resting on an ordering nobody promised is a
    # watermark that works until it does not.
    #
    # `test/courier/test_span_exporter_test.exs` asserts this contract directly,
    # because the failure mode is an EMPTY LIST rather than a wrong one, and an
    # empty list is the one result no caller can tell from "nothing happened".
    :ets.insert(@table, Enum.map(spans, fn span -> {row_id(), span} end))
    :ok
  end

  def export(:logs, _sdk_table, _resource, _config), do: :ok
  def export(:metrics, _sdk_table, _resource, _config), do: :ok

  @impl true
  def shutdown(_config), do: :ok

  @doc "Every span exported so far, oldest first."
  def take do
    ensure_table()
    :ets.tab2list(@table) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  @doc """
  A watermark: the value to pass to `take_since/1` to read only what comes next.

  WHY, and it is not tidiness. The suite is mostly `async: true` and every request
  through the endpoint exports a span into THIS table, so a test that clears the
  table and then reads it is reading whatever any other test happened to export
  while it was working. The first version did exactly that and failed with
  "expected exactly one exported span, got 8" — eight being every request the rest
  of the suite had made in the meantime.

  An earlier version avoided it with `clear/1`, which is worse: clearing a shared
  table is a test deleting another test's evidence, so two tests asserting the same
  time pass or fail depending on the scheduler.

  ## What a watermark is NOT, and this cost a day to find out

  **A mark taken now does NOT exclude spans another test made.** It excludes spans
  that were EXPORTED before the mark. The exporter is handed whatever
  `Courier.SpanCollector` is holding at the moment something flushes it, and the
  collector batches: a span that ended in an earlier module and was never flushed
  is inserted into this table at the time of the NEXT flush — which, in a canary
  test, is that test's own `flush/0`. Marking it now and reading since the mark
  hands the backlog straight to the reader.

  Measured on `mix test --seed 885732`: a test that marked in `setup` and read
  since the mark saw SEVENTEEN `courier.web.request` spans and had made ONE. The
  other sixteen were `/inbound/resend`, `/readyz` and `/healthz` requests from
  three earlier modules, still in the collector's queue.

  So the order is not interchangeable: **drain `Courier.SpanCollector` first, then
  mark.** Once the queue is empty, "arrived after the mark" and "this test made it"
  are the same set. `test/courier/telemetry_canary_test.exs` is the working
  example; `Courier.ObservabilityTest` still reads the whole table and still has
  the version of this defect that does not need a backlog to fire.

  ## Why the table is never deleted

  Nothing prunes it, and that is bounded by the suite rather than by the code: one
  row per exported span, and a full `mix test` exports on the order of a thousand.
  `clear/1` is still here for a caller that genuinely wants a clean slate, and the
  canary file stopped calling it — deleting the whole table to read a slice of it
  is the same move as `clear/1`, one level up.
  """
  def mark do
    ensure_table()
    row_id()
  end

  @doc "The spans exported since `mark`, oldest first."
  def take_since(mark) do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {id, _span} -> id > mark end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # The row key, AND the watermark, from one sequence. See the comment on the
  # insert in `export/4`, which is where the argument for it belongs; `mark/0` is
  # here too so that the two cannot drift apart again — that drift is the entire
  # defect this file's test covers, and it happened because they were written in
  # different places and read as if they were the same counter.
  defp row_id, do: :erlang.unique_integer([:monotonic, :positive])

  @doc """
  Forget everything.

  Not tidiness: without it, one test's spans satisfy the NEXT test's absence
  assertion, and a suite of canary tests where each one sees the previous one's
  spans is a suite that proves less the longer it runs.
  """
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:public, :named_table, :set])
      _ -> @table
    end
  end
end
