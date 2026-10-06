# REPORT — courier consumes `identity.member.invited`, and cannot yet send the mail

**Packet:** courier-w18-consumer
**Branch:** `worker/courier-w18-consumer`
**Date:** 2026-10-06
**Gate:** 1458 passed (was 1409). Tiers: 651 no-database / 807 database.

---

## 1. The one-paragraph version

The fleet's bus was one-ended: every service published, nobody subscribed,
every `consumes:` in every `cafaye.yml` was empty. **This packet built the other
end** — a consumer with a claim loop, a dedupe, a retry budget, a subscription
and a handler — and **the handler refuses, because the event cannot carry the
one thing an invitation needs.** identity publishes `account_id`,
`invitation_id`, `email`, `role`, `invited_by_id`; `Courier.Mailers`'s
`team_invitation` needs `email`, `url`, `account_name`, `invited_by`. One of the
four is present. Two are recoverable by a lookup. **`url` is not recoverable by
anything at all**, because identity returns the invitation token in its `201`
and stores only its SHA-256.

So: the consumer is built, tested and repeatable. The invitation is not sent,
and that is reported rather than worked around. Sending it would mean mailing a
stranger on a domain they have no reason to trust, ending in a broken promise.

---

## 2. The payload gap, measured rather than assumed

### 2.1 What identity publishes

`internal/outbox/tenancy.go`, `NewMemberInvited` (line 128), appended in
`Invite`'s transaction at `internal/accounts/service.go:604`:

| field | in the event |
| ----- | ------------ |
| `account_id` | yes |
| `invitation_id` | yes |
| `email` | yes |
| `role` | yes |
| `invited_by_id` | yes |

**That was verified line-by-line on 2026-10-06 and is not re-derived here**, per
the packet's instruction not to spend the session chasing it.

### 2.2 What the template needs

`Courier.Mailers.required("team_invitation")` is `[:email, :url,
:account_name, :invited_by]`.

### 2.3 The gap, gap by gap — and the two are NOT the same kind

| the template needs | in the event? | recoverable? |
| ------------------ | ------------ | ------------ |
| `email` | yes | — |
| `role` (used in the body) | yes | — |
| `account_name` | **no** | **yes** — `GET /v1/accounts/{id}` |
| `invited_by` | **no** | **yes** — the inviter's member record |
| `url` | **no** | **NO.** See below. |

### 2.4 `url` is unrecoverable, and this is the whole finding

The accept link is built from the invitation's one-time token. identity returns
that token **in the `201` and never again**:

- `internal/accounts/store.go:145` — `invitationColumns` holds `token_digest`,
  not a token.
- `internal/accounts/service.go:522-527` — *"The token is returned exactly once,
  here, and is never stored. A caller that loses it mints a new invitation;
  there is no way to recover it."*
- `internal/httpapi/accounts.go:552-561` — *"THE TOKEN IS HERE AND ONLY HERE …
  there is no column holding it, only its SHA-256, and no operation that
  re-reads one. **In a later packet the invitation email is handed to courier
  and this field goes away** — until courier exists, returning the token is the
  only way an invitation can be delivered at all."*
- `openapi/v1.yaml:2512` — *"the token is the delivery mechanism until
  invitation mail is handed to the courier service."*

**So any consumer of this event, in any language, on any bus, has exactly the
information courier has and the same absence.** There is no lookup. There is no
join. `account_invitations` stores the digest.

**THE FIX IS ONE LINE IN IDENTITY** (not applied — the packet forbids modifying
`identity/`):

```go
// internal/outbox/tenancy.go, NewMemberInvited
type memberInvitedPayload struct {
    AccountID    string `json:"account_id"`
    InvitationID string `json:"invitation_id"`
    Email        string `json:"email"`
    Role         string `json:"role"`
    InvitedByID  string `json:"invited_by_id"`

    // ADD THIS. Or a fully-formed redeem URL, which is better: the platform's
    // accept route is not courier's to know.
    AcceptanceURL string `json:"acceptance_url"`
}
```

