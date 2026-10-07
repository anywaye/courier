# REPORT — courier: the sessions-revoked consumer

Branch `worker/courier-w39-passwordnotice`. Packet: consume
`identity.session.revoked` and send the account-security notice the person is
owed when their credentials end.

## What this is

The fleet's third subscription, and the first one that **sends mail**. The
invite packet built the consumer and its handler refuses by design (the accept
URL is unrecoverable from any event); the acceptance packet's handler records
an in-app notification (the payload carries no address). This payload carries
the recipient and the fact — `user_id`, `email`, `reason` — so the positive
arm is a real send through the real `Courier.Deliver`.

- `lib/courier/consumers/sessions_revoked.ex` — the handler
- `lib/courier/mailers/templates/account_security.{html,text}.eex` — the template
- `lib/courier/mailers.ex` — the fourth type, `account_security`
- `lib/courier/deliver.ex` — `Deliver.account_security/1`
- `config/config.exs` — the registry entry and the subject
- `cafaye.yml` — the `consumes:` entry, with the publisher cited
  (`identity/internal/outbox/recovery.go`, `NewSessionsRevoked`)
- `test/courier/consumers/sessions_revoked_test.exs` — 19 tests
- `test/courier/mailers_test.exs` — 5 tests for the new type

## The reason-branching decision: two renderings, one template, a closed set

The event covers TWO reasons with one type. The handler branches on `reason`
into two renderings of one `account_security` template:

    password reset         → "Your password was changed."
    email address changed  → "The email address on your account was changed."

**Why branch at all, rather than mail a reason-agnostic notice.** The two
facts have different remediations, and a notice that does not name which one
happened forces the reader to guess: a person whose password was changed resets
it — they still control the address a reset link goes to — while a person whose
address was moved cannot use a mailed link at all, because the address the
account now uses is not theirs. "Your account was updated" is the shape of
mail people learn to ignore, and this is the one mail they must not.

**Why one template, not two.** One type, one subscription, one
`notification_type` on the bus. The reason is a rendering choice, not a mail
type. Two templates would double the `kinds` and `required` tables for a fact
that is one shape: credentials ended, act accordingly.

**Why an unknown reason is a refusal, not a default.** The closed set is the
publisher's contract: `validateReason` in the same file refuses a third value
at build time, and core's payload schema (`additionalProperties: false`,
`required: [user_id, reason]`) pins the shape. But the publisher's validation
is not the consumer's boundary — a different publisher, an older build, a
buggy middlebox — sends what it likes, and the consumer that trusts the
publisher is the consumer that **renders the wrong reason**: a notice saying
"your email address was moved" about an admin revocation is a false claim
about somebody's account, delivered to their inbox. So the handler validates
the reason itself and refuses `{:error, {:unknown_reason, reason}}` — the
same fail-closed shape as `Courier.Suppressions`' `{:error,
{:unknown_bounce_type, value}}`. The row walks its attempt budget and is then
left alone to alert on, which is the honest shape for "this needs a decision
in identity, not a retry".

## What the payload had to carry

Three fields, and the handler needs all three:

| field | why |
| --- | --- |
| `user_id` | the subject — the person whose credentials ended |
| `email` | **the recipient** — the first event courier has consumed that carries an address |
| `reason` | which of the two facts happened, validated against the closed set |

**This is the first event courier consumes whose payload is sufficient for a
mail.** The invitation was missing the one field that mattered (the accept
URL, unrecoverable by design) and the acceptance carried no address at all.
This one carries the recipient and the fact, so the handler sends and nothing
is looked up — the same discipline the invite packet established, satisfied for
the first time.

**The address is the NEW one for the email-change reason.** `ConfirmEmailChangeNew`
reads the user after `SetEmail` in the same transaction, so the event carries
the address the account now uses. That choice is identity's, measured and
recorded in `REPORT-identity-event-payloads-01.md` §2.3: "a notice confirming
a change belongs at the address the account now uses." This handler mails
what the event carries and nothing else — the old-address-as-warning
alternative is a payload change (the event is one field, not two), not a
consumer change.

## What was deliberately not done

- **No lookup of any kind.** The handler has no identity client, no user read,
  no account read. The payload is the whole of what it acts on. A field the
  payload does not carry is a refusal, not a gap to fill — the member_invited
  precedent.
- **No new refusal vocabulary beyond one.** The handler adds exactly one
  refusal of its own — `{:error, {:unknown_reason, reason}}` — and everything
  else it returns is `Courier.Deliver`'s or `Courier.Mailers`' unchanged. A
  handler that translated another module's refusals into its own dialect would
  put every future caller in the position of matching on strings nobody else
  produces.
- **No `from`, no `text`/`html` in the request.** courier sends transactional
  mail it renders from its own templates; the sender and subjects stay
  configuration. The subject is reason-agnostic ("Security notice for your
  caFaye account") because the configuration is one line per type and the body
  is where the reason-specific wording lives.
- **No bulk type.** `account_security` is `:transactional`, like every type
  courier sends. Adding a bulk type is a change in core, not here.

## The core enum gap, reported and not applied

Adding `account_security` to `Courier.Mailers.types/0` means the
`courier.email.delivered` event's `data.notification_type` can carry a fourth
value, and `core/schemas/events/courier/email/delivered.schema.json` freezes
that field to an enum of the three current names. The switch is one row here
plus one enum value in core, and core is not this repository's to change.

`test/courier/events_test.exs` pins the known divergence — `Mailers.types() ==
@notification_type ++ ["account_security"]` — rather than asserting an
agreement that no longer holds. A fifth type still fails it. The day core's
enum grows the fourth name, the `++ ["account_security"]` comes out and the two
lists are equal again.

## The `bound/1` fix: a tuple refusal must not kill the loop

`Courier.Consumers.bound/1` renders a handler's refusal reason into the
`last_error` column. It was `reason |> to_string() |> String.slice(0, 2_000)`,
and `to_string/1` **raises** on a tuple — tuples do not implement `String.Chars`.
The earlier handlers never hit this: `MemberInvited` refuses with an atom and
`MemberAccepted`'s failure path is a rescued raise, which is a string. This
handler is the first whose refusal reaches `bound/1` as a tuple
(`{:invalid_payload, changeset}` from `Courier.Mailers`, passed through
unchanged).

The raise is inside `record_failure/3`, which `safe_apply/2`'s rescue does
**not** cover — so it kills the loop, which is the one thing this module exists
to prevent. `bound/1` now renders a non-binary reason with `inspect/1`, which
never raises and keeps the reason readable on the row. The test "a handler
failure leaves `consumed_at` NULL" asserts `last_error =~ "email"` through the
real loop, so the fix is proven by a claim about a row rather than about a
function.

## The gate

`mise exec -- ./bin/prime` — green, `Result: 1512 passed`. The floors were
re-measured on this tree: whole suite 1488 → 1512, no-database tier 665 → 670
(30 files), database tier 823 → 842 (46 files). The +24 split 5 / 19, read off
the case templates the tier greps use: 5 in `mailers_test.exs` (a plain
`ExUnit.Case`), 19 in the new `sessions_revoked_test.exs` (a
`Courier.DataCase`). 1512 is 670 + 842.

Two existing files changed assertions without gaining tests:
`notification_preferences_test.exs` and
`notification_preferences_controller_test.exs` both enumerate the types
`Mailers.types()` returns, and the fourth type is now one of them —
`NotificationPreferences.types/0` delegates to `Mailers.types/0`, so the
preference defaults cover `account_security` too.
