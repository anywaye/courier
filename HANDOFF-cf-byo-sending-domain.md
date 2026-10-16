# cf-byo-sending-domain — report and handoff

A tenant's mail leaves from the tenant's own domain, on the tenant's own
provider credential, and courier refuses rather than falling back to the
deployment's key when the from-domain is not one it can prove.

Branch: `feat/byo-sending-domain` (worktree `moon/wt/cf-byo-domain`). Nothing
pushed; the manager merges.

## Commits

```
ba900d4  ci: the floors are the measurement — whole 1740 = no-db 795 + db 945
aaea7d3  test(backup): decide tenant_sending_domains, and raise the CI floors
fb9ba4f  feat(sending-domains): the send path selects by from-domain, and refuses without one
cfb3e26  test(sending-domains): the context — storage, the two-part proof, revocation
4fc5cf5  feat(sending-domains): tenant sending domains, storage and the send-path seam
```

The tree carried uncommitted partial work from the interrupted first attempt.
It was a real skeleton — the schema, the context, the migration and the DNS
seam — but it **did not compile** (`send_and_record/4` was called and only
`/3` defined; `Courier.TenantSendingDomains` was missing `import
Ecto.Changeset`; a `*registered*` typo in a comment was a syntax error), the
tenant credential was computed and then **thrown away** (the send called
`Mailer.deliver/1` with the deployment config regardless of the chosen
sender), and no test existed. I kept the shape and fixed the wiring.

## The narrow command

```
$ mix test test/courier/deliver_test.exs test/courier/tenant_sending_domains_test.exs
Running ExUnit with seed: 422460, max_cases: 16
..........................................
Finished in 0.4 seconds (0.3s async, 0.1s sync)
Result: 42 passed
```

Plus the file the send-path tests live in:

```
$ mix test ... test/courier/deliver_sending_domain_test.exs
Result: 50 passed
```

Full gate: `./bin/prime` → **`Result: 1740 passed`, exit 0**.

## Red proofs

Each mutation was applied to `lib/courier/deliver.ex` on the committed tree,
the named test run, the mutation reverted with `git checkout --`, and the file
re-confirmed green (8/8).

| # | mutation | named test that went red |
| - | -------- | ------------------------ |
| 1 | tenant branch ignores the row's credential (`Mailer.deliver(email)` instead of `Mailer.deliver(email, config)`) | *a verified domain is selected → the TENANT's token is what the provider receives* — 7/8 |
| 2 | unverified clause made unmatchable (`verified_at: nil, id: nil`) so an unverified row falls through to the tenant branch | *a row that is not usable refuses → an UNVERIFIED registered domain refuses the send* — 7/8 |
| 3 | `no row` always answers the deployment credential (`if true do`) | *no registered domain… → a from-domain nobody registered is refused, with no fallback* + the different-domain and account-B tests — 5/8 |
| 4 | revoked clause made unmatchable | *a row that is not usable refuses → a REVOKED domain refuses the send* — 7/8 |

Mutation 3 going red on three tests is the point: "no fallback" is one
condition and the cross-domain and cross-account refusals are the same
condition.

## The DNS records required, and why they prove control

`Courier.TenantSendingDomains.verify/2` requires all three, looked up against
the domain's `cf-bounce` prefix using `Courier.SendingDomains.Dns`:

| record | required shape |
| ------ | -------------- |
| MX `cf-bounce.<domain>` | the exact set `route1.mx.cloudflare.net`, `route2.mx.cloudflare.net`, `route3.mx.cloudflare.net` (preference ignored; a subset is refused) |
| TXT `cf-bounce.<domain>` | contains `include:_spf.mail.cloudflare.net` |
| TXT `cf-bounce._domainkey.<domain>` | contains `v=DKIM1` **and** `p=` |

The MX trio is Cloudflare's **inbound route** footprint — the domain's mail is
pointed at Cloudflare's route servers. The SPF `include` is Cloudflare's
**outbound** authorisation — it names the infrastructure that is allowed to
send as the domain. The DKIM record is the public half of the key Cloudflare
**signs** outbound mail with. Publishing those three under the `cf-bounce`
selector requires write access to the domain's zone, which is the control being
proven; a domain hosted elsewhere has none of them and a domain on Cloudflare
DNS but not onboarded lacks the exact triplet. They prove control *of the DNS
zone and of Cloudflare's onboarding* rather than mere residency.

The records alone can in principle be copied by somebody who can read them, so
the proof is **DNS plus the credential**: with the tenant's token and provider
account id, `verify/2` sends one real message from the domain under proof and
requires the provider to accept it. A token that can send from the domain is a
token scoped to it; a domain the provider refuses is a domain not onboarded.
The DNS check runs **first**, so a domain that is not on Cloudflare costs no
provider request, and a resolver `{:error, _}` is `{:dns_lookup_failed, _}` — a
verification that could pass on a broken resolver proves nothing.

## How the from-address reaches the credential lookup

`Courier.Mailers` builds the message from `config :courier, :mailing, :from`
(the `MAIL_FROM` / `MAIL_FROM_NAME` machinery in `config/runtime.exs`).
`Courier.Deliver.fetch_sender/1` takes the domain part of the built message's
`from`, lowercased, and asks `Courier.TenantSendingDomains.for_domain/1` for it.
Then:

* **verified and enabled row** → `adapter_config/1` opens the sealed credential
  and `Deliver` passes `[adapter: Courier.Adapters.CloudflareEmail, api_key:
  tenant_token, account_id: …, base_url: …]` as the per-call config to
  `Mailer.deliver/2`, which `Swoosh.Mailer.parse_config/4` merges over the
  deployment configuration for that one send and persists nowhere.
