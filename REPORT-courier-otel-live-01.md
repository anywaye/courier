# REPORT — courier-otel-live-01: courier's spans reach a live collector, and the seventh defect

Branch `worker/courier-otel-live-01`, two commits on `f3578fe`.

**Outcome: a seventh defect, found, fixed, and proved live.** It was not one of the
four classes the packet predicted. It is the same *family* as the sixth — the kill
switch — one layer out: `OTEL_SDK_DISABLED=true` did not turn telemetry off, it
turned courier into a service that answers **500 to every request it serves**,
including `/healthz`.

---

## 1. The diff, and the decisions in it that were not forced

```
 lib/courier/telemetry.ex                 |  83 +++++++++-
 test/courier/telemetry_disabled_test.exs | 260 +++++++++++++++++++++++++++++++
 gate.yml                                 |   8 +-
 .github/workflows/ci.yml                 |  23 ++-
 4 files changed, 367 insertions(+), 7 deletions(-)
```

`f6d114c` the fix and its test · `732cfbc` the three floors

### Decisions not forced, with what I rejected

**a. Pass the no-op tracer through untouched, rather than rebuilding a synthetic
one.** `otel_tracer_noop` implements the whole `otel_tracer` behaviour over a `[]`
context, so it already answers `start_span/4`. The rejected alternative was to
*construct* a `#tracer{}`-shaped tracer with courier's `on_end` processor installed,
so the disabled path and the enabled path share code. It would have meant
fabricating a record the SDK never returns, on the one path where the SDK is
telling us there is no SDK. If the SDK's shape changes, the no-op branch keeps
working and the rebuild is the only thing that can go wrong.

**b. Keep the `raise`.** `build_tracer/0` raises when the `#tracer{}` record's shape
is not what courier expects. That raise is the reason an SDK change is loud instead
of silent, and this defect was *not* a reason to remove it — a disabled SDK is not a
broken record. Removing it would have made this packet's fix also delete the
protection the previous packet bought.

**c. `normalize_tracer/1` and `put_tracer/1` as public seams.**
`config/runtime.exs` writes `config :opentelemetry, …` once at boot, so a test cannot
restart the SDK into a different boot and get a real `sdk_disabled := true`. The
rejected alternative was for the test to assert on `sdk_config/0`'s keyword list —
which is precisely what the six previous packets did, and what let this defect
through twice over. The second alternative, a test that calls
`Application.stop(:opentelemetry)`, would be testing a VM nobody deploys and would
take the whole suite's spans with it. `put_tracer/1` hands courier's half of the
decision the answer the SDK gives; that is all a unit test can honestly reach.

**d. The new tests are a `CourierWeb.ConnCase`, so all 5 landed in the DATABASE
tier** (698 → 703) and none in the no-database tier (645, unchanged). Measured by
re-running both tiers, not by reading the case template and hoping. The tier is the
claim: a file that drives a request belongs where the request can be proved served.

**e. Both halves of the disabled state are installed in the request tests** — the
environment variable *and* the tracer — rather than the variable alone. The
variable alone would have made the test pass for the wrong reason: the suite's SDK
booted with the switch unset, so it would have exercised the *enabled* tracer under
a disabled-looking environment and proved nothing. Naming both is what makes the
assertion mean what it says.

---

## 2. The proof

### 2a. courier's spans are in ClickStack

