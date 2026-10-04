# REPORT — courier-telemetry-canary-flake-01

**Repo** `/Users/kaka/Code/any/moon/cafaye/courier`
**Branch** `worker/courier-telemetry-canary-flake-01` (off `master` at `54dfb42`)
**Worktree** `wt-m39-courier-canary-01`
**Machine** Elixir 1.20.4, Erlang/OTP 29 (erts-17.1), macOS, `smp:8:8`
**Push** not done. Not mine.

Two commits. `e761a20` (the flake) and `b60cb0a` (the presence assertion). Both
are in this branch; neither is merged or pushed.

---

## 1. The headline

The flake is real, it was in the tree, and it is fixed. Getting to the mechanism
turned up the mechanism in the brief **wrong in its cause but right about its
window**, and then turned up a second defect underneath it that was worse: the
watermark helper the fix depends on **had never worked, and had no callers**.

| | before | after |
|---|---|---|
| `mix test`, consecutive runs | 18 green / 2 red (seeds 885732, 589147) | **0 red / 30 green** |
| `mix test --seed 885732` | **3 of 3 red** | 3 of 3 green |
| canary module alone, consecutive | 0 red / 20 green | 0 red / 20 green |
| `test_span_exporter_test.exs` (new, 3 tests) | did not exist | 3 green; **0/3** with the fix reverted |
| exporter drops every span → canary module | **10 passed** | **0/10 passed** |

Nothing was skipped, nothing was sharded, and nothing was retried. Every number
above is a count from a run whose output is quoted in this report.

---

## 2. The before-rate, and how it was measured

`mix test` on this tree is 1314 tests and about 5.4 seconds wall clock, so the
whole-suite rate was measured directly rather than inferred. Twenty consecutive
runs with no seed argument, on unmodified `master` (`54dfb42`) in this worktree:

```
run 1   seed: 885732   Result: 1313/1314 passed    <-- red
run 2   seed: 465087   Result: 1314 passed
run 3   seed: 685761   Result: 1314 passed
run 4   seed: 255797   Result: 1314 passed
run 5   seed: 243318   Result: 1314 passed
run 6   seed: 903376   Result: 1314 passed
run 7   seed: 431013   Result: 1314 passed
run 8   seed: 105298   Result: 1314 passed
run 9   seed: 424026   Result: 1314 passed
run 10  seed: 79196    Result: 1314 passed
run 11  seed: 637934   Result: 1314 passed
run 12  seed: 12754    Result: 1314 passed
run 13  seed: 589147   Result: 1313/1314 passed    <-- red
run 14  seed: 200353   Result: 1314 passed
run 15  seed: 666767   Result: 1314 passed
run 16  seed: 154366   Result: 1314 passed
run 17  seed: 313748   Result: 1314 passed
run 18  seed: 443605   Result: 1314 passed
run 19  seed: 380028   Result: 1314 passed
run 20  seed: 17378    Result: 1314 passed
```

**2 failures in 20 runs — one in ten, matching the packet.**

Seed 885732 is a hard reproducer, which is what made the rest of this report
possible:

```
$ mix test --seed 885732        # three times, unmodified master
  1) test a request PATH never reaches a span an id in an unmatched path reaches
     nothing at all (Courier.TelemetryCanaryTest)
     test/courier/telemetry_canary_test.exs:185
     a 404 produced a span with a route. The path is caller-controlled text, so
     recording it is a cardinality bomb and a content leak in one move; the 404
     status is the answer.
     code: for span <- request_spans() do
Result: 1313/1314 passed
Failed: 1 test
```

Two honest notes on the measurement, because both affect how much it is worth:

* **The packet's seed did not reproduce here.** `mix test --seed 890226` is green
  on this machine, unmodified. Seed 885732 came out of my own 20-run sweep. The
  failure is seed-order-dependent, not seed-pinned to the packet's box.
* **My first loop printed a wrong summary line.** It tested
  `grep -q "failure"`, which does not match this Elixir's output format —
  `Result: 1313/1314 passed` / `Failed: 1 test`. It printed
  `==== FAILURES: 0 / 20 ====` against two red runs. The tally of 2 above is read
  off the per-run `Result:` lines that same loop printed, not off its summary. The
  after-count in §6 uses a pattern that matches, and that is why it is right where
  the first one was not.

