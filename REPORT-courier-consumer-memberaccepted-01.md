# REPORT — courier: the member-accepted consumer

Branch `worker/courier-w24-memberaccepted`. Packet
`moon/prompts/…-courier-consumer-memberaccepted-01.md` (consume
`identity.member.accepted` and tell the member they are in).

## What this is

The fleet's second subscription, and the first one courier can **act** on. The
invite packet built the consumer — claim, dispatch, mark, dedupe, retry — and its
handler refuses by design, because the accept URL is unrecoverable from any
event. This packet's handler is the opposite shape: the payload's three fields
are exactly what one of courier's delivery surfaces takes, so the positive arm
is a real write to real tables.

- `lib/courier/consumers/member_accepted.ex` — the handler
- `config/config.exs` — the registry entry
- `cafaye.yml` — the `consumes:` entry, with the publisher cited
  (`identity/internal/outbox/tenancy.go`, `NewMemberAccepted`)
- `test/courier/consumers/member_accepted_test.exs` — 16 tests
- `test/courier/consumers_test.exs` — the two assertions that hold the registry
  and the manifest to each other, extended to the second entry

## The surface decision: in-app notification, and the payload is why

Two delivery surfaces exist in courier, and the payload decides which one is
actionable:

| surface | needs | in the payload? | actionable? |
| --- | --- | --- | --- |
| in-app (`Courier.Notifications`) | `account_id`, a recipient, a type | `account_id` + `user_id` (a real person — they just accepted) | **yes** |
| email (`Courier.Mailers` + `Courier.Deliver`) | an address, and for "you joined account X" an `account_name` | **neither** | **no** |

**So the handler records a notification and mails nobody.** The member who
accepted is the recipient (`user_id` is the whole reason this surface works),
the type is `welcome`, and `params` carries `role` — the one fact a renderer
needs that is not already a column on the event row.

This handler is `Courier.Notifications.record/2`'s **first production
caller**. The in-app packet built and tested the record; nothing had ever
written one.

### Why not email, and why that is not a gap in the handler

The mail a member would want needs the recipient's address and the account's
name. The payload carries neither, and courier has deliberately no identity
client — `REPORT-courier-consumer-invite-01.md` §2.6 refused a second identity
client in exchange for one field, and that refusal stands. The unblock is one
line in identity's `NewMemberAccepted`: carry the member's address. Until it
lands, a mail with a blank where the address — or the account name — should be
is the exact failure the invite packet refused to send, so the refusal is
**reported here rather than coded**: a handler that never attempts email has
no email-refusal branch to write.

### Why the type is `welcome` and not a new `member_joined`

`Courier.Notifications.types/0` is a closed vocabulary, and the in-app packet's
own warning applies: a new type is a decision about how a consumer renders it,
courier renders nothing, and "naming a type with no renderer behind it is how a
type ships that nothing can display." A member who just accepted is being told
they are in — `welcome` is that type, and it has semantics behind it already.

## The name divergence, consumed and not resolved

core's catalog (`core/docs/event-naming.md`) calls this fact
`identity.member.joined`; identity publishes `accepted` per the packet decision
recorded in the source comment at `tenancy.go:55-70`. **The handler subscribes
to what is actually published** — a subscription to a type no publisher declares
fails on somebody else's deploy (core's rule 6) — and the divergence is
reported here rather than renamed. Nothing in courier's vocabulary changes.

## What the next consumer (subscription lifecycle) will need

The same file publishes the rest of the membership lifecycle, and the payload
discipline this handler establishes covers part of it:

