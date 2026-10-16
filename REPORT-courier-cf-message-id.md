# REPORT — cf-message-id: the provider owns Message-ID

Worktree: `/Users/kaka/Code/any/moon/wt/cf-message-id`
Branch: `fix/cf-message-id-header`
Worktrees used: this one only. No second repository was needed.

## The defect, and the fix

Cloudflare Email Sending refuses a caller-supplied `Message-ID` — in either
case — with `400` and `{"success":false,"errors":[{"code":10202,"message":"email.sending.error.email.invalid"}],"result":null}`
(measured live on cafaye.com, 2026-10-16). `Courier.Deliver.tag/2` attaches
`message-id` (`<courier-<uuid>@cafaye.com>`) to **every** message it sends, so
every send through the Cloudflare adapter was refused.

The adapter (`lib/courier/adapters/cloudflare_email.ex`) now:

1. **Does not forward `message-id`.** `prepare_custom_headers/2` runs the
   message's headers through `drop_provider_owned_headers/1`, which drops the
   keys in `@provider_owned_headers` case-insensitively. It is a targeted drop
   of a header the provider OWNS, not an allow-list: `List-Unsubscribe` and
   `List-Unsubscribe-Post` still travel. The comment on `@provider_owned_headers`
   is the record.
2. **Reports the provider's id.** `accepted/2` returns
   `{:ok, %{id: result["message_id"]}}` — the provider's own Message-ID, the id
   its bounce and delivery reports quote — instead of `{:ok, %{id: nil}}`. A 2xx
   whose body carries no `message_id` still returns `{:ok, %{id: nil}}`; no id is
   invented.

The test server (`test/support/cloudflare_server.ex`) now behaves like the
provider: a request whose body carries a `message-id` header (either case) is
refused with `400 / 10202` — the same way the previous packet made it refuse the
`email` address key. A test that only asserted "the adapter dropped it" would be
re-stating the adapter's own constant; this makes the round trip fail if the
header is forwarded again.

## Commits

| sha | subject |
| --- | --- |
| `5f27691` | fix(adapter): the provider owns Message-ID — stop forwarding it, report its id |
| `03c1d65` | test(cf-message-id): split the send and not-forwarded proofs |
| `6dd442f` | chore(gate): raise the floors to the measured tree, and repair gate.yml's nesting |

## The exact wording left about Message-ID

On `@provider_owned_headers` in `lib/courier/adapters/cloudflare_email.ex`:

```
# THE PROVIDER OWNS `Message-ID`, AND THIS LIST IS WHY COURIER NEVER SENDS IT.
#
# Cloudflare Email Sending refuses a caller-supplied `Message-ID` — in EITHER
# case — with `400` and exactly
# `{"success":false,"errors":[{"code":10202,"message":"email.sending.error.email.invalid"}],"result":null}`
# (measured live on cafaye.com, 2026-10-16). It assigns a Message-ID itself and
# returns it as `result.message_id` on every 2xx — that is what `accepted/2`
# now reports as the receipt id, and it is the id the provider's own bounce and
# delivery reports quote.
#
# `Courier.Deliver`'s `tag/2` attaches `message-id`
# (`<courier-<uuid>@cafaye.com>`) to EVERY message it sends, so forwarding this
# one header was the difference between a delivery and a refusal of the whole
# message. It must never be forwarded again.
#
# This is a targeted drop of a header the provider OWNS, NOT an allow-list.
# `headers` is `additionalProperties: string` and Cloudflare accepts real
# headers — `List-Unsubscribe` and `List-Unsubscribe-Post` travel through it
# for RFC 8058 compliance — so refusing everything not on a list would break
# the moment Cloudflare adds a header. Only the provider-owned ones are ours to
# remove.
@provider_owned_headers ["message-id"]
```

## Commands, real output

Narrow (`mise exec -- mix test test/courier/cloudflare_delivery_test.exs test/courier/mailer_adapter_test.exs`):