### The flake is invisible if you run the file

Worth knowing before anybody spends an afternoon on this. The canary module on its
own, twenty consecutive runs on unmodified master:

```
==== module-alone failures on BASELINE: 0 / 20 ====
```

Every run `Result: 10 passed`. The contamination does not come from inside the
file, so **running the file cannot reproduce it** — only the whole suite can. The
packet's instinct to "target the canary module directly" for speed would have
measured nothing at all.

---

## 3. The mechanism, instrumented

The brief says not to start from its explanation, and that was the right call.
Instrumented by printing, at four points, the exporter table's row count and
`Courier.SpanCollector.pending/0`:

* `Courier.SpanCollector.flush/0` → `[FLUSH] caller=… pending=N`
* `Courier.TestSpanExporter.export/4` → `[EXPORT] pid=… n=N route=… trace=… start=…`
* the canary file's `setup` → `[SETUP] pid=… test=… rows_before_clear=N pending_before_clear=N rows_after_clear=N`
* the canary file's `request/4` and `request_spans/0` → `[REQ]` / `[READ]`

All gated on an env var so one run could be traced without drowning in the rest of
the suite's exports. Instrumentation was temporary and is reverted; the tree at
`e761a20` contains none of it.

`COURIER_CANARY_TRACE=1 mix test --seed 885732`, the failing test:

```
[SETUP] pid=#PID<0.5991.0> test=:"test a request PATH never reaches a span an id in an unmatched path reaches nothing at all"
        rows_before_clear=0 pending_before_clear=16 rows_after_clear=0
[FLUSH] caller=#PID<0.5991.0> pending=17
[REQ]   pid=#PID<0.5991.0> GET /v1/accounts/CANARY-4e1b-DO-NOT-EXPORT status=404
[READ]  pid=#PID<0.5991.0> n=17
        route="/inbound/resend" status=200   ×9
        route="/inbound/resend" status=500   ×…
        route="/readyz"       status=503/200 ×4
        route="/healthz"      status=200     ×3
        route=nil             status=404     ×1   <- the only span this test made
```

`request_spans/0` returned **seventeen** spans and the test had made **one**. The
assertion "a 404 produced a span with a route" failed on sixteen spans with routes
belonging to requests made in three other files. Its own span is the `route=nil` one
at the end — a 404 with no route, which is exactly what the test wants.

### The brief's mechanism is refuted, and the real one is a queue

Across all ten setups in that run:

```
9 rows_before_clear=0 pending_before_clear=0  rows_after_clear=0
1 rows_before_clear=0 pending_before_clear=16 rows_after_clear=0
```

**The exporter table was empty before `clear/0` and empty after it, in all ten
setups.** The brief's mechanism — an export landing in the table *after* the next
test's `setup` cleared it — did not happen once. `clear/1` was clearing faithfully
and deleting nothing it should not have.

What was not empty was `Courier.SpanCollector`, and `pending_before_clear` is the
discriminator: **16 for the one test that failed, 0 for all nine that passed.**
Single variable, no overlap.

`Courier.SpanCollector` is a batcher, not a per-request sink. A span ends into its
queue and leaves the queue when something flushes it, and exactly two things flush
it: a test that calls `flush/0`, and the collector's five-second timer. So a test
in another module that drives a request and never flushes leaves its span sitting
in that queue, and the next flush — which is *this test's own* `flush/0` — exports
the whole backlog into the shared table. `clear/1` was clearing the right table and
the leak was upstream of it, in a queue it cannot see.

So: the brief's **window** is right (between "span ended" and "row in the table")
and its **cause** is wrong. The window is not unclosed because of a race; it is
unclosed because it is a queue, and it is wide open rather than narrow. That also
explains the 1-in-10 rate exactly, with no appeal to timing at all: it depends on
whether the modules scheduled just before this one happened to leave a backlog,
which is precisely what a seed decides.

---

## 4. What the fix is, and why it is two steps

**Drain `Courier.SpanCollector`, then mark the exporter table — in that order.**

`test/courier/telemetry_canary_test.exs`, `setup`:

