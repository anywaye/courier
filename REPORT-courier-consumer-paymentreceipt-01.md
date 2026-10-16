# REPORT-courier-consumer-paymentreceipt-01 — the receipt, and the two decisions it needed

**Packet:** the billing local-stack round — the one thing the whole-stack walk
showed missing that a person can see. **Branch:** `master` (landed directly).
**Verdict:** `mix test` 1701 passed, 0 failures. `gate.yml` floor restated
1688 → 1695, the CI tiers restated (database 903 → 916, files 51 → 52), and the
consumes list unchanged in SIZE but joined by a fifth entry.

---

## 1. The gap the walk made visible

Walked on the whole cafaye stack (launch four + billing on the shared cluster),
a real test-mode charge settled and published `billing.payment.succeeded` onto
the `cafaye` JetStream stream — and nothing in the fleet consumed it. Courier's
`consumes:` held four `identity.*` types; no `billing.*` subscription existed
anywhere. The customer paid and was never told, by anyone, that they had.

The money event was built for exactly this from the beginning:
billing-event-payloads-01 added the recipient fact (`email`) to the two payment
types because "courier has no billing client and no billing tables, so an event
with no address on it is an event that is dropped" (its own words, in
`app/services/webhooks/stripe_events.rb`). The field was published first and the
consumer came second; this is the consumer that fact was waiting for.

## 2. What landed

- `Courier.Consumers.PaymentSucceeded` — `billing.payment.succeeded` → the
  receipt. The payload is read three fields at a time (`email`, `amount`,
  `cafaye_customer_id`) with the invoice id optional, every refusal named,
  nothing sent on a malformed payload. The amount is rendered HERE
  (`19.00 USD`; JPY and friends at zero decimals) because courier has no Money
  concept and the templates must never compute.
- The seventh notification type, `receipt`: `Courier.Mailers`, both templates,
  the subject line, and every closed-set table that reads the catalog — the
  events schema-gap table, the mailers types, the preferences catalog in two
  files, the controller's two seven-slot patterns, the header sweep's payload
  fixture, and `Courier.Consumers`' subscribed list. All thirteen new tests are
  in the database tier, where `Courier.Deliver`'s transaction runs.
- `cafaye.yml` (+ the config `:consumes` map) gained
  `billing.payment.succeeded`.

## 3. Two decisions, made here and stated

### 3.1 The delivered event's `user_id` carries the CUSTOMER

`Courier.Deliver` attributes a send to a user and refuses without one — and the
money event names no user. It names the cafaye CUSTOMER the money moved for;
billing has no users (its customers are account-owned) and the fleet's consumer
rule forbids looking anybody up. So the payer's customer id is the attribution,
and every check still runs: the preference check is vacuous for an id with no
stored preference (default on), the per-type unsubscribe is vacuous for a
`transactional` type (no header exists to have recorded one), and the address
suppression check — the load-bearing one — is unchanged.

The tension is recorded rather than hidden: a reader of `courier.email.delivered`
joining on `user_id` for THIS type is reading a customer id, and a
`payer_identity` field core owned would be the honest fix.

### 3.2 The invoice id is optional, and the receipt still sends

An invoice-backed payment carries `invoice_id`; a payment-mode Checkout does
not. Refusing the send for the second shape drops receipts for payments the
platform legitimately produces, so the reference line renders when it is
present. This is the only optional field in the catalog.

## 4. The core enum gap, reported and NOT applied

`receipt` is now a type courier can put in a payload, and
`core/schemas/events/courier/email/*.schema.json` (all four) freeze
`notification_type` to the three names core last froze. `Courier.EventsTest`'s
gap table carries the divergence by name the way the sessions-revoked packet
established — an EIGHTH type fails it until core's enum grows. The switch is one
enum value per schema in core, and core is not this repository's to change.

## 5. What the packet does not do

- No PDF receipt. `prawn` in billing is the phase-E packet, and an HTML mail is
  the honest first receipt — nothing was waiting on the PDF to be able to send
  one.
- No receipt for a payment with no recipient fact (a dashboard customer, or a
  `/v1` customer whose email was never set): billing keeps the field ABSENT in
  that case, and the handler refuses it by name rather than mailing a guess.
- No preference UI. The preference defaults (on) apply to the seventh type like
  the other six; a person turns receipts off through the existing surface when
  parlor wires the toggle for the money types.
