# Changelog

All notable changes to cafaye **courier** are recorded here. courier is a
service, so "notable" means *a change to the HTTP surface, the event contract,
or the way it is built and run* — not a refactor that a caller cannot see.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once courier is past `0.1.0`. The manifest records the platform-facing contract
surface in [`cafaye.yml`](cafaye.yml); a change to the events or the API
document lands in both files in one commit, because core asserts the two agree.

## [Unreleased]

### Added

- **The receipt: a subscription nobody had consumed, on the money event that
  named it.** `Courier.Consumers.PaymentSucceeded` consumes
  `billing.payment.succeeded` and sends the mail a person is owed when money
  moves — the whole-cafaye-stack walk found the event landing on the bus with
  nothing subscribed to it, a settled charge nobody was ever told about. The
  payload was built for this from the start (billing-event-payloads-01's
  recipient fact), and this is the consumer that fact was waiting for.

  **The seventh type, `receipt`** — transactional, no unsubscribe header, with
  the amount rendered by the consumer (`19.00 USD`; zero-decimal currencies at
  zero) because courier has no Money concept and a template must never compute
  a figure. The invoice id is the optional field of the catalog: an
  invoice-backed payment carries one and a payment-mode Checkout does not, and
  dropping receipts for the second shape would drop receipts for payments the
  platform legitimately produces.

  **Two decisions, stated in the report rather than in a commit line.** The
  delivered event's `user_id` carries the cafaye CUSTOMER this event names —
  the send is attributed to the payer, not to a person, and the preference
  check is vacuous while the address-suppression check is unchanged. And the
  attribution is a customer id because billing has no users and the consumer
  rule forbids looking anybody up. Reported with the core enum gap in
  `REPORT-courier-consumer-paymentreceipt-01.md`.

- **A third provider: Cloudflare Email, through the same
  `COURIER_MAIL_ADAPTER` seam.** Cloudflare Email Routing is receive-only and
  has no send API; the sending half of a Cloudflare Email connection is the
  **MailChannels transactional API**, so `Courier.Adapters.CloudflareEmail`
  posts to `POST https://api.mailchannels.net/tx/v1/send` with `X-Api-Key`
  and a `personalizations` / `from` / `subject` / `content` body. One
  variable, `COURIER_CLOUDFLARE_API_KEY`, required rather than defaulted and
  refused at boot when missing or empty — the same refusal the SMTP and
  Postmark variables get, generated from the same provider table rather than
  a per-provider branch. `describe/1` says `adapter=cloudflare token=set` and
  never the key. Domain authorisation (the `_mailchannels` TXT record and SPF)
  is a later packet's scope.

  **A provider that refuses a send is surfaced, never swallowed.** Every
  non-2xx is `{:error, {code, body}}` — the status and the provider's own
  error body, decoded when it is JSON — and a transport failure is
  `{:error, reason}`. There is no code path that returns `{:ok, _}` for a
  mail the provider did not accept, and that claim is proved against a REAL
  Bandit listener on a kernel-assigned loopback port
  (`Courier.TestSupport.MailChannelsServer`) rather than a stub: 14 tests in
  `test/courier/cloudflare_delivery_test.exs` drive the real
  `Courier.Adapters.CloudflareEmail` through the real
  `Swoosh.ApiClient.Req`, and assert on the bytes that arrived. Both halves
  of the contract are covered — the success receipt, and 403 / 500 / 400 with
  a non-JSON body / an unreachable endpoint / a missing key.

- **The SSL redirect is a runtime opt-in — `COURIER_FORCE_SSL` — so the
  launch stack can send mail.** `config/prod.exs` set compile-time
  `force_ssl` excluding only `localhost`/`127.0.0.1`, and the compose network
  talks courier-to-courier over plain HTTP on a private network: every
  `POST /v1/messages` on a non-localhost peer got `307 → https → 405`, which
  is what kept verify, reset and invitation mail RED in the site loop-proof.
  Genuine prod sets `COURIER_FORCE_SSL=true` and gets the redirect;
  everything without it serves plain HTTP. `/healthz` and `/readyz` answer
  plain HTTP either way. Proved red-first in
  `test/courier_web/plugs/force_ssl_test.exs` (9 tests: the compile-time key
  is gone, the signal maps onto the flag, the plug passes with it absent and
  307s with it present, the probes exempt in both).

- **A push to master now publishes courier's image and chart — the publish
  loop's missing end.** The substrate's Argo `Application` reads
  `repoURL: oci://ghcr.io/cafaye/charts` with `chart: courier` and
  `targetRevision: 0.1.0`, and kit's `m84` (W84) landed the publish half in
  kit itself: a reusable `publish.reusable.yml` and a caller template
  (`kit/templates/publish/publish.yml`) whose header says to copy it to
  `.github/workflows/publish.yml` in the service repository, verbatim. Measured
  on the merged trees: courier had not copied it, so the chart
  (`chart/`, `version: 0.1.0`) and the image its chart references were
  published by nothing — the substrate's `courier` Application pointed at a
  registry nothing wrote to. This packet copies the caller verbatim and proves
  it in courier's own gate, red-first.
  - **`.github/workflows/publish.yml` is kit's template, byte for byte.** No
    paraphrase, no re-derived permissions, no split: it is one `uses:` of the
    composed `publish.reusable.yml`, which builds and pushes the image and
    packages and pushes the chart. The composition lives in kit; a caller that
    inlines the steps has forked it. Courier's chart directory is `chart/`,
    which is the reusable workflow's own default, so the verbatim copy carries
    no `chart-dir:` input.
  - **`test/courier/chart_test.exs` proves the loop, red-first.** Six tests,
    all in the no-database tier: the caller exists, triggers on a push to
    master, calls `cafaye/kit/.github/workflows/publish.reusable.yml@master`,
    grants `packages: write` (a reusable workflow can request a permission but
    cannot grant itself one — omitting it is a 401 at the push that reads
    like a wrong password), passes `push: true` (the reusable workflows
    default to `false`, so a caller that omits it publishes nothing and says
    nothing), and names the chart directory whose `Chart.yaml` version equals
    the substrate's `targetRevision: 0.1.0` — the chart version IS the OCI
    tag, and the failure message names both sides. Three red controls, each
    run rather than described: the caller removed (6 red), `push: false`
    (1 red), the chart version bumped to `0.1.1` (2 red).
- **courier's chart has a way in — the Ingress W81 added to the generator,
  applied to a chart that predated it.** W85 generated `chart/` from a
  generator that had no Ingress, so the chart shipped with a `ClusterIP`
  Service and nothing declaring a way in — the exact gap LAUNCH D9 measured
  ("cert-manager is installed and asked for nothing"). W81 landed the fix in
  `cafe gen chart` (`chart/templates/ingress.yaml` plus an `ingress:` values
  block, off by default and gated on `ingress.enabled`); this packet brings
  the already-landed chart forward to match. The template is applied
  byte-for-byte as the generator emits it: the whole document inside
  `{{- if .Values.ingress.enabled }}`, a `fail` guard on enabled-with-no-host
  (an Ingress with no host is a silent misroute), the traefik class, and the
  backend port read from `.Values.service.port` so the Ingress and Service
  cannot disagree. `ingress.enabled` stays `false` and `ingress.host` stays
  empty — the template refuses to render an enabled Ingress with no host,
  which is the point.
  - **One deliberate, documented deviation from the generator:**
    `clusterIssuer` is `letsencrypt-prod` — the ClusterIssuer the
    substrate's install creates once per cluster (kit step 7, W83) — rather
    than the generator's empty default. The generator's default is the safe
    off-position (no TLS until a values commit names an issuer, "a secret
    nothing writes"); naming the issuer here means an enabled Ingress gets
    a certificate without a second values edit. The deviation is one line in
    `values.yaml` with a comment saying why, not a change to the generator
    — fixing `cafe gen chart` is cafe packet m88. Measured, not assumed: the
    packet brief said the generator defaults `clusterIssuer` to
    `letsencrypt-prod`; building and running the current generator
    (`1c8d4d3`) shows it emits `""`. The chart follows the brief's explicit
    requirement and reports the generator's actual output.
  - **`chart/README.md` gained the generator's "Reaching the service"
    section**, documenting the knob — the chart's operator guide was silent
    about a values block it now carries.
  - **`test/courier/chart_test.exs` proves the Ingress**, red-then-green:
    the template exists, the whole document is gated on `ingress.enabled`
    (an ungated Ingress is always-on), the no-host `fail` guard is present,
    the values block is off by default with the traefik class and the
    cluster's issuer, and the template wires `ingressClassName` from the
    value so the two cannot disagree about the edge.
- **courier has a Helm chart — the launch deploy artifact the substrate's
  `Application` pulls.** `chart/` is generated by `cafe gen chart` (cafe W72)
  and adjusted for courier: the image is `ghcr.io/cafaye/courier` with a
  versioned tag (never `latest`), secrets are referenced by name via
  `envFrom` (never inlined), the service port is 4000 (matching the
  container port), and the readiness probe is `/readyz` (baked into the
  template, not a value). The chart is the deploy artifact for the Argo
  `Application` in `kit/templates/substrate/manifests/applications/courier.yaml`
  — it is NOT a second deploy path. `DEPLOYMENT.md` is explicit that there
  is no helm-from-CI template in kit and one may never be added, because
  a second deploy path beside Argo is a split brain. The chart is pulled
  by Argo, or it does not run.
  - **`chart/templates/application.yaml` was removed deliberately.** The
    generator emits an Argo `Application` whose source is a git repo
    (`path: chart`), but the substrate already owns courier's `Application`
    (an OCI chart source) and applies it from `install.sh`. Two
    `Application`s named `courier` in `argocd` fight each other — split
    brain. The generated one was deleted, not ignored.
  - **`test/courier/chart_test.exs` proves the chart's content**, not that
    a file exists: the readiness path is `/readyz`, secrets are referenced
    and not inlined, the image tag is not `latest`, and `Chart.yaml`'s
    `name`/`version` are `courier`/`0.1.0` (the seam the `Application`'s
    `targetRevision` pins). The test is a plain `ExUnit.Case` — it reads
    files from disk and touches no database.
- **courier can send email through a second provider.** `COURIER_MAIL_ADAPTER`
  accepts `postmark` beside `smtp`, so "email, through more than one provider"
  is configuration rather than a code change. Postmark is transactional-only
  with API-token auth, matching the mail courier sends; Swoosh's own adapter
  is used, so no HTTP client was hand-written.
  - **`COURIER_POSTMARK_API_TOKEN` — required when the adapter is postmark**,
    refused at boot with the variable named when it is missing or empty. The
    provider set is one table (`Courier.MailerAdapter.providers/0`) naming
    each provider's Swoosh adapter, its Swoosh HTTP client (nil for SMTP,
    which dials `gen_smtp` directly), its variable builder, and its startup
    describer; `adapter!/1`, `describe/1`, the supported-values refusal and
    the new `api_client/1` all look the table up, so a third provider is an
    entry plus two functions rather than a fourth branch.
  - **The startup line names the provider and whether its token is set —
    never the token.** The same rule SMTP's line has, asserted by a canary
    in `test/courier/mailer_adapter_credentials_test.exs` against captured
    log output, paired with presence assertions so a line that printed
    nothing would not pass.
  - **`config/runtime.exs` turns Swoosh's HTTP client on from the resolved
    adapter** (`MailerAdapter.api_client/1`) rather than from a second
    variable: SMTP never calls it, Postmark posts through
    `Swoosh.ApiClient.Req`, and a deployment that configured the adapter and
    forgot the client would otherwise boot with both halves dark.
  - **No live send was exercised** — this machine has no provider account.
    The proof is configuration mapping and refusals; a real send needs a
    Postmark server token and would go through `Swoosh.Adapters.Postmark`
    unchanged.
