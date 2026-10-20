# AGENTS.md

Conventions for `courier`, the cafaye notification service. Read this before
changing anything. The house rules in `moon/PLAN.md` §1 and §3 apply on top of
it: tests first, every packet ends in a green suite and a commit, never push
from a worker branch.

## What this repository is

`courier`, Elixir 1.20 / OTP 29, Phoenix 1.8, **API only**: no HTML, no
LiveView, no assets, no dashboard, no gettext. It owns transactional email,
notification preferences, and every outbound webhook. The contracts and the
manifest schema are owned by `cafaye/core`; `cafaye.yml` here is a draft
validated against `core/schemas/cafaye.manifest.schema.json` and is regenerated
by `cafe init` when core freezes the format. Nothing is copied from
`moon/refs/jumpstart-pro` — it is a behavioral spec for later packets, and
PLAN.md §2 forbids copying from it.

## Layout

```
lib/courier/health.ex                 readiness check: does the database answer
lib/courier/release.ex                migrations from inside a release, no Mix
lib/courier/mailer.ex                 the Swoosh mailer: the adapter is config
lib/courier/mailer_adapter.ex         the provider adapter, read from the
                                      environment, and the refusal that stops
                                      courier booting into a silent one
lib/courier/mailers.ex                compose the three transactional emails, and
                                      say which of them may be unsubscribed from
lib/courier/mailers/templates/        the bodies, compiled at build time
lib/courier/deliver.ex                the send: preference, provider, outbox row
lib/courier/events.ex                 the CloudEvents envelope and the catalog
lib/courier/outbox_event.ex           one emission, and the envelope it publishes
lib/courier/outbox.ex                 THE outbox WRITE: the row and the job that
                                      publishes it, in one transaction
lib/courier/notification_preference.ex         the row behind a user's answer
lib/courier/notification_preferences.ex       read and write those answers
lib/courier/notification_event.ex             something that happened, once
lib/courier/notification.ex                   that event addressed to one person,
                                            with when they saw it and read it
lib/courier/notifications.ex                  the in-app RECORD: record an event
                                            to N recipients, list one inbox,
                                            mark seen, mark read, count unread.
                                            Renders nothing and sends nothing
lib/courier/inbound.ex                the behaviour: verify, then parse, then
                                      ingest, in THAT order
lib/courier/inbound/signature.ex       the CONSUMER's half of the Standard Webhooks
                                      scheme: is this POST really the provider?
lib/courier/inbound/resend.ex         Resend's reports in courier's vocabulary
lib/courier/unsubscribes.ex          RFC 8058: the two headers, and the door they
                                      open
lib/courier/unsubscribe_token.ex      the one-click credential, stored as a digest
lib/courier/nats_publisher.ex         the behaviour the relay publishes through
lib/courier/nats_publisher/noop.ex    the stand-in that hands envelopes back
lib/courier/observability.ex          the span-attribute ALLOWLIST, and the one
                                      record/2 every span in courier goes through
lib/courier/span_collector.ex         the on-end processor, installed by hand
                                      because the SDK's own is silently dropped,
                                      and the export table the exporter reads
lib/courier/telemetry.ex              the contract, the resource, and the SDK
                                      wiring the application controller reads
lib/courier/principal.ex              the caller, the resolver behaviour, and the
                                      default that authenticates nobody
lib/courier/principal/introspection.ex the production resolver: identity's
                                      introspection endpoint, and the three
                                      answers courier turns it into
lib/courier/principal/introspection/document.ex  the answer, in three answers:
                                      a principal, "no", or "unreadable"
lib/courier/principal/introspection/transport.ex  the seam, and why it is one
lib/courier/principal/introspection/transport/req.ex  the one that dials
lib/courier/secret_box.ex             sealing: a signing secret at rest, AES-GCM
lib/courier/idempotency_key.ex        one (account, endpoint, key) claim, and its answer
lib/courier/idempotency.ex            claim a key, store the response, replay it
lib/courier/webhook_endpoint.ex       the row, its changesets, its status enum
lib/courier/webhook_endpoints.ex      the context: register, change, remove, trip
lib/courier/webhook_delivery.ex       one delivery, and its retry state
lib/courier/webhook_deliveries.ex     the retry budget's arithmetic
lib/courier/webhooks/signature.ex     the Standard Webhooks signature, exactly
lib/courier/webhooks/verifier.ex      the consumer's half: tolerance, HMAC check
lib/courier/webhooks/url_guard.ex     the SSRF guard: resolve, check, return target
lib/courier/webhooks/dns.ex           the resolver seam, and its :inet impl
lib/courier/webhooks/payload.ex       the bytes signed, and the ping body
lib/courier/webhooks/sender.ex        the delivery behaviour and its policy
lib/courier/webhooks/sender/req.ex    the Req implementation that ships
lib/courier/workers/process_outbox_worker.ex  the relay itself
lib/courier/workers/dispatch_webhooks_worker.ex  outbox event -> delivery rows
lib/courier/workers/deliver_webhook_worker.ex    due delivery -> signed POST
lib/courier/error_reporting.ex        the SDK seam: capture/3, capture_any/3,
                                      enabled?/0, allowed?/1
lib/courier/error_reporting/filter.ex the SDK's before_send: the first barrier
lib/courier/error_relay.ex            the fleet's redaction chokepoint: the
                                      throttle, the counters, the ingest entry
lib/courier/error_relay/policy.ex     the allowlists, the blocked values, the
                                      error.type vocabulary, the fingerprint
lib/courier/error_relay/sender.ex     the bounded queue and its brutal-kill drain
lib/courier/error_relay/sink.ex       Sentry envelope framing, both directions
lib/courier/error_relay/sink/req.ex   the sink that ships, one attempt, no retry
lib/courier/error_relay/sink/noop.ex  the sink that counts what it discards
lib/courier_web/error_endpoint.ex     the ingest listener, on its own port
lib/courier_web/error_router.ex       /api/:project_id/envelope/, and the probe
lib/courier_web/controllers/error_envelope_controller.ex    one envelope, in
lib/courier_web/controllers/error_envelope_health_controller.ex  the relay's
lib/courier_web/plugs/ingest_token.ex the shared secret, from X-Sentry-Auth
test/courier/error_relay/policy_test.exs the allowlists, the canaries, the
                                      vocabulary, and the fingerprint
test/courier/error_relay_test.exs      the throttle, the counters, and the
                                      end-to-end boundary on the stored bytes
test/courier_web/error_reporting_test.exs  the SDK-side filter: a canary that
                                      fails the test if it ever reaches an event
test/courier_web/error_relay_endpoint_test.exs  the ingest surface: the token,
                                      the route an SDK actually derives, and
                                      the SDK's own framing
test/support/clock.ex                 the relay's injected clock, for throttle tests
test/support/recording_sink.ex        a sink that records envelopes instead of
                                      forwarding them
test/support/failing_sink.ex          a sink that raises, for the queue's drain
test/support/sentry_test_client.ex    the SDK's transport, pointed at a test sink
                                      and its own database on the SAME postgres
ops/glitchtip-database.sql            the store's role and database, idempotent
lib/courier_web/problem.ex            core's problem+json envelope, built once
lib/courier_web/messages.ex           the send surface's own rules: a CLOSED
                                      vocabulary, and the mapping from `to` to the
                                      payload's `email`
lib/courier_web/plugs/trace.ex        a trace id and the path, for every request
lib/courier_web/plugs/parse_body.ex   Plug.Parsers, with courier's 400
lib/courier_web/plugs/principal.ex    who is calling; 401 when nobody is
lib/courier_web/plugs/idempotency.ex  Idempotency-Key on a mutating POST, and its 409s
lib/courier_web/plugs/problem_content_type.ex  a non-2xx is problem+json
lib/courier_web/plugs/telemetry.ex     the request span: above the router, below
                                      the parsers, and route template not path
lib/courier_web/controllers/health_controller.ex   GET /healthz, GET /readyz
lib/courier_web/controllers/messages_controller.ex   POST /v1/messages, the only
                                      door into Courier.Deliver, and the mapping
                                      from every refusal to a status
lib/courier_web/controllers/notification_preferences_controller.ex  GET/PUT /v1
lib/courier_web/controllers/webhook_endpoints_controller.ex  the six /v1 actions
lib/courier_web/controllers/error_json.ex        the errors Phoenix renders
lib/courier_web/router.ex             probes at the root, /v1 for the API
lib/courier_web/plugs/principal.ex   who is calling; 401 when nobody is, and 503
                                      when courier cannot find out
test/courier/principal/introspection/document_test.exs  the answer, as a table,
                                      with no socket and no database
test/courier/principal/introspection_test.exs the resolver, end to end against a
                                      table, and the credentials' absence from logs
test/courier/principal/introspection/transport_req_test.exs  the shipped
                                      transport, driven through Req's own plug
test/courier_web/plugs/principal_config_test.exs  the plug's two refusals over
                                      real requests, and openapi.yaml's 503
test/support/introspection_transport.ex a transport that answers from a table
test/courier/health_test.exs          the readiness check, on its own
test/courier/mailers_test.exs         what the platform hands in, per message
test/courier/mailers_config_test.exs  the sender and the subject are config
test/courier/smtp_delivery_test.exs   THE PROOF: a real send through a real
                                      SMTP adapter to a real gen_smtp server on
                                      a real socket, and the failure paths
test/courier/mailer_adapter_test.exs  the adapter courier refuses to ship
                                      without, and the two boot gates
test/courier/mailer_adapter_credentials_test.exs  a password never reaches a log
test/courier/deliver_test.exs         the three promises, in one transaction
test/courier/deliver_adapter_test.exs what happens when the provider says no
test/courier/notification_preferences_test.exs  defaults, writes, rejections
test/courier/events_test.exs          the envelope against core's schema
test/courier/nats_publisher_test.exs  the behaviour and the stand-in
test/courier/observability_test.exs   the allowlist, asserted on directly
test/courier/telemetry_test.exs       the contract, the resource, the wiring
test/courier/otel_export_test.exs     THE PROOF THAT COURIER EXPORTS: the real
                                      exporter, the real encoder, the real
                                      pending table, and the six defects below
test/courier/telemetry_canary_test.exs  THE PROOF: a canary in every field a
                                           caller controls, in nothing exported
test/courier/secret_box_test.exs      a secret is not readable from its column
test/courier/backup_config_test.exs   the two Kamal files held to each other:
                                      the mount, the shared secret names, no key
                                      material, and README's data-loss window
test/courier/backup_tables_test.exs  what a pg_dump carries, read out of
                                      information_schema: every table named, no
                                      file bytes, nothing pointing outside
test/courier/idempotency_test.exs     the claim, the refusals, the retention, the expiry
test/courier/webhook_endpoints_test.exs        the rows and their promises
test/courier/webhook_endpoints_config_test.exs the guard, with a chosen resolver
test/courier/webhook_deliveries_test.exs       the budget, the backoff, the id
test/courier/webhooks/signature_test.exs       the spec's scheme, verified twice
test/courier/webhooks/url_guard_test.exs       every blocked address class
test/courier/webhooks/payload_test.exs         the bytes on the wire
test/courier/webhooks/sender_test.exs          the request and its classification
test/courier/inbound/                 the verified-inbound base: a provider's own
                                       documented payloads, and the scheme as a
                                       published test vector
test/courier/inbound/resend_test.exs   Resend's payloads verbatim, and the mapping
test/courier/inbound/signature_test.exs  svix's own published vector, and every
                                      way a request is not authentic
test/courier/unsubscribes_test.exs    the one-click gate as a library: the digest,
                                      the state-less row, the transaction
test/courier/unsubscribe_headers_test.exs  THE HEADERS, on real message bytes and
                                      on a real SMTP socket
test/courier_web/controllers/unsubscribe_controller_test.exs  the door, over real
                                      requests: RFC 8058's own POST, the replay,
                                      the 404, and the refusal afterwards
test/courier/inbound_test.exs         THE PROOF: the whole inbound path against a
                                      real email_suppressions table, so "an unsigned
                                      payload records nothing" is a claim about rows
test/courier/bounce_correlation_test.exs  THE PROOF: a real Cloudflare send records
                                      the provider's receipt id, and a signed report
                                      quoting it resolves to the send instead of
                                      warning — the join, driven end to end
test/courier/workers/                 the relay, the fan-out, and the sender
test/courier_web/controllers/          the API, and the authorization matrix
test/courier_web/controllers/messages_controller_test.exs  the send surface:
                                      the refusals first, then the delivery
test/courier_web/controllers/messages_controller_config_test.exs  the two
                                      refusals that need the adapter swapped
test/courier_web/router_test.exs      which controller, which scope, which methods
test/courier_web/plugs/idempotency_test.exs  the header over real requests: one
                                           mutation, the replays, and the three 409s
test/courier_web/openapi_document_test.exs  openapi.yaml against the router, both
                                           directions, and why the probes are
                                           the only omission
test/courier_web/openapi_paths_test.exs     the reader, a test per normalisation,
                                           and the comparison with faults injected
test/support/openapi_paths.ex        the reader and the comparison the two above
                                    are built on; copy this file, not a shared kit
test/support/kamal_config.ex         the reader for config/deploy.yml and
                                    config/kamal-backup.yml; refuses rather
                                    than under-reads, and recognises a `secret:`
                                    NAME only
test/support/recording_sender.ex      a sender that records instead of sending
test/support/header_resolver.ex       a principal that reads a header
test/support/test_dns.ex              a resolver that answers from a table
test/support/test_span_exporter.ex    the exporter that records instead of sending
test/support/test_spans.ex            reading those spans, and RAISING on empty
test/support/fake_resend.ex           a Resend that SIGNS, so workers B and C can
                                      test the inbound path with no provider
test/support/smtp_server.ex           a real SMTP server for the round-trip test:
                                      :gen_smtp_server on a kernel-assigned
                                      loopback port
gate.yml                              the gate, DECLARED: command, proof, what it needs
kit.ref                               the pinned kit commit the stack comes from
config/deploy.yml                     kit's Kamal template with courier's facts,
                                      and the backup accessory that mounts the
                                      backup config into a container
config/kamal-backup.yml               WHAT is backed up, rendered from kit's .erb,
                                      not the .erb: read with YAML.safe_load and
                                      never interpolated
bin/prime                             the gate: deps, database, tests
bin/assert-suite                      refuses a run that skipped or excluded tests
bin/gate-self-test                    proves gate.yml is able to fail
bin/gate-db                           the postgres the gate needs, when the machine
                                      has none at the address config/test.exs names
bin/toolchain-pins                    reads mise.toml, checks CI has not drifted
bin/dev                               kit's, verbatim: fetch kit.ref, merge, up
.github/workflows/ci.yml              calls kit's workflow, plus gate and release
Dockerfile                            two-stage release build, slim final stage
docker-compose.yml                    an OVERRIDE on kit's stack: the courier
                                      service, its database and role on the
                                      SHARED cluster, and the crash layer
rel/overlays/bin/server               the release entrypoint the image runs
rel/overlays/bin/migrate              the release's migration entrypoint
```

