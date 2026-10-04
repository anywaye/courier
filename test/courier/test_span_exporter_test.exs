defmodule Courier.TestSpanExporterTest do
  @moduledoc """
  The exporter table's READ API, which is what every redaction assertion in this
  repository stands on.

  ## Why this file exists at all, and it is not tidiness

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

  ## What is asserted here, and why against a real request

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

  ## Ordering, and it is not tidiness

  `async: false`. This file and `Courier.TelemetryCanaryTest` both read one shared
  table and both bracket their own work with a mark, and the drain in `setup` is
  only safe while nothing else is mid-flight — the same scheduling argument
  `Courier.ObservabilityTest` makes about its `clear/1`. Two `async: true` readers
  of one table would each drain the other's evidence into the other's window, and
  this file would be the second thing in the repository to look like it works.
  """

  use CourierWeb.ConnCase, async: false

  setup do
    # Drain, then mark — the order, and the reason for it, are in
    # `Courier.TestSpanExporter.mark/0`. Draining after marking would leave this
    # file's own backlog inside its own window, which is the defect the canary test
    # was filed for.
    Courier.SpanCollector.flush()
    mark = Courier.TestSpanExporter.mark()

    %{mark: mark}
  end

  test "a watermark hides what was already exported and shows what comes after", %{mark: mark} do
    # `/healthz` before the mark, `/readyz` after it. `/readyz` answers 200 or 503
    # depending on whether the repo is up, which does not matter here: what is
    # asserted is WHICH spans come back, not what is on them.
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
    # Derived from the two reads rather than from a hand-written expectation, so it
    # keeps holding as more callers share the table.
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
    # THE CAVEAT, asserted rather than left in a comment, because it is the caveat
    # that makes the canary test independent of its neighbours and it is exactly
    # what a future refactor would delete as redundant.
    #
    # The mark is taken first, then the span is produced and exported. Nothing here
    # is another test's span — it is this test's own — and it still lands inside the
    # window, because a watermark filters by WHEN A ROW ARRIVED and not by WHICH
    # TEST MADE IT. The only thing that makes those two the same set is an empty
    # collector queue at the moment the mark is taken.
    #
    # So this test is not asserting that a watermark is enough. It is asserting that
    # it is NOT, which is why `Courier.TelemetryCanaryTest` flushes the collector in
    # its `setup` before it marks. Reverse this assertion and the drain becomes
    # deletable — which is the point of writing it down.
    mark = Courier.TestSpanExporter.mark()

    request("/healthz")
    Courier.SpanCollector.flush()

    assert Courier.TestSpanExporter.take_since(mark) != [],
           "a span exported after the mark is inside the mark's window by construction. " <>
             "If this ever goes false, the exporter has gained a real origin tag and this " <>
             "test, and the drain in the canary test, can both be simplified."
  end

  defp request(path) do
    # `dispatch/5` rather than `get/2`, because it is what the canary file uses and
    # it needs no `@endpoint` to have been started. One helper rather than two call
    # shapes, so "what a request is" is not a variable in a test about ordering.
    Phoenix.ConnTest.dispatch(Phoenix.ConnTest.build_conn(), @endpoint, "GET", path, nil)
  end
end
