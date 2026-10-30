defmodule Courier.TestSpanExporterTest do
  @moduledoc """
  The exporter table's READ API, which is what every redaction assertion in this
  repository stands on.


  `Courier.TestSpanExporter.mark/0` and `take_since/1` had NO CALLERS. Not in this
  repository, not in the canary tests that need exactly what they do. They were
  documented at length, they were correct on paper, and nothing ever asked whether
  they worked.

  They did not work. `export/4` numbered its rows with a plain
  `:erlang.unique_integer()` and `mark/0` drew from
  `:erlang.unique_integer([:monotonic, :positive])`, which is not two draws from one
  counter but two DIFFERENT sequences: the monotonic one counts up from 1 and the
  plain one counts DOWN from -576460752303423488. `take_since/1` asks `id > mark`,
  so it asked a negative number whether it was greater than a small positive one,
  and the answer was no for every row on every run. `take_since/1` returned `[]`
  always.

  That failure mode is why this file is here rather than one more line in another
  one. A watermark that returns the WRONG spans fails loudly at the assertion that
  notices. A watermark that returns an EMPTY list is indistinguishable from "this
  test produced nothing", which is precisely the answer a redaction test cannot
  check — and `test/courier/telemetry_canary_test.exs` measured green while reading
  exactly nothing.


  The contract, driven through the real endpoint and the real collector, because the
  alternative is asserting the arithmetic of two integer helpers and calling that a
  watermark. The two spans are told apart by their ROUTE rather than by an id,
  because two spans differing only in an id are not distinguishable by any assertion
  a reader can write:

    * a watermark hides a span that was ALREADY in the table when it was taken, and
      shows one exported after — which is the whole meaning of it, and the only way
      to catch a mark that quietly returns `[]`;
    * the window is a SUFFIX of `take/0` in `take/0`'s order, so the two reads
      cannot be telling different stories about the same rows;
    * and, stated as a contract rather than left in a comment, that a mark does NOT
      exclude a span produced after it — which is why every caller has to drain
      `Courier.SpanCollector` first. See `Courier.TestSpanExporter.mark/0`.


  `async: false`. This file and `Courier.TelemetryCanaryTest` both read one shared
  table and both bracket their own work with a mark, and the drain in `setup` is
  only safe while nothing else is mid-flight — the same scheduling argument
  `Courier.ObservabilityTest` makes about its `clear/1`. Two `async: true` readers
  of one table would each drain the other's evidence into the other's window, and
  this file would be the second thing in the repository to look like it works.
  """

  use CourierWeb.ConnCase, async: false

  setup do
    Courier.SpanCollector.flush()
    mark = Courier.TestSpanExporter.mark()

    %{mark: mark}
  end

  test "a watermark hides what was already exported and shows what comes after", %{mark: mark} do
    assert request("/healthz").status == 200
    Courier.SpanCollector.flush()

    later_mark = Courier.TestSpanExporter.mark()

    assert later_mark > mark,
           "two marks on one VM must be ordered, or nothing below means anything"

    assert request("/readyz").status in [200, 503]
    Courier.SpanCollector.flush()

    everything = Courier.TestSpanExporter.take()
    window = Courier.TestSpanExporter.take_since(later_mark)
    from_the_start_of_the_test = Courier.TestSpanExporter.take_since(mark)
    routes = fn spans -> Enum.map(spans, &Map.get(&1.attributes, :"http.route")) end

    assert "/healthz" in routes.(everything),
           "`take/0` is the whole table and must still contain the span exported " <>
             "before the mark. If it does not, the table is being cleared under this " <>
             "file by a caller that still uses `clear/1`."

    assert "/healthz" in routes.(from_the_start_of_the_test),
           "the setup's mark was taken before /healthz was even requested, so that span " <>
             "belongs in its window. This is the caveat the third test names, checked " <>
             "against the setup this file actually runs."

    refute "/healthz" in routes.(window),
           "the watermark's whole job is to hide a span already exported before it was " <>
             "taken, and /healthz is that span."

    assert "/readyz" in routes.(window),
           "a span exported after the mark belongs to the mark's window.\n\n" <>
             "An empty window here is the failure this file exists for: the mark and the " <>
             "row ids come from two different `:erlang.unique_integer/1` sequences, so " <>
             "`id > mark` is never true and every caller's window is silently empty."
  end

  test "the window is a SUFFIX of the table, not a differently-ordered table" do
    request("/healthz")
    Courier.SpanCollector.flush()

    mark = Courier.TestSpanExporter.mark()

    request("/readyz")
    Courier.SpanCollector.flush()

    everything = Courier.TestSpanExporter.take()
    window = Courier.TestSpanExporter.take_since(mark)

    assert window != [],
           "the /readyz export landed after the mark and belongs in the window"

    assert window == Enum.drop(everything, length(everything) - length(window)),
           "the window must be the tail of `take/0`, in `take/0`'s order. Both read the " <>
             "same rows, so any other shape means the two are reading different orderings."
  end

  test "a mark does NOT exclude a span produced after it, which is why callers drain" do
    mark = Courier.TestSpanExporter.mark()

    request("/healthz")
    Courier.SpanCollector.flush()

    assert Courier.TestSpanExporter.take_since(mark) != [],
           "a span exported after the mark is inside the mark's window by construction. " <>
             "If this ever goes false, the exporter has gained a real origin tag and this " <>
             "test, and the drain in the canary test, can both be simplified."
  end

  defp request(path) do
    Phoenix.ConnTest.dispatch(Phoenix.ConnTest.build_conn(), @endpoint, "GET", path, nil)
  end
end