## Rules

**Tests first, and show the red.** Write the test, run it, watch it fail for the
reason you expect, then implement (PLAN.md §3). A probe test that passes
without the route is worse than no test.

**The probes are production infrastructure.** `mix test` must cover both, and
the DB-down path must be a real one: `health_controller_test.exs` stops
`Courier.Repo` under the application supervisor rather than mocking the check.
Keep the failure response terse and log the reason instead — probe responses
are read by orchestrators, and this repository is public.

**A readiness check never raises.** Anything that can go wrong with the database
comes back as `{:error, reason}` from `Courier.Health.ready?/1`. Delivery here
is at-least-once, and a probe that takes down the endpoint is a self-inflicted
outage.

**Versions live in two places, not three.** `mise.toml` and the `ARG`s at the
top of the `Dockerfile` (Elixir 1.20.4, OTP 29.1.1). `mix.exs` keeps the `~>`
floor for library consumers; do not pin an exact version there.

**No dependency without approval.** The generated Phoenix 1.8 app is the whole
dependency list. Swoosh, Oban, Broadway, and the HTTP clients for the webhook
pipeline are Phase 3 packets — not this one, not "just to prepare".

**A mailer with no adapter that can reach a provider is a silent default, and
that is worse than a crash.** courier ships `{:swoosh, "~> 1.28"}` and
`{:gen_smtp, "~> 1.0"}`, and the second one is the load-bearing half: swoosh
declares `gen_smtp` OPTIONAL and `Swoosh.Adapters.SMTP` declares it REQUIRED, so
naming swoosh alone compiles a courier whose only shipped adapter is
`Swoosh.Adapters.Local` — which renders into memory, returns a provider-shaped id
and opens no socket. That is the state this repository was in: a paid product
that accepted every send, wrote an outbox row for each, published a `delivered`
event, and mailed nobody. No error, no warning. Three rules came out of it:

  * **The adapter has no default, and prod will not boot without one.** Not
    "warned about" — refused. A running courier that cannot send is worse than
    one that will not start, because the damage is outbox rows and events
    claiming delivery, for mail that was never delivered, and nothing in a
    dashboard shows it. `Courier.MailerAdapter.adapter!/1` raises in
    `config/runtime.exs`; `Courier.Application` re-checks the EFFECTIVE adapter
    as a second, independent gate — the same input twice would catch nothing, so
    the second one reads `Application.get_env` rather than the environment.
  * **`Swoosh.Adapters.Test` and `Swoosh.Adapters.Local` are named in
    `Courier.MailerAdapter.silent_adapters/0` and asserted as a set.** A third
    silent adapter has to be classified, or the set test fails. `none` is
    permitted in dev and refused in prod; the value is a NAME from a fixed set,
    never a module name, so the silent adapter cannot be named through the front
    door the refusal was built to close.
  * **An adapter no test can exercise is an adapter nobody has checked.** So
    `gen_smtp` is in EVERY environment, not `only: :prod`, and
    `test/courier/smtp_delivery_test.exs` drives real sends through the real
    adapter to a real `:gen_smtp_server` on a real kernel-assigned loopback port.
    Mocking the adapter would prove the mock works. The mutation is the proof:
    point those tests at `Local` or `Test` and five of the six fail.

**A credential is never in a log, and never in a committed file.** At SMTP a
"username" is usually an API key, so `Courier.MailerAdapter.describe/1` prints
the host, the port and whether auth is on, and omits *both* credentials — the
startup line an operator reads is not where a password belongs.
`test/courier/mailer_adapter_credentials_test.exs` captures real log output from
real sends and asserts the secret is ABSENT, which is the assertion worth more
than "it logged something": a boundary that deletes everything passes that. Two
tests in it are about the repository rather than about a call — no committed
`config/*.exs` may carry `username:`/`password:`/`relay:` inside a
`config :courier, Courier.Mailer` block — and they are scoped to the mailer's own
block because `config/test.exs` legitimately commits `password: "postgres"` for
the test database. A scan loosened until it goes green is a scan that has stopped
looking.

One packet has been approved since, and the two names it added are
`{:opentelemetry, "~> 1.7"}` and `{:opentelemetry_exporter, "~> 1.11"}`: the
trace SDK and the OTLP exporter, in **every** environment including test, because
without them courier cannot emit a span at all and kit's collector has nothing to
redact. They are the floor, not a choice among alternatives — the alternative was
courier exporting nothing and the whole redaction boundary being untested. What
was **not** added is as load-bearing: no `opentelemetry_metrics` (the Erlang SDK
has no metrics API — measured, `ls deps/opentelemetry/src | grep -c metric` is
`0`), no `opentelemetry_logger` (logs come from the collector's `syslog/crash`
receiver via compose `logging:`, which is a property of the container rather than
a per-language SDK), and no `opentelemetry_phoenix` (it would record
`url.path`, `url.query` and headers as its own attributes, and depending on the
engine to strip them would make courier's boundary one control where this
repository insists on two).

**`mix precommit` before you commit.** It compiles with warnings-as-errors,
drops unused deps from the lockfile, formats, and runs the suite. `bin/prime`
is the gate for a clean checkout; `mix precommit` is what a change must pass.

**The gate is declared in `gate.yml`, not discovered.** Written against
`cafaye/core`'s `schemas/gate.schema.json` and checked by its
`harness/bin/gate-check`, which reads `command`, `miseTask`, `entrypoint`, the
`external.requirements`, the `ci` block, and the `proof`. Two things follow.
First, the proof: `bin/prime` must print `Result: N passed` at or above the floor
in `gate.yml`, and that is what separates a gate from a command that exits zero —
`1/1 passed` and `3/3 passed` are the same claim without a floor. When the suite
grows, **raise `gate.proof[].minimum` in the same commit**, the same rule that
already applies to CI's `bin/assert-suite` floors. Second, the requirements: the
gate needs a migrated postgres, the pinned toolchain, and one hex fetch, and
`selfContained: false` with that list is the honest answer. **A gate that needs
something and does not say so is the defect this format exists to prevent**, so
add a requirement rather than letting the gate quietly assume one.
`bin/gate-self-test` breaks `gate.yml` nine ways and asserts core's checker
catches each; it is a CI step of its own, not part of `bin/prime`, because a
self-test inside every gate invocation is a second gate that can disagree with
the first.

**The CI gate is `bin/prime`, the same command, not a CI variant of it.** If the
two can disagree, one of them is lying. The workflow adds a database, the tier
counts and the lockfile guard *around* that command; it does not reimplement it.

**The send path's HTTP door is `POST /v1/messages`, and its contract is
`synchronous`.** The whole send happens inside the request — the preference is
read, the suppression list is consulted, the provider is dialled, the outbox row
is written — so the caller learns the real outcome rather than a receipt for an
intention. **A 200 means the provider accepted the message for delivery and
courier wrote the `courier.email.delivered` row in the same transaction; it does
not mean the mail arrived**, because a submission protocol says nothing about
arrival and courier has no receipt to report one with. `data.status` is therefore
`accepted` and is never `delivered`: a field reading `delivered` would be courier
claiming a fact about somebody else's inbox that it cannot know.

The queued alternative was considered and is real — `Courier.Workers` exists and
`oban` is already a dependency — and it loses on one requirement: **a 202 answers
before the suppression check has run**, so a refusal arrives after the response and
a caller who cannot tell "suppressed" from "sent" retries forever. The availability
price of the synchronous choice is stated rather than assumed: courier holds a
database transaction open across the provider's dial, and a slow provider makes
this request slow. What makes it survivable is that the failure is honest (a 503
with a code the caller retries) and the retry is free under an `Idempotency-Key`.

**Three refusals, told apart by status and `code` and not by `detail`**, because a
client branches on the code:

| outcome | status | `code` | retry? |
| --- | --- | --- | --- |
| accepted for delivery | 200 | — | — |
| the recipient's mailbox is suppressed | 409 | `conflict` | **no** |
| the request is wrong, or the user declined this type | 422 | `validation_failed` | after fixing it |
| the provider refused, or courier cannot deliver | 503 | `unavailable` | yes, same key |