- **courier can now remember what it told somebody.** Two tables —
  `notification_events` (one thing that happened, for an account) and
  `notifications` (that event addressed to one person, with `seen_at` and
  `read_at`) — and `Courier.Notifications` to write and read them. Before this, a
  notification courier delivered left no trace courier could later read:
  preferences existed to decide whether to send and nothing recorded what was
  sent, so *"what was I told about, and which of those have I read?"* had no
  answer. `parlor` renders an inbox from this; `openapi.yaml` is **unchanged**,
  because this packet adds no route (see the report for why).
  - **`account_id` is on BOTH tables, `NOT NULL`, in the FIRST migration.** The
    reference implementation's `noticed_events`/`noticed_notifications` carry no
    `account_id` and cannot be retrofitted cheaply here, because every
    row-level-security policy in this repository is written as
    `account_id = (select cafaye.current_account_id())`. Added later, that
    predicate is `NULL` for every existing row, which Postgres resolves as "not
    true" — so pre-existing rows become invisible to their own account rather
    than visible to another one. `cafaye.protect_table/2` is called for both
    tables, which is what installs `FORCE ROW LEVEL SECURITY`; the FORCE bit and
    the per-command policies are asserted from `pg_class` in
    `test/courier/notifications_boundary_test.exs`.
  - **The recipient is `NOT NULL`, and an event with no notification is a state
    `record/2` cannot produce.** An event addressed to nobody is a fan-out that
    has not happened, and an unread count that could see one would be a lie.
    `record/2` writes both rows in one transaction and **rolls it back** if the
    second write refuses — `Repo.transaction/1` whose function *returns* an
    error commits, so the rollback is the mechanism rather than the comment.
  - **`seen` and `read` are different facts and neither is cleared.** `seen_at`
    is "it appeared in a list"; `read_at` is "the person opened it". Both marks
    are idempotent — a second call returns the same row with the **first**
    timestamp — and `read_at` implies `seen_at` in the database
    (`check (read_at is null or seen_at is not null)`), because opening something
    is a stronger statement than seeing it and a deep link can open a
    notification that was never in a list.
  - **`params` is jsonb, not a rendered body.** The reference ships notification
    bodies as ERB fragments through `ApplicationController.render`; courier is
    API-only and renders nothing, so a consumer reads these keys and decides what
    a person sees. No template, body, partial or view was added.
  - **Six defects were found while writing it, and five of them were in this
    code rather than in the tree it was written against.** They are written down
    in `REPORT-courier-inapp-notifications-01.md` with the measurements; the two
    worth reading there are `Repo.transaction/1` wrapping its function's return
    (`record/2` answered `{:ok, {:ok, …}}` and 31 tests failed on a shape nobody
    had written down), and Ecto's `on_conflict: :nothing` documentation being
    true only for database-generated primary keys — with a client-generated uuid
    it returns the **proposed** struct, so the unique index fired correctly
    while the function handed its caller an id belonging to no row.

