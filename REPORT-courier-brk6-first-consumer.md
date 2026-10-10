# REPORT — BRK-6: the first consumer, and the idempotency that makes it safe

**Packet:** brk6-first-consumer
**Branch:** `broker/courier-brk6`
**Date:** 2026-10-10
**Commits:** `87d8fb1` (handler), `143087e` (subscription, floors)
**Gate:** 1663 passed (was 1646). Tiers re-measured: 760 no-database (35 files) / 903 database (51 files). `tenancy-check .` — 0 failures, 3 warnings (the same three, all pre-existing).

---

## 1. The one-paragraph version

The broker was one-ended: courier published onto the bus and nothing read it.
**This packet built the other end and closed the loop on the platform's central
promise — a user signs up, and `identity.user.created` produces exactly one
welcome email from courier.** Two pieces: `Courier.Consumers.UserCreated`, the
handler that sends through the real `Courier.Deliver`, and
`Courier.Consumers.Subscriber`, the supervised child that holds an `identity.>`
subscription and records each delivery. The dedupe discipline is the one the
table has had since the consumer's first packet — **the `consumed_events`
primary key IS the envelope id** — and the packet's central claim is now proved
over a real socket: the same event id delivered twice sends the mail once.

## 2. The consumer, and why it is this one

`identity.user.created`, published by identity's `internal/outbox/envelope.go`
(`NewUserCreated`, verified there and not re-derived here) in the same
transaction as the user row, before any email verification. Payload:

    {"user_id": "<uuid>", "email": "<address>"}     subject: the user id

**Why this one and not the siblings.** The invitation handler refuses by design
(the accept URL is unrecoverable from any event) and the acceptance handler
records an in-app notification (the payload carries no address). This payload
carries the recipient and the address, which is everything
`Deliver.welcome/1` needs — so it is the one event whose positive path is a
real send, and the first consumer on this bus whose central promise is
reachable end to end. A first consumer that refused by design would have left
the handler chain unexercised on its one positive path.

**What I deliberately did NOT build:** a second consumer. The packet's
instruction, followed. `identity.member.removed`, `account.created` and the
remaining tenancy events are recorded by this same subscription (the prefix —
see §3) and reported `skipped` by the loop, which is the state
`Consumers`'s moduledoc describes for a type with no handler yet, and the
`consumes:` entry in `cafaye.yml` is a one-line change per future consumer.

## 3. The idempotency discipline, and where it is enforced

**A dedupe key in a table with a unique constraint — the constraint is the
discipline.** `consumed_events`'s primary key IS the envelope's own id, so a
second delivery of the same event id cannot insert and
`Courier.Consumers.record/2` answers `{:error, :already_consumed}`. There is
no check-then-insert anywhere; two concurrent redeliveries race on the insert
and exactly one wins.