- **`identity.member.role_changed`** carries `user_id`, `previous_role`,
  `new_role` (per `tenancy.go`'s own comment on the builder). The same
  discipline — validate the string fields, record an in-app notification —
  applies unchanged.
- **`identity.member.removed`** carries `user_id` and the role they held. Same
  shape.

**What this payload discipline does not cover**, and the next consumer will
have to decide:

1. **A two-recipient event.** `identity.account.ownership_transferred` names
   *two* memberships (`previous_owner_id`, `new_owner_id`) because a transfer
   changes two memberships at once. This handler's discipline is one recipient
   from `user_id`; the next consumer of that event needs
   `Courier.Notifications.record/2`'s `:recipients` list, which this packet
   deliberately did not use. The fan-out is the event's shape, not a field
   this payload lacks.
2. **An event that carries the account name.** `identity.account.created`
   carries `name` and `slug` — the very field `identity.member.accepted`
   lacks. The asymmetry is the finding: the platform's account-created event
   can render "you created account X" with a name, and its member-accepted
   event cannot render "you joined account X" with one. A renderer shows the
   account by id on the accepted event and by name on the created event, and
   that difference is identity's payload, not courier's handler.
3. **Email for any of it.** Every membership event is email-blocked on the
   same two absences (address, account name). One line in each identity builder
   unblocks them; until then the in-app surface is the only actionable one.

## What was deliberately not done

- **No email.** The payload has no address and no account name; courier has no
  identity client. The unblock is identity-side and named above.
- **No new notification type.** `welcome` is the "you're in" type; a
  `member_joined` would ship a type with no renderer.
- **No `account_name` in `params`.** The payload does not carry one and
  courier cannot look one up. A blank where the name should be is the one
  outcome this packet exists to prevent.
- **No `account_id` in `params`.** It is a column on `notification_events`;
  duplicating it into jsonb would be two copies of one fact that can disagree.
- **No `record_type`/`record_id`.** The event happened to a membership, and
  the payload carries no membership id — a polymorphic reference to a row
  courier cannot name is a pointer that 404s.
- **No change to `Courier.Consumers.MemberInvited`.** It refuses by design.
- **No change to `identity/`, `billing/`, `core/`, or any other repo.**

## The tests, and the red they produce without the wiring

16 tests in `test/courier/consumers/member_accepted_test.exs`, a
`Courier.DataCase` because every claim is a claim about rows — the
notification the handler writes, the `consumed_events` row the loop marks, the
dedupe the primary key enforces. The file carries `@moduletag account:` because
the account the handler writes is the **payload's**, so the test's tenant
identity must be the same uuid or every write is refused `42501`.

The four the packet asked for, and where each lives:

| claim | test |
| --- | --- |
| the event is received and the action happens | "is recorded as an in-app notification, addressed to the member" + "a delivered acceptance event reaches the handler and is recorded" |
| a malformed event is refused, not crashed on | the five "an event courier cannot parse" arms + "records nothing when the payload is refused" |
| a handler failure leaves `consumed_at` NULL | "a handler failure leaves consumed_at NULL, so the event is retried" |
| a redelivered envelope id is deduped | "a redelivered envelope id is deduped, not acted on twice" |

**The red, measured.** With the registry entry removed from `config/config.exs`
and the handler module left in place, 4 of the 16 fail: the three integration
tests (the event is `skipped`, not `handled` — `handler_for/1` returns `nil`)
and the registry test ("names the same type the registry is keyed on"). The 12
that still pass are the unit arms that call the handler module directly; they
do not need the wiring, which is exactly why the wiring has its own tests.
Restoring the entry: 16/16.

Two test bugs of mine, recorded because both were wrong about the code rather
than the code being wrong: an empty payload is refused as `"data"` (the
`MemberInvited` discipline — `fetch_data/1` refuses an empty map before
`fetch_fields/1` names a field), and a non-uuid `account_id` **raises**
`Ecto.ChangeError` at dump time rather than being changeset-refused, because
`account_id` is `put_change`d past the cast. The loop's rescue catches that —
the integration test proves it — but a raise is not a refusal, so the unit test
uses a 300-character `user_id`, which `validate_length` refuses cleanly.

## The gate

`mise run prime`, after the floors were raised:

```
Finished in 7.3 seconds (3.9s async, 3.4s sync)

Result: 1488 passed
```

1488 = 665 (no database, unchanged across the same 30 files) + 823 (database,
807 + 16 across 44 + 1 files). The floors moved in the same commit:
`gate.yml` `minimum` 1472 → 1488, and CI's whole-suite and database floors
1472/807 → 1488/823. `core/harness/bin/gate-check`: 0 failures, 2 warnings
(the pre-existing unproven-requirement notices).

## Findings

1. **`Courier.Notifications.record/2` had no production caller before this
   packet.** The in-app packet built and tested the record across 61 tests and
   nothing ever wrote one. This handler is its first caller, which is the
   argument for acting on the first payload that can reach it rather than
   waiting for the perfect one.
2. **A non-uuid `account_id` raises inside `record/2` rather than being
   refused.** `account_id` is `put_change`d after the cast, so a malformed
   value reaches `dump_field!` and raises `Ecto.ChangeError`. The loop catches
   it (the integration test's log line is the proof), so it is not a crash —
   but it means the handler-failure path for a malformed account is a rescue,
   not a changeset. Not fixed here: it is `Courier.Notifications`' behaviour,
   pre-existing, and the loop's contract is that a raise is a failed row.
3. **The payload's three fields are exactly one surface's worth.** That is the
   packet's design decision made visible: `identity.member.invited` can act on
   nothing (no URL), `identity.member.accepted` can act on the in-app surface
   (has `user_id`), and both are email-blocked on the same two absences. The
   fleet's event payloads are per-surface, and courier's consumers will be
   too until identity's builders carry more.