- **A recipient can unsubscribe from bulk mail with one click, and courier stops
  sending it.** Gmail and Yahoo's bulk-sender requirements (enforced since June
  2024) are about RFC 8058: a `List-Unsubscribe` header whose HTTPS URI a mail
  client `POST`s to on the recipient's behalf, with no session and no
  confirmation page. courier had none of it, and an email product that ships
  without it lands in spam. `Courier.Mailers.kinds/0` and
  `Courier.Unsubscribes` are the gate; `POST` and `GET /unsubscribe/{token}` are
  the door. `openapi.yaml` is at **2.3.0**: one additive path with two
  operations, a new tag, a new `UnsubscribeToken` parameter, an
  `UnsubscribeResult` schema, one new reusable response, and one new
  `errors[].code`. No existing path, verb, request field or response shape
  changed.
  - **The kind is the code's, not a caller's.** `Courier.Mailers.kinds/0` is a
    closed table over the types courier can send, and its default for an
    unclassified type is `:transactional` — so a new notification type cannot
    grow an unsubscribe link by omission. All three types are transactional
    today, so **nothing courier sends carries the header**, and that negative is
    asserted on real composed messages per type and on the raw SMTP `DATA` a
    real `gen_smtp` server received.
  - **The token in the path is the whole authorization**, and it is stored as a
    SHA-256 and never as itself: 32 bytes of `:crypto.strong_rand_bytes/1`, so a
    database dump is not a list of mailboxes anybody can unsubscribe. RFC 8058
    §3.1 forbids the request from carrying cookies or authorization at all, which
    is why the route is outside `/v1` and behind no auth plug; an unknown token
    is a **404** rather than a 401, because it is a resource's address. No status
    redirects (§3.1's MUST NOT), and a replay is the same 200 with the same
    body.
  - **An unsubscribe writes an `email_suppressions` row with no `state`**, and
    the absent state is the mechanism rather than a detail: a bounce and a
    complaint are facts about the mailbox and stop every type courier sends, so a
    stateful unsubscribe row would be a person who stops receiving product
    updates and then cannot reset their password. It publishes
    `courier.notification.suppressed` with `reason: "preference_off"` in the same
    transaction — the first caller that type has had, and the manifest already
    declared it.
  - **Two things the packet cannot deliver, stated rather than implied.** RFC 8058
    §4 requires a DKIM signature covering both headers and listed in the `h=`
    tag; courier submits through a relay and holds no private key for the sending
    domain, so the signing is the relay's. And an unsubscribe row is immutable,
    as every row in that table is, so **no route clears one** — the remedy for an
    accidental unsubscribe is another address, and a route that clears one belongs
    with the first bulk type rather than in this commit.

- **courier hears what happened to a message, and a hard-bounced address stops
  being mailed.** `Courier.Suppressions.ingest/1` was written, tested and
  documented as "the HTTP surface's entry point" — and nothing called it. The
  suppression table was therefore only ever written by tests, permanently empty in
  production, and a customer whose address hard-bounced was mailed again forever.
  That is how a sending domain's reputation dies, killed by the list meant to
  prevent it. `POST /inbound/resend` is the missing caller.
  - **The route is authenticated by a SIGNATURE, not a token, and it is outside
    `/v1`.** Both halves are the same argument: a provider is not a tenant. Resend
    signs with Svix and sends no bearer token, so behind
    `CourierWeb.Plugs.Principal` every delivery is a `401`; and behind no plug at
    all it is an unauthenticated `POST` that records suppressions, which anyone
    who finds the URL can use to suppress anyone's mail. Core's conventions settle
    it — "Inbound webhooks are **not** JWT-authenticated: they are signed, per the
    sender's convention, and the receiver checks the signature before parsing."
    Outside `/v1` because that prefix is courier's contract with a *tenant* and
    `PLAN.md` MD6 generates client SDKs from `openapi.yaml`: an operation filed
    there that cannot take a bearer token is a method a generated client calls
    wrongly.
  - **The order is mechanical, not a convention.** The signature is verified
    before the body is parsed, and **`CourierWeb.Plugs.ParseBody` now skips this
    route** — it is an *endpoint* plug, so it ran on every request, and
    `Plug.Parsers` would have decoded an unauthenticated body with the `:json`
    parser before the verifier ever saw it. Spec §Signature scheme names
    parse-then-re-serialize as "a very common failure mode" of verification, and
    the verifier's refusal of anything but the received bytes is only the right
    refusal if nothing upstream already rewrote them. The skip is keyed on a list
    the **router** owns, and `router_test.exs` asserts every path in it is a route
    the router serves, so a rename cannot leave it behind.
  - **Three statuses, because the three refusals are three different problems.**
    An unauthenticated request is a **401** whatever its body — a `400` would
    confirm that courier decoded a forged payload. A body courier cannot classify
    is a **422** with `errors[]` naming the field, because a `200` would be courier
    claiming it did something with a report it could not read. And a courier with
    no inbound secret is a **500** naming the variable, because
    `Courier.Inbound.Signature`'s moduledoc raises the objection directly: a route
    answering 401 to its own misconfiguration is indistinguishable from one under
    attack, "and the operator's first question would be the wrong one".
  - **A redelivery is a 200, and there is no `Idempotency-Key`.** A provider
    retrying a webhook it got no answer for is *normal*, not an error. The
    deduplication is `email_suppressions`'s unique index on
    `(provider, provider_event_id)`, which `Courier.Inbound.Resend` derives from
    the report's own **content** rather than from the `webhook-id` header — a
    stronger key, because one delivery can name many recipients and keying on the
    header would collapse a broadcast into one suppression and go on mailing four
    of five bounced addresses for ever. The header a provider sends is one no
    provider sends, and `CourierWeb.Plugs.Idempotency` is scoped to a principal
    this route has none of, deliberately.
  - **No response on this operation carries an email address.** Not the `200`
    counts, not a `422`'s `detail`, not a value echoed back from the payload.
    `email_suppressions` has no `account_id` and is not exposed through any route,
    so an address in a response is a way to query mailboxes courier holds — the
    same posture as the 409 on `POST /v1/messages`, which does not echo one
    either. The address is in courier's **logs**, which is where the parser's
    refusals put it, and `inbound_controller_test.exs` asserts a canary address is
    absent from all six of the answers its six requests produce.
  - **`COURIER_INBOUND_RESEND_SECRET` is required in prod and never defaulted.**
    Unset, every hard bounce and complaint is *discarded* while
    `POST /v1/messages` goes on mailing addresses that have permanently refused —
    the failure `Courier.Suppressions` exists to prevent, through the door meant
    to prevent it. It is the secret courier **verifies** with, copied from the
    provider's dashboard, and deliberately NOT the outbound signing secret: a
    deployment that leaked a customer's outbound secret must not thereby be able
    to forge inbound suppressions. One variable **per provider**, because a shared
    variable would make a second provider's configuration an edit to the first's.
  - **The body is bounded at 1 MiB before it is read.** The route is
    unauthenticated, an unbounded read is a denial of service handed to whoever
    finds the URL, and every documented provider report is a few kilobytes. The
    bound lives in `CourierWeb.InboundController.max_body_bytes/0` so the test
    that pads a body over it does not hard-code a copy of the number.

- **`courier.email.bounced` and `courier.email.complained` have a caller.** The
  previous packet added the builders, and an event builder with nothing behind it
  is the same lie as a catalog entry with nothing behind it. An accepted report
  now publishes its event, in the **same transaction** as the suppression row, so
  there is no suppression without the announcement and no announcement about a
  mailbox courier does not hold.
  - **`user_id` and `notification_type` are READ BACK from the send, not carried
    across.** `core/schemas/events/courier/email/bounced.schema.json` requires
    them and sets `additionalProperties: false`; a provider report carries a
    `Message-ID` and a recipient and never a user, and an event with a `null` user
    id is a payload core's own schema rejects on the bus. So courier joins
    `email_suppressions.message_id` to the `outbox_events` row `Courier.Deliver`
    wrote for that send and reads the fields it validated there. The test proves
    the join by really sending a message through `POST /v1/messages` and using the
    `message_id` the provider would have quoted.
  - **A report courier cannot tie to a send records its suppression and publishes
    no event**, with a log line naming the `Message-ID`. That is the one gap and
    it is in the DATA, not the mechanism — and it rolls the safe way: the row is
    the load-bearing half, so the transaction commits rather than throwing away
    the fact that stopped the mail because an announcement could not be built.
  - **A duplicate publishes nothing**, which is what makes a redelivery free: the
    second delivery is a `{:ok, :duplicate, row}` and never reaches the event
    write, so a `courier.email.bounced` is published once per bounce **by
    construction** rather than by a check somebody has to remember.

- **courier reports errors, and the report cannot carry what a redaction boundary
  exists to keep out of one.** Error reports carry request context, so they are a
  second path by which a credential, a prompt or a piece of PII could leave the
  process — the same leak the span pipeline was built to prevent, arriving by a
  different door. Two independent barriers, because the realistic failure is one
  of them being removed by a well-meaning change and nobody noticing for a month.
  - **`Courier.ErrorReporting.Filter` is the SDK-side barrier** and runs as
    Sentry's `before_send`. It is **fail-closed**: an event it cannot read is an
    event courier does not report. Losing a crash is recoverable; a customer
    credential in a third party's index is not.
  - **`Courier.ErrorRelay.Policy` is the relay-side barrier**, the single
    chokepoint every event passes on its way to the store. The exception
    **message** goes, and so do the frame **variables** — which in Elixir are the
    function arguments.
  - **The relay enqueues, it does not send.** A slow or dead error store cannot
    become courier's latency or courier's outage; the queue is bounded, and
    dropping under pressure is counted rather than silently absorbed.
  - **The store is self-hosted GlitchTip, over the Sentry envelope protocol.**
    Not self-hosted Sentry, whose FSL-1.1 forbids using it as the engine of a
    commercial offering. GlitchTip's backend and frontend are MIT, so hosted
    error reporting carries no copyleft obligation.
  - **A deployment is the leak this exists to close.** A service whose DSN points
    at `sentry.io` rather than at courier's relay never reaches the policy at
    all, so the SDK-side filter is deliberately kept even though it is thin.
  - **`COURIER_ERROR_RELAY_TOKEN` is required in prod**, compared with
    `Plug.Crypto.secure_compare/2`, and every refusal logs an atom
    (`:no_token`, `:wrong_token`, `:no_token_configured`) — never the value
    presented.
  - **Reporting is off in test** and that is asserted rather than assumed:
    `CourierWeb.ErrorReportingTest` proves capturing an error puts nothing in any
    mailbox and opens no socket. The *receiving* half is still exercised, with a
    recording sink standing in for GlitchTip.

- **courier can actually send mail, and it refuses to boot if it cannot.**
  A buyer installs courier, sets their SMTP credentials, sends a notification, and
  it arrives. That was not true before: `Swoosh.Adapters.Local` was configured in
  both dev and prod, and that adapter renders a message into memory and returns a
  provider-shaped id **without opening a socket**. A released courier accepted
  every send, wrote an outbox row for each one, published a `delivered` event, and
  mailed nobody — with no error and no warning anywhere.
  - **`gen_smtp` is now a declared dependency, and it is the load-bearing half.**
    `swoosh` declares `gen_smtp` **optional** and `Swoosh.Adapters.SMTP` declares
    it **required**, so naming `swoosh` alone compiles a courier whose only
    shipped adapter is the silent one. No amount of configuration could have
    fixed that state.
  - **The adapter is read from the environment and has NO default.**
    `COURIER_MAIL_ADAPTER` is `smtp` — the universal one; SES, Postmark, Mailgun,
    SendGrid and Resend all speak SMTP or have an SMTP front — plus
    `COURIER_SMTP_HOST`, `_PORT`, `_USERNAME`, `_PASSWORD`, `_AUTH`, `_TLS` and
    `_SSL`. An unset adapter, or one naming a provider courier does not ship,
    **stops the boot**, in `config/runtime.exs` and again in
    `Courier.Application`. The second gate reads the *effective* configuration
    rather than the environment, so it catches the committed-file route that the
    first one cannot see.
  - **`COURIER_MAIL_ADAPTER=none` is refused in production.** It is the
    Local adapter, and it is the right adapter for a developer working on
    courier's templates without a relay. It is not the right adapter for a
    deployment, and being able to reach it by forgetting a variable is the whole
    problem. A refusal at boot was chosen over a loud warning because a running
    courier that cannot send is worse than one that will not start: the damage is
    outbox rows and `delivered` events claiming delivery for mail that never
    went, and nothing in a dashboard shows it.
  - **A credential never reaches a log, in any environment.** The startup line
    names the host, the port and whether auth is on, and deliberately omits the
    **username** as well as the password — at SMTP a username is usually an API
    key. Nothing is committed to a config file, and two tests scan `config/*.exs`
    to keep it that way.
- **The SMTP adapter is tested against a real provider-shaped server.**
  `test/courier/smtp_delivery_test.exs` starts a real `:gen_smtp_server` on a
  kernel-assigned loopback port and drives real sends through
  `Swoosh.Adapters.SMTP` — real `EHLO`/`MAIL FROM`/`RCPT TO`/`DATA`, real AUTH,
  real `gen_smtp_client` underneath — and asserts the bytes that arrived. It is
  not mocked: pointed at `Local` or at `Test` instead, five of its six tests
  fail, which is the measure of whether the assertion means anything.
  - The `gen_smtp` server ships with `gen_smtp` itself and runs on `ranch`, so
    this costs no dependency and no hand-rolled socket that would accept anything.
  - The suite's floor moves with it: 678 → 728 tests, and the no-database tier
    306 → 356. The database tier and the SSRF table did not move, because not one
    of these 50 tests touches `Courier.Repo` and no URL guard was touched.

- **courier emits OpenTelemetry spans, into the collector that ships with kit's
  stack.** `<SERVICE>_OTEL_ENDPOINT` is the only contract (core D16) and it is
  **on by default** — unset, it is `http://otel-collector:4318` — so a developer
  running `mix phx.server` and a deployer both get traces without assembling
  anything, and a self-hoster already running a backend sets one variable and
  kit's stack goes quiet. Bring-your-own is a supported deployment, not a
  degraded mode.
  - **One request span per request, named `courier.web.request`.** A child span
    per email send, per webhook delivery and per outbox emission, named
    `courier.email.send`, `courier.webhook.deliver` and `courier.outbox.emit`.
    The span is recorded by `CourierWeb.Plugs.Telemetry`, which sits **above the
    router and below the parsers**: inside the router a 404 and a 405 would have
    no span at all, and below the parsers a body that cannot be read would have
    none either — and that failure is exactly the one nobody wants invisible.
  - **`http.route` is the route TEMPLATE, never the concrete path.** A template
    has one value per endpoint; a concrete path has one per request, and kit's
    collector derives metrics with a `spanmetrics` connector that mints a series
    per distinct value. A 404 therefore carries **no** route: the path there is
    caller-controlled text, so recording it is a cardinality bomb and a content
    leak in one move.
  - **Only 5xx is an error span.** A 401 and a 404 are courier refusing, which is
    courier working; an error rate that counts them is a function of how much
    guessing the platform absorbs, and an alert on that pages somebody to switch
    off the protection doing its job.
  - **Metrics come from the collector, not from courier**, and this was measured
    rather than chosen: the Erlang SDK ships no metrics API at all
    (`ls deps/opentelemetry/src | grep -c metric` is `0`). The connector runs
    after redaction, so a derived metric cannot carry a dimension the allowlist
    stripped. The cost is stated rather than hidden: courier cannot emit a gauge,
    so a stalled outbox relay is invisible on the metrics signal.
  - **Logs cost nothing and are not a per-language dependency.** compose
    `logging:` sends the container's stdout/stderr to the collector's
    `syslog/crash` receiver, which makes a crash a log record with a
    `service.name` on it. The `syslog` driver rather than `filelog` because the
    filelog form does not work at all under Docker Desktop or OrbStack.
- **One span-attribute allowlist, and one recorder.**
  `Courier.Observability.record/2` is the choke point every attribute in courier
  passes through, projected from `core/schemas/telemetry/*.schema.json`.
  `test/courier/telemetry_canary_test.exs` plants a canary in every field a
  caller controls — path, query, headers, body — drives real requests through
  the real router, and **raises** if it finds one in anything exported. It is a
  test that fails when the boundary leaks, which is the only shape a redaction
  proof can have.
  - **Every absence assertion is paired with a presence one**, because a boundary
    that deletes everything passes "no canary" and is useless. Three separate bugs
    left this suite green with nothing exported at all while it was being written,
    and `Courier.TestSpans.rendered!/0` now raises rather than returning an empty
    string so that shape cannot recur quietly.
- **Two dependencies, and the floor they are.** `{:opentelemetry, "~> 1.7"}` and
  `{:opentelemetry_exporter, "~> 1.11"}`, in every environment including test —
  without them courier cannot emit a span at all and the collector has nothing to
  redact. Deliberately **not** added: `opentelemetry_metrics` (no such API in
  this SDK), `opentelemetry_logger` (logs come from the container), and
  `opentelemetry_phoenix` (it records `url.path`, `url.query` and headers as its
  own attributes, and relying on the engine to strip them would make this one
  control where the repository insists on two).
- **`bin/gate-db`, and a `satisfy` command in `gate.yml` that names a file.**
  Adopting kit's stack removed courier's own postgres container, and kit's
  `fleet_check.py` fails a service that publishes its own port on one kit already
  ships (`ports:` is a list and a second file's list is APPENDED, so an override
  buys you both ports). So the host-side suite needs a postgres at
  `localhost:5432` that courier no longer owns, `bin/gate-db` starts one, and the
  declaration points at it. The old `docker compose up -d db` named a service this
  repository no longer has, which is a gate declaration reporting a satisfied
  operator while describing a repository that does not exist.

- **`Idempotency-Key` is implemented on the two mutating `POST`s.** Core's
  `docs/openapi-conventions.md` §Idempotency has required it since courier-05, and
  courier-12 measured that courier accepted the header and ignored it: three
  requests with one key created one row and answered `201`, `422`, `422` (the 422s
  were the unique index on `url`, not the key), there was no
  `Idempotency-Replayed` header, and a non-uuid key and a 5000-character key were
  both taken without complaint. That gap is closed, and core's contract checker
  — which named all three of the openapi idempotency rules as violations — is now
  green against this repository.
  - **A retry is free and provably is one mutation.** The same key with the same
    body returns the first response **byte for byte** with
    `Idempotency-Replayed: true`. For `createWebhookEndpoint` that response
    carries the `whsec_` signing secret, which exists in exactly one 201 and
    cannot be re-derived — so a client that lost it to a timeout gets it back
    from its retry, which is the whole reason a registration endpoint needs this.
  - **The claim is taken before the controller runs, not after.** A key recorded
    only once the action has happened cannot prevent anything: two requests would
    both run and both mutate. `idempotency_keys` holds the claim in an `in_flight`
    state between the two, and `unique (account_id, endpoint, idempotency_key)` is
    what decides the race at the database.
  - **A retried `POST /{id}/test` sends nothing the second time.** Asserted by
    clearing the recording sender and finding nothing recorded, because a test
    endpoint that receives duplicate pings is a support question.
  - **A request that did not succeed leaves no row.** A stored 4xx would pin the
    caller's own typo for 24 hours — they fix it, retry with the same key, and get
    a 409 about a key they never reused — and a stored 5xx would pin a transient
    courier failure for the same day. Only a 2xx is replayed.
  - **A key that is not a uuid is now a 422.** An unbounded key is a string in a
    unique index, paid for by every write that is not the one carrying it.

### Changed

- **courier runs on the platform's ONE shared postgres cluster, as a tenant of
  it.** The previous entry below describes the state this one replaces, so it is
  left as written and this one says what is different.
  - **`kit.ref` moves `a0959929` → `1770009`.** At the old pin
    `templates/compose/postgres/` did not exist in kit at all, so there was no
    cluster to join — only the one container kit shipped, which courier was
    overriding into a private database by name. Nineteen kit commits come with
    the bump; under `templates/compose/` the diff is `.env.example`,
    `docker-compose.yml`, `otel-collector.yml` (four resource attributes
    core-26 added, exempted on all three signals) and the whole of `postgres/`.
  - **The database and the role are now declared, not impersonated.** The old
    file overrode `POSTGRES_USER: courier` and `POSTGRES_DB: courier`, which made
    courier the cluster's **superuser** — the role that owns the cluster, reads
    every database in it, and creates roles. Measured on the shared stack before
    this change: that role answered a query against a sibling service's database
    with its rows. It now declares `KIT_POSTGRES_DATABASES: courier` and nothing
    else, so kit's `initdb/10-cluster.sh` creates `courier` as
    `LOGIN NOSUPERUSER` owning a database of the same name, and applies
    `REVOKE ALL ON DATABASE … FROM PUBLIC` to every database in the cluster.
    Measured after: `has_database_privilege('public', <other service>, 'CONNECT')`
    is false for all of them, and courier's own connection to a sibling's
    database fails `FATAL: permission denied for database` /
    `User does not have CONNECT privilege`.
  - **`KIT_POSTGRES_ROLE_CONNECTIONS` is 20, not kit's default 10.** courier's two
    Oban queues and the web pool share one `Courier.Repo` pool; 11 connections at
    rest and 11 peak measured, so at 10 the service cannot start. The limit lives
    in the cluster's `pg_authid`, so on an **existing** volume raising it needs
    kit's `bin/dev db grant` — `docker-entrypoint-initdb.d` runs once per volume
    and a changed variable is not re-read.
  - **Two lines exist only because of a kit bug, and both are commented as such
    in the file.** kit's postgres service is the only one of its seven that uses
    bare `./postgres` paths rather than `${KIT_COMPOSE_DIR:-.}/postgres`, so
    courier re-points the build context and the initdb mount at the fetched tree.
    Without them the build fails outright; with them the shared cluster is built
    from kit's own Dockerfile and initialised by kit's own script.
  - **courier now joins the `platform` network explicitly.** An override's
    `networks` list replaces rather than merges, and courier's previous file
    named none, so `docker compose config` rendered
    `courier: {default: null}` against `postgres: {platform: null}` and the
    daemon refused to start it.
- **`docker-compose.yml` is an OVERRIDE on kit's stack, not a copy.** `kit.ref`
  pins the kit commit, `bin/dev` is kit's own script verbatim, and this
  repository's compose file owns three things: its database name and role, its
  own service, and the crash layer. It carries no collector configuration — that
  file holds the redaction allowlist, which kit derives from core's schemas, and a
  service that owned it would be shipping a telemetry boundary nobody derived. No
  `depends_on: otel-collector` either: nothing but the collector may be in a
  readiness path, because a service that waits for the collector serves no traffic
  while the collector is down, which is strictly worse than serving traffic with
  no traces.
- **`gate.yml`'s database requirement was rewritten** rather than left pointing at
  a `db` service that no longer exists. See `bin/gate-db` above.
- **The suite is 630 → 678, and the floors moved with it in the same commit** —
  `gate.proof[].minimum` to 672, CI's `whole suite` to 678 and `no database` to
  306. The `database` tier did not move, because not one of the 48 new tests
  touches `Courier.Repo`, which is what that tier counts.
- **`cafaye.yml` declares `core: ^0.2.0`, not `^0.1.0`.** The stale number was
  flagged in the manifest's own header as an unresolved guess — "assumes core's
  first release is 0.1.0; if it lands as 0.2.0 this line is wrong". It landed as
  0.2.0, and core-17 made `core:` enforced rather than declarative, so the guess
  had become a build failure. The header note is rewritten to say what the line
  now does rather than deleted, because it is the only record in the file of which
  line is checked by something outside this repository.
- **`openapi.yaml` is 1.3.0 → 1.4.0.** `Idempotency-Key` on both POSTs, the two
  409s they can now answer, and the `Idempotency-Replayed` response header. A
  minor bump: no path changed, no operation was added or removed, and nothing that
  existed changed shape. A client that sends no key is unaffected.
- **409 is no longer a status courier does not return.** The document's header
  listed it among the omissions, with the measured reason that a duplicate `url`
  is a 422 whose `errors[0].code` is `taken`. That is still true and still what
  the header says about *that*; the 409 that is now declared is for
  `Idempotency-Key`.

### Fixed

- **Two Elixir behaviours that made idempotency silently not work**, both found by
  running the thing rather than by reading it, and both now written into the code
  that depends on them so the next reader does not rediscover them:
  - **`conn.resp_body` inside a `before_send` callback is iodata, not a binary.**
    `Phoenix.Controller.json/2` encodes to iodata and `Plug.Conn` stores what it
    is given, so a first draft that required `is_binary/1` released every claim.
    Nothing raised: the request answered `201`, and the retry created a second
    endpoint.
  - **Ecto's keyword `where/2` does not apply the schema's field type.** A
    `DateTime` handed to `where(IdempotencyKey, expires_at: ^now)` reaches the
    database uncast and matches nothing against a `utc_datetime_usec` column —
    measured as 1 row by raw SQL and 0 rows by the query, against the same table.
    Every query in `Courier.Idempotency` uses the `where([k], ...)` macro form.
- **Six tests in `webhook_endpoints_test.exs` and `webhook_endpoints_config_test.exs`
  that could only pass while the rest of the suite left no rows behind.** Each
  asserted `Repo.aggregate(WebhookEndpoint, :count) == 0` — a claim about every
  other test in the repository as much as about `Courier.WebhookEndpoints`, green
  only while nothing else had ever written a row and red the moment one was
  visible. Each of the six now mints its own account and counts only that
  account's rows, which is the assertion the test means: *this* call wrote
  nothing. No assertion was weakened, no test made slower, and no `async: false`
  added — the ordering dependency is gone rather than scheduled around.
- **`deliver_test.exs` compared two lists whose order the database does not
  promise.** `Repo.all(OutboxEvent)` carries no `order_by`, so the row order is
  PostgreSQL's choice; the assertion compared it against a fixed sequence and
  failed in 2 of 50 whole-suite runs with
  `["password_reset", "welcome", "team_invitation"]` where it expected
  `~w(welcome password_reset team_invitation)`. Both sides are sorted now, which
  keeps the assertion exactly as strong (all three types present, each once,
  nothing else) and stops it testing the server's whim.

### Security

- **The tenant identity now spans each authenticated request's database work —
  the `TenantIdentity` plug's transaction never did.** `CourierWeb.Plugs.
  TenantIdentity` opened `Tenancy.with_account/3` around `fn -> conn end` —
  no database work — and committed before the `:idempotent` plug and the
  controller ran, discarding the transaction-local `cafaye.account_id`. Every
  authenticated request then ran with no identity: protected writes raised
  `42501` and protected reads returned zero rows. The plug is removed; each
  `/v1` action and the `:idempotent` plug opens its own `with_account/3`
  around its own work, with the account `CourierWeb.Plugs.Principal`
  stashed. A request-lifetime checked-out connection was refused: the only
  connection-holding Ecto offers is function-scoped, and a session-level
  `set_config` on a pooled connection leaks one account's identity to the
  next checkout. Statement errors under a scope are contained with
  `mode: :savepoint` on the operation (Ecto's documented remedy) — an inner
  `Repo.transaction/1` with `Repo.rollback/1` is not containment, measured:
  nested Ecto transactions are not savepoints and an inner rollback fails the
  outer commit as `{:error, :rollback}`. Proved in
  `test/courier_web/plugs/tenant_scope_test.exs` (6 tests: write+read with no
  ambient identity, pool recovery after 32 mid-transaction failures, a full
  send plus idempotent replay, and the pipeline shape).
  - **What this does *not* do, stated rather than glossed:** the pre-existing
    control-flow rollbacks in `Courier.Unsubscribes`, `Courier.Notifications`
    and `Courier.InboundReports` now nest inside the per-action scope, so their
    failure paths (concurrent duplicate) fail the scoped commit rather than
    mapping to their documented statuses. `Courier.Deliver`'s send path is
    not in that list: `send_and_record/3` returns its failures (provider
    refused, token unmintable, row unwritable) as values rather than rolling
    back — a rollback there is control flow over nothing written, and nested
    it fails the request's own scoped commit. The two provider-retry tests in
    `messages_controller_config_test.exs` prove the mapping under scope. The
    remaining failure-path statuses under scope are the known exposure a
    successor must re-verify with the full gate, not a shape this packet
    proved.

- **`GET` and `PUT /v1/notification_preferences/{user_id}` are authenticated, and
  tenant-scoped.** Both were reachable with no credential at all, which meant any
  caller could read or overwrite any other tenant's notification preferences by
  guessing or enumerating a `user_id`. This closes the gap the `0.1.0` Security
  section below recorded, on the deadline that section asked for ("before a
  customer generates a client from this document").
  - **Behind courier's own pipeline.** The two routes moved into the same
    `:api, :authenticated` scope as the webhooks, so an anonymous caller is a
    `401` from `CourierWeb.Plugs.Principal` — the same refusal, body for body, as
    every other authenticated route. No second mechanism, no new plug.
  - **Tenancy is recorded, not asked for.** `notification_preferences` gains a
    NOT NULL `account_id`, written from `conn.assigns.current_account` and never
    from a request. `Courier.NotificationPreferences.list/2` and `update/3` take
    the account as their first argument and answer `{:error, :not_found}` for a
    user whose rows belong to somebody else.
  - **A cross-tenant answer is a 404, never a 403**, because core's conventions
    forbid a 403 that leaks the existence of a resource the caller cannot see.
    And the 404 is **narrow**: a user nobody has written preferences for is still
    a `200` with the defaults, since courier holds no foreign key to identity's
    users and cannot tell that user from one that does not exist.
  - **`account_id` cannot be named by a caller.** It is not a field of a
    preference entry, so an entry carrying one is a 422 naming
    `preferences[0].account_id`, rather than being silently dropped.
  - **The unique index stays on `(user_id, notification_type)`.** A user has one
    set of preferences, not one per account, so the account is the row's owner
    and not part of its identity. That is also what keeps
    `NotificationPreferences.enabled?/3` — the delivery path, which is addressed by
    a user and has no account in it — reading by user alone and unambiguous.
  - **What this does *not* fix, stated rather than glossed:** courier cannot ask
    identity which account a user belongs to, so the **first authenticated `PUT`
    for a user id is what claims it**. An account that writes for a user id
    nobody has written for gains the claim — no access to anything that existed,
    and the account that actually owns the user then gets a 404 and a settings
    page that cannot save. The alternative was no writes at all.
  - **The migration deletes the rows it cannot attribute.** Every row that existed
    was written through an unauthenticated route, so there is no honest account to
    give it. Backfilling a placeholder would put every user's opt-outs under an
    account nobody owns — one missing predicate away from being readable by every
    tenant — and a nullable column invites the next query that forgets to filter
    on it. The loss falls in courier's own safe direction: a removed preference
    reads as *no preference*, which reads as **on**, so a user courier forgets is a
    user courier mails, never a user's mail going to somebody else. There are no
    customers yet to have an opt-out to lose.

### Changed

- **`openapi.yaml` is 1.4.0 → 2.0.0, a major bump and this document's first.**
  No path changed, no operation was added or removed, and no response body
  changed shape — but the two notification-preferences operations went from
  `security: []` to requiring a bearer token, which changes what a client has to
  send and is therefore breaking rather than additive. A client generated from
  1.4.0 sends no token and receives a 401. The previous header's own arithmetic
  called this move ("a major `info.version` and every generated client"); it was
  paid here because no 2.x client exists yet.
- **Every operation in `openapi.yaml` now declares a `401` and a scope.**
  `notifications:read` and `notifications:write` on the two preferences
  operations, matching the `webhooks:read` / `webhooks:write` naming. The two
  operations also declare the `404` they can now answer, through a
  `NotificationPreferencesNotFound` component of their own rather than reusing the
  webhook one, because its `detail` is a different sentence.
- **`Courier.NotificationPreferences.list/1` is `list/2` and `update/2` is
  `update/3`**, with the account as the first argument. `enabled?/3` is unchanged
  and takes no account — see above.

### Known gaps

- **courier cannot emit a metric gauge**, so a stalled outbox relay is invisible
  on the metrics signal and shows up only as a flat trace count. The alternative
  would be a service-side meter, and the SDK has no metrics API to build one with.
- **A 500 span carries no route.** The exception is raised past the router, so
  there is no matched route to record, and a concrete path is not an acceptable
  substitute. The status, the method and the error type are there; the path is not.
- **The Erlang SDK drops the span processor it starts for itself.**
  `otel_tracer_server:init_processor/3` calls `supervisor:start_child(otel_span_sup,
  [Module, Config])` against a `one_for_one` supervisor, which answers
  `{:error, {:invalid_child_spec, …}}`, and the result is discarded with `_ =`.
  Verified against `Supervisor.which_children(:otel_span_sup)` in opentelemetry
  1.7.0 and 1.5.1: the sweeper and the ETS table are there and a processor never
  is. `Courier.SpanCollector` installs the processor itself and raises at boot if
  the SDK's record shape changes, so the workaround fails loudly rather than
  silently exporting nothing.

### Tests

Fourteen more, all written before the code they cover:

- **The authorization matrix on both preferences verbs** — anonymous is a `401`
  on each, the request is halted in the plug (`conn.assigns[:action]` is nil), and
  another account gets a `404` on the read and on the write. The write half reads
  the row back as its owner afterwards, because a refusal that still stored the
  batch would be a 404 and a breach.
- **"The same refusal the authenticated routes already return" is asserted by
  comparison, not by a copy.** An anonymous request to each preferences route and
  to `GET /v1/webhook_endpoints` is decoded, `instance` and `trace_id` are dropped,
  and the two bodies are asserted equal. A hand-written expectation for the
  envelope would pass against a plug that answered 401 for the wrong reason.
- **The first-writer-claims rule is a test in both directions** — an account that
  owns a user may keep writing, and an account that does not is refused even after
  the owner has written three times.
- **`router_test.exs`'s assertion flipped with the router.** It previously asserted
  that these two routes were *not* behind the authenticated pipeline, with a
  comment explaining why the gap was deliberate; it now asserts that both verbs
  are, which is the same claim about the same pipeline.

Forty-eight more, and the first three files in courier are about a boundary rather
than a behaviour:

- **`telemetry_canary_test.exs` — nine tests, and the reason this packet
  exists.** A canary string is planted in a path, a query string, a bearer token,
  a cookie, an API key, a user-agent, a malformed `traceparent`, a webhook URL, a
  signing secret and a request body, and then real requests are driven through
  the real router; any appearance of that string in an exportable span attribute
  raises `THE REDACTION BOUNDARY LEAKED` and prints the whole export. Each of the
  three failure modes it distinguishes has a test of its own: a 404 carries **no**
  route, a 404 is **not** an error span, and a parameterised route exports its
  **template**.
- **`observability_test.exs` — eighteen, on the allowlist itself.** The names are
  names somebody already thought of; no name contains a word that names content
  (`payload`, `params`, `body`, `header`, `token`, `secret`, `email`, `tenant`,
  …); and a value that is not on the list is dropped rather than recorded. The
  two files are not the same claim — a canary test is satisfied by a service that
  exports nothing, and an allowlist test by a service that never calls `record/2`.
- **`telemetry_test.exs` — twenty-one, on the contract and the wiring.** The
  endpoint variable and its default are the same value in code and in compose; the
  resource carries `service.name`, `service.version`, `deployment.environment` and
  a `tenant_id` that is absent rather than empty by default; a span survives the
  real SDK and arrives at a real exporter; and telemetry that cannot be installed
  reports *why* instead of silently doing nothing. One of these found a real bug:
  `enabled?/0` was inverted, so telemetry was off by default in every
  environment except the test suite that proved it worked.

courier can send a transactional mail, honour what the user asked not to receive,
record every send as an event that its own relay publishes, and deliver those
events to customer HTTP endpoints with the Standard Webhooks signature scheme.

### Added

- **`openapi.yaml` now declares every error it can return, and a test proves the
  document and the code agree about them.** courier-12 was opened on a claim that
  the RFC 9457 envelope was defined in `components` and wired to nothing.
  Re-measured, that specific claim no longer reproduced — courier-05 had already
  attached the envelope to all four responses the document declared. What did
  reproduce, and what this closes, is the version of the same defect one level
  down: **every one of the eight operations could answer a `500` and a `406`, and
  none of them declared either.** A client generated from this document had no
  way to learn that. All eight now declare both, and `info.version` goes
  `1.2.0` → `1.3.0` — a minor bump, because no path changed, no operation was
  added or removed, and no request or response that already existed changed
  shape.
  - **`400` moved in both directions, because the parser's verb list is not the
    one it looks like.** `Plug.Parsers` reads a body for `POST`, `PUT`, `PATCH`
    **and `DELETE`**, so `DELETE /v1/webhook_endpoints/{id}` was reachable at
    400 and declared nothing — a client that sends a body with its delete gets a
    response no document described. The mirror of that was already wrong in the
    document: `GET /v1/notification_preferences/{user_id}` declared a 400, and
    `Plug.Parsers` **does not read a body on a `GET`**, so that 400 is
    unreachable and a client generated from it writes a branch that can never
    run. The 400 is removed there and added to the delete. The new check compares
    the document against the parser in **both** directions — declared ⇒ reachable
    and reachable ⇒ declared — for every operation, which is how both halves were
    found.
  - **`test/courier_web/openapi_error_responses_test.exs` is the new check**, and
    it is the language-specific half a neutral harness cannot be: it provokes
    each status against the running endpoint and asks the document whether it
    admits it. There is no table of statuses per operation written down in it,
    because a table is a check that can only fail for a case somebody remembered
    to type — the operations come from the document and the router, path
    parameters are filled in mechanically, and the statuses come from sending
    requests. `test/support/openapi_paths.ex` grew `document_responses!/1` and
    `component_responses!/1` to read what is declared, and a `$ref` to a
    component the document does not define is now a raised error rather than a
    response that looks wired and is not.
  - **The document's header now admits what courier does *not* return**, with the
    measured reason for each: `403`, `409`, `415`, `429` and `503` on `/v1`, and
    `Idempotency-Key`, which courier accepts and ignores. A test asserts both
    halves — that no operation declares one of those statuses, and that the
    header says why — so the omission is an admission rather than a silence. The
    two checks that already existed stay as they were; nothing was weakened.
- **`errors[].detail` is now declared.** courier has been sending it inside a
  422's `errors[]` — a bad `limit` reads "is not a positive integer" rather than
  only `invalid_format` — and the schema did not mention it. It is optional and
  says so, because only some entries carry one.

### Fixed

- **A `406` no longer reports itself as `internal`.**
  `CourierWeb.Problem.for_status/1` had no entry for 406, so it fell through to
  the `:internal` default and a client that asked for `text/html` was answered
  `{"status": 406, "code": "internal", "title": "Internal server error"}` — its
  own `Accept` header reported back to it as courier having failed, wearing the
  one code every generated client retries. `internal` is core's reserved slug
  for 500. Declaring a 406 in the document while it said that would have put the
  lie into the permanent contract, so the code was fixed first. Measured over a
  real socket, because `Phoenix.NotAcceptableError` carries no conn and
  `Phoenix.ConnTest` cannot see the response it produces.

- **`openapi.yaml` and the router are now held to each other by a test, in both
  directions.** `test/courier_web/openapi_document_test.exs` reads the document
  and `CourierWeb.Router.__routes__/0` and fails if either describes an operation
  the other does not. It compares **paths, never counts** — a count comparison
  passes on a rename and fails on a pure addition, which is backwards — and its
  readers raise rather than under-read, because two readers that both find
  nothing agree with each other and a green check over nothing is worse than no
  check. The route set comes from the router's own definitions rather than a
  list written out in a test, which is the shape that can only fail for a name
  somebody remembered. `/healthz` and `/readyz` are the only omission: they are
  named in the document's header and in the test's exclusion list with the
  reason, keyed by method *and* path so a carve-out cannot cover a second method
  on the same path, and the test fails if that list stops naming a route the
  router actually serves.
- **`GET` and `PUT /v1/notification_preferences/{user_id}` are now in
  `openapi.yaml`.** They were in the router with tests behind them and absent
  from the document, which courier-03 flagged rather than leaving quietly; that
  was the right call and this closes it. The document's operation count goes
  from 6 to 8 and `info.version` from `1.1.0` to `1.2.0` — a minor bump, since
  nothing that already existed changed shape. The document no longer describes
  itself as partial: it now covers every route except the two probes, and both
  it and `test/courier_web/openapi_document_test.exs` say so.
- **CI, and it calls `cafaye/kit` rather than copying it** —
  `.github/workflows/ci.yml` is a six-line `uses:` for kit's reusable workflow
  plus the two jobs kit cannot own. It is the first CI this repository has had:
  every "the gate is green" claim for courier so far rested on whoever ran the
  suite by hand, on that day, on that machine.
  - **The shared half** — `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master`
    with `language: elixir`, the working directory, the toolchain pinned from
    `mise.toml`, a coverage floor, and telemetry off. The `.github/workflows/`
    in that path is load bearing: GitHub does not resolve subdirectories of the
    workflows directory, which is why the file kit shipped at
    `workflows/ci.reusable.yml` was unreachable from every caller in the fleet.
  - **The gate** — `bin/prime`, unmodified, against a `postgres:17` service
    container, then each test tier named and counted: 564 in the whole suite,
    252 without a database, 312 with it, 62 in the SSRF table on its own. Every
    count is asserted, so a tier cannot quietly stop running, and a deleted test
    cannot keep the badge green. The files in each tier are derived from the
    case templates, so a new test file cannot fall outside one.
  - **The lockfile guard** — `git diff --exit-code -- mix.lock` after the gate. A
    prime that resolves differently lets two worktrees disagree about one commit,
    and a green suite cannot see that.
  - **The release and its boot contract** — `mix release` on the pinned
  toolchain (the only thing here that compiles in `:prod`), then three
  assertions: the release refuses to boot without `COURIER_SECRET_BOX_KEY` and
  names it, accepts a test-only key and then refuses on `DATABASE_URL`, and
  with both set seals under the key it was given. The key used there is a
  test-only fixture; nothing in `config/runtime.exs` reads a default, and the
  first assertion is the proof.
- **`bin/assert-suite`** — asserts a `mix test` run executed everything it
  reports. It accepts exactly one shape of ExUnit's summary (`Result: N passed`)
  and fails on a fraction, on a skipped or excluded count, and on `0 tests`, so a
  run cannot satisfy itself by having verified less.
- **`bin/toolchain-pins`** — reads the `[tools]` pins out of `mise.toml` so CI
  builds with the toolchain `mise install` gives a developer, and checks kit's
  `versions:` input against the same file, so the one version literal GitHub
  cannot avoid cannot drift into a second toolchain.
- **Outbound webhooks, signed per [Standard Webhooks](https://www.standardwebhooks.com)**
  — PLAN.md §7 adopted the spec with "No custom scheme", so a consumer verifies a
  courier delivery with an official library (Svix's, Twilio's, Kong's,
  Supabase's) and learns nothing about courier. The implementation is exact:
  - **Base string** — `msg_id.timestamp.payload`, spec §Signature scheme ("the
    message's: ID, timestamp and body are concatenated (delimited by
    full-stops)").
  - **Algorithm** — HMAC-SHA256, symmetric, identifier `v1`, serialized
    `v1,<base64>`, per the spec's §Signature scheme table.
  - **Secret** — `whsec_` + base64 of 32 random bytes, the spec's serialization
    and inside its 24–64 byte range.
  - **Headers** — `webhook-id`, `webhook-timestamp`, `webhook-signature`, and no
    fourth header, per spec §Webhook headers.
  - **Replay protection** — a 300-second tolerance on `webhook-timestamp`, the
    number every reference implementation in `refs/standard-webhooks/libraries/`
    uses, enforced by `Courier.Webhooks.Verifier` and published to consumers so
    they are not left to guess the one value that decides whether a replay is a
    replay.
  - **Body** — the CloudEvents envelope, encoded once so the bytes signed are the
    bytes sent, which the spec calls "a very common failure mode" when it is not.
  The expected HMAC in `Courier.Webhooks.SignatureTest` is computed in the test
  from the spec's base string, not by calling the signer.
- **`Courier.Webhooks.UrlGuard`** — the SSRF guard, and the reason this packet
  could not have been written without one: courier signs requests to a URL a
  *customer* chose, which is an SSRF machine. It resolves the host, refuses the
  URL when **any** answer is a blocked address (a public name answering with
  `127.0.0.1` is the attack), and returns the resolved address for the sender to
  dial with the registered name as the `Host` header — so the address that was
  checked is the address that is connected to. Refused: non-http(s) schemes,
  loopback, `0.0.0.0`/`::`, link-local `169.254.0.0/16` and `fe80::/10`, RFC1918,
  `fc00::/7`, IPv4-mapped IPv6, multicast and reserved, `localhost` and `.local`,
  and a zone id. Sixty tests, one per blocked class.
- **`webhook_endpoints`** — uuid id, `account_id` with no foreign key (identity
  owns accounts and there is no table here to point at), url validated for shape
  and then run through the guard, description, `status` enum, `UNIQUE
  (account_id, url)` and a check constraint, both enforced by the database and not
  only by the changeset. The signing secret is generated by courier, sealed with
  AES-256-GCM (`Courier.SecretBox`) and returned exactly once in the 201; it is
  not a castable field, so a body naming its own secret is ignored.
- **`webhook_deliveries`** — one row per `(endpoint, event)` rather than per
  attempt, which is what makes the spec's "the same id on every retry" true by
  construction: there is only ever one `webhook_id` per delivery. Carries status
  (`pending`/`succeeded`/`failed`/`exhausted`), attempt, status code, duration,
  the reason, and `next_attempt_at`.
- **`POST`, `GET`, `GET /:id`, `PATCH /:id`, `DELETE /:id`, `POST /:id/test`** —
  `/v1/webhook_endpoints`, JSON, cursor-paginated per core's conventions. The
  create response carries the `whsec_` secret; no other action can produce it.
- **`Courier.Workers.DispatchWebhooksWorker`** — fans an outbox event out to the
  enabled endpoints of its account, idempotent three ways: the mark and the
  deliveries commit together, `(endpoint_id, event_id)` is unique, and the claim
  is `for update skip locked`. Events with no account are skipped: `Courier.Deliver`
  records `email.delivered` for a *person*, and fanning those out to every account
  would deliver one customer's mail events to another.
- **`Courier.Workers.DeliverWebhookWorker`** — sends what is due and records the
  answer. The classification is the spec's §Delivery success and failure table:
  `2xx` succeeds, `5xx`/`408`/`429`/no-response retry, `3xx` and other `4xx` are
  recorded and not retried, and `410 Gone` disables the endpoint immediately
  because the spec says a receiver answering it "should disable the webhook
  endpoint, and stop sending it messages".
- **`Courier.Principal` and `CourierWeb.Plugs.Principal`** — the shape of "who is
  calling", settled before the packet that fills it in. An anonymous request is a
  401 on every webhook action, the account comes from the principal and never
  from the body, and the default resolver authenticates *nobody* — so a deployed
  courier without identity's JWT verifier refuses every webhook request rather
  than serving them to whoever asks.
- **`webhooks_dispatched_at` and `account_id` on `outbox_events`** — courier's
  additions to core's table, the way `last_error` is. `account_id` is whose
  endpoints an event goes to; `webhooks_dispatched_at` is when it was fanned out,
  which is a different moment from `published_at`.
- **`:req`** — the one dependency this packet adds, and the one this repository's
  own generated rules name as preferred over `:httpoison`, `:tesla` and
  `:httpc`. `Courier.Webhooks.Sender.Req` sets `redirect: false`, because the spec
  says a `3xx` is a failure and following redirects wastes both ends' load — and
  because a redirect to `169.254.169.254` would be an SSRF hop the guard never saw.
- **`COURIER_SECRET_BOX_KEY`** — the 32-byte key signing secrets are sealed under,
  required at boot in prod and never defaulted. A default would be a key in
  version control that every deployment that forgot to set one would seal its
  customers' credentials under.

### Changed

- **One postgres image across the platform: courier moves to
  `postgres:17-alpine`.** The two places that actually pin the image —
  `docker-compose.yml`'s `db` service and the `services: postgres` block in
  `.github/workflows/ci.yml` — now carry the same string, character for
  character, and `gate.yml`'s database requirement names it too, so a local
  `docker compose up` and a CI gate run are the same server. Previously both
  pinned `postgres:17`, the debian image: 477MB against alpine's 291MB, and it
  was the only postgres variant left in a local cache where every *running*
  database container was already `postgres:17-alpine` — so the next
  `compose up` re-pulled an image the platform had standardized away from.
  The two pins never disagreed with each other; they disagreed with the
  platform, which is the same defect wearing a different hat.
  - **Booted, migrated from scratch, and the database tier run on it** — not a
    comment. All six migrations applied to an empty alpine server, and every
    tier green: 535 in the whole suite via `bin/prime` unmodified, 241 in the
    no-database tier, 294 in the database tier, 62 in the SSRF table. Zero
    skipped, zero excluded, and no tier is gated on an environment variable.
  - **The musl/collation question, answered rather than assumed.** Alpine's
    postgres is musl (`aarch64-unknown-linux-musl`, Alpine 3.24.2) and its
    databases report `datlocprovider = c`, which means the `en_US.utf8` in
    `datcollate` is a nominal locale name and not glibc's Unicode-aware
    ordering. The orderings genuinely differ — `Apple Banana Zebra _underscore
    apple` under musl's `c` provider against `_underscore apple Apple banana`
    under `en-US-x-icu`. **Nothing in courier depends on the difference**, and
    the reason is structural rather than lucky: all eight `order_by` clauses in
    `lib/` order on `inserted_at`, `occurred_at`, `next_attempt_at` or `id` and
    never on a user-supplied text column; every text-ordering assertion in the
    suite is an `Enum.sort` in the BEAM, whose order for binaries is byte order
    and does not go through libc at all; and the one text column in a unique
    index (`webhook_endpoints.url`) is compared with `=`, which is byte
    equality and therefore collation-independent. A future `ORDER BY` on a
    customer-supplied string is where this would start to bite, and the finding
    is recorded rather than papered over so the next reader knows the floor.

### Security

- **The two `notification_preferences` operations are documented as served
  without authentication** (`security: []`), because that is what the router
  does: they are in the `:api` pipeline only, and the gap is recorded in
  `CourierWeb.NotificationPreferencesController`'s moduledoc and pinned by
  `router_test.exs`. Core's `docs/openapi-conventions.md` asks for required
  scopes on every operation, so this is a disagreement with the contract rather
  than a settled fact, and it is a `> DECISION NEEDED (courier-05)` in the
  document's header. **It should be closed before a customer generates a client
  from this document**: a client built against `security: []` sends no token, so
  authenticating them later is a major `info.version` bump and a regenerated SDK
  for everyone who already did.
- **The retry budget is bounded, in two places** (PLAN.md §7). A delivery is
  attempted at most 8 times: 5 minutes apart at first, doubling, capped at 6 hours,
  with jitter drawn from the headroom *under* the cap. A full budget spans about
  sixteen hours. Separately, an endpoint is disabled after 5 consecutive failures,
  with the count and the last error recorded so "why did delivery stop" has an
  answer that is not in a log. `410 Gone` skips the count entirely.
- **A customer-disabled endpoint is not courier-disabled.** `disabled_reason` is
  what tells them apart: a success re-enables an endpoint courier tripped and
  leaves one the customer turned off alone, and re-enabling a tripped endpoint
  clears the count courier showed them.

### Tests

Three hundred and forty-one more, all written before the code they cover. The ones
worth naming:

- **`Courier.Webhooks.SignatureTest`** computes the expected HMAC from the spec's
  base string in the test file, by code that is not the signer. A test asserting
  the signer against itself passes even when the base string is wrong.
- **`Courier.Webhooks.UrlGuardTest`** asserts each blocked address class
  individually, and covers the three parser bugs the tests found:
  `URI.parse/1` truncates a bracketed IPv6 host to its first four characters,
  `Integer.parse/1` partial matches made a port stripper split IPv6 literals at
  their first colon, and `:inet` answers IPv6 as a tuple while `getaddrs` answers a
  list. Each one fails closed — blocking every public address — and each was
  found by a test, not by reading the code.
- **The authorization matrix** is every action × {anonymous, other account, own
  account}, asserted rather than described, plus a router test that every webhook
  route is behind the authenticated pipeline.
- **Nothing sleeps.** The backoff schedule is asserted on the recorded
  `next_attempt_at` and on `backoff/1`'s return value, never by waiting for a
  window to elapse. The one test that cares that a delivery is *not* picked up
  early is the one call in its file that does not move the clock.
- **The same `webhook_id` on every attempt**, asserted across a whole budget:
  delivery is at-least-once, so a consumer deduplicating on it must see one event
  however many times courier retried.

## [0.1.0] — courier-02

courier can send a transactional mail, honour what the user asked not to receive,
and record every send as an event that its own relay publishes.

### Added

- **Swoosh and Oban** — the two dependencies this packet needed, and nothing
  else. `Swoosh.Adapters.Test` in test, `Swoosh.Adapters.Local` in dev and prod:
  a released courier exercises the whole pipeline without mailing anyone.
- **`Courier.Mailers`** — `build/2` composes `welcome`, `password_reset` and
  `team_invitation` and returns a `Swoosh.Email`; `deliver/2` is that plus
  `Courier.Mailer`. Bodies are templates under
  `lib/courier/mailers/templates/`, compiled at build time and wrapped in one
  shared layout per format. The sender and the subject lines are configuration
  (`config :courier, :mailing`, address from `MAIL_FROM` at boot), because they
  are the two things an operator should reword without touching a module.
- **`Courier.Deliver`** — the three public sends, plus `email/2` for a type the
  caller has as data. Order of the checks is the contract: unknown type, then
  missing user, then an unrenderable payload (refused *before* the provider is
  asked), then the user's preference. What is left is one transaction that calls
  the provider and writes `outbox_events`, so a send nobody made and a row
  nobody can see cannot both be true. Returns the message id — also sent as a
  real `Message-ID` header — and the event's id.
- **`Courier.NotificationPreferences`** — one row per (user, notification type),
  defaults all-on, `list/1` never writes. A rejected batch stores nothing, an
  entry that names no channel leaves the stored value alone, and `push` is stored
  and returned without being a delivery decision anything acts on.
- **`GET` and `PUT /v1/notification_preferences/:user_id`** — JSON, under the
  `/v1` prefix core's conventions require. An unknown user is a 200 with three
  types on, not a 404: identity owns the user table, and a 404 would be courier
  claiming to know something about the requester it does not know.
- **The problem+json error envelope** — `CourierWeb.Problem` builds it, and
  every non-2xx response uses it: `application/problem+json` with a stable
  `https://errors.cafaye.com/<code>` `type`, a `code`, a `detail`, the `instance`
  path, a `trace_id` that matches the `X-Trace-Id` header, and per-field
  `errors[]` on a 422. `CourierWeb.Plugs.Trace` assigns both the id and the path
  before the router runs, so a request that matched no route is answered from the
  same id as everything else. Per-field names are the *request's*
  (`preferences[0].notification_type`), because the body is what a caller can fix.
- **`Courier.Events`** — the CloudEvents envelope, and the catalog of the types
  courier may emit, which `Courier.EventsTest` checks against this repository's
  `cafaye.yml` in both directions.
- **`outbox_events`, `notification_preferences`, `oban_jobs`** — the three
  migrations. `outbox_events` is core's table (see
  `core/docs/event-outbox.md`) with courier's column names and one addition,
  `last_error`, so a refused publish says why without reconstructing Oban's job
  history.