**A suppressed mailbox is a 409 and not a 422**, and the reason is that it is not a
property of the request: a hard bounce and a spam complaint are facts about a
*mailbox*, recorded by a provider and not chosen by this caller, and the table
behind them is never exposed through any route — so this response is the only
place the fact can surface. **A declined preference is a 422**, the opposite answer
on purpose, because a decline is visible through
`GET /v1/notification_preferences/{user_id}` and changeable through the `PUT` beside
it, and `errors[]` — which core reserves for 422 and nothing else — can name `type`
as the field at fault. One code for two different remedies would have been worse
than either.

The suppression response deliberately **does not echo the address** and carries no
`errors[]`: `email_suppressions` has no `account_id` by design, so the 409 is a
fact about a mailbox rather than about another tenant's data, and a status nobody
can read the list through is the same posture the suppression packet took when it
declined to expose one.

**The send path consults suppression, and the controller does not.** Both live in
`Courier.Deliver` — the preference first, then the mailbox — because a hard-bounced
address does not get mail *whatever the caller asked for*, and every caller of that
module is a caller of that promise. `Courier.DeliverTest` and the endpoint's own
tests assert it from both sides; `messages_controller_test.exs` proves it from the
library side precisely because a check that lived only in the controller would be a
check the library could fail.

**The send surface's vocabulary is closed, and that is the point.**
`Courier.Mailers` casts a payload with `Ecto.Changeset.cast/3` against a fixed field
list and **discards everything else without a word** — right for a library a trusted
caller holds, wrong for a request body, where a misspelled `emai_enabled` would be
accepted with no sign anything was ignored. So `CourierWeb.Messages` refuses an
unknown key as a 422 naming it, and `account_id` is in that set: the account is
`conn.assigns.current_account` and never the body's.

**There is no `from` and no `text`/`html` in the request, and both absences are
deliberate.** courier sends *transactional* mail it renders from its own templates.
A caller that could choose the sender would be a phishing relay wearing the
platform's sending domain, and the reputation cost lands on every other tenant's
mail; raw bodies on the wire would make courier a general-purpose relay handing out
every template, layout and escaping decision. So the sender and subjects stay
configuration, and a body carrying `from` is a 422 naming `from`.

What survives of "at least one of text/html" is `Courier.Mailers.body?/1`, a check
on the **rendered** message called from `Courier.Deliver` where the message is the
only thing in hand — and it is a 500 rather than a 422 when it fails, because the
caller's request was fine and courier's own template rendered nothing. `Swoosh`
delivers a bodiless email and answers a provider-shaped id, so without the check a
message with nothing in it would be recorded as delivered and published as
`courier.email.delivered`: the same silent default the adapter work refuses,
reached by a different road. It is tested on hand-built messages as well as on a
real render, because a predicate that only ever sees messages it is guaranteed to
accept is a predicate nothing has checked.

**The adapter gate is asked a third time, per request, and the reason is
visibility.** `Courier.MailerAdapter` refuses to boot and `Courier.Application`
re-checks the *effective* adapter; this action asks the same predicate again so the
refusal reaches the caller as a 503 instead of being a boot-time property nobody
sees. A courier that booted with a silent adapter would otherwise answer 200, write
an outbox row and publish `courier.email.delivered` for mail nobody receives. It is
scoped to `:prod` exactly as `verify_boot!/1` is, because `Test` and `Local` are the
correct adapters in the environments that configure them — and reaching that scope
from a test is why `MailerAdapter.config_env/0` reads application env rather than
`Mix.env/0`.

**A 503 on a customer operation is new, and it moved a list in
`openapi_error_responses_test.exs` rather than being added to it.** That file's
`@unreachable` map asserted that no operation declared a 503, because only
`GET /readyz` sent one. A send has a dependency courier does not control, so the
status became reachable and the fix was to **correct the list and say why** — which
is what its own comment instructs. A third status left that map (409 in courier-14)
and the second departure is what shows the map is a list and not a constant.

**A tier that CI cannot name is a tier nobody ran.** The suite partitions
exactly, by the case template: 760 tests in the 35 files that never touch
`Courier.Repo`, 903 in the 51 that do, and `mix test` is aliased to
`ecto.create` first, so a runner with no database executes *zero* of the 1663 —
SSRF table included. Both counts are asserted in CI by `bin/assert-suite`, and
the SSRF table gets its own 62-test run so the log carries a line that can only
exist if that harness ran. Re-measured on the tree carrying the third provider
(the Cloudflare Email adapter), and again on every packet since — **these
numbers were stale by 68 for eleven packets before somebody re-measured them**,
which is the same finding `gate.yml` carries about its own floor: a floor is a
decrease detector, so a stale number is green and silent. **When you add or
delete a test, raise the floor in
`.github/workflows/ci.yml` in the same commit.** Deleting a test to make CI green
is caught by the floor; adding one is caught because CI goes red until you raise
it. Both are one-line diffs, and only one of them changes what courier verifies.

**A backup configuration nobody reaches is a document.** `config/kamal-backup.yml`
is read by no process in this repository: the only reference to it anywhere is one
`files:` line in `config/deploy.yml`, mounting it into the `backup` accessory at
`/app/config/kamal-backup.yml`, which is where `kamal-backup` opens it. Delete
that line and the file is still valid, still careful, and inert — the same defect
one layer down as not having written it. So `Courier.BackupConfigTest` reads
**both** files: the mount exists, and every secret the backup config names is in
the accessory's `env.secret` list. That second one is not a convention: the
`kamal-backup validate` builds the accessory's environment from that list and
from nothing else, so a secret named in one file and missing from the other is a
valid file in each and a **rejected pair** — measured on kamal-backup 0.5.2,
which reports `RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required`. The
rule is one-directional on purpose: every secret named in the backup config is in
the accessory, and the accessory holds two more (`AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`) because `ConfigFile::TOP_LEVEL_KEYS` has no key for an
AWS credential at all. A check demanding the two files name the same set would be
wrong in the direction of failing on correct configuration.

**`config/kamal-backup.yml` is RENDERED, and the `.erb` is not what ships.** kit
ships `templates/kamal/kamal-backup.yml.erb`; what lands here is its rendered
output, with `app:` a literal. Kamal evaluates ERB in `config/deploy.yml` because
Kamal owns that file; `kamal-backup` does not — `KamalBackup::ConfigFile#data`
reads the path with `YAML.safe_load` and nothing else. An unrendered
`app: <%= service %>` is therefore *not a syntax error*: YAML reads it as a
literal scalar, and the failure is a repository full of snapshots under
`databases/<%= service %>/primary/`, tagged `app:<%= service %>`, which no
`kamal-backup list` filtered on this app ever finds. The test asserts the absence
of a tag **on the lines the tool reads**, because this file's own header quotes the
tag while explaining the failure.

**"Nothing on local disk" is a claim about courier's COLUMNS, and it is asserted
from the schema.** `config/kamal-backup.yml` has no `paths:` key, so no restic
file snapshot is ever taken (`latest_file_backup: null` in `evidence` is correct,
not a gap). That is only defensible while courier stores nothing outside Postgres,
so `Courier.BackupTablesTest` reads `information_schema` on every run and fails if
a column appears holding file bytes or pointing at bytes held elsewhere. The one
permitted `bytea` is `idempotency_keys.response_body` — a cached response body
*inside* Postgres, expired on a clock — and the one thing that check must never
become is "there is a bytea column, therefore there are files".

**The SecretBox key cannot be in the backup, and that is the answer rather than a
gap.** `webhook_endpoints.secret` is sealed under `COURIER_SECRET_BOX_KEY`, and
`config/runtime.exs` refuses to boot without it — so it is not in the database and
cannot be in a dump of the database. **A restore brings every signing secret back
as ciphertext, and courier cannot read its own rows until that key is supplied
unchanged.** The rows come back; the ability to sign with them does not. Hence
`COURIER_SECRET_BOX_KEY` is asserted ABSENT from both the backup config and the
accessory's secret list, and asserted PRESENT in `config/runtime.exs` — an absence
with nothing on the other side of it is a boundary that deletes everything. The
same shape applies to `RESTIC_PASSWORD`: lose it and every snapshot in the
repository is permanently unreadable, including the ones not yet lost.

**A scheduled dump is not PITR, and the number is measured from when the previous
backup FINISHED.** With the shipped `schedule: 1d`, up to **24 hours** of
committed transactions are lost if the database is destroyed — not to a wall-clock
deadline. The scheduler's loop is *run a backup, then sleep the interval*, so one
cycle is the interval **plus that run's duration**, and `pg_dump` takes its
snapshot at the **start** of the dump, so the gap between two snapshot points is
that whole cycle and is never exactly 24 hours. A failed backup is not retried
until the next interval either; the loop logs and sleeps. `Courier.BackupConfigTest`
reads `schedule:` from the config and asserts README quotes the matching window,
so changing the cadence without changing the README goes red.

**`config/deploy.yml` is kit's template with courier's facts, and the differences
are three — two changes and one absence.** Copied from
`templates/kamal/deploy.yml.erb` at kit d201080: (1) the proxy healthcheck path is
`/readyz`, because `CourierWeb.Router` serves `/healthz` and `/readyz` and nothing
else, so kit's `/up` would 404 on every probe and `kamal deploy` would tear back
every rollout after `deploy_timeout` on a release that is otherwise fine;
(2) `env.secret` carries courier's own boot-required variables, read off
`config/runtime.exs`'s `raise`s rather than from memory. The third is an ABSENCE:
neither file has `migrate:`, so **`bin/migrate` is not run by a `kamal deploy`.**
Kamal 2.12.0 rejects the key outright (`Kamal::ConfigurationError: unknown key:
migrate`, measured with the real binary) and runs migrations from
`.kamal/hooks/pre-deploy`. That hook is courier's own file to add and this
repository has not added it, because silently changing what a deploy does is the
thing these rules keep refusing.

Re-measure both, and **re-measure the labels rather than only the floors.** The
suppression packet added 31 database tests and nobody raised this file: the
*floor* stayed green because it is a decrease detector, while the number printed
beside it quietly stopped describing the tree for a whole packet. A floor that
cannot catch it is not the same thing as a comment that cannot be stale, and only
one of the two is a gate.

**A test asserts about its own rows, never about the table's.** A count over the
whole table — `Repo.aggregate(WebhookEndpoint, :count) == 0` — is a claim about
every other test in the repository as much as about the code under test: it is
green only while nothing else has ever written a row, and red the moment one is
visible. That is the *test-level* shape of the tenant-isolation weakness D18
tracks, and it failed in about one run in nine until courier-15 gave each of the
six affected tests its own tenancy key and counted only its own account's rows.
The rule generalises past those six: **mint an account per test that needs to
assert nothing was written, and count that account.** The same reasoning covers
reads: a `Repo.all/1` with no `order_by` returns rows in PostgreSQL's order, not
insertion order, so an assertion that compares two lists must sort both sides
before it is a claim about courier rather than about the server's whim.

