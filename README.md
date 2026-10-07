# courier

cafaye **courier** — transactional email, notification preferences, and every
outbound webhook. Phoenix 1.8 API-only service, Elixir 1.20 / OTP 29, Postgres.

This repository is the v0 scaffold. It is a working, deployable service with
probes, a release image, and a local stack — and deliberately no notification
logic yet.

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

- **The floors are decrease detectors, not targets.** 1458 tests, 651 of them
  without a database, 807 with it, and 62 in the SSRF table. Delete one and CI
  goes red. Add one and CI goes red until the floor is raised, which is the
  intended direction.
- **The `ci` job is expected to be red today**, on `test` (kit runs a bare
  `mix test`, which is `ecto.create` first, in a job with no database) and on
  `coverage` (kit runs `mix coveralls --minimum-coverage N`; the task is in
  `excoveralls`, the flag does not exist, and the command needs an explicit
  `MIX_ENV=test`). Both are in kit's file. The floor is enforced in `gate`, where
  it can be. Delete the `ci` job when kit's Elixir job grows a `services`/`env`
  seam — and not before.

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
this file is regenerated by `caf init` rather than hand-maintained once core
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
COURIER_MAIL_ADAPTER=smtp | postmark

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
```

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
COURIER_INBOUND_RESEND_SECRET=whsec_…    # required in prod; the provider's own secret
```

That secret is the one courier **verifies** with, copied from the provider's
dashboard (Resend: the webhook endpoint's Signing Secret). It is not the secret
courier signs outbound deliveries with — those are generated per endpoint,
sealed under `COURIER_SECRET_BOX_KEY` and stored in the database, and conflating
the two would mean a deployment that leaked a customer's outbound secret could
also forge inbound suppressions.

**Unset is a refusal to boot in production.** Every hard bounce and every
complaint would be *discarded*, silently enough that `email_suppressions` stays
empty, `POST /v1/messages` goes on mailing addresses that have permanently
refused, and a sending domain's reputation dies of a cause no dashboard names.
That is the failure `Courier.Suppressions` was written to prevent, arriving
through the door meant to prevent it.

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