- **`Courier.Workers.ProcessOutboxWorker`** — the relay: claim a batch with
  `for update skip locked`, publish each through `Courier.NatsPublisher`, mark
  `published_at` from the acknowledgement and never before, record the attempt
  and the reason otherwise, leave a row alone once it has exhausted its
  attempts, and let one refusal stand between the rows behind it. Batch size,
  attempt cap and backoff are read from application env at runtime.
- **`Courier.NatsPublisher`** — the behaviour, and `Noop`, which hands each
  envelope to the process that published it. That hand-off is what lets the relay
  be tested end to end with no broker, and it means the Gnat publisher is a
  config change (`config :courier, :nats_publisher`) and not a rewrite.

### Changed

- **Event types are now three segments: `courier.email.delivered`, not
  `email.delivered`.** courier-01/02 shipped the two-segment spelling, and
  `cafe contract lint` rejects it: core's frozen `eventType` grammar is
  `^[a-z][a-z0-9]*(-[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*$`
  and core's `docs/event-naming.md` §courier records the same drift ("courier's
  own manifest says `email.queued` and four siblings, which core v0.2's frozen
  grammar rejects"). `Courier.Events` and `cafaye.yml` now agree with it, and
  `Courier.EventsTest` checks the two against each other. **This changes the
  `type` on events already on the bus**, so any consumer that matches on
  `email.delivered` needs `courier.email.delivered`.
