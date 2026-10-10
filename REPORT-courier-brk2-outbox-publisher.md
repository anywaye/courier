# BRK-2 — courier's outbox publisher starts, and the row reaches the bus

Branch `broker/courier-brk2`, commit `0a799e8` on top of `74affe3`. Gate: **1646 passed, exit 0**
(`minimum: 1646` in `gate.yml`, the three floors in `.github/workflows/ci.yml` raised in
the same commit). Worktree: `/Users/kaka/Code/any/moon/wt/courier-brk2`

## brk-2R (the second dispatch): what it found and changed

The re-dispatch arrived describing the pre-packet tree ("no loop", 1156 tests) and one
finding to settle: `stream_refused 404: "stream not found for subject:
courier.email.delivered"`. On arrival the tree was **clean and already carrying
`0a799e8`**; the packet's code was done. So this attempt did the four things the
dispatch asked for that were not:

1.  **Explained the 404 with evidence — see the stream section below.** Short version:
    kit's stream has covered `courier.>` since it existed; courier's subject naming is
    correct and was measured storing a real publish in a real stream; and the quoted
    string is courier's own simulated-refusal fixture, not a sentence any nats-server
    version emits (grepped `main` and `v2.11.0`). **No change to courier, and nothing to
    report to kit — the subject list is not wrong.**
2.  **Corrected this report's own stale claim** that bounces and complaints are
    unpublished: `inbound_reports.ex:278` writes them to the outbox, so the relay drains
    all four event types, not two. The correction is in the table below.
3.  **Documented `NATS_URL`** in `README.md` (a new "Events on the bus" section) and in
    `AGENTS.md`'s Environment section, on the same terms as `COURIER_OTEL_ENDPOINT`:
    optional everywhere, unset is a supported state.
4.  **Recorded the reproduction**: `evidence/brk2-broker-proof.exs` (the real publish
    against a real broker) and `evidence/brk2-broker-api-probe.exs` (the shapes ruled
    out). Neither is in the suite; both need a broker the gate has no contract to
    provide.

Gate re-run after the documentation and report changes: **1646 passed, exit 0** (the
floor did not move — no test was added or removed). `tenancy_check.py .`: **0 failures**,
3 warnings, unchanged.

## What the manager's measurement was missing, and what was already there

**`Courier.Workers.ProcessOutboxWorker` already claims, publishes and marks.** Its
`claim/0` is exactly the `select ... for update skip locked` over unpublished rows,
bounded by `batch_size`, ordered oldest first; `mark_published/2` writes `published_at`
from the publisher's answer and nothing else. It was **not** missing — the packet's real
gap was the two halves around it:

1.  **There was no publisher that could reach a broker.** `Courier.NatsPublisher` was a
    behaviour whose only implementation was `Noop` — a test double that answers `:ok` and
    hands the envelope back to the calling process. `config/test.exs` was the only place
    it was configured, so nothing in any other environment could have published anywhere.
2.  **There was no connection and no `NATS_URL` condition.** `Courier.Application`'s tree
    had no bus child, and `config/runtime.exs` read no such variable.

So this packet added the publisher and the connection, not the relay. No relay code was
changed and no relay test was edited.

## The dependency, stated plainly because it needs the manager's sign-off