```elixir
Courier.SpanCollector.flush()

Process.put(@mark_key, Courier.TestSpanExporter.mark())
```

and `request_spans/0` now reads `Courier.TestSpans.finished_spans_since/1`
filtered by name, instead of the whole table.

Neither step is sufficient on its own, and the same measurement says why for both:

* **The mark alone is not enough.** A watermark filters by *when a row arrived*,
  not by which test made the span. The sixteen foreign spans are inserted into the
  table *after* any mark taken now — being exported late is exactly what being stuck
  in a queue means. This is not a guess; it is what the instrumented run shows.
* **The drain alone is not enough.** It empties the queue but leaves every
  previously *exported* row in the table, so the next test in the file still reads
  the previous test's span — which is the failure the old comment at 305–308 was
  half-right about.

The packet listed three options. Measured rather than assumed:

* *Tag each span with an identifying attribute* — not taken. The exporter is the
  real SDK, the read is of an opaque finished span record, and `Courier.Observability.record/2`'s
  allowlist is six names wide; adding a test-only tag would mean either widening
  that allowlist or reaching around it. §7 shows the allowlist working exactly as
  designed against an injected attribute.
* *Assert on the delta rather than the whole table* — **this is the one taken.**
* *Make the export synchronous with respect to the test* — not needed and not
  possible from here: the batching lives in `Courier.SpanCollector`, in `lib/`, and
  it is deliberate (bounded queue, one timer, `Courier.SpanCollector`'s moduledoc
  argues for it against a memory-leak argument). Draining it is the test-side
  equivalent of the same guarantee without changing production behaviour.

### The comment the packet asked me to fix

The old comment said the name filter was the defence, and admitted in the same
breath that the filter "cannot tell them apart". Both halves were true and they
contradict each other, which is why the failure shipped. It is replaced with what
the arrangement now is, and the admission is kept rather than deleted — the filter
still cannot tell two `courier.web.request` spans apart, which is why it was never
the defence. The measurement and the two-step reasoning live in `setup`.

### Not done: `clear/0` is gone from this file, and the table now grows

The exporter table is never pruned. Bounded by the suite rather than by the code —
one row per exported span, a full `mix test` on the order of a thousand — and it
was already the case for every other module. Noted rather than silently accepted;
if it ever matters, pruning by id is a two-line change in `take/0`'s neighbourhood
and not before.

---

## 5. The second defect, which the fix ran straight into

Wiring the watermark in made the flake go green immediately — which is exactly the
outcome the packet forbids, so the read count got instrumented before anything was
committed:

```
[READ] mark=6  pending=0 n=0 routes=[]
[READ] mark=7  pending=0 n=0 routes=[]
[READ] mark=9  pending=0 n=0 routes=[]
[READ] mark=12 pending=0 n=0 routes=[]
[READ] mark=15 pending=0 n=0 routes=[]
```

**`n=0`.** Every canary test, reading nothing, passing. A 1-in-10 red turned into a
0-in-10 green — the same defect this file was written to prevent, reached by
fixing the flake.

The cause: `Courier.TestSpanExporter.mark/0` and `take_since/1` **never worked, and
had no callers anywhere in the repository.** `export/4` numbered its rows with a
plain `:erlang.unique_integer()` and `mark/0` drew from
`:erlang.unique_integer([:monotonic, :positive])`. Those are two different
sequences, not two draws from one counter:

```
iex> {m, r, r > m} = {erlang.unique_integer([:monotonic, :positive]),
...>                   erlang.unique_integer()}
{1, -576460752303422142, false}
```

The monotonic sequence counts up from 1; the plain one counts **down** from
-576460752303423488. `take_since/1` asks `id > mark`, so it asked a negative number
whether it beat a small positive one, and the answer was no for every row on every
run. `take_since/1` returned `[]` always.

Nobody caught it because nothing called it — the only occurrence of
`TestSpans.finished_spans_since`/`take_since` in the tree was the docstring
describing what it was for. That is also the shape of the flake: a helper that was
correct on paper, documented at length, and never asked whether it worked.

Both sides now draw from one private `row_id/0`, monotonic rather than plain
because monotonic is the only one of the two the OTP documentation *guarantees* to
be strictly increasing — a watermark resting on an ordering nobody promised is a
watermark that works until it does not.