- **`exposes.api` now points at `openapi.yaml`**, courier's first documented HTTP
  surface. The document covers `/v1/webhook_endpoints`; the notification
  preferences routes exist and are tested but are not in it yet, which the file
  says in its own header rather than implying a completeness it does not have.
- **`CourierWeb.ErrorJSON`** no longer renders the Phoenix default body
  (`%{errors: %{detail: "Not Found"}}`) that `0.1.0` shipped. That shape is not a
  cafaye error body, and every client in this platform is written against
  `application/problem+json` with a stable `code`. `ErrorJSONTest` changed with it.

### Tests

A hundred and thirty, written before the code they cover, all written *first* in
this packet: the mailers, the deliver path, the preferences, the API, the
envelope, and the relay. What is worth naming:

- The provider is never mocked to make it fail — `Courier.TestSupport.FailingAdapter`
  is a real Swoosh adapter, because the Test adapter cannot fail and "the
  provider said no" has to be tested through the real path.
- Nothing sleeps. The relay is exercised in-process with `Oban.Testing.perform_job/3`,
  so a row is marked before the assertion reads it, and "one refusal does not
  hold up the rows behind it" is a publisher that refuses exactly one
  notification type.
- The tests that change application env are `async: false` and say why in a
  comment above `use`.
- Four assertions in the packet's own test files had to be corrected, because they
  could not pass as written: an envelope that omitted `specversion` while the
  next test asserted it, two `DateTime.from_iso8601/1` matches against a two-tuple
  the pinned Elixir has not returned since 1.4, a `Keyword.keys/1` on changeset
  errors keyed by request strings (which is what the AGENTS.md rule against
  `String.to_atom/1` on user input forces), and a relay fixture whose assertion
  asked for newest-first under a test named "publishes oldest first". Each edit
  says so in a comment at the line.