**The suite connects as `courier_app`, and that is what makes the RLS proofs mean
anything.** `config/test.exs` and `config/dev.exs` used to name `postgres`, a
**superuser**, and a superuser bypasses RLS whatever `FORCE ROW LEVEL SECURITY`
says. So the three policies installed by
`20261003090000_protect_account_scoped_tables` were inert in every environment
this repository configured, and 1276 green tests could not tell an enforced
boundary from an installed one. `Courier.Tenancy`'s moduledoc carried the
measurement; this is the change it was asking for.

  * **Two modules, not one repo key with a switch.** `Courier.Repo` is
    `courier_app`; `Courier.OwnerRepo` is the owner, and it is **not** in
    `:ecto_repos` and not in the supervision tree, so no running release holds a
    connection that bypasses every policy. The rejected version was one repo key
    with `COURIER_OWNER_DATABASE_URL` overriding it — which does not "make
    migrations run as the owner", it makes **the tests** run as the owner, and the
    suite goes green with the boundary off. Two modules make the phase a
    compile-time fact. `mix.exs`'s `test` alias runs `ecto.create`/`ecto.migrate`
    against the owner and the suite itself against `courier_app`.
  * **`bin/migrate` had the same defect one layer out.** `Courier.Release.migrate/0`
    iterated `:ecto_repos`, which is `[Courier.Repo]` — so a release that
    migrated would have failed on the first migration that creates a table, with
    `permission denied for schema public`, from a binary whose application half
    works. It runs `Courier.OwnerRepo` now, and `COURIER_OWNER_DATABASE_URL`
    configures it **without being a boot requirement**: nothing in the request
    path reads it, so refusing to start over a migration credential would take a
    healthy release down for something no request needs.
  * **The sequence grant used to be a kit defect this tree pinned.**
    `cafaye.protect_table/2` at `15cee0e1` granted table DML and no sequence
    privilege, so a protected table with a `bigserial` column was uninsertable by
    the login role; kit fixed it in `63663f8`, and the copy was re-taken on
    2026-10-16 at `537441e`, which includes the fix — so `protect_table` now
    grants USAGE on the protected table's own sequence and the
    `notification_preferences_id_seq` grant in
    `20261005120000_grant_app_role_runtime_dml` is a no-op kept as history.
    `oban_jobs_id_seq` is still granted only there: `oban_jobs` is not
    account-scoped and the substrate never touches its sequence. A missing grant
    surfaces as `42501`, the same SQLSTATE the policies raise, so an assertion
    checking the code alone cannot tell a working boundary from a table nobody
    can write to; that migration grants the six unprotected tables' DML
    minimally, and **no `TRUNCATE` anywhere** — it is the one DML privilege with
    no row filter.
  * **`@moduletag account:` is the harness's half, and it is opt-in.** The sandbox
    already wraps every test in a transaction, so the identity is set on that
    connection rather than in a `with_account/3` — a nested transaction is a
    SAVEPOINT whose release does not discard a transaction-local setting. A file
    touching only `outbox_events`, `email_suppressions` or `webhook_deliveries`
    needs no tag: those tables have no `account_id` **by design**, which is the
    same fact `tenancy.yml`'s empty `rls.tables` records.
  * **Each request's scoped transactions change the test's identity, and a
    read-back after a request is scoped to the LAST request's account.** Harmless
    in production — every scoped transaction commits, so `COMMIT` discards
    the setting in the database, which is the whole of `is_local := true`'s
    argument — but in a test the sandbox's transaction sits OUTSIDE them. Measured
    on a driver test: `identity after OWNER post: 6f5d…` then
    `identity after OTHER post: 7a6e…`. (An earlier shape put the transaction in
    `CourierWeb.Plugs.TenantIdentity`, which committed before the controller ran
    and broke every authenticated route in production while the suite stayed
    green; the scope now lives in each action and in the `:idempotent` plug,
    where a transaction can wrap the work.) Three assertions were reading a
    protected row back as the wrong account, and one of them (the DELETE) passed
    *because* the row was invisible rather than because it survived — a boundary
    that satisfies a denial arm for free.
  * **`Courier.NotificationPreferences.addressable/2` is now structurally
    unreachable for a cross-tenant read, and the answer changed.** It decided that
    case by READING the stored row's `account_id` and comparing it in Elixir; as a
    policy subject the read returns nothing, so the comparison never runs. The
    write is then refused by the database with `42501`, which was a **500 where a
    404 was documented**; `store_all/3` translates it to `:not_found`, matched on
    the *message* rather than the SQLSTATE so a missing GRANT stays loud. The
    read's 404 is gone and the answer is 200-with-defaults, byte-identical to a
    user who does not exist — which leaks **less**, since the 404 existed only to
    withhold the fact that a row exists. **This is a contract change and
    `openapi.yaml` still declares the 404.** Reported, not reconciled: see
    `REPORT-courier-app-role`.
  * **A floor that only moves when a test is WRITTEN is a floor that cannot see a
    test changing what it needs.** This packet added one test and moved
    `error_reporting_test.exs` between tiers, because it now reads
    `schema_migrations` through `Courier.OwnerRepo` — a table the runtime role is
    deliberately not granted.
  * **`tenancy.yml`'s `no-identity` arms are now TRUE where they were a
    convention, and its `rls.databaseEnforced: false` needs a reader.** That file
    says courier's boundary is "the application, and the application's own tests
    are what hold it", and it was honest while the suite ran as a superuser. It
    is *more* honest now — the policies are enforced against the role courier
    actually connects as — which means `rls.databaseEnforced: false` now
    describes something narrower than it did: three tables ARE enforced, by
    `protect_table`, and the four that are not are the ones the migration
    enumerates. **Not updated in this packet**, and that is a finding rather than
    an omission: `tenancy_check.py` reads `sources:` as evidence and the
    migration list it reads now contains a second RLS-bearing file, so the
    `tenancy.rls-undeclared` silence this file relies on has to be re-measured by
    whoever owns the checker. Reported, not guessed at.

