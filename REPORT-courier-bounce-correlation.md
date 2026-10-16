# courier — bounce correlation: the outbox records an id the provider will never quote

## What the defect was

A real password reset sent through Cloudflare was recorded as
`outbox_events.subject = courier-2be282f1-c01e-4c65-b7d5-1e1dbbeb8df9` —
courier's own generated id (`"courier-" <> Ecto.UUID.generate()`), written into
the message's `Message-ID` header by `Courier.Deliver.tag/2`. Cloudflare owns the
`Message-ID`: it refuses a caller-supplied one (`400 / 10202`) and reports its
own `result.message_id`, which `Courier.Adapters.CloudflareEmail.accepted/2`
returns as the receipt id. `Courier.Deliver.send_and_record/4` matched
`{:ok, _metadata}` and **discarded** it, so the provider's id was recorded
nowhere.

The provider's bounce and delivery reports quote **its** id, and
`Courier.InboundReports` joined a report back to a send by matching the quoted
`Message-ID` against `outbox_events.subject` — courier's id. So the two ids never
met: the report recorded its suppression, published no event, and logged
`courier holds no sent message for Message-ID "…"`. Nothing could say which
send, which user, or which notification type the bounce was about.

## Option chosen: record both ids (option 1)

Courier's own id is load-bearing — every existing row holds one,
`Courier.OutboxEvent.envelope/1` publishes it, and the platform's events are
keyed on it — so it stays in `subject`, and the provider's `result.message_id`
is recorded **beside** it in a new, nullable `outbox_events.provider_message_id`
column. `Courier.InboundReports` matches each candidate `Message-ID` against
**both** columns.

