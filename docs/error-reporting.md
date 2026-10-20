# error reporting in courier

How an unhandled error in courier becomes a redacted, deduplicated, throttled row
in a GlitchTip the other two services also write to — and why each piece is the
shape it is. This document is the design and the citations.

## The three layers, and which one reports

PLAN.md §7b describes courier's error layers. The SDK reporting is the **third**
and the least important: a handled error, a retry that worked, and a degraded
dependency that degraded on purpose are all **events**, and events go to the OTel
pipeline where the collector already redacts them. What the SDK adds is the thing
the trace pipeline is not for — an error nobody caught, with the file, the line
and the function, in a place designed for triage.

So `Courier.ErrorReporting` has two entry points and the distinction is visible at
the call site rather than behind a config flag:

```elixir
Courier.ErrorReporting.capture(exception, extra: %{job_id: id})   # unhandled
Courier.ErrorReporting.capture_any(exception, extra: %{attempt: 3}) # deliberate
```

`capture/3` is for a crash. `capture_any/3` exists so that a **retried** error is
a deliberate, greppable act rather than something a threshold turns on
automatically — the same reason the collector does not record retried spans.

## OTel conventions, verified from source

The `error.type` vocabulary is **not invented here**. It is core's, and the
provenance was checked in `open-telemetry/semantic-conventions` rather than
remembered:

- **`error.type` is Stable.** Its spec says it SHOULD be a *predictable,
  low-cardinality* value, and SHOULD NOT be set on a successful operation. A
  low-cardinality closed enum is exactly the requirement, which is why the list is
  an enum rather than an exception class name.
- **`_OTHER` is the Stable fallback** for a value that does not fit the vocabulary.
  It is the last member of `Courier.ErrorRelay.Policy.error_types/0` and it is
  used, not defined-and-ignored.
- **Handled and retried errors SHOULD NOT be recorded.** From the same spec's
  recording guidance, which is what `capture_any/3` exists to respect.
- **`recording-errors.md` is Development status**, so it is cited as guidance and
  not as a contract. The contract this repository enforces is core's
  `docs/observability.md`, which is where the 12 values plus `_OTHER` come from.
- **Span status `Error`** is set by the instrumentation rather than by the SDK
  here; the SDK is not a span producer and pretending otherwise would mean
  inventing a second status channel.

**Absent is refused, not defaulted.** `Policy.classify/1` refuses an `error.type`
that is not in the vocabulary; an undeclared value becomes `_OTHER` only when the
reporter says so explicitly. The difference matters: a typo silently becoming
`_OTHER` would put a class of bug into the store's "everything else" bucket where
nobody filters on it.

## Two barriers, and why the second one is the fleet's

Core's `schemas/telemetry/redaction.schema.json` asks for `defenceInDepth`, an
`enforcedAt` per rule, and a `neverRecord` list. This repository implements it as
two independent allowlists:

1. **`Courier.ErrorReporting.Filter`** — the Sentry SDK's `before_send`. It runs
   in the reporting process, **before the envelope exists**, so it is the barrier
   that survives a DSN misconfiguration. A DSN pointed at a third party by mistake
   still cannot ship an exception message or a request URL.
2. **`Courier.ErrorRelay.Policy`** — the relay, on the way in, on **every**
   service's envelopes including courier's own. It is the fleet's boundary, and it
   is the one that has to be right for `identity` and `billing`, whose SDKs
   courier does not control.

`Policy`'s `blocked_values` is copied **byte-for-byte** from the collector's list in
`kit-worker-kit-18-integrate/templates/compose/otel-collector.yml` — JWTs,
`sk-`, `sk-ant-`, `Bearer`. A value the collector would never persist is a value
the relay never forwards, and the two lists cannot drift because one is derived
from the other rather than remembered.