### The regression test, and proof it bites

`test/courier/test_span_exporter_test.exs` is new, `async: false`, and drives real
requests through the real endpoint so the assertion is about a watermark rather
than about two integer helpers. Three tests:

* a watermark hides a span already exported before it and shows one exported after
  (two requests told apart by their `http.route`);
* the window is a **suffix** of `take/0` in `take/0`'s order — derived from the
  reads, not hand-written;
* **a mark does NOT exclude a span produced after it**, which is the caveat that
  makes the drain in the canary file load-bearing. Asserted rather than left in a
  comment, because it is precisely what a future refactor would delete as
  redundant. Reverse it and the drain becomes deletable.

Mutation, verified in the file before the run (`grep -n "MUTATION\|row_id"`
returned lines 152, 171–174), row ids put back on the plain sequence and `mark/0`
left monotonic:

```
1) test a mark does NOT exclude a span produced after it [...]   code: assert ... != []
2) test a watermark hides what was already exported [...]       code: assert "/healthz" in routes.(...)
3) test the window is a SUFFIX of the table [...]                code: assert window != []
Result: 0/3 passed
Failed: 3 tests
```

With the fix: `Result: 3 passed`.

---

## 6. The round trip: the canary still fires

### 6a. A planted leak

The realistic leak, planted in `lib/courier_web/plugs/telemetry.ex` — record
`conn.request_path`, the concrete caller-controlled path, instead of the matched
route pattern, on every span including a 404's:

```elixir
# MUTATION: the leak this canary exists to catch. The CONCRETE,
# caller-controlled path instead of the matched route pattern, on every span
# including a 404's — unbounded text in a metric label and a customer's
# unsubscribe token on a span, in one move.
finish(span, conn.request_path, conn.status || @raised_status)
```

```
1) test a request body never reaches a span a notification preference, keyed to a user, exports neither the id nor the answer
   test/courier/telemetry_canary_test.exs:141
   ** (RuntimeError) THE REDACTION BOUNDARY LEAKED.

   The canary "CANARY-4e1b-DO-NOT-EXPORT" reached an exportable span attribute. It was
   planted in a field a caller controls, so whatever route it took is a route by
   which a customer's email, a password, a webhook signing secret or a bearer token
   reaches a searchable, retained, widely-readable store — [...]

   The whole export:

   name=courier.web.request kind=server status=unset http.request.method="PUT" http.response.status_code=401 http.route="/v1/notification_preferences/usr_CANARY-4e1b-DO-NOT-EXPORT"

   code: assert_no_canary()

Result: 5/10 passed
Failed: 5 tests
```

Five of ten red: the three `assert_no_canary` tests that plant the canary in a path
or a URL, the unsubscribe-token test, and the "an id in an unmatched path" test
(the 404 now carries a route, which is the assertion it exists for). Removed, and
the module is back to `Result: 10 passed`.

Two things in that output are worth reading twice:

* **The export contains exactly one span** — this test's own. Before commit 1 the
  same render would have carried the whole suite's backlog. The narrowing is
  visible in the failure message.
* **My first attempt at this mutation did not fire.** I planted
  `courier.mutant.path`, an attribute name outside the allowlist, and the canary
  module reported `Result: 10 passed`. `Courier.Observability.record/2` refused it
  — that is the allowlist doing its job, and it means a leak has to arrive on one
  of six allowed names to reach a span. Worth recording: the canary tests prove what
  the allowlist *misses*, and this round trip is what shows the allowlist is not
  decorative.

### 6b. The presence assertion

The packet requires the canary's presence assertion to survive. **It did not
exist**, and that is the third finding, in `b60cb0a`.

This file's moduledoc said:

> `Courier.TestSpans.rendered!/0` raises rather than returning an empty string, so a
> suite in which courier exported nothing fails loudly instead of passing quietly.
> That guard is the single place this is checked.

It did not call `rendered!/0`. It had a private renderer returning `""` for an empty
export, and `assert_no_canary/0` was satisfied by an empty string. The only
occurrence of `TestSpans.rendered!/0` in the repository was the sentence claiming it
was guarding this file.

Round trip, both directions, `Courier.TestSpanExporter.export/4` mutated to drop
every span:

```
before commit b60cb0a    test/courier/telemetry_canary_test.exs   Result: 10 passed
after  commit b60cb0a    test/courier/telemetry_canary_test.exs   Result: 0/10 passed
                         Courier.ObservabilityTest                Failed: 8 tests
```

Ten redaction tests green while exporting nothing, before. Zero after. The guard
also names the span count, because an empty result has two causes diagnosed in
opposite directions — courier exported nothing, or the caller's own filter hid
everything:

> **nothing to render (0 spans in)**, so every assertion about a canary being absent
> from that render would be vacuously true.
>
> Two causes, diagnosed in opposite directions. If courier exported NOTHING, check that
> the request really reached `CourierWeb.Plugs.Telemetry`, that
> `Courier.Telemetry.enabled?/0` is true, and that `config/test.exs` still names
> `Courier.TestSpanExporter` as `config :courier, :otel_exporter`.
>
> If courier exported plenty and the CALLER'S FILTER hid it, the filter is the bug: a span
> name that has changed, or a watermark whose window is empty because
> `Courier.SpanCollector` was not drained before `Courier.TestSpanExporter.mark/0`.
> Print `Courier.TestSpanExporter.take/0` and count — the spans are there.

The second cause is this file's own bug from commit 1, so it is named in the message
that a future version of this file will read.

---

## 7. The after-count

**Thirty consecutive `mix test`, no seed argument, on this branch. 1317 tests each
(1314 + the 3 new ones).**

```
run 1  seed 755444  1317 passed     run 16  seed 958922  1317 passed
run 2  seed 839349  1317 passed     run 17  seed 821635  1317 passed
run 3  seed 410958  1317 passed     run 18  seed 487036  1317 passed
run 4  seed 544291  1317 passed     run 19  seed 493832  1317 passed
run 5  seed 560565  1317 passed     run 20  seed 406304  1317 passed
run 6  seed 829891  1317 passed     run 21  seed 227543  1317 passed
run 7  seed 14366   1317 passed     run 22  seed 131860  1317 passed
run 8  seed 171890  1317 passed     run 23  seed 54454   1317 passed
run 9  seed 179817  1317 passed     run 24  seed 267872  1317 passed
run 10 seed 230534  1317 passed     run 25  seed 219959  1317 passed
run 11 seed 956184  1317 passed     run 26  seed 357658  1317 passed
run 12 seed 640578  1317 passed     run 27  seed 801514  1317 passed
run 13 seed 407081  1317 passed     run 28  seed 392585  1317 passed
run 14 seed 19161   1317 passed     run 29  seed 69629   1317 passed
run 15 seed 970442  1317 passed     run 30  seed 312114  1317 passed

==== FAILURES: 0 / 30 ====
```

And the hard reproducer, three times:

```
$ mix test --seed 885732
Result: 1317 passed      (×3; was 1313/1314, Failed: 1 test, ×3)
```

Canary module alone, twenty consecutive runs on this branch: `0 / 20` red. That
number means what §2 says it means — it was 0/20 red before too, and it is not
evidence about the flake. It is reported because it was measured, and because
"running the file is not a reproducer" is the single most useful thing to know
about this defect.

**Tallies, kept apart from passes, in the same voice as the before-rate: 2 failures
in 20 runs before, 0 in 30 after; 3 of 3 red at seed 885732 before, 3 of 3 green
after. Thirty runs is not proof of zero — at a 1-in-10 rate, 30 clean runs puts the
upper bound on the residual rate at roughly 1 in 77 (95%). It is proof that the
mechanism is gone rather than that the flake is unlucky.**

---

## 8. Found outside the packet, named, not silently expanded

1. **`Courier.SpanCollector`'s moduledoc claims a test file that does not exist.**
   `lib/courier/span_collector.ex:44`:

   > * it is asserted, not assumed: `test/courier/span_collector_test.exs` drives a
   >   real request and reads what came out the other end.

   `test/courier/span_collector_test.exs` does not exist. And a grep for assertions
   on `SpanCollector.pending/0`, `capacity/0`, the 2000-row bound or `drop_oldest/1`
   returns **nothing, anywhere in `test/` or `lib/`**. The collector is the component
   this entire flake lived inside — its batching is the mechanism — and its capacity
   bound, its drop-oldest policy and its five-second timer are all unasserted. A
   docstring asserting a safety property over a file that is not there is worse than
   no docstring, and this one is load-bearing: it is the reason a reader believes
   the collector is covered. Worth its own packet; writing that file is a different
   afternoon from this one.