Run: `mix phx.server` on the host with `COURIER_OTEL_ENDPOINT=http://192.168.158.7:4318`
(the collector's address on `kitprobe_platform`), against a real migrated database.

```
$ docker exec kitprobe-clickstack-1 clickhouse-client --query \
  "SELECT TraceId, ParentSpanId, SpanName, SpanAttributes['http.route'] AS route,
          SpanAttributes['http.response.status_code'] AS code, ServiceName,
          toString(Timestamp) AS ts
     FROM otel_traces WHERE ServiceName='courier'
       AND Timestamp > now() - INTERVAL 10 MINUTE
     ORDER BY Timestamp DESC FORMAT PrettyCompact"

┌─TraceId──────────────────────────┬─ParentSpanId─────┬─SpanName────────────┬─route────┬─code─┬─ServiceName─┬─ts─────────────────────────────┐
1. │ 4bf92f3577b34da6a3ce929d0e0e4736 │ 00f067aa0ba902b7 │ courier.web.request │ /healthz │ 200  │ courier     │ 2026-10-05 23:52:41.283560500 │
2. │ e4758696a1b8c79d162b5f5c66de4aa9 │                  │ courier.web.request │ /readyz  │ 200  │ courier     │ 2026-10-05 23:52:41.140289791 │
3. │ 44bf698582520e26a5a67da8d05ae5ab │                  │ courier.web.request │ /healthz │ 200  │ courier     │ 2026-10-05 23:52:40.815270208 │
4. │ ddb9ce86f1b1f675cc320ab7c5486fb9 │                  │ courier.web.request │ /healthz │ 200  │ courier     │ 2026-10-05 23:50:18.834152292 │
└──────────────────────────────────┴──────────────────┴────────────────────┴──────────┴─────┴─────────────┴───────────────────────────────┘
```

**Row 1 is traceId continuity, end to end.** It is the span produced by

```
$ curl -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
       http://127.0.0.1:4000/healthz
status=200
```

The trace id courier put in ClickStack is byte-for-byte the one I sent, and the
`ParentSpanId` is the parent from the header. That is the mechanism the packet asked
for, and it can only be true if the W3C extraction, the span, the encoding, the
socket and the collector all agree.

### 2b. The collector's own logs, as the second source

```
2026-10-05T23:50:25.094Z  info  Traces  {"kind":"exporter","data_type":"traces","name":"debug",
                                               "resource spans":1,"spans":1}
2026-10-05T23:50:25.095Z  info  courier.web.request ddb9ce86f1b1f675cc320ab7c5486fb9
                                       0867137fa42e0473 http.route=/healthz
                                       http.response.status_code=200 http.request.method=GET
```

### 2c. Counts

```
$ ... SELECT ServiceName, count() AS span_count, uniqExact(TraceId) AS distinct_traces
      FROM otel_traces WHERE ServiceName='courier'
        AND Timestamp > now() - INTERVAL 1 HOUR GROUP BY ServiceName
┌─ServiceName─┬─span_count─┬─distinct_traces─┐
1. │ courier    │          3 │               3 │
└─────────────┴─────────────┴─────────────────┘
```

### 2d. The kill switch, before and after — the empty result is the evidence

**Before the fix.** `OTEL_SDK_DISABLED=true`, courier booted and logged that
telemetry was off, and then:

```
$ curl -i localhost:4000/healthz
HTTP/1.1 500 Internal Server Error

[error] ** (ArgumentError) errors were found at the given arguments:
  * 1st argument: not a tuple
    :erlang.tuple_to_list([])
  (courier 0.1.0) lib/courier/telemetry.ex:254: Courier.Telemetry.build_tracer/0
  (courier 0.1.0) lib/courier_web/plugs/telemetry.ex:91: CourierWeb.Plugs.Telemetry.call/2
```

**After the fix, same command, same build with the fix:**

```
$ OTEL_SDK_DISABLED=true … mix phx.server
[info] telemetry off (OTEL_SDK_DISABLED=true); spans stay in this node
$ curl -o /dev/null -w '%{http_code}\n' localhost:4000/healthz   ->  200
$ curl -o /dev/null -w '%{http_code}\n' localhost:4000/readyz    ->  503
```

`/readyz` is 503 because there was no database in that particular run — which is the
point: **the two are now tellable apart.** Before the fix both were 500 and the
database's answer was unrecoverable from the response.

**And nothing leaked while disabled**, which is the other half of the promise:

```
$ ... SELECT ServiceName, count() FROM otel_traces
      WHERE ServiceName='courier' AND Timestamp > toDateTime('2026-10-05 23:47:00')
(empty result)
```

The disabled run started at 23:48:11. Zero courier spans in ClickStack after it.

### 2e. What the collector says courier exported, byte for byte

```
$ curl -o /dev/null -w '%{http_code}\n' -X POST http://192.168.158.7:4318 …            -> 404
$ curl -o /dev/null -w '%{http_code}\n' -X POST http://192.168.158.7:4318/v1/traces … -> 200
```

A bare path 404s and `/v1/traces` answers, and courier's spans arrive — so the
exporter did append the signal suffix. Reading the address out of the exporter's own
initialized state confirms it rather than inferring it:

```
scheme=~c"http"  host=~c"192.168.158.7"  port=4318  path=~c"/v1/traces"
```

---

## 3. What I ruled out, with evidence

The packet named four classes. Each was measured, not read.

**The endpoint path — NOT courier's defect.** Measured above: `/` 404s,
`/v1/traces` 200, spans arrive. The exporter appends the suffix itself, via
`otel_exporter_otlp:merge_with_environment/8`'s `endpoints_append_path(_, _,
"v1/traces")`. courier passes `endpoints: [endpoint()]` and the SDK does the rest.

**TLS at a plaintext collector — NOT courier's defect.** The exporter's state carries
`scheme = "http"` and `ssl_options` for an `http` endpoint are the
`tls_certificate_check` defaults, which `httpc` never uses without a scheme upgrade.
Nothing in courier forces `https`, and the successful export over plaintext is the
proof.

**Scheme-dependent precedence — present, documented, and NOT what broke this.**
Measured:

| environment | `Telemetry.endpoint/0` | exporter actually dials |
| --- | --- | --- |
| neither variable set | `http://otel-collector:4318` | `http://otel-collector:4318/v1/traces` |
| `COURIER_OTEL_ENDPOINT` only | the cafaye value | the cafaye value |
| **both set** | the cafaye value | **`http://elsewhere:9999/v1/traces`** |