### Known gaps

- **No provider adapter.** `Swoosh.Adapters.Local` everywhere but test: a send
  succeeds and nothing is delivered. The provider packet replaces one line of
  configuration and needs credentials in `config/runtime.exs`.
- **No authentication on `/v1`.** There is no JWT verification here yet, so what
  the tests cover is shape and semantics, not who may ask. `consumes` is still
  empty and nothing subscribes courier to identity or billing events.
- **No NATS.** The relay publishes to a stand-in. Gnat is `config :courier,
  :nats_publisher` and a module that declares the behaviour.
- **No push, no inbound webhooks from anyone but Resend, and no event for a
  report courier cannot tie back to a send.** `email.bounced` and
  `email.complained` are emitted now, and `email.queued` and
  `notification.suppressed` are still declared and not emitted — the send path is
  synchronous and has no backlog, and `Courier.Deliver` still promises no event
  for a send it refused. A report whose `Message-ID` names no `outbox_events` row
  records its suppression and publishes no event, because core's schema requires
  a `user_id` courier would otherwise have to invent.
- **Templates are EEx, not HEEx.** This dependency set has no HEEx engine
  (`phoenix_template` 1.1, no LiveView, no `phoenix_component`) and the brief's
  "no dependency without approval" rule outranks the packet's wording. The one
  free-text field per message is escaped where it enters the template assigns.