Option 2 (record only the provider's id) was rejected because it breaks every
existing row, the published envelope, and `courier.email.delivered`'s `data`
shape for no gain this column does not already provide. Nothing was removed, so
no existing contract changed — the change is additive in every direction.

The provider's id is a **column, not a field in the event's `data`**:
`courier.email.delivered`'s schema in `cafaye/core` is `additionalProperties:
false` with four frozen fields, so a fifth key would fail core's own schema on
the bus. It is a fact for the join, which reads rows, not for the payload.

## Schema change, and whether it is additive

Additive. One migration,
`priv/repo/migrations/20261016120000_add_provider_message_id_to_outbox_events.exs`:

* `alter table(:outbox_events) add :provider_message_id, :string` — nullable, no
  default, no backfill. Every existing row reads `NULL`, which is the honest
  state ("this send predates the column / its provider gave no id").
* a partial index `outbox_events_provider_message_id_idx` on the column
  (`WHERE provider_message_id IS NOT NULL`) — the join's own lookup.
* `Courier.OutboxEvent` gains `field :provider_message_id, :string` and
  `:provider_message_id` is added to the `cast/3` list (optional; not
  `validate_required`).
* No grant change: `outbox_events` already holds `select, insert, update` for
  `courier_app`, and a new column on an existing table needs no new privilege.

`data`, `subject`, the envelope, the adapter's receipt shape and the
`{address, name}` wire format are all untouched.

## Where the join now happens

* **Persistence** — `lib/courier/deliver.ex`, `Courier.Deliver.send_and_record/4`
  calls `record(type, user_id, message_id, provider_message_id(receipt), email)`;
  `record/5` writes `provider_message_id` into the
  `OutboxEvent.changeset/2` **inside the same `Repo.transaction/1** that dialled
  the provider. `provider_message_id/1` reads `%{id: id}` / `%{"id" => id}` and
  answers `nil` for anything else.
* **Join** — `lib/courier/inbound_reports.ex`, `Courier.InboundReports.sent/1`
  (called from `sent_for/1`): the `WHERE` is
  `event.subject == ^candidate or event.provider_message_id == ^candidate`
  (both columns, both candidate forms), and `attributable?/1` keeps the
  `user_id` / `notification_type` check a publishable payload needs.

## Commits

| sha | subject |
| --- | --- |
| `e5b5070` | feat(bounce-correlation): record the provider's message id beside courier's |
| `b63ca8b` | chore(gate): raise the floors to the measured provider-message-id tree |
| (the commit carrying this file) | docs(bounce-correlation): the packet report |

Branch: `feat/bounce-correlation`. Nothing merged, nothing pushed.

## Testing

### The narrow command

```sh
mise exec -- mix test test/courier/deliver_test.exs \
  test/courier_web/controllers/inbound_controller_test.exs \
  test/courier/cloudflare_delivery_test.exs \
  test/courier/bounce_correlation_test.exs \
  test/courier/inbound_test.exs test/courier/inbound/
# Result: 190 passed
```

The new file `test/courier/bounce_correlation_test.exs` is `async: false` (it
swaps `config :courier, Courier.Mailer` and `config :swoosh, :api_client`) and a
`CourierWeb.ConnCase` (every claim is about a row through the real router). It
drives:

1. a real send through `Courier.Adapters.CloudflareEmail` against
   `Courier.TestSupport.CloudflareServer`, whose 2xx carries
   `result.message_id` — asserting `outbox_events.provider_message_id` equals
   what the fixture answered and `subject` is still courier's own id;
2. a 2xx **without** `message_id` — asserting nothing is stored and no id is
   invented;
3. **the join**: a signed `POST /inbound/resend` whose payload quotes the
   provider's id, asserting `events == 1`, the warning absent, and the published
   `courier.email.bounced` naming courier's own `message_id`, the right `user_id`
   and the right `notification_type`;
4. courier's own id still resolving with a provider id recorded beside it
   (additive);
5. an id courier holds for neither column still warning and publishing nothing.

### The full gate

```sh
mise run prime
# Result: 1802 passed        exit: 0
```

`mise run prime` needs network on the first `mix local.hex --force`; the first
attempt timed out on `builds.hex.pm` and was re-run. `mix precommit` also
reported `Result: 1802 passed`, exit 0.

### Red proofs

| mutation | file | tests that went red | result |
| --- | --- | --- | --- |
| join reads only `event.subject` again (drop `or provider_message_id == …`) | `lib/courier/inbound_reports.ex` | `Courier.BounceCorrelationTest` "a report quoting the provider's id resolves to the send instead of warning…" | `4/5 passed` |
| `:provider_message_id` dropped from `OutboxEvent.changeset/2`'s cast list | `lib/courier/outbox_event.ex` | the same join test **and** "records the provider's receipt id, and keeps courier's own" | `3/5 passed` |

Both reverts restored `5 passed`.

## Floors moved (measured, in the same commits)

The gate is a decrease detector, so five new tests require raising the floors.
Measured by running the two tier greps and the whole suite:

| | before | after |
| --- | --- | --- |
| whole suite | 1797 | **1802** |
| no database | 815 (37 files) | 815 (37 files) |
| database | 982 (56 files) | **987 (57 files)** |

`1802 = 815 + 987`, so the parts still sum to the whole. Raised in `gate.yml`
(`minimum`), `.github/workflows/ci.yml` (the whole-suite, database and summary
floors, plus the tier step's name), and the comments above each. `bin/gate-self-test`
passes 11/11 and ran the real gate with `Result: 1802 passed`.

## Deliberately left alone

* courier's own id, `outbox_events.subject`, the published envelope and the
  platform events.
* the adapter's receipt shape and the `{address, name}` wire format.
* the `with_data/2` contract: a resolved report still publishes courier's own
  `message_id` and the send's `user_id` / `notification_type`; the provider's id
  only ever resolves the join.
* the "courier holds no sent message" warning — it is unchanged and still fires
  when nothing matches.
* the inbound parser (`Courier.Inbound.Resend`) and its `provider_event_id` key.

## What the inbound path does that made this harder than the brief implies

* **The provider that sends is not the provider that reports.** Outbound is
  configurable (`smtp` / `postmark` / `cloudflare`); inbound is Resend-shaped
  (`/inbound/resend`, `Courier.Inbound.Resend`). So the stored provider id and
  the report's `data.message_id` come from two vocabularies, and the correlation
  is only as good as whichever provider the report actually comes from. This
  packet makes the id courier sent through available to the join; it does not
  reconcile the two providers, and the brief's "Cloudflare's report" is not a
  path that exists in this tree today.
* **Two candidate spellings and a qualifier.** `Suppression` stores the quoted
  `Message-ID` with brackets stripped and the qualifier kept (`strip_qualifier/1`
  is a no-op on an id with no `@`), and the row holds courier's id in `subject`
  and the provider's in a second column, so the join has to try the stripped
  form and the quoted form against both columns.
* **The join is inside a transaction that may not use a savepoint.** The report's
  suppression and its event are one transaction, and `suppression.message_id` is
  only ever in hand there, which is why the lookup stayed a single query rather
  than a two-step read.