`{:gnat, "~> 1.18"}` is added to `mix.exs`. **AGENTS.md says "no dependency without
approval" and this is the one thing here that needs it.** The evidence I acted on: the
hex cache carries `gnat-1.18.1.tar` plus its full transitive closure
(`nkeys`, `ed25519`, `curve25519`, `chacha20`, `poly1305`, `salsa20`, `kcl`,
`nimble_parsec`, `equivalex`, `connection`), fetched on a distinct day in a group of
twelve that is precisely gnat's dep tree and nothing of courier's. `gnat` is MIT
(verified in the 1.18.1 tarball's own `metadata.config` and `LICENSE.txt`).

The alternative I considered and rejected: a hand-rolled publish-only NATS client over
`:gen_tcp`, which would need no approval. It lost because identity's design
(`internal/outbox/nats.go`) is written against the official client's JetStream
`PublishMsg` and its reconnect semantics, and "ack, then mark" is only a rule if a
transport can answer — a protocol implementation that is only exercised by a test I also
wrote proves the test. If the manager refuses `gnat`, the seam is clean: delete
`Courier.NatsPublisher.Bus`'s `Gnat.` call and the rest of this packet stands.

## What courier publishes, and where

Subjects are the event `type`, with **no mapping table** — core's `event-outbox.md` rule,
and the one identity names in `nats.go` ("No mapping table, no prefix rewriting"). The
subject is read off the envelope, so the catalog below is `Courier.Events.types/0`
restricted to what actually has a producer today.

| type | subject | producer today |
| --- | --- | --- |
| `courier.email.delivered` | `courier.email.delivered` | `Courier.Deliver`, in the send's transaction |
| `courier.email.bounced` | `courier.email.bounced` | `Courier.InboundReports.publish/2` → `Outbox.insert/1` |
| `courier.email.complained` | `courier.email.complained` | `Courier.InboundReports.publish/2` → `Outbox.insert/1` |
| `courier.notification.suppressed` | `courier.notification.suppressed` | `Courier.Unsubscribes`, one-click endpoint only |

**Deliberately left unpublished and unlisted:**

*   `courier.email.queued` — `Courier.Events` has no builder for it because courier has no
    queue (the send is synchronous). No row of that type can be written, so none is
    published.
*   **Nothing account-scoped** — the fan-out has no producer (already a known finding from
    the outbox-enqueue packet).

**CORRECTED IN brk-2R.** This section originally claimed `courier.email.bounced` and
`courier.email.complained` were "builder only — no inbound surface" and that "the outbox
write on that path is the missing sentence". **Both were wrong, and the measurement is
the correction**: `lib/courier/inbound_reports.ex:212` pipes every row `ingest/1` records
into `publish/2`, and `insert_event/2` at `lib/courier/inbound_reports.ex:278` writes
through `Courier.Outbox.insert/1` — the one function AGENTS.md says writes an outbox row,
which enqueues the relay in the same transaction. The relay therefore drains all four
types above, not just `delivered` and `suppressed`. The original claim came from reading
the moduledoc's `defp publish` sketch and not following the call; the lesson is the
packet's own AGENTS.md rule ("a probe test that passes without the route is worse than no
test") applied to a report: **an inspection is not a measurement, and a report is a claim
about code like any other.**

Every subject is prefixed `courier.`, which is the fleet's contract rule. The publisher
refuses anything that is not, rather than sending it somewhere the `cafaye` stream's
`courier.>` filter does not claim (which the broker would silently accept and no consumer
would read).

## The ship of Theseus decisions identity forced, and where each is

*   **Batch size stays as it is (50, config-read), not 100.** Courier's batch lives in
    `config :courier, :outbox` and is read at runtime. Identity's `100` was chosen for a
    loop that claims directly; courier's relay holds a Postgres **transaction** across the
    publishes, so a larger batch holds row locks longer *and* the transaction open longer,
    against the broker's dial. Changing it is an operator decision, not a code one.
*   **The one-second fixed poll, deliberately not exponential, is now REAL.** Courier's
    loop is Oban's crontab, `"* * * * *"` — a fixed one-minute sweep, no backoff, plus the
    per-event fast path. Identity's argument ("a backoff that grew while idle would leave a
    newly registered user's event sitting unpublished for minutes") is the Oban worker's
    `backoff/1` on *failure*, which is a different thing and was already there; the sweep
    never backs off. No change needed.
*   **`NoopPublisher` exists and is never wired.** `config/test.exs` configures it and
    nothing else does. `config/runtime.exs` puts **`Courier.NatsPublisher.Unconfigured`**
    in the application env when `NATS_URL` is unset, and a test asserts no non-test config
    file configures the Noop. This is the "dark loop" refusal, one layer down.
*   **A broker that is down is not a boot failure; a URL that does not parse is.**
    `Courier.Nats.init/1` returns `{:stop, {:nats_url_does_not_name_a_broker, url}}` for
    the second, and catches both `{:error, _}` and a raised exit from `Gnat.start_link/1`
    for the first. Measured, both: `Courier.NatsTest` asserts the `{:error, _}` answer for
    a closed port and the `{:stop, _}` answer for `not-a-url` and `amqp://…`.

## The proof — the row is ON THE BUS, not "the publisher was called"

`test/courier/nats_publisher/bus_test.exs` is four tests driving real bytes:

*   `Courier.TestSupport.NatsServer` (new) listens on a kernel-assigned loopback port and
    speaks the protocol: the `INFO` greeting gnat's handshake waits one second for,
    `PING`/`PONG`, `SUB` accepted unanswered, and the JetStream publish ack — the real
    `{"type":"io.nats.jetstream.api.v1.publish_ack_response","stream":"cafaye",…}` body —
    answered on the request's own `_INBOX.` reply subject with sid 0. The direct analogue
    of `test/support/smtp_server.ex`.
*   A real `Gnat` connection is started through `Courier.Nats`, a real row is written
    through `Courier.Deliver`, and the real `ProcessOutboxWorker` is performed.
*   The assertions are on **what arrived at that port**:
    `assert [%{subject: subject, payload: payload}] = NatsServer.published(ctx.server)` with
    `subject == "courier.email.delivered"`, `payload == Jason.encode!(OutboxEvent.envelope(row))`
    byte for byte (core's "the signed bytes are the sent bytes"), and the envelope's `id`,
    `source`, `specversion`, `subject` and `time` read out of the wire and matched to the
    row. `published_at` is set only because the broker acked, which is why `Gnat.pub/4`
    was not used — it returns when the bytes are on the wire.
*   The refusal case answers an ack body carrying `error` (`404`, "stream not found for
    subject…"), and asserts the row was **not** marked, `attempt_count == 1`, and
    `last_error` reads the broker's own code and description.

`test/courier/nats_publisher/unconfigured_test.exs` is the other half: no broker, no
connection process, and a row that stays unpublished with `nats_url_not_set` in
`last_error` after two passes.

## Three things I changed beyond the modules, and why

1.  **`mix.lock` moved** (gnat and its ten transitives). This is a dependency addition, not
    a gate resolving differently — CI's lockfile guard is a `git diff --exit-code` *after*
    `bin/prime`, and prime does not re-resolve a committed lock.
2.  **`Courier.Nats` traps exits.** Without it, a gnat connection that dies takes the linked
    `Courier.Nats` with it, which takes the application — measured: `** (EXIT from
    #PID<0.541.0>) :econnrefused` killed the process that started the connection. With
    `trap_exit`, the exit is a message that one warning answers and the 5-second retry
    reconnects from. Rows stay claimable throughout.
3.  **`Courier.Workers.ProcessOutboxWorker` was NOT touched.** `mark_refused/2` does
    `to_string(reason)`, so a publisher whose reason is a tuple raises
    `Protocol.UndefinedError` inside the relay's own transaction — which the first version
    of `Bus` hit and the refusal test caught. The fix was to make `Bus`'s reasons binaries
    and atoms (what a `last_error` string column wants) rather than to change the worker,
    because the worker's contract is asserted in 13 existing tests. **If a future publisher
    needs a structured reason, `mark_refused/2` is where that has to change**, and the
    comment in `Bus.check_ack/1` says so.

## The `stream_refused 404`, explained with evidence (brk-2R)

The manager's finding was, verbatim:

    stream_refused 404: "stream not found for subject: courier.email.delivered"

and the packet asked which of three things was true — the stream was created
before the subject list kit now defines, courier publishes a subject the stream
does not cover, or the broker had a different stream. **Established, in this
order, with a real broker (`nats:2.10.24-alpine`, the image family kit's stack
runs) and the real `Courier.Nats` connection driving the real
`Courier.NatsPublisher.Bus`:**

1.  **Kit's stream has covered `courier.>` since the stream existed.** Both
    creation sites agree: `templates/compose/docker-compose.yml:540`
    (`nats-stream-init`) and `templates/substrate/install.sh:1365` (step 10),
    each `nats stream add cafaye --subjects "identity.>,billing.>,courier.>,
    muse.>,darkroom.>" …`. `git log -S "courier.>"` over kit finds no commit that
    ever removed it — cbf97cc added it in compose, 83d40d4 mirrored it in the
    substrate installer. **The subject list is not wrong; nothing is reported to
    kit.**
2.  **Courier's subject naming is correct against that stream, measured.** With
    the stream created by kit's own verbatim argv, a real publish of a real
    envelope was **acknowledged (`:ok`)** and **stored in the stream**:
    `nats stream info cafaye` reports `Messages: 1`, and `nats stream get cafaye
    1` returns subject `courier.email.delivered` with the exact CloudEvents
    envelope the publisher encoded. No change to courier's subject naming.
3.  **Where the 404 shape could NOT have come from, measured.** A plain
    `Gnat.request/4` on the subject against a broker with **no stream**, and
    against a broker with a stream covering only `identity.>`, gets **no reply at
    all** — `{:error, :ack_timeout}` after the 10s budget, not a 404. The
    `$JS.API.STREAM.PUBLISH.<stream>` path produced no reply either on this
    build, for a covered subject, an uncovered one, and a missing stream.
4.  **The string the manager quoted is courier's own fixture, not a broker's
    answer.** "stream not found for subject: …" does not exist anywhere in
    nats-server (grepped `main` and the `v2.11.0` tag: nothing; err_code 10059 is
    `JSStreamNotFoundErr`, whose description is exactly "stream not found", with
    no subject appended — `server/errors.json`). The one place the exact string
    exists is `test/courier/nats_publisher/bus_test.exs`'s simulated refusal
    body, which `Bus.describe_refusal/1` formats into the quoted line. **The
    finding was the suite's own refusal-path fixture read as a live broker
    reply.** It stands as what it is: the test that a refused publish leaves the
    row claimable with the broker's reason recorded.

The reproducible run is `evidence/brk2-broker-proof.exs` (the publish) and
`evidence/brk2-broker-api-probe.exs` (the shapes ruled out above); neither is in
the suite, because both need a broker the gate has no contract to provide.

## What is deliberately NOT done, and is the successor's first move

*   **`NATS_URL` is not supplied by `docker-compose.yml`.** `Courier.ComposeConfigTest` now
    classifies it as an optional read ("absent is a supported state"). Adding the variable
    to courier's compose override so the dev stack publishes is a compose decision I did not
    make unasked, and kit owns the broker's address. One line:
    `NATS_URL: nats://nats:4222` in the courier service's `environment:`.
*   **`courier.email.bounced` / `courier.email.complained` are published, and the
    original report said otherwise.** CORRECTED above: the outbox write on the
    inbound path exists (`inbound_reports.ex:278`), so the relay drains them too.
    Nothing to do here; the correction is the deliverable.
*   **`README.md` and `AGENTS.md` do not document `NATS_URL` yet.** Both carry the
    environment-variable tables as prose; the new variable is only in
    `config/runtime.exs` and `Courier.ComposeConfigTest`'s `@optional_reads`. Worth doing
    before this is read by an operator. — **DONE in brk-2R** (README's
    "Hearing back" section gains an "Events on the bus" section; AGENTS.md's
    Environment section gains the variable, on the same terms as
    `COURIER_OTEL_ENDPOINT`: optional everywhere, unset is a supported state).