The alternative fix is **not** "let courier re-read the token" — that is the
credential-exposure change identity has deliberately refused three times, in the
same file, in its own words. The alternative is a **redeem-by-invitation-id**
route (`POST /v1/invitations/accept_by_id`, authorising on the authenticated
session and the account, not on a bearer token in a mail), which removes the
credential from the email entirely and is the better design. **That is a manager
decision, not this packet's, and it is reported rather than designed.**

### 2.5 What courier does about it

`Courier.Consumers.MemberInvited.deliver/1` refuses with
**`:missing_acceptance_url`** before anything is dialled, so no outbox row and
no `courier.email.delivered` event ever claims an invitation went out.

**The order is asserted as a test, and it is a real decision.** With a `url` but
no names, the refusal is `Courier.Mailers`' own
`{:error, {:invalid_payload, changeset}}` naming `account_name` and
`invited_by`. Checking the names first would answer `:invalid_payload` — a
*validation* error, which reads like the caller's mistake, on an event courier
did not author — and would hide the permanent gap behind the recoverable one. The
permanent one is reported first, in courier's own vocabulary, because courier is
the thing that knows it.

### 2.6 The two lookups were deliberately NOT built

`account_name` and the inviter's name are each one HTTP call. Building them
would make this handler a **second identity client** — a second base URL, a
second credential, a second failure mode, a second thing to keep in step with
identity's `openapi.yaml` — **in exchange for a mail with a broken link in it.**
That is strictly worse than refusing, which is why these are refusals and not
"not implemented yet".

### 2.7 A third gap, smaller, named

`Courier.Deliver` requires `user_id` for the preference check, and an invitee
has **no user** — the invitation exists precisely because they have not signed
up. The invitation's own id is used as the attribution key. **The cost is
stated:** an invitee who *does* have an account is checked against the
invitation's preferences rather than their own. The fix is a nullable
`invitee_user_id` on the event, so courier can branch on it.

---

## 3. The design decision the packet asked for

> The consumer needs a claim loop like the outbox relay's … but there is a
> question the relay does not face: **what does the consumer mark, and when?**

### 3.1 The answer

**`consumed_at` is written from the handler's own answer, and from nothing
else.**

| | the relay | the consumer |
| --- | --- | --- |
| the mark means | "the **broker** acknowledged" | "the **handler** succeeded" |
| at that moment | nobody has acted on the message | the provider has been dialled; a person may already have the mail |
| a failure means | send it again — nothing happened | **do not mark**; retry, because something irreversible may already have happened |
| the order | ack **then** mark | handle **then** mark |

**The order is inverted on purpose and it is the whole answer.** Marking
`consumed_at` on the broker's ack would record "handled" for a handler that
then failed, and the next pass would skip an invitation nobody was sent. A
failure leaves `consumed_at` NULL, which is what makes the row claimable again.

The three columns are three separate facts and conflating any two is the bug
this layout exists to prevent:

| column | the fact |
| ------ | -------- |
| `attempt_count` | this has been tried N times |
| `last_error` | the most recent failure's reason, or NULL |
| `consumed_at` | **the handler succeeded — and only that** |

### 3.2 A schema change was unavoidable, and here is core's rule for it

> `core/docs/event-outbox.md` §"At-least-once, so idempotent": "**Dedupe on
> `id`.** Store the envelope `id` in a table with a unique constraint and insert
> it in the same transaction as the handler's own work. […] an in-memory 'have I
> seen this?' set is wrong the moment there are two replicas."

At-least-once makes duplicates **ordinary operation**: the publisher commits and
dies before it acks; the mark statement fails after the ack; the broker
redelivers. There is no way to be idempotent across two replicas without a
shared row, and the alternative is correct on one replica and wrong on the
second — a failure mode that never reproduces in a test.

**`consumed_events` keys on the envelope's own `id`**, so the primary key *is*
the unique constraint and `record/2` answers `{:error, :already_consumed}`. No
separate "seen" index to keep in step with it.

---

## 4. What was built