**The exception message is dropped, and that is the price of admission.** An error
store is retained for months and is readable by anybody with dashboard access; the
exception message is the part most likely to contain a value a user typed. So
`Policy` keeps `error.type`, the exception **class**, `filename`, `abs_path` and
`function`, and drops the message and the frame `vars` — the latter because Elixir
frame variables are the **bound arguments**, which is the most direct route to a
credential that exists anywhere in this system. The collector already deletes
`exception.message` and `exception.stacktrace` for exactly this reason.

One documented narrowing: SDK-side envelopes can contain `"vars":null`, because
`vars` is a declared field of `Sentry.Interfaces.Stacktrace.Frame` and the struct
round-trip restores it at its default. The **relay** drops the key outright; the
assertion is on the value, and both are stated in
`CourierWeb.ErrorReportingTest` rather than left as a surprise.

## The relay speaks the Sentry protocol, because it has to

Every client of this relay is a Sentry SDK, and **an SDK cannot be told where to
post**. `Sentry.DSN.parse/1` pops the last path segment off the DSN as the project
id and rebuilds the URL as `<base>/api/<project_id>/envelope/`. That single fact
determines three things:

- the route is `POST /api/:project_id/envelope/`;
- the token is read from **`X-Sentry-Auth`**, as `sentry_key`, because a DSN's
  userinfo is what an SDK puts there — `COURIER_ERROR_RELAY_TOKEN` *is* the key
  half of the relay DSN an operator writes;
- the route is **symmetric** with the relay's own output, since
  `Courier.ErrorRelay.Sink.Req` posts to `<scheme>://<host>/api/<project>/envelope/`
  too. What comes in is what goes out; courier adds authentication, redaction and
  throttling.

The consequence is the whole argument for the relay: **three unmodified SDKs feed
it with no bespoke HTTP client on any of them**, and the reporters share one DSN
shape and one secret.

**The project id is ignored.** All three services report into the one project
`COURIER_ERROR_SINK_DSN` names. Honouring a caller-supplied project id would mean
either a sink DSN per project or a caller choosing which store its crash lands in.
Separation between services is the `error.type` vocabulary plus a `service.name`
tag, both set from the envelope.

**A DSN with a base path is not served, deliberately.** `pop_project_id/1` splits
the path, so a prefixed DSN derives a prefixed URL — and the surface is on its own
port, published nowhere, and its shape should not be whatever a token holder's DSN
says. A prefixed DSN gets a `404` and the fix is a character in the operator's
configuration, not a code change.

## Deduplication and throttling: two controls of different kinds

- **Client-side limiter** (`Courier.ErrorReporting`): one report per fingerprint
  per window in the reporting process. It exists so a hot loop cannot saturate a
  socket before the relay ever sees it.
- **Relay fingerprint token bucket** (`Courier.ErrorRelay`): a per-fingerprint
  bucket, burst 5 then one per class per minute, with **an injected clock** so the
  schedule is asserted rather than waited for. Eviction is least-recently-seen.
  Nothing sleeps: the backoff and the throttle are both asserted on recorded state.

**No `sample_rate`.** Sentry does not sample errors by design, and a rate would
silently discard the one crash that mattered. Volume control belongs in two places
this repository owns. Measured against a live store: ten identical errors produced
**one** issue and the relay counted four throttled — the store's own grouping did
the rest.

## Nothing raises, nothing blocks, nothing retries

- **The ingest surface answers `200 {}` and counts a reason** for every body it
  cannot use. A Sentry SDK retries every non-2xx, so a `400` for a malformed
  envelope is a retry storm in whichever service sent it, and a `500` for a
  redaction bug is worse. `CourierWeb.ErrorEnvelopeController`'s moduledoc says this
  and the controller honours it.
- **The relay answers before anything is forwarded.** The store cannot add a
  millisecond to a request in another service, and the assertion in the endpoint
  tests is on the `200` arriving *before* the sink was called.