* **row exists but is unverified or revoked** → refused (`{:unverified_sending_domain, domain}`
  / `{:revoked_sending_domain, domain}`). No mail, no outbox row.
* **no row, and the from-domain is not the deployment's own** → refused
  (`{:no_sending_domain, domain}`). **No fallback to the deployment credential.**
* **no row, and the from-domain IS the deployment's own** →
  `Mailer.deliver/1`, the deployment adapter and credential, **exactly as
  before this table existed**. Every send courier makes today is from
  `cafaye.com`, so every existing send takes this branch and the global path is
  unchanged.

`for_domain/1` has no `account_id` predicate: the account scoping is the
table's row-level security (`cafaye.protect_table/3`), so another account's
domain is invisible and the send path's answer for it is the same `nil` as
"never registered" → refused. Account B cannot use account A's domain, and
cannot learn that A registered it.

The deployment's own domain is `Courier.Mailers.deployment_domain/0`
(`config :courier, :mailing, :deployment_domain`, kept in step with `MAIL_FROM`
by `config/runtime.exs`). **This is an addition the brief did not ask for**,
and the reasoning is in "the brief vs the repo" below.

## What I deliberately left alone, and why

* **No HTTP endpoint, no controller, no UI.** The registration/verification
  API is a separate packet, as the brief says. The context is public and ready
  for it.
* **`Courier.MailerAdapter`'s boot gate, and the smtp/postmark rows.** The
  deployment adapter is untouched; it is still the fallback for the
  deployment's own mail.
* **The row-level security substrate.** `protect_table('tenant_sending_domains',
  'courier_app')` is called verbatim, the same call the three existing protected
  tables make, and the test reads `relrowsecurity`/`relforcerowsecurity` and the
  four policy names out of the catalog. The table's primary key is a `:binary_id`
  (not `bigserial`) precisely so the known kit sequence-grant defect at this
  `kit.ref` (`protect_table` grants DML and no sequence privilege) does not apply.
* **A dependency.** None added. The DNS resolver is `:inet_res`; the provider
  post reuses the shipped `Courier.Adapters.CloudflareEmail`.
* **The credential.** `tenant_sending_domains.credential` holds `SecretBox`
  ciphertext; there is deliberately no `token/1`/`credential/1` read function.
  The test reads the column as raw SQL and asserts the plaintext is neither
  equal to nor contained in it.

## The brief vs the repo — the one place they disagree, loudly

**The brief contradicts itself about the fallback, and I followed the repo.**

* §3 and the test list say *"refuse the send when no verified domain provides
  that from-address … no fallback, no deployment credential used"* and *"no
  registered domain for the from-address refuses the send."*
* "What NOT to do" says *"the deployment credential stays as the fallback it is
  today for mail that has no registered domain."*

Read literally together they are unsatisfiable: every message courier sends
today is from `cafaye.com`, which is nobody's registered domain, so "refuse
when no verified domain provides the from-address" would refuse courier's own
password resets and turn the whole existing suite red. The repo wins: the
deployment's **own** from-domain keeps the deployment credential (unchanged
behaviour, and `deliver_test.exs`/`deliver_adapter_test.exs` stay green), and
**every other** from-domain with no verified row is refused. That is the
reading under which "no fallback" is still true where it matters — a tenant's
or an unclaimed domain never silently rides the deployment key.

The `:deployment_domain` config key exists because of the same gap: "the
deployment's own domain" cannot be inferred from the message's from-address in
a hosted, multi-sender courier, or the two are equal by construction and the
"no row → refuse" branch is unreachable. Making it explicit is what lets the
send path tell "courier's own mail" from "a from-address nobody registered".

## What remains — for the successor

1. **`tenancy.yml` is now stale.** It says "five tables are RLS-forced"; there
   are six. Per this repo's own precedent (the app-role packet's note that
   `tenancy.yml` needs a reader), I did **not** edit it: its header records that
   a populated `rls.tables` produces `tenancy.rls-policy-absent` from the
   scanner, and guessing at the checker is worse than reporting. Whoever owns
   `tenancy_check.py` must re-measure.
2. **`Courier.SendingDomains.Dns.System` (`:inet_res`) has no test.** The seam
   is tested from the courier side (the double answers from a table); the
   shipped resolver is not driven against a real resolver. The repo's rule is
   "a seam is tested from both sides", and this is one side. The parsing of the
   `#dns_rr{}` record is the untested half.
3. **The verification recipient is a hard-coded platform address**
   (`sending-domain-verification@cafaye.com`). A real deployment wants that
   configurable; it is a constant for now and the send proves provider
   acceptance, not inbox receipt.
4. **The registration API.** Not built, by instruction. `register/2`,
   `verify/2`, `revoke/1`, `list/1`, `get/2` are the surface it will wrap; the
   account comes from the principal and never from a request.
5. **`openapi.yaml` is untouched** (no route added, so the router/document
   test is unaffected) — but the API packet will need the domain operations in
   it.

## False starts worth not repeating

* `@primary_key {:id, :binary_id, autogenerate: true}` as a *migration* module
  attribute did **not** give the table a uuid primary key; the repo's own
  convention is `create table(:x, primary_key: false) do add :id, :binary_id,
  primary_key: true` (see `20261006120000_create_notifications.exs`). The first
  run produced a `bigserial` id and every insert failed `DBConnection.EncodeError`.
* `mix ecto.drop` printed "already been dropped" while a connection was live and
  the database survived; `dropdb --force` is what actually reset the test DB.
* The test DNS double's key is `{type, name}` — a 3-tuple `{type, name, records}`
  inserts silently and every lookup answers `:nxdomain`.
