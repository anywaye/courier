# REPORT-courier-outbox-enqueue-01

**Repository:** `courier` · **Branch:** `worker/courier-outbox-enqueue-01` ·
**Base:** `8c30e76`

The queue had three workers and no producer. Every send wrote a durable
`outbox_events` row that nothing would ever publish, and 1301 green tests said
nothing about it, because every one of them drives `perform/1` directly.

Everything below is measured on this tree. Tallies are reported separately from
passes, because a tally copied out of a report is the defect this fleet keeps
refusing.

---

## 1. The defect, before the fix

`reports/courier-outbox-enqueue/prove-outbox-enqueue.sh` drives
`Courier.Deliver.welcome/1` end to end against its own probe database and then
reads `oban_jobs`. On the pre-fix tree (`1b105a7^`, log:
`reports/courier-outbox-enqueue/prove.log` as committed in `1b105a7`):

```
Oban.insert in lib/: 0
cron configuration in lib/ and config/: 1        <- a comment saying nothing is scheduled

arm: enqueue — Courier.Deliver end to end, then read oban_jobs
  outbox rows after one send: 1
  oban jobs after one send:  0
  FAIL  oban jobs after one send = 0 (expected 1)

tally: passes 3, failures 4, measurements 0 — RESULT: RED
```

Two things in that run are the whole story:

* **the row is written** — the outbox contract ("the state change and its event
  commit together") was never in question;
* **the queue is empty** — and the sweep arm of the same harness was GREEN,
  because the harness supplies the job itself. The consumer works. The producer
  did not exist.

This is the same shape `AGENTS.md` records for `Courier.Suppressions.ingest/1`:
*written, tested, documented — and nothing called it.* One layer further out.

---

## 2. The decision: both triggers, and why neither alone is right

The brief offers two shapes and asks for one. **This packet ships both, with a
division of labour, because each of them is load-bearing for a different
property, and there is a third reason (testability) that I could not design
around.**

### 2.1 The enqueue, inside the transaction

`Courier.Outbox.insert/1` writes the row *and* queues the relay, in the caller's
transaction. `Courier.Deliver` and `Courier.InboundReports` — the two writers —
call it and nothing else.

The obvious objection, and it is the brief's own, is real: a request that dies
between the `COMMIT` and the enqueue strands the row forever, which is exactly
the failure the outbox pattern exists to prevent. But **that is a transaction
boundary, so it is answered with a transaction.** Row and job commit together or
neither does, and the only surviving failure mode is a row nobody wrote. There is
no window to shrink; there is a window to close.

Measured, in `test/courier/outbox_enqueue_config_test.exs`, with a mail adapter
that refuses so the transaction really unwinds:

```
a send that rolled back leaves no row and no job
  Repo.all(OutboxEvent) == []
  all_enqueued(worker: ProcessOutboxWorker) == []
```

**The pair is the assertion.** "No row" alone passes with a stray job in the
queue, and a stray job is a relay that claims nothing and reports success — the
invisible half of the failure. The positive twin is in the same file: the same
call with an adapter that accepts leaves exactly one job naming one row.

### 2.2 The sweep, because for two of the three workers it is not a choice

`config/config.exs` gains an `Oban.Cron` crontab: one entry per worker, every
minute. For `DeliverWebhookWorker` this is not belt and braces, it is the only
shape — a delivery becomes due **by the clock**. `next_attempt_at` is written by
the failure that set it, five minutes into the future, and nothing happens at
that moment, so there is no write to hang an enqueue on and no event to subscribe
to. Chaining the job (`{:error, _}` so Oban retries it with `backoff/1`) was
considered and rejected: it changes that worker's public contract — the suite
asserts `{:ok, %{sent: n}}` in three files — and a chain of jobs dies with its
first discarded link, where a timer cannot.

For the relay itself the sweep is the floor that makes the enqueue an
*optimisation* rather than a dependency: a repair, a future call site, a restored
backup or a rolled-forward row is recoverable without a code change. Measured,
`test/courier/outbox_enqueue_test.exs` "the floor: the crontab's own job publishes
a row that nothing enqueued" — a row written with a plain `Repo.insert/1`, no
`Courier.Outbox` in sight, published by the job the plugin inserted.

**The overlap is harmless and the reason is not new:** the relay's claim already
excludes rows with `published_at` set, and that is at-least-once's ordinary
condition rather than a second design. Two triggers for one idempotent loop is
what every production outbox does; the alternative here was a design where a
missing enqueue is silently permanent.

### 2.3 The reason I could not design around: the sweep alone is untestable here

`config/test.exs` sets `testing: :manual`, and under that Oban starts **no plugins
at all** — `deps/oban/lib/oban/config.ex:108` replaces `plugins` with `[]`. A
pure-sweep design therefore has no in-suite way to observe the thing that runs the
queue. The options were: assert that a crontab is *configured* (a comment with a
test's name on it, and it cannot catch Oban starting with `plugins: []`), or
start the plugin. This packet does the second:

```
conf  = Oban.Config.new(app_env) merged with its OWN instance name
peer = Oban.Peers.Isolated, leader?: true, registered under that name
cron = Oban.Cron started with courier's crontab, allow()ed into the sandbox
send(cron, :evaluate); :sys.get_state(cron)     # a barrier, not a poll
```

That is Oban's real insertion path (`handle_info(:evaluate, …)` →
`insert_scheduled_jobs/1`), reading courier's shipped crontab out of application
env rather than a crontab the test wrote. The test then asserts the inserted
job's `meta["cron_expr"]` is the expression in the config, and that running it
publishes the stranded row.

---

## 3. The idempotency question, answered

**The job is unique, keyed on the event id, and one event cannot publish twice
even when two jobs exist.**

```elixir
unique: [period: :infinity, keys: [:event_id], states: :incomplete]
```

| question | answer | where it is proved |
| --- | --- | --- |
| does a retried insert enqueue twice? | no — the second kick answers `conflict?: true` and the queue still holds one job | `outbox_enqueue_test.exs`, "neither later kick enqueues anything" |
| can an event be re-announced later? | yes — the key is "no **pending** job", so once it is gone the event can be kicked again | same file, "and the event can be kicked again once its job has run" |
| can one row publish twice? | no — the claim excludes `published_at IS NOT NULL` | "the job does not publish the row twice", from the producer's side |
| is a republish a defect? | no — at-least-once, same envelope `id`, which is the promise `Courier.OutboxEvent`'s moduledoc makes | same test asserts `envelope["id"] == event_id` |

Three of those decisions were measured rather than reasoned, and two of them the
other way:

* **`fields: [:worker]` — rejected.** It is the obvious key and it is wrong
  twice. Oban takes `pg_advisory_xact_lock` around a unique insert
  (`deps/oban/lib/oban/engines/basic.ex:450`) and an xact lock is held until the
  transaction ends, so one key for the worker **serialises every concurrent send
  for the length of the provider's dial** — courier already holds a transaction
  open across that dial. And it strands every send past the first until the next
  sweep. The test "two sends queue two jobs, and one run of the loop publishes
  both rows" is the assertion, and it also records something true about the
  design: **the job is a trigger and the table is the work**, so two jobs are not
  two units of work and a test asserting `published: 1` per job would be
  asserting that courier does not implement the loop it cites.
* **`states: :incomplete`, not the default.** The default (`:successful`) holds
  the key for a job that *succeeded*, which is a row Oban has already deleted
  (`jobs: :delete`).
* **`states:` is the bare group, and `[:incomplete]` is a runtime error.**
  `Oban.Job.cast_unique_group/1` expands an atom and passes a list through
  untouched, so the wrapped form reaches PostgreSQL as the literal state
  `"incomplete"` and the `oban_job_state` enum refuses it. Measured on this tree:
  **22P02**, on every send, which is what surfaced it. It is written into
  `Courier.Outbox`'s moduledoc because it is invisible in a diff.

**A kick that fails never fails the send.** The provider has already accepted the
mail by the time the relay is queued, so refusing the send because the queue was
briefly unwritable would buy nothing and cost a duplicate delivery to a person.
The row is durable, the sweep is the floor, and the failure is a log line.

---

## 4. The falsification, in production code

Two mutations, both against production code, both reverted, with the number and
the command. The tests were not touched in either run.

**A — the enqueue removed from `Courier.Outbox.insert/1`:**

```
$ mix test test/courier/outbox_enqueue_test.exs \
           test/courier/outbox_enqueue_config_test.exs
Result: 6/13 passed
Failed: 7 tests
```
log: `reports/courier-outbox-enqueue/prove-mutated-no-enqueue.log`

**B — the same tree, through the probe harness with the expectation inverted**
(`COURIER_OUTBOX_EXPECT=none`, so it demands *no* enqueue):

```
  outbox rows after one send: 1
  oban jobs after one send:  0
  ok    oban jobs after one send = 0
  measured  the send wrote a durable row and the queue is empty: 1 row, 0 jobs
  tally: passes 4, failures 0, measurements 1 — RESULT: GREEN
```
log: `reports/courier-outbox-enqueue/prove-mutated-none.log`

**C — untouched:**

```
$ mix test
Result: 1314 passed

$ bash reports/courier-outbox-enqueue/prove-outbox-enqueue.sh
  outbox rows after one send: 1
  oban jobs after one send:  1
  job args:    %{"event_id" => "5a1cc3e6-1741-470c-a3ba-42fc507a67a9"}
  args name the row: true
  performed the queued job: %{published: 1}
  row published: true
  tally: passes 7, failures 0, measurements 1 — RESULT: GREEN
```
log: `reports/courier-outbox-enqueue/prove.log`

Two things worth reading off B. First, the harness runs the *same* script and the
*same* driver in both directions — the inverted run is not a different assertion
dressed up as a falsification. Second, the sweep arm is GREEN in all three runs:
the consumer was never the broken part, and a harness that could only show the
consumer working would have missed this defect entirely.

---

## 5. What the suite proves, and the two things it cannot

13 tests, all in the database tier, in two files:

| claim | how it is asserted |
| --- | --- |
| a send leaves a job whose args name the row | `Deliver.welcome/1`, then `all_enqueued/1` |
| running **the job the queue holds** publishes that row | the job is re-read from `oban_jobs` and executed; never `perform_job(Worker, %{})` |
| the row is not published before the job runs | `published_at == nil`, no envelope in the mailbox |
| the loop does not publish a row twice | two passes, one envelope, `published_at` unchanged |
| two sends → two jobs → one run publishes both rows | the batch claim, recorded as a design fact |
| a rolled-back send leaves no row and no job | a refusing adapter, in the `*ConfigTest` file that owns the swap |
| the crontab's own plugin publishes a row nothing enqueued | `Oban.Cron` started in-test, driven by `:evaluate`, read after `:sys.get_state/1` |
| the crontab names every worker nothing enqueues | read from application env, all three asserted |
| the plugin reaches the effective Oban config outside the suite | `Oban.Config.new(testing: :disabled).plugins` |

**Cannot be asserted here, and is not claimed:** that the plugin fires on a real
minute boundary. That is a timer, this suite's rule is that nothing sleeps, and
the honest form of the claim is the crontab's existence plus Oban's own
`Expression.now?/2`. The one-minute interval is a decision (§7) not a
measurement.

**Deliberately not asserted:** that a future caller uses `Courier.Outbox.insert/1`.
There is no such assertion anywhere in this repository for any other rule of this
shape; the choke point is a structure, and a grep-based "convention test" would be
a test that passes by inspection. What §6.1 records is that there are two writers
today, both converted.

---

## 6. Findings, and what was deliberately not fixed

### 6.1 Nothing in courier writes an account-scoped outbox event

`DispatchWebhooksWorker.claim/0` selects rows with `account_id is not null`. Both
writers emit events for a **person** and set no `account_id`:
`Courier.Deliver.record/4` writes `courier.email.delivered` for a user courier
cannot place in an account, and `Courier.InboundReports.attrs/1` writes
`courier.email.bounced` / `courier.email.complained` for an address.

So **that crontab entry now runs every minute and correctly finds nothing.** The
fan-out has no producer. Fixing it means deciding what account-scoped event
courier emits — a contract decision in `cafaye/core`, not a bug in this tree —
and inventing one here would be exactly the scope widening the brief forbids. What
this packet does is give the consumer a clock, so the gap is now *visible* (a
dispatch run every minute that reports 0) instead of *inert*.

### 6.2 Core's retention section is unimplemented, and stays that way

`core/docs/event-outbox.md` asks for published rows to be pruned in batches on a
schedule. courier has published nothing until this packet, so the table has been
empty of spent rows for its whole life, and a pruner added now would be pruning
nothing. It becomes real work the moment events flow at volume; it is a separate
packet with a separate argument about how long the slowest consumer's redelivery
window is.

### 6.3 There is still no alert on the oldest unpublished row

Core asks for one, and courier cannot emit one: the Erlang OpenTelemetry SDK ships
no metrics API (`AGENTS.md`, measured: `ls deps/opentelemetry/src | grep -c
metric` is `0`), and the relay publishes nothing to the NATS server it could
report from. With the sweep at one minute, the observable is the sweep's own
`published: 0` runs and the relay's `attempt_count` — which is what the crontab
now makes visible for the first time.

### 6.4 A pre-existing formatting defect in the previous packet's test

`test/courier/workers/dispatch_webhooks_worker_identity_test.exs` was committed
unformatted (no trailing newline, one over-long line), so `mix precommit` rewrote
it on every run and **no worker could finish this packet with
`git status --porcelain` empty** — which is the brief's definition of done.
Fixed here, in a separate hunk, and said here rather than smuggled.

### 6.5 The `TelemetryCanaryTest` race is unchanged, and measured again

Adding 13 tests to the tier that contains it could plausibly have made it worse,
so it was measured with and without this packet's two files:

```
database tier, WITH the two new files     2 failures in 16 runs, then 0 in 10
database tier, WITHOUT them (own list)    2 failures in 10 runs
```

4 in 26, no signal in either direction, and the failing assertion is the one
`AGENTS.md` already documents (`request_spans/0` reads every
`courier.web.request` span in a table shared by the whole VM). Neither new file
drives a request — no endpoint, no `Plug.Conn`, no `ConnCase` — so neither can add
a span for that file to read. The rate is higher than the 1-in-8 recorded there
for whole-suite `bin/prime` runs, on this machine rather than CI; not adjusted,
not hidden.

---

## 7. Decisions this tree could not make for me

Written down as the brief asks, with the alternatives and the one implemented.

1. **The crontab interval: one minute.** Alternatives: 10 seconds (ten times the
   job rows for no gain — the relay's own backoff already handles a broker that is
   down), five minutes (cheaper, but it is also the ceiling on how long an
   unpublished row can sit, and it would make the fast path look like decoration).
   One minute is also the number an alert would use, which is why it is stated in
   one place: `config/config.exs`. It is configuration, not a constant in a worker.
2. **All three workers on the crontab, rather than only the relay.** The argument
   per worker is in the configuration comment; the short version is that two of the
   three have no write to hang an enqueue on.
3. **`Oban.Cron` over a hand-rolled `GenServer` with `Process.send_after`.** No new
   dependency (`Oban.Cron` ships in the `oban` package), no table, and the schedule
   is re-read at boot so a restart cannot lose the trigger. A hand-rolled timer
   would have been ~40 lines of process code to answer a question a dependency
   already answers — and `mix.exs` has a standing rule that a dependency is not
   added without approval.
4. **Keep `Courier.Outbox.enqueue_relay/1` public.** The invariant it carries
   ("no pending relay job for this event") belongs to the relay, not to one caller:
   a second producer, a repair, or an operator kicking a stuck event all go through
   it and all get the same answer. It is also what makes requirement 3 provable
   without a test-only entry point.
5. **Leave `DispatchWebhooksWorker.with_account/3` alone.** It is correct, it was
   given an identity in `8c30e76`, and this packet is not that packet.
6. **Leave `DeliverWebhookWorker`'s return contract alone** (§2.2), and do not
   chain a `DeliverWebhookWorker` enqueue out of
   `WebhookDeliveries.insert!/2` for the same reason: the first attempt could be
   chained, but the retries could not, so a chain would be a fast path with a
   timer beside it and one more place to be wrong.

---

## 8. Floors, re-measured and raised in the same commit

| | before | measured | floor |
| --- | --- | --- | --- |
| whole suite (`bin/prime`) | 1301 | **1314** | 1295 → **1308** |
| no database (27 files) | 619 | **619** | 619 (unchanged) |
| database (36 → 38 files) | 682 | **695** | 682 → **695** |
| SSRF table | 62 | 62 | 62 (unchanged) |

`gate.yml`'s `minimum` and `.github/workflows/ci.yml`'s three floors moved
together, and **1314 is 619 + 695**, so the parts still sum to the whole. The 13
are in the database tier and the split is read off the case templates — the same
derivation CI's tier steps use: `outbox_enqueue_test.exs` is a `Courier.DataCase`
because every claim in it is a claim about a row, and `outbox_enqueue_config_test.exs`
is one because its subject is a transaction unwinding, which needs a swapped mail
adapter and therefore owns that swap for the whole VM (`async: false`).

`mix precommit`: `Result: 1314 passed`. `core/harness/bin/gate-check`: `OK, 0
failure(s), 2 warning(s)` — both warnings pre-existing and about requirements the
checker deliberately does not run.

---

## 9. What a reader should check

* Delete the two lines of `Courier.Outbox.insert/1` that enqueue, run the two new
  files, and read §4's numbers again.
* Change `states: :incomplete` to `states: [:incomplete]` and send a mail. 22P02,
  on every send, with no other symptom.
* Grep `Repo.insert` in `lib/courier/deliver.ex` and
  `lib/courier/inbound_reports.ex` and find no outbox row written without the
  relay job.
* Read `config/config.exs`'s crontab and ask which of the three entries could be
  removed. The answer for `DeliverWebhookWorker` is "none", and that is the whole
  argument for §2.2.