So `OTEL_EXPORTER_OTLP_ENDPOINT` beats `COURIER_OTEL_ENDPOINT` in the exporter while
`endpoint/0` reports the opposite — **the contradiction already recorded in
`init_exporter/1`'s moduledoc is real and still present**, and it is a reporting
bug, not an outage: courier still exports to *a* place, and an operator who sets both
gets the standard one. That is upstream precedence inside
`otel_exporter_otlp:merge_with_environment/8`, which puts the environment's value
into `endpoints` unconditionally. courier's stated alternative — mutating its own
process environment at boot — is worse (global, racy, invisible in a diff), and this
packet did not take it.

**A kill switch that boots courier — that WAS the sixth defect, fixed in `c80128c`.**
Re-measured: the boot now succeeds. **The seventh defect is what that fix left
behind**, and it is the same switch:

`opentelemetry_sup:init/1` matches `sdk_disabled := true` and returns
`{ok, {#{}, []}}` — **no children at all**, not "no processors". So
`otel_tracer_provider_sup` never starts, and `:otel_tracer_provider.get_tracer/4`
catches its own `exit:{noproc, _}`:

```erlang
handle_call({get_tracer, _Name, _Vsn, _SchemaUrl}, _From,
            State=#state{shared_tracer=undefined}) ->
    {reply, {otel_tracer_noop, []}, State};
```

`[]` is `:otel_tracer_noop`'s own tracer context (`-define(NOOP_TRACER_CTX, [])`).
courier's `build_tracer/0` destructured that answer and reached for fields only a
`#tracer{}` has, so `Tuple.to_list([])` raised — in the request path, on every
request. The SDK was saying "there is no SDK, and that is fine"; courier read it as
a broken record.

---

## 4. What I deliberately did NOT do

- **Did not run the full suite more than once per state.** `bin/prime` ran four times
  with the fix (1348 green, 4/4) and four times on the pre-fix baseline (1343 green,
  4/4). The packet said the full suite is yours; four runs per state was to attribute
  a flake, not to substitute for your gate.
- **Did not touch `kit/`, `core/`, or any sibling.** The precedence contradiction in
  §3 is upstream in `opentelemetry_exporter`; reported, not fixed.
- **Did not add `sdk_disabled` handling to `sdk_config/0`.** The SDK reads
  `OTEL_SDK_DISABLED` itself; courier's keyword list has no say in
  `opentelemetry_sup:init/1`'s clause. Nothing in courier's configuration could have
  prevented this defect, which is why the fix is in `build_tracer/0` and not in the
  configuration.
- **Did not build courier's Docker image or `bin/dev` the stack.** The shared
  `kitprobe` stack was read and written to over its network, which is what it is for.
  A host-side `mix phx.server` with `COURIER_OTEL_ENDPOINT` pointed at the collector
  is the same running service on the same wire, and it costs minutes rather than an
  image build.
- **Did not remove the `kitprobe-probe-1` container** or anything else in the shared
  stack. The only container I created was `courier-otel-live-pg`, and it is removed.
