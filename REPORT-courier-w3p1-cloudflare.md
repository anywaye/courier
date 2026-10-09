# REPORT-courier-w3p1-cloudflare — the third provider, and what the partial work
# was actually hiding

Branch `agents-first/w3p1`, worktree `courier-w3p1`. Three commits:

```
5a777f6 w3p1: the third provider's second boot gate, and the floors at 1625
d05ad55 w3p1: the Cloudflare adapter's contract fetched, the 202-with-a-failed-result surfaced, and the floors re-measured on a fresh postgres
b2b2fa9 w3p1: recovery commit — the previous attempt's adapter and fake server, unverified until gated
```

Nothing is pushed and nothing is merged.

## Where the packet stands

**Done, and green.** `COURIER_MAIL_ADAPTER=cloudflare` resolves through the
seam to `Courier.Adapters.CloudflareEmail` with one required variable
(`COURIER_CLOUDFLARE_API_KEY`); it sends through a real HTTP request to a real
listener and reports every failure; selected-but-unconfigured refuses at boot
naming the variable and the adapter; `mix precommit` is green at
**`Result: 1625 passed`, exit 0**.

## What the previous worker got right, and I kept verbatim

The adapter, the fake server and the delivery tests were all sound work, and
the judgement to keep them was a judgement against this repository's own
conventions rather than against a blank page.

* **The provider is MailChannels, not Cloudflare.** Cloudflare Email Routing
  is receive-only and has no send API; the sending half of a Cloudflare Email
  connection is the MailChannels transactional API. That is the right contract
  and it is the part most likely to have been guessed wrong.
* **A courier-owned Swoosh adapter, in Postmark's shape.** `use Swoosh.Adapter,
  required_config: [:api_key]`, `Swoosh.ApiClient.post/4`, the `config[:base_url]`
  seam `Swoosh.Adapters.Mailgun` and `Postmark` both have. No new dependency —
  a rule this repository states twice.
* **A real Bandit listener, not a mock.** `Courier.TestSupport.MailChannelsServer`
  is the HTTP sibling of `Courier.TestSupport.SmtpServer`, and it exists for the
  reason that file does: a mock provider proves the mock works.
* **The seam was not restructured.** Third entry in `providers()`, one builder,
  one describer, refusals generated from the table. No per-provider branch.

## What was wrong in it

**1. The credentials test file did not compile, and the whole suite died
before its first test.** `mailer_adapter_credentials_test.exs` called
`cloudflare_config/0`, which was never written. `mix test` exited 1 with a
CompileError and printed no `Result:` line at all — so a green run is not a
thing the previous worker ever saw, and 45 tests were failing behind it on the
database it was using. Fixed by writing the helper, with the key as the canary
so the assertion is that the key courier was configured with never reaches a
log line.

**2. The contract was written from memory, because the worker believed the docs
were unreachable.** They are, and the spec is published as OpenAPI:

```
https://docs.mailchannels.com/llms.txt
https://docs.mailchannels.com/api-reference/send/send-an-email   (Email API reference v1.7.1)
https://docs.mailchannels.com/email-api/errors.md
```

The previous worker's shapes were **right in every particular**. Reading the
schema is still what turned one of them from "probably fine" into a defect —
below — and it fixed two things that knowledge alone got subtly wrong:
`headers` is `additionalProperties: string`, an OBJECT, not a Postmark
`[{Name, Value}]` array; and `attachments[].content_id` is the **bare** cid,
where MailChannels documents `<img src="cid:logo123">` referring to an
attachment whose `content_id` is `logo123` — the `cid:` prefix a
Postmark-shaped adapter adds would be a broken image in every HTML mail.

## The defect this packet's own work found

`SendResult` is `{index, message_id, reason, status}` with `status` in
`sent | failed`. **So a 202 can carry a message that failed** — the request
was well-formed and the provider refused the one message inside it. The
previous worker's adapter returned `{:ok, %{id: request_id}}` for every 2xx,
which is the silent default this packet exists to end, wearing a success
status: an outbox row, a `courier.email.delivered` event, and mail that was
never sent. A status-code check cannot see it.

`accepted/2` now inspects `results` and answers `{:error, {code, failures}}`
when any result is not `sent`. Four tests cover the 2xx space that had none:
the failed 202, the all-sent 202, the 200 dry-run body (`{"data": [...]}`, a
success with no id), and an unparseable 2xx (a success with no id — an adapter
must not invent a refusal the provider did not make). One test covers the
optional payload shapes cc / bcc / reply-to / headers / attachments, because
`Courier.Mailers` produces none of them, so the happy path exercised none of
them, and a payload builder only ever asserted on inputs it is guaranteed to
produce is one nothing has checked.

## The floors, and where they were measured

`gate.yml` `minimum` 1600 -> 1625, CI whole 1600 -> 1625, no-database 723 ->
748 (34 files), database UNCHANGED at 877 (47 files). 1625 is 748 + 877, so
the parts still sum to the whole. The +25 are 19 the previous worker wrote and
5 (then 1) from this one.

**The measurement is on `bin/gate-db`'s postgres, not on kit's shared cluster,
and that difference is the finding of this packet.** The brief named
`COURIER_TEST_PG_PORT=15500`, which is kit's cluster, and that run gave
**45 failures and no `Result:` line** on this exact tree: `notification_events`,
`notifications` and `consumed_events` land in the `cafaye` schema instead of
`public`, so `backup_tables_test.exs` and `notifications_boundary_test.exs`
fail on tables the migrations did create. That cluster's `courier_test` carries
another worker's half-applied state. None of it is this packet's code, and a
floor moved on that measurement would have been the contaminated-run defect
`gate.yml` already describes. gate.yml's declared `requirements` block already
names the right database; the brief did not.

## What is NOT done

* **DKIM / SPF / domain authorisation is W3-P5**, by scope. The Cloudflare
  sender needs the `_mailchannels` TXT record for Domain Lockdown and
  `include:relay.mailchannels.net` in SPF. The adapter's moduledoc and README
  say so rather than implying a Cloudflare sender works out of the box.
* **No real send against the live API.** There is no MailChannels key in this
  environment, and the packet's proof is the real socket against a real
  listener. That is the same standard `smtp_delivery_test.exs` holds itself to.
* **`config/deploy.yml` and `chart/values.yaml` do not name
  `COURIER_CLOUDFLARE_API_KEY`**, deliberately: neither names
  `COURIER_POSTMARK_API_TOKEN` either, and both carry the boot-REQUIRED
  variables. The adapter credential is adapter-contingent, so an operator
  setting `COURIER_MAIL_ADAPTER=cloudflare` adds it to their own secret store.
  If the manager wants it pre-declared for the launch stack, that is a one-line
  change in each file and a decision, not an omission I could make.
* **A bug report on the shared cluster.** Whoever owns kit's postgres should
  know that a worker migrating `courier_test` gets three tables in the wrong
  schema. I have not filed it, and I have not touched that database.

## Successor's first move

There isn't one for this packet — it is finished and gated. If you are here for
W3-P5 (domain authorisation), start from
`test/courier/cloudflare_delivery_test.exs` for the shape a provider test takes
in this repository, and note that `MailChannelsServer` already answers any
status you set, so a DKIM/SPF refusal needs no new fixture.