**The toolchain is pinned in `mise.toml` and nowhere else.** `bin/toolchain-pins`
is how CI reads it, so the workflow cannot disagree with the worktree; the one
unavoidable duplicate is kit's `versions:` input, and `bin/toolchain-pins
--check` fails when that line and `mise.toml` stop matching. Bump both or neither.

**`mix.lock` must not move when the gate runs.** A prime that resolves
differently is a prime that lets two worktrees disagree about one commit, and the
suite cannot see it. CI runs `git diff --exit-code -- mix.lock` after `bin/prime`.

**`async: false` is a comment, not a shrug.** If your test stops or restarts a
process the suite shares — `Courier.Repo`, the endpoint, the Oban queue — it must
be `async: false` and say why in a comment above `use`. The same goes for a test
that changes application env, which the whole VM shares: those live in their own
`*ConfigTest` file, as `ProcessOutboxWorkerConfigTest`,
`WebhookEndpointsConfigTest` and `DeliverWebhookWorkerBudgetTest` do.

**`openapi.yaml` and the router are held to each other by a test, in both
directions.** `test/courier_web/openapi_document_test.exs` reads the document and
`CourierWeb.Router.__routes__/0` and fails if they disagree — an operation in the
document the router does not serve, *or* a route the router serves the document
does not describe. Both are failures, not warnings: a warning nobody acts on is a
note in a file nobody reads, and PLAN.md MD6 has the platform generating client
SDKs from this document, so an omission here is a method a generated client will
not have. The only omission is `/healthz` and `/readyz`, named in the document's
header and in the test's exclusion list with the reason, and the test fails if
that list stops naming a route the router serves.

It compares **paths**, never counts: a count comparison passes on a rename and
fails on an addition, which is backwards. The readers raise rather than
under-read, because a document reader that finds nothing and a router reader that
finds nothing agree with each other, and a green check over nothing is worse than
no check. **A route added to `router.ex` is not finished until it is in
`openapi.yaml`, and an operation added to `openapi.yaml` is not finished until
the router serves it.** The only omission is `/healthz` and `/readyz`, named in
the document's header and in the test's exclusion list with the reason, and the
test fails if that list stops naming a route the router serves.

Every operation in that document requires a bearer token, including the two
notification-preferences operations, which stopped being the exception in
courier-16. `openapi_error_responses_test.exs` works out which operations must
declare a 401 by **provoking** them rather than from a list, so it is the check
that noticed; a `security:` key or a status written down in the test would each
have kept asserting the old thing and gone green.

**A preference is the user's, and the account is who owns it.**
`notification_preferences.account_id` is written from the principal and never from
a request, and the unique index stays on `(user_id, notification_type)` — one
answer per person, not one per account, which is what lets `enabled?/3` (the
delivery path, and it takes no account) keep reading by user alone. Two
consequences are load-bearing and both are asserted:

  * **A 404 is the only cross-tenant answer, and it is narrow.** A user nobody
    has written preferences for is a 200 with the defaults, because courier holds
    no foreign key to identity's users and cannot tell that user from one that
    does not exist. The 404 appears only once a row exists and belongs to another
    account, and never a 403 — see the rule above on leaking existence.
  * **The first authenticated `PUT` for a user id claims it.** courier cannot ask
    identity which account a user belongs to, so whoever writes first records the
    owning account. An account that writes for an unwritten user id therefore
    gains the claim — no access to anything that existed, and the real owner then
    gets a 404. That is a real limitation rather than a design, and it is why the
    migration that added the column **deletes** every row written through the
    unauthenticated routes instead of backfilling a guess: an unattributable
    opt-out is either visible to every tenant or to none, and "to none" fails in
    the direction courier's own rule demands, *silence is not consent*.

**A retryable `POST` claims its `Idempotency-Key` before it does the work, and
only a 2xx is kept.** The ordering is the whole mechanism: a key recorded after
the action cannot prevent anything, so `Courier.Idempotency.claim/1` runs in the
plug and the response is stored in `before_send`, with the row sitting in
`in_flight` between the two. Two properties follow and both are load-bearing:
**a request that did not succeed releases its key** rather than storing the
failure — a stored 422 would pin a caller's typo for 24 hours, and a stored 500
would pin a courier blip for the same day — and **`endpoint` is the concrete
request path**, not the route pattern, so a client that reuses one key to test
four endpoints is not refused on the second.

Two Elixir traps sit under this and are written into `CourierWeb.Plugs.Idempotency`
and `Courier.Idempotency` rather than left in this file alone, because both fail
**silently**: `conn.resp_body` inside `before_send` is **iodata, not a binary**
(`Phoenix.Controller.json/2` encodes to iodata and `Plug.Conn` stores what it is
given), and Ecto's keyword `where/2` **does not apply the schema's field type**,
so a `DateTime` compared against a `utc_datetime_usec` column matches nothing.
Use the `where([k], ...)` macro form and `IO.iodata_to_binary/1`.

**The inbound path verifies before it parses, and that order is the security
property.** `Courier.Suppressions.ingest/1` was written, tested, documented as
"the HTTP surface's entry point" — and nothing called it, so the suppression
table was only ever written by tests and a customer who hard-bounced was mailed
again forever. The obvious way to give it a caller is a route that
`Jason.decode!`s a body and passes it in, and that route is an unauthenticated
`POST` that records suppressions: anyone who finds the URL can suppress anyone's
mail, which is a denial of service on the whole product delivered by the feature
meant to protect it. So `Courier.Inbound.handle/5` verifies first and parses
only on `:ok`, and `test/courier/inbound_test.exs` drives the real
`Courier.Suppressions` against the real `email_suppressions` table and asserts
**no row exists** afterwards. It is a `Courier.DataCase` for that reason alone: a
mock would make "the parser refused" and "the row is absent" the same claim. A
negative assertion is paired with a positive one throughout, because a boundary
that records nothing ever passes every "records nothing" test.

**The verifier's correctness is pinned to a vector the PROVIDER published, not to
courier's own signer.** `Courier.Webhooks.Verifier`'s moduledoc says courier is a
producer and "nothing here receives webhooks"; Resend signs with Svix, which is
the scheme Standard Webhooks was standardised from, so `Courier.Inbound.Signature`
reuses `Courier.Webhooks.Signature` rather than reimplementing the crypto — and
`test/courier/inbound/signature_test.exs` leads with Svix's own worked example
from <https://docs.svix.com/receiving/verifying-payloads/how-manual>, because
"a test that asserted the signer against itself would pass even if the base
string were wrong". Resend's own verification page prints a signature whose
secret it never shows (`process.env.WEBHOOK_SECRET`); measured, it is NOT the
HMAC of the body printed beside it, and the test file records that rather than
building a fixture on a coincidence. Two rules that look like details and are not:
the signing secret is checked **before** any header, so a courier deployed without
one reports its own misconfiguration on every request rather than an attacker's
missing header; and `:crypto.hash_equals/2` is called behind a `byte_size` guard,
because it **raises** `ArgumentError` on a length mismatch and an unguarded call
turns "POST a 4-character signature" into a 500. **The constant-time comparison
is the one claim no behavioural test can catch** — mutating `hash_equals` to `==`
left the suite at 108/108 green — so it is asserted on the source, and the test
says why a timing test would be worse than useless.

**Whether a message may be unsubscribed from is the KIND, and the kind is a closed
table in `Courier.Mailers` — not a request field, not configuration, and not a
caller's guess.** `Courier.Mailers.kinds/0` maps every type courier can send to
`:transactional` or `:bulk`, `Courier.Deliver` calls exactly one function
(`Courier.Unsubscribes.decorate_for/3`), and that function is where the
conditional lives so it cannot drift from the table. Two rules that look like
details:

  * **The default for an unclassified type is `:transactional`,** and the
    direction is the whole decision. A new type nobody classified would otherwise
    grow an unsubscribe link, and an account-management email with one is its own
    defect — the remedy courier could offer a person who reset their password and
    found a link is a support ticket. Failing towards "no header" is the direction
    a person notices.
  * **The table is a LIST OF PAIRS, not a map, and the reason is the compiler.**
    Every value in it is `:transactional` today, so a map literal infers
    `%{String.t() => :transactional}` and the type checker then correctly reports
    that an arm matching `:bulk` can never run — right about the literal, wrong
    about the code, and `--warnings-as-errors` turns it into a red build. The
    "simplification" back to a map is invisible in a diff, which is why the
    comment on the table says so.

**An unsubscribe is recorded as a `email_suppressions` row with NO `state`, and
the absent state is the mechanism rather than a detail.** A bounce and a complaint
carry a state and refuse **every** type courier sends, because they are facts
about the MAILBOX, and `Courier.Deliver` consults that table for a password reset
exactly as firmly as for a newsletter. A stateful unsubscribe row would be a
person who stops receiving product updates and then cannot reset their password.
So `Courier.Suppression.unsubscribe_changeset/2` is a **separate changeset** that
never casts `state` at all, `state` became nullable in the database, and
`Courier.Suppressions.unsubscribed?/2` reads those rows by `(email,
notification_type)`. Three consequences worth knowing:

  * **`state/1` has always had that case.** Its own moduledoc spells the fold out
    as "rows, none carrying a state -> `nil`", and the middle line was unreachable
    while the column was `NOT NULL`, because the only state-less writer was a soft
    bounce and it records no row. The migration is what makes the documented fold
    true, and `suppressed?/1` and `find/1` already filtered on it.
  * **The two-value vocabulary is not weakened.** `state` is still an `Ecto.Enum` of
    two values with no database CHECK, and a `NOT NULL` is not what the original
    migration argued for — it argued that there is no third "suppressed: true"
    boolean. `nil` is not a third value; it is the absence of one.
  * **The alternative measured worse, and the measurement is the reason this
    repository does not write a `notification_preferences` row.** That table
    records `account_id NOT NULL` — which account is *entitled* to a user's
    answers — and an unsubscribe has no principal, so the row would have to carry
    the account that SENT the mail, which is a tenancy claim made for a user id an
    authenticated caller chose. The cost is a route that works today breaking: the
    wrong account claims the user, and the account that actually owns them gets a
    404 from a settings endpoint that worked yesterday. Writing the answer where
    the table has no tenancy column makes the worst case "this person stops
    getting one kind of mail".

**The one-click token is stored as a SHA-256 and never as itself, and the plaintext
exists in exactly two places: the `List-Unsubscribe` header and the recipient's
mail client.** `Courier.UnsubscribeToken` is the opposite of `Courier.SecretBox`
and the difference is the direction of the operation: a webhook signing secret has
to be read *back* to sign with, and an unsubscribe token never does anything but be
looked up. So a database dump is not a list of mailboxes anybody can unsubscribe —
`test/courier/unsubscribes_test.exs` reads the column as raw SQL for that reason
and asserts the digest does not *contain* the token, not merely that it differs.
RFC 8058 §3.1 asks for "an opaque identifier or another hard-to-forge component"
and §6 says why in the plainest terms in the RFC: a malicious mailer could
otherwise cause unsubscriptions "as a side effect of users reporting the spam".

**The token in the path is the whole of the authorization, an unknown one is a
404, and the POST is never redirected.** Three rules, each from a MUST in RFC 8058
rather than from taste:

  * **§3.1: "The POST request MUST NOT include cookies, HTTP authorization, or any
    other context information."** A mail client holds no bearer token and is
    forbidden from sending one, so `POST /unsubscribe/{token}` is outside `/v1`
    and behind no auth plug — behind `CourierWeb.Plugs.Principal` every
    one-click unsubscribe in the world would be a 401. The same paragraph asks
    for a hard-to-forge URI, and the token is the answer.
  * **A token courier did not issue is a 404, not a 401.** It is the *address* of a
    resource rather than a credential presented at a door, and it covers a token
    of the wrong shape and one that is not a string as well — one answer, so the
    endpoint is not an oracle that can be used to test tokens. `openapi.yaml`
    declares no 401 for either verb, and `openapi_error_responses_test.exs`
    provokes every status the route can send against the document.
  * **§3.1: "The mail sender MUST NOT return an HTTPS redirect."** A redirect is
    the one thing here that would work for a browser and silently break the mail
    client that matters, so the test asserts the **absence** of a `Location`
    header.

**The token is read from `conn.path_params` and never from `params`,** and that is
a decision rather than tidiness: `Plug.Parsers` merges the request body into
`conn.params`, so a one-click `POST` whose body carried its own `token` could name
a different mailbox than the path did — and the path is the whole of this route's
authority. The test sends exactly that request, with two real tokens, and asserts
the path won.

**A replay is the same 200, and the deduplication is the index that was already
there.** The unique `(provider, provider_event_id)` constraint answers a second
`POST` with `:duplicate`, keyed on the token's id, and the event is published only
on the new row — so a mail client that timed out gets the first answer back rather
than an error. There is no `Idempotency-Key` for the two reasons
`POST /inbound/resend` has none: the header is scoped to a principal, and RFC 8058
forbids this request from carrying authorization at all.

**And courier sends no bulk mail, so the positive branch of the send path is
unreachable today — and the reason is in core, not here.** All three types are
`:transactional`, and adding a fourth is a change in `cafaye/core`: every payload
courier publishes carries `notification_type`, and
`core/schemas/events/courier/email/*.schema.json` freezes that field to an enum of
the three names courier sends. The switch is one row in `kinds/0` **plus** one enum
value in core, and the table's test — that its keys are `types/0` — is what makes
that a decision rather than a drift. `test/courier/unsubscribe_headers_test.exs`
says which half of the gate is therefore proved where, rather than leaving a
reader to assume both.

**The one-click endpoint is the only route whose answer depends on a row and a
rejected credential, and the canary test moved tiers because of it.**
`test/courier/telemetry_canary_test.exs` drives real requests through the real
router with no sandbox, because every request it drove was refused before it
reached a controller that touches a database. A canary could be planted on a
request the `:accepts` plug refuses and the file would have stayed in the
no-database tier — and the tier's own claim ("these tests never touch
`Courier.Repo`") would have quietly become false. **A floor is a decrease detector;
a tier is a statement about what the tests do**, and a statement that holds only
because a request was answered early is a lie with a number on it. The file became
a `Courier.DataCase` and the floors in `.github/workflows/ci.yml` were re-measured
in the same commit, which is the only one of those two numbers that went **down**.

**That file has a pre-existing race this packet reproduced rather than chased, and
the record of it belongs here.** `request_spans/0` reads *every*
`courier.web.request` span in a table shared by the whole VM, filtered only by
name, and the "a 404 produced a span with a route" assertion is a loop over that
whole table. So a span from a concurrently finishing `async: true` test in another
file is read as this file's. Measured on this tree: **1 failure in 8 whole-suite
`bin/prime` runs, 0 in 12 isolated runs of the file.** The failing assertion
predates this packet and runs against spans this packet does not produce; what
this packet did was add one request to the file, which does not make an existing
race reachable and is stated in `REPORT-courier-24-unsubscribe` so the next
reader counting runs knows it. The two available fixes are both worse: filtering
`request_spans/0` more narrowly would weaken the presence assertion every other
test in the file depends on — the "a check over nothing passes" failure the
file's own moduledoc is built against — and moving the new canary out of the file
would stop proving that a one-click token, the sharpest value in this service
after a signing secret, reaches no span.

**A provider payload written from memory is indistinguishable from a correct one
until the provider's real bytes arrive**, and by then it is in production rows.
Every payload in `resend_test.exs` is copied from a named
`resend.com/docs/...` page. Two things that reading the docs changed: the bounce
vocabulary is `Permanent` / `Transient` / `Undetermined` on one page and
`Permanent` / `Temporary` on another, so **both** soft spellings are accepted and
`Undetermined` is deliberately soft — being told there was a bounce is not being
told the mailbox is gone, and `Courier.Suppressions` already states the asymmetry
("being wrong towards sending is expensive and cumulative"). And
`provider_event_id` is `"<type>/<email_id>:<address>"`, all three parts, because
a **broadcast shares one `email_id` across every recipient**: keyed on the email
alone, four of five bounces collide with the first and four live mailboxes go on
being mailed forever. The `email.complained/` prefix is load-bearing for the same
reason from the other side — measured, a complaint about an address that had
already hard-bounced collided with the bounce's row, the unique index returned
`duplicate`, and the `:suppressed` row was never written, inverting the one
precedence rule `Courier.Suppressions` exists to make unbreakable.

**An event courier cannot classify is refused, not defaulted.**
`{:error, :unsupported_event}` for a `type` courier has not read, and
`{:error, {:unknown_bounce_type, value}}` for a bounce type outside the documented
set — the same fail-closed choice as `Courier.ErrorReporting.Filter` returning nil
rather than emitting what it cannot redact. A provider that adds an event type
should produce a log line, not silence. The distinction that matters: a KNOWN
value meaning "the provider does not know" (`Undetermined`) is classified, and an
UNKNOWN value is a refusal.

**A send and the report about it meet on the provider's id, because the provider
owns the `Message-ID`.** `Courier.Deliver` writes courier's own id into the
`Message-ID` header and records it as `outbox_events.subject`, and
`Courier.InboundReports.with_data/2` used to join a report back to that send on
`subject` alone. That assumed the provider quotes courier's id. Cloudflare owns
the header — it refuses a caller-supplied one with `400 / 10202` and returns its
own `result.message_id` — so a real password reset was recorded as
`subject = courier-2be282f1-…`, the provider's bounce quoted a different id, and
`Courier.InboundReports` logged `courier holds no sent message for Message-ID
"…"` for a message courier really sent. So courier keeps its own id (every
existing row, the published envelope and the platform's events are keyed on it)
and records the adapter's receipt id **beside** it in
`outbox_events.provider_message_id`, in the same transaction as the send —
`Courier.Deliver.send_and_record/4` has the receipt in hand exactly there, and a
crash before the write would lose the correlation for a message that went out.
`sent_for/1` then matches each candidate `Message-ID` against **both** columns.
Two rules that look like details and are not: a receipt with **no** id (a 2xx
whose body carries no `message_id`, a shape the adapter supports deliberately)
records `nil` and courier invents nothing, because the existing "holds no sent
message" warning is then the honest answer; and the provider's id goes in a
**column**, not in the event's `data`, because `courier.email.delivered`'s schema
in `cafaye/core` is `additionalProperties: false` and a fifth key would fail
core's own schema on the bus. `test/courier/bounce_correlation_test.exs` drives
both halves for real — a send through `Courier.Adapters.CloudflareEmail` against
a real HTTP fixture, and a signed `POST /inbound/resend` quoting the id it
returned — and its join assertion goes red if the query stops reading
`provider_message_id` while the storage assertion goes red if the column is left
unwritten.

**An outbox row is written by `Courier.Outbox.insert/1` and by nothing else, and
that function enqueues the relay in the caller's transaction.** courier had three
Oban workers and no producer for 1301 green tests: `Oban.insert` appeared zero
times in `lib/`, there was no cron plugin, and `Courier.Application` started Oban
and left it empty, so a send wrote a durable row that nothing would ever publish.
The gap was one layer out from every worker test, because a test that drives
`perform/1` proves the consumer works and says nothing about who calls it.

Four rules, and each is a place the obvious version is wrong:

  * **The enqueue is inside the transaction, so the window is empty rather than
    small.** Enqueueing after the COMMIT reintroduces "the state changed and
    nobody was told" from the other side: the process dies between the two and the
    row is unpublished forever with nothing in the database saying so.
    `outbox_enqueue_config_test.exs` asserts the ROLLBACK as a pair — no row **and**
    no job — because a job outliving its row is a relay that claims nothing and
    reports success.
  * **Both writers go through the one function.** `Courier.Deliver` and
    `Courier.InboundReports` are the two places courier writes `outbox_events`, and
    enqueueing from only the first would leave every bounce and complaint in the
    same unreached state. There is no third one; add it here, not in a caller.
  * **The job is unique on the EVENT id**, `period: :infinity, states: :incomplete`.
    `fields: [:worker]` is the obvious key and it is wrong twice: Oban takes
    `pg_advisory_xact_lock` around a unique insert and an xact lock is held to the
    end of the transaction, so one key for the worker serialises every concurrent
    send for the length of the provider's dial; and it strands every send past the
    first until the next sweep. And `states:` is the **bare group** — `[:incomplete]`
    reaches PostgreSQL as the literal state `"incomplete"` and the `oban_job_state`
    enum refuses it (measured: 22P02), because `Oban.Job.cast_unique_group/1`
    expands an atom and passes a list through.
  * **The crontab in `config/config.exs` is the FLOOR, not a second design.** It is
    mandatory rather than belt-and-braces for `DeliverWebhookWorker`, whose
    deliveries become due by the *clock* — `next_attempt_at` is written five minutes
    into the future by the failure that set it, so there is no write to hang an
    enqueue on. `config/test.exs` sets `testing: :manual`, under which Oban starts no
    plugins at all (`deps/oban/lib/oban/config.ex:108`), so the suite cannot observe
    a timer; `Courier.OutboxEnqueueTest` therefore starts `Oban.Cron` itself, with
    courier's own crontab out of application env, under its own instance name and
    its own leader peer. Asserting the crontab is *configured* would be a comment
    with a test's name on it.

  One finding this packet deliberately did **not** fix, because fixing it would
  mean inventing an event nobody has decided to emit: **nothing in courier writes an
  account-scoped outbox event.** `DispatchWebhooksWorker` claims rows with an
  `account_id`, both writers emit events for a *person* and set none, so that
  crontab entry now runs every minute and correctly finds nothing. The fan-out has
  no producer; this packet gave the consumer a clock, and the producer is a
  decision.

**A webhook signature is not courier's to invent.** PLAN.md §7 adopted [Standard
Webhooks](https://www.standardwebhooks.com) and said "No custom scheme", which
means the base string is `msg_id.timestamp.payload`, the headers are
`webhook-id` / `webhook-timestamp` / `webhook-signature`, and a consumer can
verify a delivery with an official library without learning anything about
courier. `moon/refs/standard-webhooks/spec/standard-webhooks.md` is the authority;
cite the section in the moduledoc when you touch any of it. Renaming a header or
"improving" the base string breaks every customer integration at once, and the
only way to find out is from them.

**The signed bytes are the sent bytes.** The spec is explicit that re-serializing
a payload between signing and sending invalidates the signature. Encode once,
sign that binary, send that binary.

**Every URL a customer gives courier passes `Courier.Webhooks.UrlGuard` before
it is stored, and the address the sender dials is the one the guard checked.**
courier will HMAC a request to an attacker-chosen URL, so this is the difference
between a webhook sender and an SSRF proxy. The guard resolves the host, refuses
the URL if *any* answer is a blocked address, and returns the resolved address —
not the name — so there is no second, unchecked lookup. If you add a way to set an
endpoint's URL anywhere else, run the guard there too; a table full of
`169.254.169.254` for whatever reads it first is the failure mode.

**A signing secret is never in the database in the clear.** `Courier.SecretBox`
seals it with AES-256-GCM under `COURIER_SECRET_BOX_KEY`, and the plaintext exists
in exactly two places: the single `201` that hands it to the customer, and the
process signing with it. The tests read the column as raw SQL for that reason.
A hash is not an option here — courier has to sign *with* the bytes.

**A retry budget is bounded and visible, and there are two of them.**
`config :courier, :webhooks` holds `max_attempts` (per delivery) and
`circuit_threshold` (per endpoint), plus the backoff base, cap and jitter
divisor. PLAN.md §7 forbids naive retries, which means the numbers live in
configuration an operator can read, not in a constant inside a worker.

**Nothing sleeps.** The backoff schedule is asserted on the recorded
`next_attempt_at` and on `backoff/1`'s return value. A test that waits for a
five-minute window is a test that takes five minutes, and one that lowers the
window to make it fast is a test that stopped checking the schedule.

**A wait in a test is a claim about causality, and a bounded poll is not one.**
`error_relay_test.exs` failed about one run in three for three separate workers
before `courier-26b` and none of them caused it. The cause was one line — an
`eventually/3` helper that polled two hundred times and gave up — and it is worth
stating as a rule because the shape recurs. **A count of iterations is a proxy
for a duration, and the proxy is only as good as the machine it ran on:** two
hundred `:sys.get_state/1` round trips measured 0.6 ms to 2.2 ms of wall clock on
the same code on the same test, while the thing being waited for arrived 0.4 ms
to 36 ms later. Whichever was bigger won. So the wait has to be chosen by **who
writes the fact being asserted**, and there are exactly three answers:

  * **the process under test writes it** — `:sys.get_state/1`. A barrier, not a
    wait: the cast is ahead of the system message in the mailbox.
  * **a process one cast deeper writes it** — `:sys.get_state/1` on that process
    too, and the ordering of the two calls is the argument. This one is still a
    **race against scheduling latency**: measured, it returns before the work is
    done in 13%–25% of rounds on a machine at load average 30.
  * **a `Task` writes it** — `Process.monitor/1` and `assert_receive` on the
    `:DOWN`. The drain cannot exit before it has written its counters, so
    observing the exit observes the write. Measured 0 misses in 180 rounds where
    the `:sys.get_state` version missed 34.

A poll is not always wrong, but **a test must never assert on silence** — "nothing
arrived within the window" is a claim about the scheduler, not about the code.
`assert` on the counter the process itself increments, after a barrier, and the
counter and the messages bound each other. `courier-26b` reports the before and
after numbers, the mutation that proves the assertion still bites, and the two
other places in this suite that carry the same risk.

**An authorization decision is a 404, not a 403, for anything the caller cannot
see.** Core's `docs/openapi-conventions.md` says 403 "leaks existence". The
account comes from `conn.assigns.current_account`, never from a request body —
`CourierWeb.Plugs.Principal` is a seam with a refusing default, so a courier
without identity's JWT verifier is locked rather than open.

**The door has a key now, and the key is `account_id`.** `Courier.Principal.
Introspection` is what `config :courier, :principal` names outside test: it reads
the caller's token from `Authorization: Bearer` and asks identity
`POST /v1/introspections`. The token is **opaque** — `cafaye_` plus random bytes,
SHA-256 in the row — so there is no claim to read locally and no key to verify
against, and asking identity is the only way to learn an `account_id`. Four rules
came out of writing it, and each is a place the obvious version is wrong:

  * **`account_id` is the only tenancy key and there is no `sub` fallback.**
    `sub` is the *user* a token names. `Document.account_id/1` uses
    `Map.fetch/2` **with no default argument**, which is what makes the fallback
    inexpressible in the one function that decides the account — and the subject
    is read two functions below and is a perfectly good uuid, which is exactly
    why a `||` would be so easy to write by accident. A document that is active
    and carries no `account_id` is `:error` (a 401), because a token courier
    cannot place is a caller courier cannot serve. An `account_id` that is
    *present and malformed* is `{:error, :unreadable}` (a 503), because identity
    said something courier does not understand, and reporting that as an answer
    is how courier ends up logging somebody in as the account `"not-a-uuid"`.
  * **One answer for every unusable token.** Unknown, revoked, expired and
    orphaned all arrive as `200 {"active": false}` and courier does not
    re-expand them. There is no branch on `exp`, no clock, and no `revoked`
    claim anywhere in `Document` — the structural reason the four cannot come
    apart. `identity`'s `mayIntrospect` runs the standing check *after* the
    token resolves, so an unknown token is inactive for everybody.
  * **Both scope claim names are read, and neither is assumed absent.** `scopes`
    and `scope` are emitted byte for byte because the fleet has not agreed on
    one (MD7, open in the manager's `cafaye/notes/decisions.md`): core requires `scopes`,
    gateway reads `scope`. courier reads the union. A claim that is present and is
    **not a string** is `{:error, :unreadable}` rather than an empty set — the
    array is the shape a losing side of MD7 could adopt, and reading it as "no
    scopes" is the silent version of that bug. The clause order matters: `:error`
    before the malformed clause, because a bare `_absent` variable matches
    everything after it. That was a real bug, caught by a test.
  * **`scopes` is parsed and deliberately NOT enforced.** `Courier.Principal`
    gained a `scopes` field and nothing reads it to make a decision, and that is
    a decision with a **measured** reason: identity's vocabulary is a closed set
    of six (`accounts:read`, `accounts:write`, `accounts:delete`,
    `oidc_clients:write`, `audit_log:read`, `account_invitations:write`), and
    **not one of the five scopes `openapi.yaml` declares** (`webhooks:read`,
    `webhooks:write`, `notifications:read`, `notifications:write`,
    `messages:write`) can be minted by it. A scope check written today would
    refuse every credential identity is able to issue. What courier enforces is
    tenancy. `openapi.yaml`'s `bearerAuth` says all of this where a client author
    reads it.

**Authentication is a network hop, so a dependency failure is a 503 and not a
401.** Every operation behind the plug can now answer `503`: identity
unreachable, slow, erroring, **or answering 401/403**, or answering in a shape
courier cannot read. Two of those are load-bearing and neither is obvious:

  * **identity's own 401 and 403 are courier's problem, not the caller's.**
    identity answers 401 when the credential *courier* presented is not one it
    accepts, and 403 when that credential may not ask about the token it named
    (`mayIntrospect`: a token caller may read *itself* and nothing else). Both
    are facts about this deployment. Reporting either as a 401 tells a customer
    to rotate a token that was never the problem, and an operator reads a wall
    of "invalid credentials" when the fault is one environment variable.
  * **A 200 courier cannot read is also a 503.** `Document.from/1` returns
    `{:error, :unreadable}` for that, and only an explicit `{"active": false}`
    is the `:error` that becomes a 401. A document that fails to *say* a token is
    usable has not said the token is unusable.

The alternative was to let the request through when identity cannot be reached,
and that is the thing this rule exists to prevent: a resolver that fails OPEN
under load is worse than `Reject`, because it fails *silently*. So is "no answer
means the session is still valid" — a caching temptation this repository refuses,
because a cached introspection answer is a revocation that has not taken effect
yet and the answer courier would serve from it is `account_id`. **There is no
cache**, and the cost is stated rather than assumed: courier's latency includes
identity's, and identity's outage is courier's outage.

**`{503, :unavailable}` is a third answer, and `CourierWeb.Plugs.Principal`
learned it.** `Courier.Principal.Resolver.answer` was `{:ok, principal} |
:error`, which was enough for a resolver that either knows or does not. A
resolver that has to **ask somebody** has a third case, and the plug is the only
place that can write the response, so it gained exactly one clause. **The 401
branch is untouched and that is a test, not a promise**:
`principal_config_test.exs` drives the same request through both resolvers and
asserts the two 401 envelopes are equal field for field — `type`, `code`,
`status`, `title`, `detail`, `instance` — dropping `trace_id` **by name** rather
than by a rule, because that field is per request by design and comparing two
requests' identities would fail for a reason that has nothing to do with the plug.
Every `/v1` operation now declares the 503 in `openapi.yaml`, and the header
says why; the document test holds it to the router in both directions, reading
the operation set out of `Phoenix.Router.route_info/4` rather than a list.

**What courier presents to introspect is `COURIER_IDENTITY_TOKEN`, and that was a
judgement call rather than an accident.** It is courier's own scoped API token,
in the environment, never in argv (anything on a command line is in `ps` output
and in a shell history) and never in a committed config file. It is never
logged and never part of a reason: every refusal is a symbol, and
`introspection_test.exs` captures real log output and asserts it is ABSENT —
which is the assertion worth more than "it logged something", because a boundary
that deletes everything passes that. **Rotation is identity's**: mint, redeploy,
revoke; nothing is cached to invalidate. `config/runtime.exs` **refuses to boot**
without it in prod, on the same rule as `COURIER_SECRET_BOX_KEY`: a resolver with
no credential authenticates nobody, and discovering that at boot is cheaper than
discovering it from a support ticket.

**RFC 7662 §2.1 lets courier forward the caller's own token, and courier does
not.** identity implements that affordance — "a token may introspect **itself**"
— so forwarding would need no second secret at all. It covers **only the token
identity is holding**, so any other tenant's token is a 403: a door shut for
every real tenant and open for exactly the one account that owns courier's own
service token. That is the worst shape a credential can have, so courier presents
its own and **reports identity's 403 as a 503** rather than pretending a tenant
can authenticate. The contract gap is in the packet report, not fixed here.

**No credential appears in argv, in a committed file, or in a log, and the whole
class of leaks here starts with a *body*.** `introspection_test.exs` asserts the
caller's token, courier's own token, and the account id are all absent from
captured output. `Transport.Req` sets `decode_body: false` so **courier** decodes
the answer, in `Document`, where the rules about what an unreadable answer means
are written down — `Req`'s default decoder hands back a map, `to_string/1` on a
map raises `String.Chars`, and the first draft did exactly that. The 2s
`receive_timeout`, `retry: false`, `redirect: false` and `max_redirects: 0` are
merged AFTER `:introspection_req_options` so nothing in `config/` can switch
them off: they are decisions, not settings.

**A request with no bearer is refused WITHOUT calling identity.** Not an
optimisation — an unauthenticated endpoint that dials a dependency per request
is a load generator pointed at identity by anybody who finds courier's URL. And
the test resolver's `x-courier-account` header is ignored by this resolver, which
is asserted over a real resolver call rather than left as a convention: a header
that becomes a fast path is an authentication bypass with a config file attached.

**A seam is tested from both sides or it is not tested.** The resolver's tests run
against `Courier.TestSupport.IntrospectionTransport`, a table; the shipped
`Transport.Req` runs against Req's own `plug: {Req.Test, …}`. A suite that only
ever answers from a table proves nothing about the request courier really builds,
and the symptom of a wrong header or path is a 403 from identity that looks
exactly like a misconfigured credential. The stub is registered in `setup`, not
`setup_all`: `Req.Test` uses nimble_ownership, and a stub set in `setup_all`
belongs to a process that has exited by the time the first test runs.

**Nothing sleeps, including the introspection dial's own budget.** The 2s timeout
is asserted as a number on `Transport.Req.receive_timeout_ms/0` rather than as
the fact that one exists, and no test waits for it.

**One span-attribute allowlist, in `Courier.Observability`, and it is a
choke point rather than a convention.** Every attribute courier records goes
through `Courier.Observability.record/2`, which drops anything not on the list;
the list is projected from `core/schemas/telemetry/*.schema.json`. That is the
whole defence, and its realistic failure is not an attacker — it is a
well-meaning engineer in six months adding `record(span, %{"courier.payload" =>
params})` because it would help debug a delivery, in the one service in the
fleet whose payloads are other customers' data. So:

  * **Do not call `span.set_attribute/3` directly.** There is one recorder and
    it filters. A `set_attribute` on a span courier owns bypasses the allowlist
    by exactly as much as the engine will later strip — which is to say it
    succeeds.
  * **`http.route` is the route TEMPLATE**, from `Phoenix.Router.route_info/4`,
    never `conn.request_path`. A template has one value per endpoint; a concrete
    path has one per request, and kit's collector derives metrics with a
    `spanmetrics` connector that mints a series per distinct value. A 404
    therefore carries **no** route at all: the path there is caller-controlled
    text, which is both the cardinality bomb and the content leak in one move.
  * **4xx is not an error span.** Only 5xx is. A 401 or a 404 is courier
    refusing, which is courier working; an error rate that counts it is a
    function of how much guessing the platform absorbs, and an alert on it pages
    somebody to switch off the protection doing its job.
  * **No `tenant_id` on a span.** It is a resource attribute, and
    `test/courier/telemetry_test.exs` holds the resource's own shape.

`test/courier/telemetry_canary_test.exs` is the proof and it is not optional: it
plants a canary in every field a caller controls — path, query, headers, body —
drives real requests through the real router, and raises
`THE REDACTION BOUNDARY LEAKED` if it finds one in anything exported. **Every
absence assertion in that file is paired with a presence one**, because a
redaction boundary that deletes everything passes "no canary" and is useless:
three separate bugs left this suite green with nothing exported at all (an
exporter implementing `export/3` where the callback is `export/4`; an `init/1`
returning `:ok` where `{:ok, state}` was required; a `record/2` guarded on
`is_map(span)` when a span is a record). `Courier.TestSpans.rendered!/0` raises
rather than returning an empty string so that shape cannot recur silently.

**Six defects meant courier exported NOTHING, and every telemetry test in this
repository passed while that was true.** The fleet measured it on 2026-09-30. The
reason the suite was blind is the whole shape of the problem:
`telemetry_test.exs` asserts the rules, `observability_test.exs` asserts the
allowlist, and `telemetry_canary_test.exs` asserts a canary is absent from an
export — **and all three were green on a courier that never made a socket.** A
canary's absence is satisfied by an absent span, so the one test whose subject is
the export proved nothing about it. `test/courier/otel_export_test.exs` is the
answer: it drives the REAL `:opentelemetry_exporter` and the REAL
`:otel_otlp_traces` encoder over courier's REAL pending table and resource. No
stand-in, because every defect below is a disagreement BETWEEN courier and a
module that is not courier — and a hand-built exporter agrees with a hand-built
caller by construction. Each was measured before it was fixed:

  * **The exporter was never initialized.** `Courier.SpanCollector` called
    `export(:traces, spans, resource, %{})`, and the fourth argument is an
    `#state{}` RECORD. `%{}` matches none of `otel_exporter_traces_otlp:export/3`'s
    three real clauses, so every flush took the catch-all and answered
    `{:error, :unimplemented}` — forever, on a build whose startup line said
    telemetry was on. `Courier.Telemetry.init_exporter/1` now builds that state,
    and it is cached in `:persistent_term` because the exporter's state holds an
    `httpc` profile named after the process that built it.
  * **The spans were not in the shape the encoder reads.** `to_proto/2` wants an
    ETS table keyed by `#span.instrumentation_scope` holding bare `#span{}`
    records — which is exactly what `otel_batch_processor:new_export_table/1`
    builds — and courier's queue is keyed by `:erlang.unique_integer()`. With a
    real state, the export raised inside the exporter on courier's own queue key:
    `FunctionClauseError` with `-576460752303345823` where a scope was wanted.
  * **The resource was not a resource.** `otel_resource:attributes/1` matches an
    `#opentelemetry_resource{}` record and answers `undefined` for anything else,
    and attribute names are FLAT dotted strings. courier's
    `%{service: %{name: "courier"}}` is not `"service.name"`, so it encoded as one
    string-valued attribute and HyperDX's `service.name=courier` group did not
    exist. `Courier.Telemetry.otel_resource/0` is the conversion, and `resource/0`
    keeps its tested shape — a second function rather than a change, because the
    nested map is what a human reads and the flat one is what the exporter encodes.
  * **`extract/5` was passed an EMPTY extractor list**, which is not "use the
    default" but "extract nothing". No inbound `traceparent` was ever parsed, so
    every request started a new trace.
  * **`get_header/2` answered `nil` for an absent header.** The SDK's own
    `default_carrier_get/2` answers `undefined`, and `otel_tracestate:
    decode_header/1` has a clause for `undefined` and none for `nil` — so it
    reached `string:lexemes_m(nil, …)`, raised, and the composite propagator
    **caught** it and returned the context unchanged. A `traceparent` with no
    `tracestate` beside it was silently discarded, which is the overwhelmingly
    common shape of the header.
  * **The kill switch BOOTED courier instead of turning telemetry off.**
    `sdk_config/0`'s disabled path set `span_processor: :otel_simple_processor`,
    a bare atom, and `otel_configuration:processors/2` wraps that key's value in
    a one-element list and maps `{Name, Opts}` PAIRS over it. So
    `OTEL_SDK_DISABLED=true` was `Could not start application opentelemetry`. The
    key is now OMITTED with `processors: []`, which is a true no-op.

**Two of those were invisible for reasons worth keeping written down.** The
extractor list and the `nil` getter BOTH fail silently, because
`otel_propagator_text_map_composite:run_extractors/5` catches an extractor's
exception and returns the context unchanged — so a broken getter is
indistinguishable from "no traceparent was sent". And nothing caught the kill
switch because `config/runtime.exs` guards the SDK block with
`config_env() != :test`, so the disabled configuration was never evaluated against
a running SDK. **An assertion about a configuration is not a boot**, and
`telemetry_test.exs` asserted a keyword list for exactly as long as that sentence
was untrue.

**A refusal is now a REFUSAL rather than a crash, and the classification is
asserted on the exporter's real return values.** The exporter answers a bare
`error` ATOM (`otel_exporter_otlp:export_http/6` returns `ok | error`), and the
old `case` had an arm for `{:error, reason}` and none for `error` — so a refused
POST raised `CaseClauseError` and was swallowed by the catch-all as "the span
exporter raised", making a refused POST and a broken exporter indistinguishable
in the log. `Courier.SpanCollector.export_pending/1` classifies `:ok`, a bare
`error`, `{:error, reason}` and a RAISE, re-queues on anything but `:ok`, and
`last_failure/0` keeps the last reason readable — because "nothing to render (0
spans in)" arriving from six test files at once is the shape these defects had,
and the reason was visible only on one log line nobody was reading.

**The drain is atomic, because `on_end/1` inserts from any request process.**
`tab2list` followed by `delete_all_objects` dropped whatever landed between the
two; `ets:take/2` per key does not. It is deliberately NOT `ets:take/2` with
`[:reference]`, which answers a REFERENCE that neither `ets:tab2list/1` nor
`ets:match_object/2` accepts (`ArgumentError: not an atom or a table identifier`,
measured on OTP 29).

**Metrics come from the collector's `spanmetrics` connector, not from courier.**
`ls deps/opentelemetry/src | grep -c metric` is `0` — the Erlang SDK ships no
metrics API at all — so there is no second implementation to be inconsistent
with kit's, and no risk of two series with the same name and different
definitions. It also runs *after* redaction, which means a derived metric can
never carry a dimension the allowlist stripped. The cost is honest and worth
stating: courier cannot emit a gauge, so **a stalled outbox relay is invisible
on the metrics signal** and shows up only as a flat trace count.

## Environment

`DATABASE_URL`, `SECRET_KEY_BASE` and `PHX_HOST`, as any Phoenix release needs,
plus one this packet added:

- **`COURIER_SECRET_BOX_KEY`** — 32 bytes, base64, the key every webhook signing
  secret is sealed under (`openssl rand -base64 32`). Required in prod and
  never defaulted: a default would be a key in version control that every
  deployment which forgot to set one would seal its customers' credentials
  under. `config/test.exs` sets a fixed one; losing the production key means
  every stored secret has to be re-issued, because the plaintext cannot be
  recovered from the ciphertext.

And one this packet added for observability, which is optional everywhere:

- **`COURIER_OTEL_ENDPOINT`** — the OTLP endpoint, defaulted to
  `http://otel-collector:4318`, which is the collector that ships with kit's
  stack (core D16: this variable is the only contract, and the collector is
  just its default value). Point it at anything speaking OTLP and courier goes
  there instead; unset it and courier exports into a collector that is not
  running, which costs spans and nothing else — there is no queue, no retry loop
  and no dial at boot. `COURIER_TENANT_ID` and `DEPLOYMENT_ENVIRONMENT` are
  resource attributes, not measurements, and both are unset by default.
  `config/runtime.exs` guards the whole block with `config_env() != :test`: that
  guard is load-bearing, because `runtime.exs` runs *after* `test.exs` and an
  unguarded line would replace the suite's in-memory exporter with a real one —
  and every redaction test asserts the **absence** of a canary, so with nothing
  exporting they would all go green having proved nothing.

And one from the event bus, which is optional everywhere and is the one variable
whose unset state courier is designed to live in indefinitely:

- **`NATS_URL`** — the broker courier's outbox relay publishes to, in the
  `nats://HOST:PORT` or `tls://HOST:PORT` form. **Unset is a supported state,
  not an error**: `Courier.Nats.supervised_child/0` answers `[]` so the
  application starts no connection, no retry loop and no publisher that could
  report events as delivered, and `config/runtime.exs` configures
  `Courier.NatsPublisher.Unconfigured` — which refuses every envelope, so rows
  accumulate in `outbox_events` with `nats_url_not_set` in `last_error`. That is
  the honest accumulation identity names ("the rows are the promise"), and it is
  why **the `Noop` publisher is configured in `config/test.exs` and nowhere
  else**: a stand-in that answers `:ok` wired into the running service would
  mark every event published and drain the outbox into nowhere. Set the variable
  and both halves appear: `Courier.Nats` (a supervised process that dials, and
  retries on a fixed 5s interval without ever taking the application down — a
  broker that is **down** is not a boot failure) and
  `Courier.NatsPublisher.Bus`, which publishes each row on the subject its event
  `type` names — no mapping table, core's rule — as a JetStream request-reply, so
  `published_at` is set from the broker's own ack. **A URL that does not parse
  IS a boot refusal** (`{:stop, {:nats_url_does_not_name_a_broker, url}}`): a
  typo is a deployment that believes it has a bus and does not, and that belongs
  at boot where an operator reads it. An empty string counts as unset. The stack
  must define a JetStream stream whose subject filter covers what courier
  publishes: kit's `cafaye` stream carries
  `identity.>,billing.>,courier.>,muse.>,darkroom.>`
  (`kit/templates/compose/docker-compose.yml:540` and
  `kit/templates/substrate/install.sh:1365`), which `courier.email.delivered`
  and the rest of the `courier.` catalog match — measured against a real
  broker, `REPORT-courier-brk2-outbox-publisher`'s stream section. It is not
  in `docker-compose.yml` yet; the dev stack publishes when one line
  (`NATS_URL: nats://nats:4222` in the courier service) is added.

And eight from the provider adapter, all read from `config/runtime.exs` by
`Courier.MailerAdapter`, **required in every environment including test** and
never committed to a config file. Only the four with a correct default are
defaulted (`COURIER_SMTP_PORT` 587, `COURIER_SMTP_AUTH` and `COURIER_SMTP_TLS`
`always`, `COURIER_SMTP_SSL` `false`); the adapter itself is required, because an
adapter with a default is wrong for exactly the deployments nobody is watching.

And two from the door, read by `Courier.Principal.Introspection`, where **the
asymmetry between them is the decision**:

- **`COURIER_IDENTITY_TOKEN`** — courier's own scoped API token, presented as the
  `Authorization` header on identity's introspection call. **Required in prod,
  never defaulted, and refused at boot**: a default would be a credential in
  version control that every deployment which forgot one would authenticate
  callers with. Mint one with `POST /v1/accounts/{account_id}/api-keys` in an
  account that belongs to courier and to nothing else; rotate by minting a new
  one, redeploying and revoking the old — there is no cache to invalidate.
  `config/test.exs` sets a fixed one, on the same terms as
  `COURIER_SECRET_BOX_KEY`. **It must be the same key identity presents as its
  own `COURIER_TOKEN`**: identity's introspection endpoint lets a token caller
  introspect only itself, so one key is held by both services — identity
  presents it outbound, courier presents it to introspect the inbound request.
  Two distinct keys produce identity's 403 and courier's 503, and the symptom is
  indistinguishable from a network fault. Tightening identity's rule is
  identity's decision (packet m65), not courier's.
- **`COURIER_IDENTITY_URL`** — identity's base URL, defaulted to
  `http://identity:8080` (the compose-network name, and identity's own port —
  its Dockerfile `EXPOSE 8080`, its compose `PORT: "8080"`; the same shape as
  `COURIER_OTEL_ENDPOINT`'s default). A wrong URL is a **503 on every
  authenticated request**: loud, diagnosable and retriable — which is why
  making a dependency's address a boot requirement would turn "identity moved"
  into a stop-the-world upgrade gate for a service that is otherwise fine.
  `config/runtime.exs`'s default is the single authority: the compose file
  deliberately does not restate it, `Introspection.url/0`'s fallback agrees with
  it, and `config/deploy.yml` states it explicitly because that is the one a
  production courier reads. `test/courier/principal/introspection_url_test.exs`
  holds all of them together and greps the tree for the two wrong values.

- **`COURIER_MAIL_ADAPTER`** — `smtp` | `postmark` | `cloudflare`. `none` is
  `Swoosh.Adapters.Local` and is **refused in production**. Unset is a boot
  failure, not a fallback to `none`. A module name is not a value: the variable
  names a provider from a fixed set, so `Swoosh.Adapters.Local` cannot be spelled
  here even if somebody wants it to. `cloudflare` is not the Cloudflare
  dashboard's own API: Email Routing is receive-only, and the sending half of a
  Cloudflare Email connection is the **MailChannels transactional API**, which
  is what `Courier.Adapters.CloudflareEmail` posts to. Domain authorisation is
  W3-P5, not this variable.
- **`COURIER_POSTMARK_API_TOKEN`** — required when the adapter is `postmark`.
- **`COURIER_CLOUDFLARE_API_KEY`** — required when the adapter is `cloudflare`;
  the MailChannels API key, required rather than defaulted for the same reason,
  and never rendered by `describe/1`, which says only `token=set` /
  `token=unset`.
- **`COURIER_SMTP_HOST`** — required when the adapter is `smtp`.
- **`COURIER_SMTP_USERNAME`** / **`COURIER_SMTP_PASSWORD`** — required unless
  `COURIER_SMTP_AUTH=never`, because `gen_smtp` refuses `auth: :always` without
  both halves at the socket, and a per-send failure there is the same defect one
  layer out.
- **`COURIER_SMTP_AUTH`** — `always` (default), `never`, `if_available`.
- **`COURIER_SMTP_TLS`** — `always` (default), `never`, `if_available`.
- **`COURIER_SMTP_SSL`** — `false` by default; `true` for implicit TLS, usually
  on 465.

An empty string counts as **unset** for all of them: `SMTP_PASSWORD=` in a compose
file produces `""`, and an empty password sent to a provider comes back as a 535
the operator has no way to explain. Losing `COURIER_MAIL_ADAPTER` means courier
does not start, which is the point — it is the cheapest possible way to find out,
and it happens before the first customer mail rather than after a support ticket.

For templates, without a relay: `COURIER_MAIL_ADAPTER=none mix phx.server`.

**And one the one-click unsubscribe deliberately did not add.**
`COURIER_PUBLIC_URL` is the name you would reach for first, and it is not here: RFC
8058 §3.1 requires the `List-Unsubscribe` header to carry an **HTTPS** URI, and
courier already has exactly one setting that says what its public URL is —
`PHX_HOST`, which `config/runtime.exs` turns into
`url: [host: host, port: 443, scheme: "https"]`. `Courier.Unsubscribes.base_url/0`
builds the header from that, so there is no second variable that can be right for
the endpoint and wrong for the header, and nothing new an operator can forget.
`test/courier/unsubscribes_test.exs` reads the scheme out of production's own
configuration — evaluating `config/runtime.exs` as a boot, with the variables a boot
needs — so the requirement is measured rather than asserted about a comment.

## Toolchain

mise, from `mise.toml`: `mise install`, then `mise run prime` for the gate.
For container work: `bin/dev` brings up the **shared** kit postgres cluster
(`kit-postgres:17`, one database and one role per service) with the release
image, and `bin/dev down` stops it keeping every volume. `bin/dev nuke` is the
only destructive step, and since the cluster is shared it now discards every
service's data in it, not courier's alone.

`docker compose up --build` on its own no longer works, and that is the point:
courier's `docker-compose.yml` is an **override**, not a stack. Read alone it
has no network and no `depends_on`, and `bin/dev` is what merges it with the
pinned kit stack (`kit.ref`) to produce a runnable one.

## Generated rules

Everything below this line is the Phoenix 1.8 generator's own guidance, kept
between its `usage-rules` markers so `mix phx.new` upgrades can replace it. The
HTML, LiveView, Tailwind, and icon rules are inert here — courier has no HTML
layer — but the Elixir, Mix, Test, and Ecto rules all apply.

This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->
## Secrets
- No `.env` files with values. Use `cafe secret set/get/list` (dev) and `cafe dev` (injects). See `docs/secrets.md`.

## Packet identifiers

`REPORT-x`, `HANDOFF-x` and `MEASUREMENTS-x` name **work packets, not
files**. The written reports were removed on 2026-10-20: duplicated across
repositories, owned by nobody, rotting faster than they were read. What
survives of a packet is its entry in `CHANGELOG.md` and, where a decision was
made, in `DECISIONS.md`. A citation to a packet id points at that entry.
