# courier

cafaye **courier** — transactional email, notification preferences, and every
outbound webhook. Phoenix 1.8 API-only service, Elixir 1.20 / OTP 29, Postgres.

This repository is a working, deployable service with probes, a release image,
backups with a drill, and a local stack — and its mail path is real, not
scaffolded. What exists today, one line per part:

- **Transactional mail, composed and sent.** Six message types in
  `Courier.Mailers` — welcome, password reset, team invitation, account
  security, and the two halves of an email change — delivered through
  `Courier.Mailer` (Swoosh). Build and deliver are separate on purpose, so a
  message can be read field by field with no adapter and no network.
- **A provider adapter that refuses to guess.** `COURIER_MAIL_ADAPTER` selects
  `smtp`, `postmark`, or `cloudflare`, read at boot; an unset or undeliverable
  adapter stops the boot rather than rendering mail into memory and reporting
  success. See "Sending mail" below.
- **The loop closed.** Providers report back: `POST /inbound/resend` takes
  signature-verified bounces and complaints into `email_suppressions`, and the
  one-click unsubscribe endpoint (RFC 8058) is its own surface with its own
  token. Both become events on the bus in the same transaction as the row.
- **The preferences and notifications surfaces are served.** Per-tenant
  `notification_preferences`, the in-app notification store, and the outbound
  webhook endpoints, all under one account boundary enforced by tenancy.

What does not exist yet is a **queue**: the send path is synchronous, so
`courier.email.queued` has no builder — that type exists to make a backlog
visible, and courier has no backlog to make visible. The "Not here yet"
section at the foot of this README keeps the rest of that list current; the
manifest's comments list what the contract still cannot resolve. Everything
else — the database boundary, the backups, the probes, the OpenAPI document —
is described below as it is, not as it was planned.

## The gate

```sh
mise install       # Elixir 1.20.4 / OTP 29.1.1, pinned in mise.toml
mise run prime     # hex, deps, database, tests
```

`bin/prime` is `mix local.hex --force && mix deps.get && mix ecto.setup && mix
test`. It needs a Postgres at `localhost:5432` as `postgres`/`postgres` —
`bin/gate-db` if you do not have one. It does **not** use the shared cluster:
kit publishes that on `${KIT_POSTGRES_PORT:-15500}` under the cluster's own
credentials, and the gate must not run against a database the dev loop mutates.

**TWO CREDENTIALS, and the suite runs as the weaker one.** `mix ecto.create` and
`mix ecto.migrate` connect as the owner (`postgres` here, because a local
postgres and CI's `services: postgres` have exactly one role and creating a
database is the one job a `NOSUPERUSER` owner cannot do). The suite itself
connects as **`courier_app`** — the app login role, which owns nothing and is a
subject of every row-level-security policy in
`priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs`. It is
not in `:ecto_repos`, not in the supervision tree, and reachable only from
`mix.exs`'s aliases and `Courier.Release`, so no running process holds a
connection that bypasses courier's account boundary. On a cluster kit
provisioned, set `COURIER_DB_OWNER_USER=courier` — that is the owner role
`10-cluster.sh` creates. See `Courier.OwnerRepo`.

Before committing a change, `mix precommit`: warnings-as-errors, unused deps
dropped from the lockfile, formatted, suite green.

## Backups

```sh
kamal accessory boot backup
kamal accessory exec --reuse backup kamal-backup backup --force
bin/drill --table notification_preferences --table webhook_endpoints
```