- **No outbox retention, and no alert on `attempt_count` or on the age of the
  oldest unpublished row** — both are on core's checklist and both want the
  runtime numbers a running relay produces.
- **A readiness failure caused by a database that vanished under a running pool
  still takes about 4.4s** (from `0.1.0`; see `Courier.Health`).

## [0.1.0] — 2026-09-30

First cut: a deployable service with no notification logic in it. The point of
this release is that the next packets have a place to land and a gate to pass,
not that courier can send email.

### Added

- **Scaffold** — Phoenix 1.8.15 API-only application (`mix phx.new --no-html
  --no-assets --no-dashboard --no-gettext --no-mailer`), Elixir 1.20.4 on OTP
  29.1.1, Ecto with Postgres. No Swoosh, no Oban, no webhook delivery.
- **`GET /healthz`** — liveness. `200 {"status":"ok"}` whenever the endpoint can
  dispatch a request; it never touches the database, so a database outage cannot
  make an orchestrator restart a healthy container.
- **`GET /readyz`** — readiness. `200 {"status":"ok"}` when the database answers
  a query, `503 {"status":"error","checks":{"database":"unavailable"}}` when it
  does not. The underlying reason is logged, never returned.
- **`Courier.Health`** — the readiness check itself, as `ready?/0` and
  `ready?/1`. Every database failure mode (repo not started, pool gone,
  connection refused, timeout) comes back as `{:error, reason}`; a probe must
  never be able to take down the endpoint that serves it.