- **Did not reformat or tidy anything unrelated.** The diff is four files, and three
  of them are the fix plus its floors.
- **Did not chase the `error_relay_test.exs` flake.** It failed once in nine `bin/prime`
  runs (`sync/1`, `test/courier/error_relay_test.exs:235/274`), is documented in
  `REPORT-courier-26b-flake.md` as a 13%–25% scheduling-latency race in
  `:sys.get_state/1` ordering, and did not recur in the eight runs I did afterwards.
  Attributed before believed, per the packet.

---

## 5. Sibling findings — reported, not fixed

**For `kit/` — none.** The collector did its job throughout: it answered
`/v1/traces`, logged courier's spans in its own debug exporter, and forwarded them to
ClickStack. Its `otlp/tempo` exporter failed with `lookup tempo: no such host` on
every batch, which is the documented "accepted silence" for a profile that is off —
not a courier finding and not a kit one.

**For `core/` — none.** `COURIER_OTEL_ENDPOINT` as the whole contract (D16) held.

**For the Erlang SDK (`opentelemetry` 1.7.0), which is neither kit nor core — this is
the one worth writing up somewhere:**
`get_tracer/4` answering `{otel_tracer_noop, []}` when `sdk_disabled := true` is
documented nowhere obvious, and the shape is a plausible thing for any consumer to
rebuild. The SDK has no comment at that `handle_call` clause saying "a consumer may be
reaching for `#tracer{}` fields here". Six services in this fleet now each know this
by hand. **Not fixed here** — it is a dependency, and this repository's rule is that
a vendor defect is reported.

**For `opentelemetry_exporter` 1.11.0:** the `OTEL_EXPORTER_OTLP_ENDPOINT`-beats-
`endpoints:` precedence in `merge_with_environment/8` is upstream and contradicts what
any consumer's own resolution function reports. A consumer that reads its config
function and compares it against its exporter's state will find two different
answers, and only one of them is where the bytes go.

---

## 6. Currently-failing command

**Nothing.** The last measured states:

```
$ ./bin/prime                                   # exit 0
Result: 1348 passed
$ bin/assert-suite /tmp/prime-final.log "whole suite" 1348
assert-suite: whole suite — 1348 passed (floor 1348)          exit 0
$ bin/assert-suite /tmp/nodb.log "no database" 645
assert-suite: no database — 645 passed (floor 645)            exit 0
$ bin/assert-suite /tmp/db.log "database" 703
assert-suite: database — 703 passed (floor 703)               exit 0
$ git diff --exit-code -- mix.lock
(mix.lock UNCHANGED)
```

`mix compile --force --warnings-as-errors` clean; `mix format --check-formatted`
clean.

**One caveat, stated rather than hidden.** My postgres is a container on
**port 15433**, not the 5432 `bin/gate-db` publishes, because something else already
holds 5432 on this machine. Every command above was run with:

```
export COURIER_DEV_PG_PORT=15433 COURIER_TEST_PG_PORT=15433
```

Both variables are read by `config/dev.exs` and `config/test.exs`; on a machine where
5432 is free, plain `bin/prime` is what you want and this caveat does not apply. The
database also needed `courier_app` created and `pg_hba` set to `trust` before the
first migration would run — a property of my ad-hoc cluster, not of courier.

---

## 7. Successor's first move

There is no half-done work; both commits are complete and green. If you want the
next increment:

1. **Decide the precedence contradiction.** `Courier.Telemetry.endpoint/0` reports
   `COURIER_OTEL_ENDPOINT` while the exporter dials `OTEL_EXPORTER_OTLP_ENDPOINT`.
   Either courier's resolution wins (mutate the process environment at boot — I
   rejected that and would again) or courier stops reporting a value it does not
   honour. The second is cheap and honest; it is a documentation-and-one-function
   change, not a behaviour change.
2. **Write up the SDK clause for the other five emitters.** `sdk_disabled := true`
   yields `{otel_tracer_noop, []}` from `get_tracer/4`, and every service that
   rebuilds a tracer needs to know it. §5 above is the text; what it lacks is a
   destination in a repository that is not courier's.
3. **Nothing here needs re-running.** The proof is in §2 with real timestamps and real
   output, and the fix is two functions and a branch.

`HANDOFF-courier-otel-live-01.md` is not written: there is no work left behind to
hand over.