`config/kamal-backup.yml` says what is backed up and
`config/deploy.yml` carries the `backup` accessory that reads it. The two are one
contract: every secret the first names must be in the second's `env.secret`
list, and `test/courier/backup_config_test.exs` fails if the mount or the
overlap is ever broken. The full procedure — and the drill, which is the step
that proves the rest — is in
[kit's backup and restore runbook](https://github.com/cafaye/docs/blob/master/src/content/docs/runbooks/backup-and-restore.md).

**What is in the backup: one Postgres database, dumped with `pg_dump`, written
to restic in a Cloudflare R2 bucket you choose.** courier owns exactly one
database and every one of its tables is content, so the backup is the whole of
courier's durable state:

| Table | What losing it costs |
| --- | --- |
| `notification_preferences` | every tenant's answer about every notification type — the first thing a customer notices |
| `notification_events` | one thing that happened, for an account. Every in-app notification points at one, so a restore carrying `notifications` without this brings back inboxes whose messages say nothing |
| `notifications` | who was told what, and **when they read it and when they saw it**. The only place courier can answer "what was I told about, and which of those have I read?", and an inbox restored with its read state lost shows every notification as unread |
| `webhook_endpoints` | every account's URL **and its signing secret** |
| `webhook_deliveries` | the attempt log, including where each endpoint is in its retry budget |
| `outbox_events` | the CloudEvents envelopes courier published, and the relay's own claim query |
| `email_suppressions` | the suppression list — the mailboxes that said no |
| `idempotency_keys` | stored responses, so a replayed `POST` returns the first answer instead of mailing twice |
| `oban_jobs` | the relay's queue |

### What it does NOT cover

Stating this is the part that matters, because a backup that is believed to cover
more than it does is worse than none.

- **Object storage, and anything held in it.** There is none today — courier has
  no bucket, no attachment table and no `bytea` column for uploaded content —
  which is also why `config/kamal-backup.yml` declares **no `paths:` key** and no
  file snapshot is ever taken (`latest_file_backup: null` in `evidence` is the
  correct answer, not a gap). `test/courier/backup_tables_test.exs` reads
  `information_schema` on every run and fails if a column appears that holds file
  bytes or points at bytes held elsewhere, because the day that happens the
  missing `paths:` becomes a real hole and this paragraph becomes a lie.
- **Anything in a container's ephemeral filesystem.** Deliberately nothing: the
  release writes nothing to a volume and holds no data volume, so there is
  nothing there to lose.
- **Postgres roles and tablespaces.** The dump is one database with no ownership,
  so the role comes from how the `postgres` accessory was provisioned. Restoring
  into a differently-named role means that role has to exist first.
- **The sealing key, and this is the one that matters most.** A restic repository
  is encrypted with `RESTIC_PASSWORD` and nothing else, so **losing that makes
  every snapshot permanently unreadable** — including the ones you have not lost
  yet. It is a different value from any credential courier uses and it is the one
  worth writing down twice, somewhere other than the bucket.

  courier additionally seals every `webhook_endpoints.secret` under
  `COURIER_SECRET_BOX_KEY` with AES-256-GCM
  (`Courier.SecretBox`), and that key **cannot** be in the backup: it is not in
  the database — `config/runtime.exs` refuses to boot without it — so it cannot
  be in a dump of the database. **So a restore brings every signing secret back as
  ciphertext, and courier cannot read its own rows until that key is supplied
  unchanged.** The rows come back; the ability to sign with them does not. Keep
  `COURIER_SECRET_BOX_KEY` and `RESTIC_PASSWORD` outside the restic repository —
  [secret rotation](https://github.com/cafaye/docs/blob/master/src/content/docs/runbooks/secret-rotation.md)
  is where they belong. Losing `COURIER_SECRET_BOX_KEY` means every stored secret
  has to be re-issued to its customer, because the plaintext cannot be recovered
  from the ciphertext.

### The data-loss window, stated honestly

**A scheduled dump is not point-in-time recovery.** With the shipped
`backup.schedule: 1d`:

- **Up to 24 hours of committed transactions are lost** if the database is
  destroyed. That is the number to quote to a customer.
- The 24 hours is measured **from when the previous backup finished**, not to a
  wall-clock deadline. The scheduler's loop is *run a backup, then sleep the
  interval*, so one cycle is the interval **plus that run's duration** — and
  because `pg_dump` opens a single repeatable-read transaction, the snapshot is
  taken at the **start** of the dump. The gap between two snapshot points is that
  whole cycle and is never exactly 24 hours.
- **A failed backup is not retried until the next interval.** The loop catches
  the failure, logs it, and sleeps. A dump failing for six hours has not been
  retried six times. Run `kamal-backup backup` by hand and it retries
  immediately — which is why **the alert is the backup**: if you are not watching
  the accessory's log, a nightly failure is invisible for a day.
- There is **no WAL shipping and no base backup**. If 24 hours is unacceptable for
  your tenants, the next step is Postgres's own continuous archiving, which is an
  infrastructure decision rather than a config one — and `kamal-backup` will not
  do it for you.
- Retention bounds how far back a restore reaches: roughly 26 snapshots, the
  oldest about a year, the newest up to a day old. **R2 has no object versioning
  and no Object Lock**, so a snapshot `prune` deletes is gone.

### Adopting it

Nothing runs until the accessory is booted and the four secrets exist. The
deploy config is committed; the values are not — `.kamal/secrets` is
git-ignored and holds `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, plus `DATABASE_URL` and
`DATABASE_PASSWORD`. `RESTIC_REPOSITORY` is
`s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/courier-db-backups` and
`init_if_missing: true` creates the *repository inside* the bucket, not the
bucket: **the R2 bucket has to exist before the first backup**, and the failure
mode of forgetting is a service that believes it is protected for as long as
nobody needs it.

## CI

`.github/workflows/ci.yml` calls `cafaye/kit`'s reusable workflow for the shared
half and adds the two jobs kit cannot own:

| Job       | What it is                                                                                                    | Why it is not in kit's workflow                                                                   |
| --------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `ci`      | `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master`, `language: elixir`, toolchain pinned from `mise.toml` | — that is kit's job, and it is the only copy                                                                 |
| `gate`    | `bin/prime` against a `postgres:17-alpine` service, each test tier named and counted, a `git diff --exit-code` guard on `mix.lock`, and a coverage floor | A caller cannot pass `services:` to a reusable workflow, and the floors are courier's numbers |
| `release` | `mix release` on the pinned toolchain, and the boot contract for `COURIER_SECRET_BOX_KEY`                          | kit builds no image, and only courier knows its release needs a key it must refuse to default        |

Two things a reader should know before trusting a green run:

- **The floors are decrease detectors, not targets.** 1593 tests, 715 of them
  without a database, 878 with it, and 62 in the SSRF table. Delete one and CI
  goes red. Add one and CI goes red until the floor is raised, which is the
  intended direction.
- **The `ci` job is expected to be red today**, on `test` (kit runs a bare
  `mix test`, which is `ecto.create` first, in a job with no database) and on
  `coverage` (kit runs `mix coveralls --minimum-coverage N`; the task is in
  `excoveralls`, the flag does not exist, and the command needs an explicit
  `MIX_ENV=test`). Both are in kit's file. The floor is enforced in `gate`, where
  it can be. Delete the `ci` job when kit's Elixir job grows a `services`/`env`
  seam — and not before.

## Publishing

A push to `master` publishes two artifacts, both through kit's reusable
workflows and one caller, `.github/workflows/publish.yml` — kit's caller
template (`kit/templates/publish/publish.yml`), copied verbatim:

- **the image** at `ghcr.io/cafaye/courier:sha-<full 40 chars>` (plus
  `<branch>`, plus `latest` on the default branch) — what `config/deploy.yml`
  deploys;
- **the chart** at `oci://ghcr.io/cafaye/charts/courier:<chart version>` — what
  the substrate's Argo `Application` pulls.

The caller grants `packages: write` — a reusable workflow can request a
permission but cannot grant itself one, and omitting it is a 401 at the push
that reads like a wrong password — and passes `push: true`: the reusable
workflows default to `push: false`, so a caller that omits the input publishes
nothing and says nothing. The composition lives in kit; the caller is one
`uses:` of `cafaye/kit/.github/workflows/publish.reusable.yml@master`, and a
caller that inlines the steps has forked it.

**The chart's `version` is the tag.** `chart/Chart.yaml`'s `version` is the
OCI tag the workflow pushes, and it must equal the `targetRevision` the
substrate's `Application` pins (`0.1.0` today): a service that bumps one and
not the other is a service that never deploys, and Argo reports no error — it
just never finds the artifact. The equality is asserted in
`test/courier/chart_test.exs`, red-first, with both sides named in the failure
message.

## Probes

| Endpoint  | Meaning   | 200                                    | 503                                            |
| --------- | --------- | -------------------------------------- | ---------------------------------------------- |
| `/healthz` | liveness  | `{"status":"ok"}`                      | never — it does not touch the database         |
| `/readyz`  | readiness | `{"status":"ok"}`                      | `{"status":"error","checks":{"database":"unavailable"}}` |

Liveness answers whenever the VM can dispatch, so a database outage never
restarts the container. Readiness answers 503 while courier cannot do work, so a
deploy holds traffic back instead of serving errors. The reason a readiness
check failed is logged, never returned — probe responses are public.

With a database that has gone away underneath a running pool, `/readyz` takes
about 4.4s to answer 503 (the pool's queue backpressure, not the query timeout).
An orchestrator with a shorter probe timeout will time out and read courier as
not ready, which is the same verdict. `Courier.Health` documents why the probe
cannot shorten it.

Both sit at the root, outside `/api`, and both are exempt from the production
SSL redirect in `config/prod.exs`: an orchestrator that gets a `301` to https
from `/healthz` reads courier as dead. `test/courier_web/router_test.exs` pins
that exclusion.

## Running it

```sh
mix phx.server                      # http://localhost:4000, dev config
bin/dev                              # kit's shared cluster (kit-postgres:17) + the release image
curl localhost:4000/healthz
bin/dev down                         # stop the stack; every volume is kept
```

The compose stack runs the same release the platform will run. Its postgres is
**kit's shared cluster**, not a courier-owned container: `bin/dev` merges the
pinned kit stack with this repository's `docker-compose.yml`, and the cluster
carries one database and **two roles** per service — `courier`, the owner, and
`courier_app`, the login the application uses. Both are `LOGIN NOSUPERUSER`; the
owner is refused at the door of every other service's database, and `courier_app`
owns nothing, so the RLS policies apply to it rather than being exempt.

`DATABASE_URL` in `docker-compose.yml` names **`courier_app`**, and
`COURIER_OWNER_DATABASE_URL` names the owner for `bin/migrate`. The split is two
variables rather than one flag because one variable cannot be two credentials,
and the release reads `DATABASE_URL` to start the application.

Migrations are **not** part of `compose up`. The cluster creates an empty
`courier` database and nothing else, so a fresh volume needs the release's own
migration path run once against it — `rel/overlays/bin/migrate`, which is
`Courier.Release.migrate/0`. `bin/dev` calls `bin/ecto.setup` for this, and note
that it resolves to `mix ecto.create && mix ecto.migrate` on the **host**, which
reads `config/dev.exs` (`postgres/postgres@localhost:5432/courier_dev`) and not
the cluster; against the shared cluster, run the release's `bin/migrate` inside
the container instead. `docker-entrypoint-initdb.d` runs **once per volume**, so
adding a database to `KIT_POSTGRES_DATABASES` after the first boot does nothing
to an existing cluster — `bin/dev db grant` prints the statements instead.

## Who is calling

Every operation under `/v1` is behind `CourierWeb.Plugs.Principal`, and outside
test that plug resolves the caller through `Courier.Principal.Introspection`:
courier reads the caller's token from `Authorization: Bearer` and asks identity
`POST /v1/introspections` what it may do and for which account.

The token is **opaque**. It is `cafaye_` plus random bytes and identity's row
holds a SHA-256 of it, so there is no claim document inside it and no published
key set to verify one against — asking identity is the only way to learn an
`account_id`. That makes authentication a network hop on every `/v1` request, and
the price is stated rather than assumed: **courier's latency now includes
identity's, and identity's outage is courier's outage.** Both surface as a `503`
`unavailable`, which is the retryable status.

| environment variable | required | what it is |
| --- | --- | --- |
| `COURIER_IDENTITY_TOKEN` | **in prod** | courier's own scoped API token, presented as the `Authorization` header on the introspection call. A credential: mint one with `POST /v1/accounts/{account_id}/api-keys` in an account that belongs to courier and nothing else, and rotate by minting a new one, redeploying, and revoking the old. **It must be the same key identity presents as its own `COURIER_TOKEN`** — identity lets a token caller introspect only itself, so two distinct keys produce identity's `403` and courier's `503`, and the symptom looks like a network fault. |
| `COURIER_IDENTITY_URL` | no | identity's base URL. Defaults to `http://identity:8080` — the compose-network name and identity's own port. A wrong URL is a loud `503`, not a crash. |

Four things about the boundary, each one tested:

  * **`account_id` and never `sub`.** `sub` is the user a token names;
    `account_id` is the tenancy boundary. An active document with no
    `account_id` is refused, and the account is read with `Map.fetch/2` so a
    fallback is not expressible in the function that decides it.
  * **One answer for every unusable token.** Unknown, revoked, expired and
    orphaned are all `200 {"active": false}` upstream; courier does not
    re-expand them, so no status distinguishes them.
  * **Both scope claim names are read.** `scopes` and `scope` are emitted
    byte for byte because the fleet has not agreed on one (MD7, open), so
    courier reads the union and assumes neither is the only one. A claim that
    is not a **string** is refused rather than read as an empty set.
  * **Scopes are parsed and deliberately NOT enforced.** identity's vocabulary
    is six names and none of them is one of the five `openapi.yaml` declares,
    so a check written today would refuse every credential identity can mint.
    Tenancy is what courier enforces. The decision is recorded in
    `Courier.Principal`'s moduledoc and in `openapi.yaml`'s `bearerAuth`.

**`Courier.Principal.Reject` is still the fallback** for a deployment whose
configuration names no resolver, and it is still correct for that case: it
answers 401 to everything. The plug's 401 is unchanged — `type`, `code`, `status`,
`title`, `detail` and `instance` are identical through either resolver, and a
test asserts it rather than promising it.

**No answer is never "allow".** identity unreachable, slow, erroring, answering
401 or 403, or answering in a shape courier cannot read is a **503**. A
resolver that fails open under load is worse than the locked door courier shipped
for a year, because it fails silently.

## Layout

```
lib/courier/health.ex                          readiness check, never raises
lib/courier/principal.ex                       the caller, the resolver behaviour
lib/courier/principal/introspection.ex         who is calling, via identity
lib/courier/principal/introspection/document.ex  its answer, read in three answers
lib/courier_web/plugs/principal.ex             401, or 503 when nobody can ask
lib/courier_web/router.ex                      probes at the root, /api reserved
test/courier/…                                  readiness check, the door, unit
test/courier_web/…                              probes incl. the DB-down path, routes
.github/workflows/ci.yml                        calls kit, plus gate and release
bin/prime                                       the gate: deps, database, tests
bin/assert-suite                                refuses a run that skipped the hard part
bin/toolchain-pins                              the one toolchain pin, read from mise.toml
Dockerfile                                      two-stage release build, slim final
docker-compose.yml                              an OVERRIDE on kit's stack: courier's
                                               service, its database and role on
                                               the shared cluster, the crash layer
cafaye.yml                                      the manifest (draft, see below)
```

## The manifest

`cafaye.yml` declares courier to the rest of the platform. It validates against
`cafaye/core`'s `schemas/cafaye.manifest.schema.json`; core owns that format, so
this file is regenerated by `cafe init` rather than hand-maintained once core
freezes the version. The events courier publishes and the OpenAPI document for
its API both exist now — `exposes.api` is `openapi.yaml`, which describes every
route the router serves except `/healthz` and `/readyz`, and a test holds the
two to each other. The identity/billing events courier will consume are still
unresolved and are listed as such in the manifest's comments, as is the fact
that the two `notification_preferences` operations are served without
authentication.

## The OpenAPI document

`openapi.yaml` is courier's contract, and `PLAN.md` MD6 has the platform
generating client SDKs from these documents — so what is missing from it is a
method a generated client will not have.

`test/courier_web/openapi_document_test.exs` reads the document *and*
`CourierWeb.Router.__routes__/0` and fails in **both** directions: an operation
the router does not serve, and a route the document does not describe. It
compares paths rather than counts, because a count passes on a rename and fails
on an addition. The two probes are the only omission and they are declared in
the document's header and in the test's exclusion list, with the reason.

A route added to `lib/courier_web/router.ex` is not finished until it is in
`openapi.yaml`, and an operation added to `openapi.yaml` is not finished until
the router serves it.

## Sending mail

courier delivers transactional email through more than one provider. The
provider is a deployment decision, read from the environment at boot, and
courier **refuses to start** without one:

```sh
COURIER_MAIL_ADAPTER=smtp | postmark | cloudflare

# SMTP — the universal one; every serious provider speaks it or has an SMTP front
COURIER_SMTP_HOST=smtp.your-provider.com
COURIER_SMTP_USERNAME=...          # required unless COURIER_SMTP_AUTH=never
COURIER_SMTP_PASSWORD=...
COURIER_SMTP_PORT=587              # the default
COURIER_SMTP_AUTH=always           # always | never | if_available
COURIER_SMTP_TLS=always            # always | never | if_available
COURIER_SMTP_SSL=false             # true for implicit TLS, usually on 465

# Postmark — transactional-only, API-token auth
COURIER_POSTMARK_API_TOKEN=...     # required when the adapter is postmark

# Cloudflare Email — sends through the MailChannels transactional API
COURIER_CLOUDFLARE_API_KEY=...     # required when the adapter is cloudflare
```

**For a box, Cloudflare is the recommended default** — and the choice is a
practical one rather than a preference. The credential (`COURIER_CLOUDFLARE_
API_KEY`) is a **scoped API token from the same Cloudflare dashboard that owns
the DNS**, so an operator who can point the domain at Cloudflare already holds
the place it comes from; the domain authorization (`_mailchannels` TXT for
Domain Lockdown and `include:relay.mailchannels.net` in SPF) is the same
Cloudflare Email Sending onboarding the DNS half already needs; and the provider
answers **synchronously** (`delivered` / `queued` / `permanent_bounces` /
`suppressed_recipients`), so the suppression list lives on the account rather
than behind a webhook. `smtp` and `postmark` remain documented alternatives —
smtp because every provider speaks it, postmark because it is a transactional
service with a single API token — and the adapter stays a one-variable choice.

Cloudflare Email Routing itself is receive-only and has no send API. The
sending half of a Cloudflare Email connection is the MailChannels
transactional API, so that is the contract this adapter speaks:
`POST https://api.mailchannels.net/tx/v1/send`, `X-Api-Key`, a
`personalizations` / `from` / `subject` / `content` body.

Setting it up is two steps, and only the second one is courier's. Authorize
the sending domain once — the `_mailchannels` TXT record for Domain Lockdown
and `include:relay.mailchannels.net` in SPF, which
`cf email-sending subdomains preview` reports on before anything is written
and the Cloudflare Email Sending dashboard adds for you — then hand courier
the MailChannels key that the authorization issued:
`COURIER_CLOUDFLARE_API_KEY`. On a box installed from the substrate template
that key arrives as `KIT_SUBSTRATE_CLOUDFLARE_API_KEY` (see
`kit/templates/substrate/install.sh`), which refuses before writing anything
when the adapter is `cloudflare` and the key is absent, so a box never comes
up half-configured. There is deliberately no verification screen and no
in-app dashboard step: the two signals an operator needs are the installer's
preflight refusal and courier's own boot line (`adapter=cloudflare
token=set`).

**A provider that refuses a send is reported, never swallowed.** Every non-2xx
is an error naming the status and the provider's own body, a transport failure
is an error, and **a 202 carrying a per-message `status: "failed"` is an error
too** — the request was accepted and the message was not, which is the one
shape a status-code check alone would miss.

`COURIER_MAIL_ADAPTER=none` renders mail into memory and opens no socket. It is
refused in production: a courier that reports a message id for mail it never sent
is the worst failure a paid product can have, because it looks like it works.

Credentials are read from the environment in every environment, are never
written to a committed config file, and never appear in a log line — including
the startup line, which names the host and port (or, for Postmark, whether its
token is set) and deliberately omits the username as well as the password,
because at SMTP a username is usually an API key.

## Hearing back from the provider

A submission protocol's whole reply is "accepted for delivery", so courier never
learns what happened to a message. The provider reports back by webhook, and
`POST /inbound/resend` is the surface that takes those reports:

```sh
COURIER_INBOUND_RESEND_SECRET=whsec_…    # provider's own secret, optional; see below
```

That secret is the one courier **verifies** with, copied from the provider's
dashboard (Resend: the webhook endpoint's Signing Secret). It is not the secret
courier signs outbound deliveries with — those are generated per endpoint,
sealed under `COURIER_SECRET_BOX_KEY` and stored in the database, and conflating
the two would mean a deployment that leaked a customer's outbound secret could
also forge inbound suppressions.

**Unset is a supported state, not a boot error** — cf-inbound-optional. With no
provider configured courier boots, sends mail, and logs

```
inbound: no provider configured — a hard bounce or a spam complaint is discarded and courier goes on mailing an address that has said it is gone; set COURIER_INBOUND_RESEND_SECRET to enable Resend inbound reports
```

Every hard bounce and every complaint is then *discarded*, silently enough that
`email_suppressions` stays empty, `POST /v1/messages` goes on mailing addresses
that have permanently refused, and a sending domain's reputation dies of a cause
no dashboard names. That is the failure `Courier.Suppressions` was written to
prevent, arriving through the door meant to prevent it — and that sentence now
lives on the boot line above so a deployment that loses bounce reporting is told.
A Cloudflare-only box has no webhook to configure: its send call answers with the
per-recipient verdict synchronously and the account keeps a suppression list, and
the adapter already surfaces a bounce-shaped 2xx as an error. Set the variable
and the surface is exactly today's behaviour; a request to it with nothing
configured is a 500 naming the variable, and no secret value ever appears in the
log.

Three things about the surface that are decisions rather than details, each
argued at length in the module that owns it:

- **It is authenticated by a signature, not a token, and it is outside `/v1`.** A
  provider is not a tenant: Resend signs with Svix and sends no bearer token, so
  a principal would `401` every delivery — and behind no plug at all it would be
  an unauthenticated `POST` that records suppressions, which is a denial of
  service on the whole product delivered by the feature meant to prevent it.
  `Courier.Inbound.Signature` verifies **before** the body is parsed, and the
  endpoint's `Plug.Parsers` is deliberately skipped for this route so the bytes
  that arrive are the bytes that were signed. It is the only operation in
  `openapi.yaml` that declares `webhookSignature` rather than `bearerAuth`.
- **A provider retry is a 200, and there is no `Idempotency-Key`.** Delivery is
  at-least-once, so a second delivery of the same report is normal; the
  deduplication is `email_suppressions`'s unique index on
  `(provider, provider_event_id)`, which the parser derives from the report's own
  **content** rather than from the `webhook-id` header — a stronger key, because
  one delivery can name many recipients and keying on the header would collapse a
  broadcast into one suppression.
- **No response on this operation carries an email address.** Not the counts, not
  a `422`'s `detail`. The suppression table has no `account_id` and is not
  exposed through any route, so an address in a response body is a way to query
  mailboxes courier holds. The address is in the logs, which is where the parser
  puts it.

Accepted reports publish `courier.email.bounced` and `courier.email.complained`,
in the same transaction as the suppression row, with the `user_id` and
`notification_type` **read back from the send that caused them** — a provider
report carries a `Message-ID` and a recipient, never a user, and an event with a
`null` user id is a payload core's own schema rejects on the bus. A report whose
`Message-ID` names no send courier made records its suppression and publishes no
event, with a log line: the row is the load-bearing half.

## Events on the bus

Every interesting thing courier does is also a row in `outbox_events`, written in
the same transaction as the thing itself: a `courier.email.delivered` for each
send, a `courier.email.bounced` or `courier.email.complained` for each provider
report courier records, a `courier.notification.suppressed` for each one-click
unsubscribe. That is the whole contract — the envelope is core's CloudEvents
shape, and the NATS subject is the event's `type`, with **no mapping table and
no prefix rewriting** (core's rule), so `courier.email.delivered` is published
on the subject `courier.email.delivered`.

Draining that table onto the bus is one variable:

```sh
NATS_URL=nats://nats:4222     # or tls://HOST:PORT; unset is a supported state
```

- **Unset is designed for, not tolerated.** No connection process starts, no
  loop runs, and the publisher courier configures
  (`Courier.NatsPublisher.Unconfigured`) refuses every envelope — so
  `published_at` stays nil and the rows accumulate. The one thing courier will
  not do is fall through to a stand-in that answers `:ok`: that would mark every
  event published and drain the outbox into nowhere, which is worse than a
  visible backlog because it looks identical to success.
- **A broker that is down is not a boot failure.** The connection process dials,
  records the failure, and retries on a fixed five-second interval; every
  publish while it is away answers `:not_connected` and every row stays
  claimable. A URL that does not parse **is** a boot refusal — a typo is a
  deployment that believes it has a bus and does not, and that belongs at boot
  where an operator reads it.
- **A row is marked published from the broker's ack, never from the bytes
  leaving the process.** The publish is a JetStream request-reply, so
  `published_at` is set only when the broker says it stored the message, and a
  refusal leaves the row claimable with the broker's own reason in `last_error`.
- **The stack must define a stream that covers the subjects.** A publish to a
  subject no stream claims is refused by the broker — which is the correct
  answer (loud, and the row stays claimable), and it is why kit's `cafaye` stream
  carries `identity.>,billing.>,courier.>,muse.>,darkroom.>`
  (`kit/templates/compose/docker-compose.yml:540`,
  `kit/templates/substrate/install.sh:1365`). Measured against a real broker
  with that stream, a real courier publish lands in it under
  `courier.email.delivered` with the envelope intact.

`NATS_URL` is not set in `docker-compose.yml`, so the local stack accumulates
events rather than publishing them until the variable is added to the courier
service's `environment:`.

## Unsubscribing

Gmail and Yahoo's bulk-sender requirements, in force since June 2024, are about
[RFC 8058](https://www.rfc-editor.org/rfc/rfc8058): a bulk message carries a
`List-Unsubscribe` header whose HTTPS URI a mail client `POST`s to on the
recipient's behalf, with no session and no confirmation page. A sender without one
lands in spam.

courier's gate for it is `Courier.Mailers.kinds/0` and `Courier.Unsubscribes`, and
there is **no new environment variable** — the URL is built from
`CourierWeb.Endpoint.url/0`, which `PHX_HOST` already turns into
`https://$PHX_HOST` in production. That matters, because §3.1 requires the header
to carry an **HTTPS** URI, and it is now the same setting that produces every
other URL courier generates. `test/courier/unsubscribes_test.exs` reads that
requirement out of production's own configuration rather than out of a comment.

**All three of courier's notification types are transactional, so nothing courier
sends today carries the header** — a password reset with an unsubscribe link is
its own defect. The kind table is where that decision lives, it is closed over the
types courier can send, and its default is `:transactional` so a new type nobody
classified cannot grow a link by omission. Adding courier's first bulk type is
**one row in that table plus one enum value in core's payload schemas**, not one
line here: every payload courier publishes carries `notification_type`, and
`core/schemas/events/courier/email/*.schema.json` freezes that field to the three
names courier sends.

The endpoint, `POST` and `GET /unsubscribe/{token}`, is outside `/v1` and behind no
authentication plug, which is not an oversight:

- **§3.1 forbids the request from carrying authorization at all** — "The POST
  request MUST NOT include cookies, HTTP authorization, or any other context
  information." A mail client holds no bearer token, so behind
  `CourierWeb.Plugs.Principal` every one-click unsubscribe in the world would be a
  `401`.
- **The token in the path is the whole of the authorization**: 32 bytes of
  `:crypto.strong_rand_bytes/1`, stored only as a SHA-256 and never as itself, so a
  database dump is not a list of mailboxes anybody can unsubscribe. A token courier
  did not issue is a **404** — it is a resource's address, not a refused
  credential.
- **It never redirects.** "The mail sender MUST NOT return an HTTPS redirect, since
  redirected POST actions have historically not worked reliably." The success is
  the answer.
- **A retry is the same 200**, and the deduplication is `email_suppressions`' own
  unique index on `(provider, provider_event_id)` with the token's id as the key —
  so a client that timed out gets the first answer back rather than an error.

What an unsubscribe records is a row in `email_suppressions` with
`provider: "unsubscribe"`, the address, the notification type, the user, and **no
`state`**. The absent state is the whole mechanism: a bounce and a complaint are
facts about the *mailbox* and refuse every type courier sends, and
`Courier.Deliver` consults that table for a password reset as firmly as for a
newsletter — so a stateful unsubscribe row would be a person who stops receiving
product updates and then cannot reset their password. A `nil` state is a case
`Courier.Suppressions.state/1` has always folded to "nothing" and never had a row
for. It publishes `courier.notification.suppressed` with
`reason: "preference_off"` in the same transaction.

**What it costs, stated rather than discovered:** the row is immutable, as every
row in that table is, and no route clears one — so a recipient who unsubscribes in
error has to be reached at another address. The alternative measured worse: the
preferences table records *which account* is entitled to a user's answers, an
unsubscribe has no principal, and writing the sending account there is a tenancy
claim made for a user id the caller chose. A route that clears an unsubscribe
belongs with the first bulk type, and deliberately does not arrive in the same
commit as the thing it would undo.

**What courier cannot do for you:** §4 requires a valid DKIM signature covering
both headers and listed in the `h=` tag, and §3.2 says a receiver that finds none
"SHOULD NOT offer a one-click unsubscribe for that message". courier submits
through SMTP to a relay and holds no private key for the sending domain, so the
signing is the relay's — the same place SPF, DMARC and everything else about the
domain lives. If the relay does not sign, the header is on the wire and the mail
client ignores it.

## Notification types (the catalog)

courier does not ship a fixed list of notification types. The catalog is a table
(`notification_types`) that courier creates and migrates on boot, and types are
added, changed and removed through the HTTP API — no Elixir, no restart, no
mounted files:

```sh
# List the types courier knows how to send.
curl -H "Authorization: Bearer $TOKEN" https://courier.example.com/v1/notification_types

# Register a new type. `required` names the fields its template needs;
# `subject` is a template with %{key} placeholders filled from the payload;
# `html_template` and `text_template` are EEx templates.
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \\
  https://courier.example.com/v1/notification_types -d '{
    "type": "welcome",
    "kind": "transactional",
    "required": ["email", "name"],
    "subject": "Welcome to caFaye, %{name}",
    "html_template": "<p>Hi <%= @greeting %></p><p><a href=\\"<%= @url %>\\">Confirm</a></p>",
    "text_template": "Hi <%= @greeting %>\\n\\nConfirm: <%= @url %>"
  }'

# Update a type's templates or subject.
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \\
  https://courier.example.com/v1/notification_types/welcome -d '{
    "subject": "Welcome, %{name}"
  }'

# Remove a type.
curl -X DELETE -H "Authorization: Bearer $TOKEN" \\
  https://courier.example.com/v1/notification_types/welcome
```

### What a template may reference

Every template is rendered with these assigns (use `<%= @name %>` in EEx):

- `greeting` — `"Hi,"` or `"Hi <name>,"` (the name is already escaped)
- `email` — the recipient's address, escaped
- `url` — an optional link
- `account_name`, `invited_by`, `role` — invitation facts
- `reason` — for `account_security` (`"password reset"` or `"email address changed"`)
- `previous_email` — the address a change is moving from
- `amount_display`, `invoice_id` — money facts (already rendered)
- `billing_url` — where a reader updates their payment method (or nil)

A template that references an assign that is not in this list renders empty
for it. A template that does not parse is rejected at create/update time
with a 422, so a broken template never reaches a send.

`required` names the fields `Courier.Mailers` validates before rendering:
`user_id`, `email`, `name`, `url`, `account_name`, `invited_by`, `role`,
`reason`, `previous_email`, `amount_display`, `invoice_id`. A type that
requires a field courier does not know about is rejected at create time.

### Defaults

On first boot (when the table is empty) courier seeds eight platform types:
`welcome`, `password_reset`, `team_invitation`, `account_security`,
`email_change_current`, `email_change_new`, `receipt`, `payment_failed`.
`loan_proposal` was removed from the defaults in this release; any deployment
that still needs it can register it through the API above. The full list of
defaults lives in `priv/notifiers/<type>/` in the source tree and is the source
for the seed.

### Subject templates

`subject` is a string with `%{key}` placeholders filled from the payload.
A placeholder naming a field the payload does not carry is a configuration
error (`:subject_misconfigured`), not a mail with a hole in it.

### Kinds

`transactional` (the default) or `bulk`. The kind decides whether the message
carries `List-Unsubscribe` and `List-Unsubscribe-Post` headers. All of
courier's defaults are `transactional`.

### Rendering

Templates are EEx, rendered at send time and wrapped in one shared layout per
format (text and HTML), so every email courier sends is wrapped alike. A change
to the wrapper is a change to one template.

## Not here yet

`courier.notification.suppressed` still has no caller for a **refused send**:
`{:error, :suppressed}` and `{:error, {:suppressed_address, _}}` out of
`Courier.Deliver` happen today and `POST /v1/messages` already answers them, but
`Courier.Deliver`'s moduledoc promises "no mail, no event, no record of a send
that did not happen" and that promise is `Courier.Events`' to argue with rather
than to override. (The one-click unsubscribe **does** publish the type, because a
person pressing the button is a standing answer that changed rather than a send
courier turned down.) `courier.email.queued` has no builder because courier has no
queue — the send path is synchronous and that type exists to make a *backlog*
visible.

Conventions live in [AGENTS.md](AGENTS.md).

## Licence

courier is under the **Business Source License 1.1** — the full text is
[LICENSE](LICENSE), and it replaced a closed "all rights reserved" grant that
allowed nothing beyond viewing (OPS-D2). Its parameters are Licensor Cafaye,
Licensed Work courier, Additional Use Grant None, Change Date 2030-10-10 and
Change License Apache-2.0.

Read the licence rather than this paragraph for what you may do. Its Terms
grant copying, modification, derivative works, redistribution and
**non-production** use; the Additional Use Grant is `None`, so production use
is not granted by this file and the licence says you must then buy a
commercial licence from Cafaye or refrain from using it. On the Change Date
each version keeps running under Apache-2.0. BSL is not an open-source
licence, and the licence's own Notice says that out loud.

The fleet's decision describes the intent as "free to run, free to self-host,
never to offer a competing service" (OPS-D2, `CAFAYE-OPS.md:176`). The
parameters chosen do not carry the first half of that sentence, and the
discrepancy is recorded rather than smoothed over in
`REPORT-ops-lic-services-a-courier.md`.