| file | what |
| ---- | ---- |
| `lib/courier/consumers.ex` | claim, dispatch, mark, the summary, the raise-wrap |
| `lib/courier/consumers/member_invited.ex` | the `identity.member.invited` handler |
| `lib/courier/consumers/subject.ex` | the type IS the NATS subject |
| `lib/courier/consumed_event.ex` | one row per event **received** |
| `lib/courier/workers/consume_events_worker.ex` | the crontab sweep |
| `priv/repo/migrations/20261006140000_create_consumed_events.exs` | the table, its indexes, the grant |
| `cafaye.yml` | `consumes: [identity.member.invited]` |
| `config/config.exs` | the registry, `:consumer` tuning, the crontab entry, the queue |

### 4.1 The rules, each the relay's rule read from the other side

- **`FOR UPDATE SKIP LOCKED`** — N replicas against one table; a slow batch in
  one does not stall the rest.
- **Oldest first, on the envelope's `time`** and then the row's insert. Not
  `inserted_at`: a publisher's backlog delivers out of insert order, and a
  redelivered old event sorted by insert time would be handled last. `time` is
  `NOT NULL` because a row with no time sorts to the end of every batch on
  PostgreSQL's default for NULL — silently.
- **A row past the attempt cap is left alone** — not retried forever, not
  dropped. `attempt_count` is the retry budget; the broker's redelivery is not
  something courier has to ask for.
- **One refusal does not hold up the batch behind it.**
- **An event courier does not subscribe to is left claimable and
  un-attempted** — not a failure (a permanent non-zero on a counter an operator
  watches), and leaving it claimable is what makes a `consumes:` entry added
  later pick up what was already delivered.

### 4.2 A raise is a failed row, not a dead consumer

**A subscriber callback runs in the process that owns the subscription.** An
uncaught raise there takes down that process, which is a denial of service on
the **whole event stream** — not just the message that caused it — and it does it
from the inside, from a handler courier wrote. So every call is wrapped in
`rescue` **and `catch`** (`exit/1` and `throw/1` kill the loop as surely as a
raise), the reason is written to the row, and the loop continues. The test
asserts the **second** event in the batch is reached, because a test that only
counted rows would pass with a loop that stopped at the first failure.

### 4.3 No `account_id`, no RLS — the same posture `outbox_events` takes

A consumed event is courier's own bookkeeping about a message from another
service; the account is in the payload and stays there. The sweep runs with no
principal, so a policy on `current_account_id()` would filter out **every row the
consumer exists to read**. `tenancy.yml`'s `rls.tables` already records this
posture for `outbox_events`, `email_suppressions` and `webhook_deliveries`;
this is the fourth.

---

## 5. Three bugs this packet's own tests caught

Worth recording because each was invisible to the test that should have seen it.

### 5.1 Every refusal was being recorded as a success

```elixir
defp safe_apply(handler, event) do
  {:ok, handler.handle(event)}   # ← the wrap
end
```

A handler answering `{:error, :missing_acceptance_url}` came back as
`{:ok, {:error, :missing_acceptance_url}}`, `run/3` matched `:ok`, and the event
was **marked handled having sent nothing**. This is the exact failure the packet
is about, reached one layer in. Caught by the two arms counting `failed`.

### 5.2 The handler parsed and stopped, so nothing was ever sent

`MemberInvited.handle/1` returned `{:ok, invitation}` from `parse/1`, and the
loop marks a row handled on `{:ok, _}`. **Every invitation would have been
recorded as handled having mailed nobody** — the silent-default failure this
repository's adapter work exists to end, reached from the consumer side. Only the
integration test over the real registry could see it; every unit test for
`handle/1` was green throughout.

### 5.3 `@type` is Elixir's typespec macro

```elixir
@type invitation :: %{...}                                  # line 95
defp fetch_type(%ConsumedEvent{type: @type}), do: :ok      # line 243
```

The pattern expanded to comparing the row's type against a **typespec**, so the
handler refused the one event it was written for with
`{:error, :not_this_event}` — a symptom that reads exactly like a registry
misconfiguration and is not one. The attribute is now `@event_type`, and the
reason is in the moduledoc.

### 5.4 A fourth, in the test harness rather than the code