- **Probe SSL exemption** — `config/prod.exs` excludes `/healthz` and `/readyz`
  from `force_ssl`. Without it a released courier answers `301` to https on its
  own probes and an orchestrator reads that as a dead service.
- **`Dockerfile`** — two-stage build: a `hexpm/elixir` builder that compiles a
  `mix release` carrying its own ERTS, and a slim Debian final stage with no
  Erlang, no Elixir and no toolchain, running as `nobody`, with a `HEALTHCHECK`
  against `/readyz`.
- **Release scripts** — `rel/overlays/bin/server` (the image's entrypoint) and
  `rel/overlays/bin/migrate`, with `Courier.Release` for running migrations
  without Mix.
- **`docker-compose.yml`** — `postgres:17` plus that release image, with the app
  gated on `pg_isready`.
- **`bin/prime`** — the gate: `mix local.hex --force && mix deps.get && mix
  ecto.setup && mix test`.
- **`mise.toml`** — the Elixir and Erlang pins, and `mise run prime`.
- **`cafaye.yml`** — the manifest, validated against
  `core/schemas/cafaye.manifest.schema.json`. Declares the five event types in
  core's courier catalog; none is emitted yet.
- **`AGENTS.md`**, **`README.md`**, **`.gitignore`**, **`.dockerignore`**.

### Tests

Seventeen, all written before the code they cover.

- The probes, through `ConnCase`, including the database-down path — which stops
  `Courier.Repo` under the application supervisor rather than mocking the check,
  and asserts that `/healthz` still answers 200 while it is down.
- The routes: which controller and action each path resolves to, that the probes
  sit outside `/api`, and that they do not answer write methods.
- The production SSL exclusion, read back out of `config/prod.exs` the way a
  release would read it.
- `Courier.Health` on its own: `:ok` against a live repo, an error tuple — never
  an exception — against one that is not running.

### Known gaps

- No migrations, so `bin/migrate` (`Courier.Release.migrate/0`, from
  `mix phx.gen.release`) answers `Migrations already up`, and the compose stack
  does not run it. Whoever adds the first migration decides whether compose
  grows a migrate service or the deploy pipeline calls `bin/migrate` directly.
  `Courier.Release` is generator boilerplate and is not covered by a test of its
  own; `mix ecto.migrate`, which the `test` alias runs on every suite, exercises
  the same `Ecto.Migrator` calls underneath it.
- No OpenAPI document, so `exposes.api` is unset in `cafaye.yml`. `/healthz` and
  `/readyz` are probes, not contract surface.
- `consumes` is empty. Nothing subscribes courier to identity or billing events
  yet, and when it does, every consumer has to be idempotent and tested:
  delivery to courier is at-least-once (PLAN.md §3).
- A readiness failure caused by a database that vanished under a running pool
  takes about 4.4s to answer, from DBConnection's queue backpressure. The
  verdict is correct at any probe timeout, but the latency is worth knowing
  before an orchestrator is configured; `Courier.Health` explains why the probe
  cannot shorten it.

[Unreleased]: https://cafaye.com/changelog/courier
[0.1.0]: https://cafaye.com/changelog/courier/v0.1.0