- **One attempt, no retry loop.** `receive_timeout` is set and `retry: false` is
  explicit, for the same reason the collector's exporters are configured with
  `sending_queue: {enabled: false}`: a queue is a memory leak with a
  telemetry-shaped trigger, and a retry loop against a dead store is a thread
  waking on a timer for the life of the process. **A lost error is strictly better
  than a growing process.**
- **The queue is bounded and its drops are logged throttled.** An unbounded queue
  converts a slow store into an out-of-memory kill of the notification service.
- **A readiness check that fails on the store would be an outage.** The relay's own
  probe is `GET /internal/v1/errors/healthz`, outside the auth pipeline, and it
  consults nothing: a relay that cannot reach GlitchTip has *lost errors*, it is
  not unhealthy, and restarting courier for it takes the notification service down
  with the error store.

## Off in test, and what "off" means

`config/config.exs` has `enabled: false` and no DSN; `config/test.exs` pins a fixed
token and a `Sink.Noop`-shaped default. `CourierWeb.ErrorReportingTest` asserts the
observable halves — `ErrorReporting.enabled?/0` false, no `:sentry` DSN, and a
canary that never appears in a captured event — rather than trusting the config
keyword.

"Off" means *nothing is captured and nothing leaves the VM*. It does **not** mean
the `:sentry` application is absent: a vendored OTP application always starts, and
the question is whether it has anything to send. `:sentry` is deliberately **not** a
child of `Courier.Supervisor` — it is its own application with no `child_spec/1`,
and listing it there crashes a release at boot.

## Configuration, and which variables are required

| variable | required | unset means |
|---|---|---|
| `COURIER_ERROR_RELAY_TOKEN` | **yes** | every envelope is refused — safe, but a deployment that means to run the relay would silently report nothing, so `runtime.exs` raises at boot |
| `COURIER_ERROR_SINK_DSN` | no | `Sink.Noop` runs and **counts** what it discards |
| `COURIER_ERROR_REPORTING_DSN` | no | `ErrorReporting.enabled?/0` is false; a diagnosable state |
| `COURIER_RELEASE` | no | `"unknown"`; no deploy-linked auto-resolution |
| `DEPLOYMENT_ENVIRONMENT` | no | `"production"` |

The asymmetry is deliberate and is the difference between a required credential and
a required observability integration. `COURIER_SECRET_BOX_KEY` and
`COURIER_ERROR_RELAY_TOKEN` are both required because **a default would be a secret
in version control** that every deployment which forgot one would then use. The
error store's DSN is not required, because an error store that is missing must not
be able to stop a notification service from sending mail.

A DSN is a credential. `Sink.Req` parses it once at boot, and **every refusal it
reports is a symbol** — `:store_refused`, `:store_unreachable` — because a relay
that logs its own DSN puts a write key in a log store, which is the exact leak this
packet exists to prevent.

## Testing notes, for whoever adds `identity` and `billing`

The shape transfers; the code does not. What is worth carrying over:

- **Derive the SDK's URL and header from the SDK's own parser** in a test, rather
  than writing what you believe the SDK sends. Both of courier's first two defects
  were invisible precisely because the fixture and the implementation shared an
  author.
- **Assert on the stored bytes, not on a return value.** The Sentry SDK reports
  `:ok` for an event it silently discarded. Three of the filter's bugs — an empty
  event, a dropped exception class, a deleted stacktrace — were invisible to every
  leak assertion and were caught only by "the crash is still a crash".
- **Run the release image.** Supervision-tree and release-only configuration
  defects cannot be caught by a suite that never boots a release.
- **Count rows in the store.** Nothing else distinguishes accepted from stored.
- Elixir-specific, but they cost real time here: `Application.put_env/2` does not
  exist (use `put_all_env/2`); `Config.Reader`'s `:env` option does not satisfy
  `System.get_env/1`; a module attribute referenced below its own definition is
  `nil`; and `Phoenix.ConnTest`'s `post/3` dispatches to `@endpoint`, which for the
  ingest surface is the wrong endpoint entirely.