```
Result: 87 passed
```

Full (`mise exec -- mix test`):

```
Result: 1747 passed
```

Tier greps (the two `grep` commands CI's tier steps use):

```
no database:  802 passed  (36 files)
database:     945 passed  (54 files)
802 + 945 = 1747          so the parts still sum to the whole
```

`bin/gate-self-test` (needs `CAFAYE_CORE=/Users/kaka/Code/any/moon/cafaye/core`):

```
== the control: the unmodified declaration ==
ok   static (declaration vs tree) green (exit 0)
ok   prove (runs the real gate)   green (exit 0)
     the gate reported: Result: 1747 passed
== the breakages ==
ok   ... (all nine caught)
gate-self-test: 11 passed, 0 failed
```

## Red proofs

| mutation | reverted | tests that went red |
| --- | --- | --- |
| (a) `drop_provider_owned_headers/1` returns `headers` unchanged (message-id forwarded again) | yes | `a message carrying message-id sends successfully` — got `{:error, {400, %{"errors" => [%{"code" => 10202, ...}]}}}`; and `the provider never receives a message-id header, in any case`. 2 red. |
| (b) `accepted/2` returns `{:ok, %{id: nil}}` again | yes | `the receipt carries the provider's result.message_id` — got `{:ok, %{id: nil}}`. 1 red. |

Both were also observed together in the pre-fix run (2 red, the same two), before
the adapter was changed.

## What I deliberately left alone

**The `Deliver` correlation gap — NOT this packet, as the brief says.** `Courier.Deliver`
records its OWN generated id and never reads what the adapter returns:

- `lib/courier/deliver.ex:343` — `message_id = "courier-" <> Ecto.UUID.generate()`
- `lib/courier/deliver.ex:348` — the tagged message is what is delivered
- `lib/courier/deliver.ex:349` — `{:ok, _metadata} -> record(type, user_id, message_id, email)`
  **discards the adapter's returned id** (`_metadata`), so the outbox row's
  message id is courier's own and the provider's `result.message_id` is thrown
  away.
- `lib/courier/deliver.ex:453-454` — `tag/2` attaches the header the provider
  refuses.

The follow-up decision (outbox stores the provider's id, or both) touches
`Deliver`, the outbox schema and the inbound-report path. Recommended successor
first move: have `Deliver` keep `metadata.id` from `deliver_to_provider/2`, and
decide whether it replaces or accompanies the `courier-<uuid>` value in the
outbox row.

Not touched: `lib/courier/deliver.ex`, `tag/2`, the outbox, `Courier.Mailers`,
the inbound-report path.

## Conventions this repo's state contradicted

1. **`gate.yml`'s proof floor had been unenforced since `dcf3366` (w85).** The
   `minimum:` line was at 2-space indent, a direct child of `gate:` rather than
   of the proof list item, so core's `gate-check` rejected the whole declaration
   with `gate: additionalProperties 'minimum'` and never read the floor. This is
   a pre-existing defect on the committed tree (verified with
   `git stash`), not introduced here. Fixed to nest under the proof item; the
   committed tree now validates. **This means every packet between w85 and now
   that "raised the floor" was editing a number nothing checked.**
2. **The committed floors were stale.** CI read `1740 / 795 / 945` and `gate.yml`
   read `1695`; the brief's own baseline was 1742. The two tier greps and
   `mix test` measure `1747 / 802 / 945`, so all three floors were raised to the
   measurement (CI: `whole 1747`, `no database 802`; `gate.yml` minimum 1747).
   The tiers moved +7 for this packet's +5 because the baseline was already 2
   short — the same stale-floor class AGENTS.md names.
3. **`mix compile --warnings-as-errors` transiently aborted** while
   `mix deps.get` was still compiling dependencies in this fresh worktree (it
   reported a deprecation warning inside `deps/connection` and exited 1). A
   re-run was clean. Not a code issue, recorded so the next reader does not
   chase it.