2. **`Courier.ObservabilityTest.spans_for/1` has the same shape and a comment that
   repeats the claim that was false.** `test/courier/observability_test.exs:341-346`:

   > So clearing the shared table here cannot delete another test's evidence. The
   > canary test, which is also `async: false` and DOES share the table, therefore
   > identifies its spans by name instead.

   It cannot go vacuous — `spans_for/1` has its own `flunk("expected exactly one
   `courier.test` span, got 0")`, and §6b measured it catching the dead exporter
   with 8 failures where the canary file caught nothing. It is also not exposed the
   way the canary file was, because `courier.test` is opened by exactly one call
   site, so the name filter *is* sufficient there. The problem is narrower and
   real: it reads the whole table and clears it, and its comment asserts as a fact
   the thing this packet spent its time proving false — that name-identification is
   what makes a shared-table reader safe. Left alone deliberately: switching it to
   the watermark is a small change, and making that change is not this packet's
   call.

3. **`Courier.TestSpans.by_name/1` has no callers** — grep returns nothing outside
   its own definition. Left in place; it is a two-line accessor with a doc and
   removing it is a manager's call, not a side effect of a flake fix.

4. **The canary `setup` now exports other tests' backlog into the exporter table**
   (that is what draining is). The table is never pruned. Bounded by suite length
   rather than by code, and it was already the case for every other module — named
   here so it is a decision rather than an oversight.

---

## 9. Checklist

- [x] Committed to `worker/courier-telemetry-canary-flake-01`. Not pushed, not merged.
- [x] Two commits, both worth a reviewer's slot. No scaffolds, no WIP markers, no
      commit message describing an intention.
- [x] Every command bounded by `timeout`. The long ones: full-suite runs at 300s
      (they take 5.4s), module runs at 300s, worktree/deps copy at 300s.
- [x] Nothing skipped. Nothing sharded. The only opt-out in this report is stated
      as an opt-out: the canary-module-alone counts in §2 and §7 are labelled as not
      being evidence about the flake, because they were 0/20 on the baseline too.
- [x] Every "fixed" claim has before/after: §7's table, §6a's 5/10 → 10/10, §6b's
      10 passed → 0/10, §5's 0/3 → 3/3.
- [x] Every mutation verified present in the file by `grep` before its run was
      counted — `MUTATION` lines at test_span_exporter.ex:91 and 152/171-174, and
      lib/courier_web/plugs/telemetry.ex:220. None of them are in the tree; `grep -c
      MUTATION` returns 0.
- [x] No containers, images or volumes started or left running. Nothing was needed:
      courier's Postgres is on the machine's own 5432. The other sessions'
      containers (`site-e2e-*`, `cafaye-*`) were listed once, read only, and left
      alone; `guard`, `cafaye-ts`, `site`, `identity` and `pantry` were not touched.
- [x] `REPORT-courier-telemetry-canary-flake-01.md` at the repo root (where every
      other courier report lives, and where it can be committed) and a copy at
      `moon/logs/` (where the packet asked for it — that directory is not a git
      repository, so the copy there cannot be committed and the root one is the
      committed copy).

## 10. What I would do next

1. **Give `Courier.SpanCollector` the test its moduledoc claims exists** (§8.1). It
   is the component the flake lived in and it has no assertions at all. The three
   worth writing are the capacity bound, the drop-oldest order, and that a flush
   exports everything pending — the last one is the fact this whole packet turned on.
2. **Switch `Courier.ObservabilityTest` to the same drain-then-mark** (§8.2), and
   delete the sentence at `observability_test.exs:341-346` that asserts as fact the
   thing that was false.
3. **Re-measure the before-rate on a machine where `mix test --seed 890226` does
   reproduce**, so the reported rate has a second source. One in ten on one box is
   one measurement, and §2's honest note about the packet's seed not reproducing
   here is the reason to want a second.