**Not a per-handler marker.** The marker was considered and is the weaker
version of the same idea: a dedupe key in `consumed_events` dedupes the
DELIVERY (the durable fact), and `mark_handled/1` — set from the handler's
answer and nothing else — is the EFFECT's own marker. Three columns, three
facts: `attempt_count`, `last_error`, `consumed_at`. The packet's ordering
requirement ("do not consume an event and then mark it processed before the
effect is durable") is structural here: the subscriber records the row on
delivery, the sweep dispatches, and only the handler's success sets
`consumed_at`. A crash mid-effect leaves the row NULL and re-runs, which is at
-least-once the consumer side; a crash AFTER the effect leaves `consumed_at`
set and the row never re-runs.

## 4. The subscription, and why it is a prefix

`Courier.Consumers.Subscriber` subscribes to **`identity.>`** — the NATS
wildcard prefix — and not to the four subscribed types. A SUB per type is the
same guarantee today and a silent failure tomorrow: identity's fifth event
arrives, the registry gains its handler when somebody opens the config, and
until then a per-type consumer drops it on the floor with every wire correct.
The prefix records it, the loop reports it `skipped`, and the manifest and the
registry stay the only two places a subscription is decided. The subscription
is asserted on the broker's own subscription list in
`test/courier/consumers/subscriber_test.exs`.

The subscriber RECORDS and does not handle: the handler runs from the sweep.
That keeps `safe_apply/2`'s raise guard where it already is — a subscriber
callback that raises takes the subscription down for every subsequent message
— and it means the write that matters (the row) happens in the process that
owns the subscription, before anything is owed.

It asks `Courier.Nats.connection()` rather than owning a socket (the
connection process already dials, retries, and survives an outage) and
re-asks on a timer, because **reconnecting the broker re-establishes the
connection and loses every subscription on it.** A subscriber that subscribed
once would go silently deaf after the broker's first blip.

## 5. The proof — what the tests actually assert

`test/courier/consumers/subscriber_test.exs` drives a real `Gnat` connection
against `Courier.TestSupport.NatsServer`, which gained the protocol's other
half for exactly this packet: `SUB` is now recorded (`subscriptions/1` is the
store) and a `PUB` to a subject a subscription claims is delivered as a `MSG`
frame — with the NATS wildcard grammar, so `identity.>` claims
`identity.user.created`. A mock transport could not prove what a consumer
RECEIVES.

The central claim, over that socket:

```
publish the same envelope id twice → exactly one row,
one Consumers.consume(), one email drained, one outbox row
```

Exactly-one is counted two ways that cannot agree with a bug: the drained
mailbox (`drain_emails/0` after the sends, which run in the test process and
are settled) and `Repo.aggregate(OutboxEvent, :count, :id) == 1`.

The other assertions:

* **an event for an unsubscribed type is recorded and `skipped`** — the prefix
  rule, proved from the delivery side;
* **an undecodable delivery is a warning naming the topic, surviving, with the
  subscriber still receiving the next good event** — loudness and resilience
  in one test;
* **the welcome mail is sent to the payload's address, through the real
  `Courier.Deliver`** — the preference check, the per-type unsubscribe check
  and the suppression check all run, because a handler that dialled a provider
  itself would skip all three.

## 6. The redaction boundary, and the leak the test caught

The event bus carries other services' message content, so nothing delivered
may reach a log or a span. The subscriber's refusal log line names the topic
and a reason SHAPED so it cannot carry the payload: `describe/1` maps the
decode failure to "the bytes were not a JSON object" and names only a
changeset's error KEYS. **The first draft used `inspect/1` and the test caught
it** — `Jason.DecodeError` holds the bytes it could not parse in `data`, so
the refusal log printed the delivered payload verbatim. That is the boundary
doing its job rather than the test failing: the assertion was `refute log =~
"kaka@example.com"` and the payload was planted with exactly that address.

`Courier.Consumers.UserCreatedTest` carries the same idiom on the handler
side (`record_failure/3` logs type and id only), plus the no-credential
boundary: identity's `NewUserCreated` comment says "no password digest and no
lockout state: the envelope goes to every subscriber on the platform, and this
is the only place where that boundary is enforced" — and this side reads its
two fields by name and discards the rest, proved on the RENDERED MAIL with a
planted token, not on the handler's return.

## 7. What this packet flipped rather than added

`test/courier/consumers/wiring_test.exs` asserted the absence of the
subscription (`refute application_source() =~ "Courier.Consumers"`), with a
moduledoc explaining why: "a subscriber needs a broker, and courier has no
NATS client". **The outbox packet expired that reason**, so the assertion is
flipped to the wired one (conditional child, same harness as the connection)
and the worker's moduledoc now says why the sweep is separate from the child.
An absence nobody re-examines is how a repository keeps believing its own
stale comments — the flip is the packet, not a test edit.

`config/config.exs`, `cafaye.yml`, the CI tier floors (1646 → 1663, 760 no-
database / 903 database) and `gate.yml`'s proof floor (`minimum: 1663`) moved
in the same commit — the floors are decrease detectors, and every number in
them was re-measured by running the tier greps and `mix precommit` on this
tree.

## 8. Known gaps, stated rather than worked around

* **A core-NATS subscription has no ack, so a crash between the broker's
  delivery and the row write loses that message.** JetStream durable
  consumers (publish-ack, redelivery on timeout) would close it; gnat 1.18
  has pull-consumer support and courier's bus is JetStream-capable (kit's
  `cafaye` stream, BRK-2). That is a deliberate not-done: this packet's
  at-least-once is the publisher's, and the consumer's crash window is one
  process lifetime — the honest residual, named here rather than papered
  over by a claim of stronger delivery.
* **`time` ordering on a prefix backlog is best-effort.** core says consumers
  must not assume global ordering across publishers; two identity events
  about one account arrive in order, two about different accounts do not.
  The welcome handler needs no ordering.
* **core's event catalog (`docs/event-naming.md`) calls this fact
  `user.created`; identity publishes `identity.user.created`** and cites its
  own open decision D1. courier subscribes to what is published — core's rule
  6 — and the divergence is reported here rather than renamed: a subscription
  to a type no publisher declares fails on somebody else's deploy.
* **The harness broker refuses a second connection** (BRK-2's design,
  unchanged): a test that needs two connections must be restructured, and
  none in this packet does.

## 9. For the successor

The subscription is one prefix with a closed registry, so a fifth event needs
one line in `cafaye.yml`'s `consumes:`, one line in
`config/config.exs`'s registry, and one handler module. The loop already
skips-and-reports what it cannot dispatch, and the tier floors are at the
measurement with zero headroom — raise them in the same commit as the next
test, per the rule about floors being decrease detectors.
