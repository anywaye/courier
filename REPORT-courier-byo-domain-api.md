# byo-domain-api — the sending-domain management API

**Packet:** `feat/byo-domain-api`. **Status: complete.** The gate is green on the
committed tree: `bin/prime` reports `Result: 1797 passed`, exit 0, and
`bin/gate-self-test` passes 11/11 against that same committed tree.

## What shipped

The HTTP surface over `Courier.TenantSendingDomains`, exactly the behaviour the
merged context already provides — no new context function was added.

| method | path | action | success | refusals |
| --- | --- | --- | --- | --- |
| `GET` | `/v1/sending_domains` | `index` | 200 | 401, 406, 500, 503 |
| `POST` | `/v1/sending_domains` | `create` | 201 | 400, 401, 406, 409, 422, 500, 503 |
| `GET` | `/v1/sending_domains/:id` | `show` | 200 | 401, 404, 406, 500, 503 |
| `POST` | `/v1/sending_domains/:id/verify` | `verify` | 200 | 400, 401, 404, 406, 409, 422, 500, 503 |
| `POST` | `/v1/sending_domains/:id/revoke` | `revoke` | 200 | 400, 401, 404, 406, 422, 500, 503 |

`create` and `verify` are behind `:idempotent`; `revoke` is not (it is
idempotent by construction — a repeat is the same row with the same status).
`index`, `show` and `revoke` are behind `:authenticated` only. All five are
behind `:authenticated`.

Files:

* `lib/courier_web/sending_domains.ex` — the closed request vocabulary.
* `lib/courier_web/controllers/sending_domains_controller.ex` — the eight actions.
* `lib/courier_web/router.ex` — five routes on the two existing scopes.
* `openapi.yaml` — the five operations, the `SendingDomain*` schemas, the
  `SendingDomainId` parameter, and a reusable `IdempotencyConflict` 409.
* `test/courier_web/controllers/sending_domains_controller_test.exs` — 23 tests.
* `test/courier_web/router_test.exs` — 5 tests.
* `gate.yml`, `.github/workflows/ci.yml` — floors raised to the measurement.

## How the account reaches the context

`conn.assigns.current_account`, written by `CourierWeb.Plugs.Principal`, and
nowhere else:

* `lib/courier_web/controllers/sending_domains_controller.ex:71` — `create`
  passes it to `Courier.TenantSendingDomains.register/2`.
* `...:91` — `index` passes it to `list/1`.
* `...:151` — `fetch/2` passes it to `get/2`, which every id-addressed action
  uses.
* `...:168` — `scoped/2` opens the `Courier.Tenancy.with_account/3` transaction
  the row-level-security policy on `tenant_sending_domains` keys on.

The body cannot name an account: `lib/courier_web/sending_domains.ex:40` is a
closed field list and `unknown/1` (line 73) refuses anything outside it, so an
`account_id` in a body is a 422 `unknown_field` — the same answer
`CourierWeb.Messages` gives. Underneath, `Courier.TenantSendingDomains.register/2`
(`lib/courier/tenant_sending_domains.ex:130`) sets `account_id` from its argument
and `Courier.TenantSendingDomain.changeset/2`
(`lib/courier/tenant_sending_domain.ex:79`) does not cast it.

## A credential never comes back

`domain_json/1` renders a fixed set of eight fields — `id`, `account_id`,
`domain`, `provider`, `status`, `verified_at`, `inserted_at`, `updated_at` — and
neither `credential` nor `provider_account_id`. There is no `token/1` on the
context, and the controller never touches `domain.credential`. Three tests assert
the rendered **keys** and the token's absence from the response bytes on a
register, a verified row, and the two read surfaces.

## Red proofs

Both were run, observed red, and reverted (`git status` clean after each).

| property | mutation | tests that went red |
| --- | --- | --- |
| a credential never comes back | added `credential: domain.credential` to `domain_json/1` | 3: *the register response's keys are the eight the document declares*, *a VERIFIED row's response carries no credential either*, *the read surfaces carry none either* — `20/23 passed` |
| the account is the principal's, not the request's | added `account_id` to `@wire_fields` and made `create` call `register(params["account_id"] \|\| current, …)` | 1: *a body carrying account_id is refused, and registers nothing* — `22/23 passed` |

The account red proof needed both edits: the closed vocabulary is a second,
independent control, so honouring the body's account alone is masked by the 422
the vocabulary sends first. That is the intended layering, and it is why the
mutation had to open both to reach the account source.

## Narrow and full commands

```
mise exec -- mix test test/courier_web/controllers/sending_domains_controller_test.exs \
  test/courier_web/router_test.exs test/courier/tenant_sending_domains_test.exs
# Result: 74 passed

mise exec -- ./bin/prime
# Result: 1797 passed, exit 0

./bin/gate-self-test
# gate-self-test: 11 passed, 0 failed  (control reported Result: 1797 passed)
```

Tier re-measurement, by the two CI greps: whole **1797** = no-database **815**
(37 files) + database **982** (56 files). The `+28` split 5 (router) / 23
(controller) by case template. The whole-suite floor in `gate.yml` and in
`.github/workflows/ci.yml`, and both tier floors, were raised to the measurement
in the same commit. The baseline was exactly 1769, so this is the packet's own
delta and not a catch-up over a stale floor.

## Deliberately left alone

* `Courier.Deliver`, the outbox, `MailerAdapter` and the adapters — the send
  path is not this surface.
* The row-level security: no policy, table or grant was touched; the controller
  uses `Courier.Tenancy.with_account/3` unchanged.
* No HTTP surface for the deployment's own domain.
* The verification recipient (`sending-domain-verification@cafaye.com`, hardcoded
  in the context) was **not** made configurable — a known, deferred follow-up.
* `List` has no pagination, because `Courier.TenantSendingDomains.list/1` has
  none; the API exposes what the context exposes.

## What the context could not do that the API needed (next packet's brief)

1. **`POST /v1/messages` cannot report a sending-domain refusal.** `Courier.Deliver`
   returns `{:error, {:unverified_sending_domain, domain}}`,
   `{:error, {:revoked_sending_domain, domain}}` and
   `{:error, {:no_sending_domain, domain}}`
   (`lib/courier/deliver.ex:291,294,303`), and
   `CourierWeb.MessagesController.create/2`'s `else` has no clause for any of
   them — a `WithClauseError`, rendered as a **500**. The sending-domain packet
   added the send path's refusals and never wired the door that reaches them.
   This is out of this packet's scope (the brief forbids touching `Deliver`), but
   a tenant whose domain is unverified gets a 500 from the send API rather than a
   422/409.
2. **The send API has no per-request from-domain.** `Courier.Deliver` chooses the
   credential by the message's from-domain, and the from-domain is
   `config :courier, :mailing[:from]` — global configuration, not a request
   field. So a tenant domain can only be selected when the deployment's config
   names it, which is one domain for the whole deployment. Per-tenant selection
   (an account→domain choice resolved in `Deliver`) is the missing half of the
   isolation this feature is for. `POST /v1/messages` does not, and per
   `CourierWeb.Messages`' own rule must not, accept a `from`.
3. **`verify/2` collapses every provider failure into `credential_refused`.** A
   token that is not scoped to the domain and a provider that is briefly down are
   the same `{:error, {:credential_refused, reason}}`, so the controller answers
   both with a 422 naming the credential — a transient provider outage reads as
   "fix your token". Distinguishing a 4xx from a 5xx (or a transport failure) in
   the adapter would let the API answer 422 vs 503 honestly.