`consume/0`'s describe had the `on_exit` that restores application env; the
crontab-sweep describe, written after, installed a handler and **leaked it into
every later test**. The integration test at the bottom of the file got
`Courier.ConsumersTest.Succeeds` instead of `MemberInvited` and reported
`{:error, "… invalid destination"}` — a raise from `send/2` to a name no longer
registered. The setup is now at module level, because *every* test that writes
application env needs the restore.

---

## 6. Evidence the tests bite

Three mutations against the shipped implementation. Each is the property the
packet named.

| mutation | result |
| -------- | ------ |
| `fetch_url/1` no longer refuses on an absent `url` | **43 → 39** |
| every handler answer treated as success | **43 → 37** |
| a raise counted as a handled event | **43 → 42** |

And the red, on the record: the tests were committed first
(`9116b2b`) with **14 undefined symbols**, every one of them the thing the packet
had not built yet:

```
Courier.Consumers.attempt/2, claim/0, consume/0, handler_for/1,
mark_handled/1, max_attempts/0, record/1, record/2, subscribed/0,
Courier.Consumers.MemberInvited.deliver/1, .handle/1,
Courier.Consumers.Subject.for/1,
Courier.Workers.ConsumeEventsWorker.backoff/1, .perform/1
```

---

## 7. What was NOT built, and why

### 7.1 The NATS subscriber itself — the socket

**`gnat` was not added.** AGENTS.md: *"No dependency without approval … Swoosh,
Oban, Broadway, and the HTTP clients for the webhook pipeline are Phase 3
packets."* The precedent is exact: `Courier.NatsPublisher` is a **behaviour**
with a `Noop` stand-in and the Gnat module is "a later packet and a config
change, because this module declares the behaviour the Gnat module will declare
too". The subscriber side is the same shape.

Consequence, stated rather than hidden: **the table is filled by `record/1`,
which nothing calls yet in production.** The delivery path — the one thing that
waits — is a broker client.

### 7.2 The subscription is NOT in the supervision tree

A supervised process opening a socket to a broker courier does not depend on
would make a developer's `mix phx.server` fail to boot on a connection it cannot
make. **What IS scheduled is the sweep**, because the sweep needs no broker, so
the table, the claim, the ordering, the retry budget and the exhaustion rule are
all real and tested now. `test/courier/consumers/wiring_test.exs` asserts both
halves: the crontab entry exists, and the supervision tree gained nothing.

### 7.3 `account_name` and `invited_by` lookups — §2.6.

### 7.4 Retention for `consumed_events`

Core requires retention pruned in batches on a schedule, past the slowest
consumer's redelivery window. **Not built.** The consequence is a table that
grows forever, which core names as "the reason someone eventually deletes rows
that were never published". It is a crontab job and a `delete`, and it must not
be written before the subscriber's redelivery window is known — pruning by a
guessed window is how a consumer loses events it had not handled.

---

## 8. Findings for other packets — reported, not fixed

1. **`ProcessOutboxWorker.mark_refused/2` can kill the relay.** It writes
   `to_string(reason)` into `outbox_events.last_error`, which is
   `varchar(255)`, with **no bound**. A provider error carrying an HTML page
   raises `22001` from inside the loop — the same denial of service this packet
   had to avoid, and it is present in the relay today. `consumed_events`
   `last_error` is `text` and truncated to 2,000 characters for exactly this
   reason; **the relay's should be too.**

2. **`outbox_events` has no `account_id` on `courier.email.delivered`**, and
   `DispatchWebhooksWorker` claims rows with one — already recorded in
   `REPORT-courier-outbox-enqueue-01.md`. Unchanged here, and this packet makes
   it more visible rather than less: the fan-out has no producer **and** now
   there is a consumer on the other side of the bus with a retry budget that
   will never see an account-scoped event.

3. **core has a catalog row and no payload schema for
   `identity.member.invited`.** identity's own CI says so:
   `internal/platform/ci/event_grammar_test.go:153` — *"core has the catalog
   row but no payload schema"*. A consumer in any other language has nothing to
   generate against. If §2.4's one-line fix is applied, that schema is where it
   has to be declared, and the manifest schema's `consumes:` rule 6 (*"Every
   consumed type exists in the core catalog"*) passes on the catalog row alone —
   so nothing mechanical will catch it.

