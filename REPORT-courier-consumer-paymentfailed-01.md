# REPORT-courier-consumer-paymentfailed-01 — the warning, and the sibling it borrows from

**Packet:** the deployment round — the one money event with no human-facing
answer. **Branch:** `master` (landed directly). **Verdict:** `mix test` 1769
passed, 0 failures. Floors restated 1752 → 1769 whole, no-database 807 → 810
(37 files), database 945 → 959 (55 files); the baseline was itself stale by one,
recorded in `gate.yml`.

---

## 1. The gap

billing publishes `billing.payment.failed` from the same
`Webhooks::StripeEvents.payment_emission` builder as the receipt, and the
recipient fact added in the payloads packet (`email`, resolvable on a first
payment since the cafaye-first lookup fix) meant the event arrived at courier
complete. Nothing consumed it: a declined card produced no mail to anyone, and
courier's subscriber was dropping the event family's failure half on the floor —
measured on the launch stack, 2026-10-16, where a real $49 payment's *succeeded*
event was refused for a missing address ten times, which is the same failure
mode the failure events had for a different reason.

## 2. What landed

- `Courier.Consumers.PaymentFailed` — `billing.payment.failed` → the warning.
  Arm-for-arm the receipt handler's shape (the two events are built by one
  builder, so a field one refuses and the other accepts would be the two halves
  of one payload disagreeing): email, `cafaye_customer_id` and `amount` required
  and refused by name, `invoice_id` optional, the row taken rather than the
  envelope, the send attributed to the cafaye customer.
- The eighth notification type, `payment_failed`: `Courier.Mailers` (types,
  kinds, required fields), the subject line, both templates, and every
  closed-set table — events schema-gap, preferences catalog in three files, the
  controller's two eight-slot patterns, the compose-config optional-reads table
  (`COURIER_BILLING_URL`), and `Courier.Consumers`' subscribed list plus the
  `consumes:` regex in `cafaye.yml`.
- `Courier.Consumers.AmountDisplay` — the payment family's ONE renderer, and
  `PaymentSucceeded` now delegates to it. Two copies would have been two answers
  to "what does 1900 USD read as", and the day they disagreed the same amount
  would print differently in the two mails about one subscription.

## 3. Decisions, stated

### 3.1 The retry schedule is deliberately not in the mail

The payload carries `next_payment_attempt` and the handler ignores it: rendering
it would make courier compute and render a date, which this repository has no
concept for, and the schedule belongs to the processor (Stripe's smart retries
live in its dashboard, not in this fleet). The mail's job is the fact and the
remedy; a test asserts the date appears in neither body.

### 3.2 The action link is configuration, not payload

`COURIER_BILLING_URL` (unset by default) is where the warning's reader goes to
update their card. The payload carries facts about the event; which page a
deployment's billing screens live on is a fact about the deployment — the same
split as `MAIL_FROM`, which is why it is read in `Courier.Mailers` and required
of no consumer. Unset means the sentence renders without a link.

### 3.3 The copy asks without announcing an ending

A failure is not final — the processor retries, and a renewed card mid-retry is
a subscription that never lapses. So the mail names the failed attempt's amount,
says "Nothing was charged." (the reassurance a person needs), and asks for the
update rather than announcing a cancellation it cannot see.

## 4. The core enum gap, extended and re-reported

`core/schemas/events/courier/email/*.schema.json` still freezes
`notification_type` to three names; courier now sends eight. The known
divergence is pinned by assertion in `events_test.exs` (a ninth type fails it)
and remains reported rather than applied — the same disposition as the receipt
packet, with this repository's four schema files named in the test.
