# REPORT — courier-w71: a second provider, so "email from different providers" is true

**Branch:** `worker/courier-w71-secondprovider`
**Base commit:** `5a96a2b` (Merge worker/courier-w70-emailchange)
**Commits:** `2975128`, `8cc98ef`, `f097c54`, `a57f4af`
**Gate:** `mise exec -- ./bin/prime` → `Result: 1576 passed`, exit 0 (final tree).
**Floors:** whole 1576, no-database 698 (31 files), database 878 (47 files) —
1576 = 698 + 878, re-measured by running the tier greps. `gate.yml` minimum
moved to 1576 in the same commits.

## What the packet was for

Launch claim L9: "email, through more than one provider". Before this packet
`COURIER_MAIL_ADAPTER` accepted `smtp` and refused everything else, so
"different providers" was not possible without editing Elixir. A buyer's choice
of provider should be configuration, not code — and that is also what proves
the adapter seam is a seam and not a single hard-coded path.

## The provider: Postmark

**Postmark**, named here as the packet requires. Reasons:

* transactional-only, which matches the "transactional email for the platform"
  line in the moduledoc — courier sends no bulk mail and never will (all three
  types are `:transactional` in `Courier.Mailers.kinds/0`);
* API-token auth, one credential, no relay/TLS/enum surface to configure;
* Swoosh ships `Swoosh.Adapters.Postmark`, so no HTTP client was hand-written.

SendGrid, Mailgun, Resend and AmazonSES were the alternatives; all have SMTP
fronts, so SMTP already reaches them, and Postmark is the one that is
transactional-only by construction.

## What was there when this attempt started

The previous attempt (killed mid-work by the model endpoint, not the packet)
had left uncommitted partial work. I read it with `git status`/`git diff`,
judged it **correct in structure and kept it**: the provider table, the
table-driven `adapter!/1` and `describe/1`, `required!/2` taking a provider
name, and the tests. What it left undone, which I finished:

* `postmark_adapter/0`, `describe_smtp/1`, `describe_postmark/1`,
  `supported_values/0` and `api_client/1` were all referenced but never
  defined — the tree did not compile;
* `smtp_adapter/0` and `credentials/1` still called `required!/1` with one
  argument after the signature changed to `required!/2`;
* README, CHANGELOG, the CI floors and `gate.yml` were untouched;
* the "silent adapter refused in `:dev`" proof was not asserted.

## Making the set data

`providers()/0` is the one table a third provider is added to:

```elixir
{:smtp, Swoosh.Adapters.SMTP, nil, "the universal one — …",
 &smtp_adapter/0, &describe_smtp/1},
{:postmark, Swoosh.Adapters.Postmark, Swoosh.ApiClient.Req,
 "transactional-only, API-token auth",
 &postmark_adapter/0, &describe_postmark/1}
```

`adapter!/1`, `describe/1`, `api_client/1` and the supported-values refusal
all look the table up; none has a per-provider branch. A third provider is an
entry here plus two functions.

**The cost, and it is a finding:** the table had to be a *function*, not a
module attribute. A module attribute is expanded where it is written, and a
capture of a local function inside one is a compile error **no matter how the
definitions are ordered** — measured on Elixir 1.20.4:

```
def bar, do: 1
@f &bar/0      # => undefined function bar/0
```

The first draft used `@providers` and the build went red until the table
became `providers/0`. The comment above the table records the measurement so
the next reader does not "simplify" it back.

## The proofs (each was red before the implementation)

* selecting `postmark` yields `Swoosh.Adapters.Postmark` **with the token
  wired** — `config[:adapter] == Swoosh.Adapters.Postmark`,
  `config[:api_key] == @sentinel`;
* a **missing token is refused with the variable named** —
  `COURIER_POSTMARK_API_TOKEN is missing`, and the refusal names the adapter
  the variable belongs to (`required!/2`);
* an **empty** token is treated as missing, not sent to the provider;
* an **unknown** adapter name is still refused, and the supported-values list
  is *generated from the table* — asserted, so a third provider appears there
  without an edit to the refusal;
* a **silent** adapter (`Local`/`Test`) is still refused in **every**
  environment including `:dev` — the unknown-adapter branch has no environment
  guard; this attempt added the missing `:dev`/`:test` assertion (the previous
  attempt only asserted `:prod`);
* `none` is still refused in `:prod`;
* **no credential reaches `describe/1`'s output** for either provider —
  `describe_postmark/1` prints `adapter=postmark token=set|unset`, and the
  credentials test asserts the canary is absent from a captured log, paired
  with the presence assertions (`token=set`, `token=unset`, `adapter=postmark`)
  that keep the refusal honest. The repository scans gained an `api_key:` half.

## Wiring

`config/runtime.exs` turns Swoosh's HTTP client on **from the resolved
adapter** (`MailerAdapter.api_client/1`) rather than from a second variable:
SMTP dials `gen_smtp` directly and never calls it; Postmark posts through
`Swoosh.ApiClient.Req`. A deployment that configured the adapter and forgot
the client would otherwise boot with both halves dark. `nil` from the table is
mapped to `false` — the same "off" value `config/config.exs` uses.

## Documentation

README's operator-variable table gains `COURIER_POSTMARK_API_TOKEN` with the
same "required when this adapter is selected" wording; the moduledoc's variable
block gains it too; the CHANGELOG gains the Unreleased entry. The unset-adapter
refusal now names both providers, not just SMTP.

## No live send was exercised

**This machine has no provider account and the packet did not invent one.**
The proof is configuration mapping and refusals. A real send needs a Postmark
server token (from `POST /v1/servers` or the dashboard) set as
`COURIER_POSTMARK_API_TOKEN`; the send itself would go through
`Swoosh.Adapters.Postmark` unchanged — the adapter is Swoosh's, and courier's
half of the path (compose → `Courier.Deliver` → outbox) is provider-agnostic
and already proven by the SMTP round-trip test.

## Gaps, named not built (all after launch)

* **Bounce/complaint webhooks for Postmark.** The inbound surface is
  Resend-only today (`COURIER_INBOUND_RESEND_SECRET`, `provider: "resend"`).
  A Postmark deployment gets no automatic suppression sync.
* **Suppression-list sync.** Nothing pulls Postmark's suppressions in.
* **Per-provider rate limits.** None; the retry budget is courier's own.
* **A third provider is an entry plus two functions** — the table is data, but
  the two functions (builder, describer) are still hand-written per provider.
  That is the intended shape, not a defect, but it is worth stating: the
  *selection* is data, the *per-provider logic* is code.