4. **identity names the type `identity.member.accepted` and core's catalog says
   `identity.member.joined`.** Already recorded in
   `identity/internal/outbox/tenancy.go`. Unrelated to this packet and not
   re-litigated here, but the first consumer of a tenancy event makes it visible
   to whoever rules on it.

---

## 9. What the next consumer should look like

The pattern is four steps and the first three are copy-paste.

### 9.1 Add the subscription — three files, in this order

1. **`cafaye.yml`** — add the type to `consumes:`. Core's rule 6: it must be in
   `core/docs/event-naming.md`, and it must not be a `courier.` type.
2. **`config/config.exs`** — add `"<type>" => <YourHandler>` to
   `config :courier, :consumers`. `Courier.ConsumersTest` holds this list and the
   manifest to each other, so a step skipped here is red, not silent.
3. **The handler module**, `lib/courier/consumers/<name>.ex`, with `handle/1`.

### 9.2 The handler's contract — four rules

1. **`handle/1` does the WHOLE job.** It is handed the `consumed_events` row,
   not the envelope, and it must `parse` then `deliver` itself. Returning
   `{:ok, _}` from a parse is how §5.2 happened.
2. **Answer, do not raise.** `Courier.Consumers` wraps you, but a raise still
   costs the event a delivery.
3. **Send through `Courier.Deliver`.** It is where the preference check, the
   per-type unsubscribe check and the mailbox suppression check live. A handler
   that dialled a provider itself skips all three.
4. **Refuse a payload you cannot render, by name**, and prefer **courier's own
   vocabulary** for a gap courier understands and `Courier.Mailers`' for one it
   does not.

### 9.3 The handler's tests — the shape that worked

    * one **positive** arm (a handler that refuses everything passes every
      refusal test);
    * one arm per missing payload field, refusing **by name**;
    * one arm for a field of the wrong **shape**, and the assertion that the
      refusal happens **before** the value is read;
    * **the counterfactual** — "would send if the payload carried X", which is
      the only thing that proves a refusal is about this payload rather than a
      function that refuses everything. It is a test because a comment claiming
      it would be untested.

### 9.4 What you do NOT write

- **No claim loop.** `Courier.Consumers` has it.
- **No dedupe.** The primary key is it.
- **No `consumed_at`.** `mark_handled/1` is it, from your `{:ok, _}`.
- **No `account_id`, no `protect_table`.** §4.3.
- **No subscription in the supervision tree** until the broker client lands.

### 9.5 And the one that is a decision, not a template

**Write down, before you write the handler, whether the event carries everything
the mail needs — and if it does not, decide lookup-or-report BEFORE building
either.** This packet could have spent its hour building two identity clients to
produce a mail with a dead link in it. The hour went into proving the gap
instead, and into a consumer the next six events can be dropped into.

---

## 10. Housekeeping

- **Gate:** `Result: 1458 passed` (`bin/prime`). Floors moved in the same commit:
  `gate.yml` minimum 1409 → 1458; `.github/workflows/ci.yml` whole suite 1409 →
  1458, no-database 645 → **651** (28 → 29 files, `wiring_test.exs` is an
  `ExUnit.Case`), database 764 → **807** (42 → 44 files).
- **`mix.lock` unmoved.** `mix.lock` was re-checked after `mix deps.get` and CI's
  `git diff --exit-code -- mix.lock` guard is satisfied.
- **`mix precommit` green**, compiling with warnings-as-errors.
- **`consumed_events` added to `Courier.BackupTablesTest`'s catalog**, with the
  consequence stated: *the dedupe lives in that table*, so losing it is not a
  loss of history — it is a loss of the guarantee. Restored, courier resumes
  from the broker's redelivery window; not restored, and the window closed, every
  handler runs a second time.
- **The grant is in the new migration**, not in
  `20261005120000_grant_app_role_runtime_dml`. Editing an applied migration
  makes the schema depend on which branch ran it — the reason
  `create_notifications` calls `protect_table` from a *new* migration rather than
  adding two calls to the old one. The cost is that the list is now in two files,
  which is stated in the migration's moduledoc.