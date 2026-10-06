# REPORT — courier: the in-app notification record

Branch `worker/w5-inapp-notifications`. Packet
`moon/prompts/m41-courier-inapp-notifications-01.md`.

## What this is

Two tables and the context over them, so courier can answer *"what was I told
about, and which of those have I read?"* — a question it could not answer at all
before, because preferences existed to decide whether to send and nothing recorded
what was sent. `parlor` renders an inbox from this.

- `priv/repo/migrations/20261006120000_create_notifications.exs`
- `lib/courier/notification_event.ex`, `lib/courier/notification.ex`,
  `lib/courier/notifications.ex`
- `test/courier/notifications_test.exs` (45) and
  `test/courier/notifications_boundary_test.exs` (16)
- `reports/courier-row-level-security/prove.sh` §6b/§6c — 18 → 23 assertions

---

## What I measured

Every command below was run and its output read. The database is the **real
PostgreSQL 17.11** the migrations apply to, not a `pg_dump`/restore clone, so the
policies and the FORCE bits are the ones the migration actually wrote.

### The gate

| # | command | exit | result |
| --- | --- | --- | --- |
| 1 | `mix compile --warnings-as-errors` | **0** | clean, dev and test |
| 2 | `mix format --check-formatted` | **0** | — |
| 3 | `mix test` | **0** | **1409 passed** |
| 4 | `bin/assert-suite /tmp/prime.log "whole suite" 1409` | **0** | 1409 ≥ 1409 |
| 5 | no-database tier (28 files) | **0** | **645 passed**, floor 645, unmoved |
| 6 | database tier (42 files) | **0** | **764 passed**, floor raised 703 → 764 |
| 7 | SSRF table | **0** | **62 passed**, floor unmoved |
| 8 | `reports/courier-row-level-security/prove.sh` | **0** | **23/23**, was 18/18 |
| 9 | `core/harness/bin/gate-check` | **0** | 0 failures, 2 warnings |
| 10 | `core/harness/bin/account-scope-check` | **0** | 9 account-scoped, 0 stale, 0 undeclared |
| 11 | `core/harness/bin/numeric-check` | **0** | 0 failures over 11 positions |
| 12 | `core/harness/bin/reserved-check` | **0** | 0 failures |

**645 + 764 = 1409**, so the tiers still sum to the whole. All 61 new tests are
in the database tier and the split is read off the case templates by the same
`grep` the CI tier steps use — neither new file could have fallen outside it,
because both are `Courier.DataCase` and that is what puts a file in that tier.

### The boundary, and the two mutations

The requirement is a test that fails when the policy is absent. Both mutations
were applied to the real database with `psql`, the suite was run, and the change
was reverted:

| mutation | tests red | which ones |
| --- | --- | --- |
| `alter table {notifications, notification_events} disable row level security` | **8 of 16** | every denial, plus `relrowsecurity` and the sweep |
| `alter table {…} no force row level security` (RLS still on) | **4 of 16** | **all four are catalog assertions** |

The second line is the whole point of the packet. With the FORCE bit gone and
RLS still enabled, **every login-role denial stays green**, because
`courier_app` is a subject of the policies either way. `relforcerowsecurity` is
the only thing that distinguishes that state from a working boundary, and it is
the bit no lint in the fleet checks — which is why `NotificationsBoundaryTest`
asserts it from `pg_class` and why the FORCE half is stated in the file's own
moduledoc as the half no login-role denial can detect.

### The catalog, before and after

```
notification_events rls=true force=true
notifications      rls=true force=true

notifications_cafaye_select | r | {kaka,courier_app}
notifications_cafaye_insert | a | {kaka,courier_app}
notifications_cafaye_update | w | {kaka,courier_app}
notifications_cafaye_delete | d | {kaka,courier_app}
```

`protect_table` grants the DML `courier_app` needs and **no sequence grant is
required**, because both tables key on a uuid. `20261005120000_grant_app_role_
runtime_dml` exists to work around the opposite — kit's substrate at the
`@substrate_sha` this repository pins grants table DML and no `USAGE` on the
sequence, so a protected table with a `bigserial` column is uninsertable by the
login role. A uuid key means that defect cannot reach here, and the migration
says so rather than leaving a reader to work it out by inserting a row.

---

## What I deliberately did not do

- **No route, no controller, no `openapi.yaml` change.** The packet asked for
  contexts and functions, and `openapi.yaml` is updated *if the new routes are
  exposed*. The reference's notification body is an ERB fragment rendered through
  `ApplicationController.render`; courier is API-only and renders nothing, so the
  route and its body shape are `parlor`'s next packet's decision to make. The
  database URL in `openapi.yaml` is unchanged and the document is not stale,
  because nothing about the HTTP surface moved.
- **No rendering of any kind.** No template, body, partial or view. `params` is
  jsonb and there is nowhere in this tree for a rendered string to live.
- **No change to the mail path.** `Courier.Deliver`, `Courier.Mailers`,
  `Courier.Unsubscribes` and `Courier.NotificationPreferences` are untouched.
  Nothing here sends anything, and nothing here is called by anything that does.
  The two are deliberately unconnected: coupling them would make recording
  contingent on sending, and a notification a person already has in their inbox
  must survive a mail that bounced.
- **No `cafaye.yml` change and no new event type.** `Courier.Notifications.types/0`
  is a *third* list, deliberately: `Courier.Events.types/0` is what goes on the bus
  and `Courier.Mailers.types/0` is what goes as mail. Folding an in-app type into
  either would make every notification a bus event, and `exposes.events` is a
  contract with core's frozen payload schemas.
- **No `tenancy.yml` rewrite.** See below — I did not re-derive a declaration
  that is already red and whose checker is core's.

---

## Findings

### 1. `Repo.transaction/1` wraps what its function returns, and one layer of that was invisible

`record/2` answered `{:ok, {:ok, %{event: …}}}`. The rollback branch returned
`{:error, {:event, changeset}}` unwrapped, so the two paths disagreed by one
layer and a spec had to lie about one of them. 31 tests failed on a shape nobody
had written down.

The same function also had a **second, worse** version of the same mistake:
`Repo.transaction/1` whose function **returns** `{:error, …}` **commits**. A `with`
that returned the error would have committed the event row it had just inserted
with no notification — precisely the "event with no recipient" state the module
exists to make impossible. The rollback is the mechanism, not a comment, and it
is asserted from both directions: a refused *event* and a refused *notification*
(the second needs a 300-character recipient id, because that is the only input
that gets past `record/2`'s own guard and as far as the column's length limit).

### 2. Ecto's `on_conflict: :nothing` documentation is true for half the key types Postgres has

The documented behaviour is that the returned struct "will be returned with the
`id` set to nil". That is true for a **database-generated** primary key and false
for one Ecto generates on the client side. Measured, with the same recipient
named twice in one call:

```
ids:       ["b8bcf74d-…", "c6ccdaaa-…"]   <- two DIFFERENT uuids
event ids: ["74bc0464-…", "74bc0464-…"]   <- one event, as designed
rows in the table: 1                      <- the index did its job
in the table:       [{"b8bcf74d-…", "9f8e7d6c-…"}]
```

So the database was right, the index was right, and the function handed its
caller an id belonging to no row — the worst of the three answers, because it is
a `200`-shaped answer to a write that did not happen. The fix is to stop asking
Ecto which branch it took: the row is read back by the unique key on every call,
inserted or not, so the answer is the stored row by construction.

### 3. `update_all/3` returns `nil` rows without a `select`, and `{1, nil}` reads as not-found

`mark_seen/3` answered `{:error, :not_found}` for a row that existed, was
visible, and **was successfully updated**. `Ecto.Repo.update_all/3`'s own doc says
the second element "is `nil` by default unless a `select` is supplied" — and
`{1, nil}` does not match `{1, [notification]}`, so the `with` fell through. This
is the narrowest version of the trap this repository writes about: **a translation
broad enough to hide a syntax error will hide one.** Here the "translation" is a
`case` with a catch-all.

### 4. A single-recipient `record/2` made the unique index unfalsifiable

The packet asked for "record an event, address it to one recipient". Written
literally, every call mints a new `notification_event_id`, so
`notifications_one_per_recipient_index` **can never fire** and the
`on_conflict: :nothing` branch is dead code. A constraint that cannot be
violated is not a constraint.

So `record/2` takes `:recipients`, a non-empty list, with `:recipient` kept as
the shorthand for one. That makes the shape the reference has reachable — one
event, one row per person, and the same person named twice in one list collapsing
to one row — and it is the reason there are two tables rather than one. The
test that names this is `THE SAME PERSON NAMED TWICE IS ONE ROW`, and it is the
one that proves the index.

### 5. A `pg_class` read is the only witness for FORCE that a suite can make

Already covered above, and it is why the prove script has a §6c. Worth adding to
the list of things a suite cannot see about itself: the test connection is
`courier_app`, which is not the owner, and the only credential that *is* the
owner is a superuser here, which bypasses RLS unconditionally. There is no third
role available that is both non-superuser and the owner. So the FORCE half is a
catalog read in-suite, and the owner's denials stay in `prove.sh`, where
`SET ROLE` gets out of superuser.

### 6. `Courier.DataCase.as_account/2` cannot express an aborted transaction

It is `case Tenancy.with_account(...) do {:ok, result} -> result end` — one
clause. A `42501` inside the transaction aborts it, so the `COMMIT` fails and
the helper raises `CaseClauseError` on `{:error, :rollback}` rather than
returning it. That is the right design for a helper whose users want a scoped
read, and it is unable to express this one case, so
`NotificationsBoundaryTest` calls `Courier.Tenancy.with_account/3` directly
**and asserts the `{:error, :rollback}`** — which is also the correct claim: the
write was refused and nothing was committed.

### 7. `backup_tables_test.exs` went red on a table nobody had declared, which is it working

    the database carries ["notification_events", "notifications"], which is
    neither a table courier's migrations create nor one of
    ["schema_migrations", "oban_peers"]. A table nobody has decided to back up
    is a table a restore loses.

Exactly its job. Both tables are now declared with what each is **for**, and
`README.md`'s backup table says why `seen_at`/`read_at` are named there
explicitly: an inbox restored with its read state lost shows every notification as
unread to every person who had already read it.

### 8. Two of my own test bugs, recorded because both produced a *false alarm about a boundary*

- The sweep assertion was `@tables -- named_by_sweep() == @tables`. `@tables` is
  written notification-first and the sweep sorts by name, so it reported
  `["notifications", "notification_events"]` as **unprotected** — a message that
  says a boundary is missing and is wrong is worse than no message, because it is
  the kind a reader stops believing. Both sides are sorted now.
- The no-identity probe in `prove.sh` was a bare `select count(*)`, missing the
  `set role courier_app` every other probe carries. It answered **2** — every row
  — because the connection was the migration's role, and on this cluster that role
  is a superuser. `ask/1` runs whatever SQL it is given, so a probe that forgets
  `set role` silently probes the superuser rather than failing to probe at all.

### 9. `NotificationEvent.changeset/2` returned a list, and the type checker caught it

`validate_record_reference/1` returned the keyword list `validate_change/3` expects
from *its* function, not the shape `changeset/2` returns from *this* one — so
`record/2` piped a list into `Ecto.Changeset.put_change/3`. The error named the
shape and not the cause, and a test asserting the valid path would not have
reached the offending clause until somebody wrote a record-carrying test.

### 10. Smaller ones, each in the file it happened in

- `add :x, references(:t, …), type: :binary_id` puts `type:` on `add/3`, which
  does not take it; the column stays `bigserial` and Postgres answers
  `datatype_mismatch … Key columns … are of incompatible types: bigint and uuid`,
  naming the constraint and both types and not the option that caused it.
- `belongs_to :event, NotificationEvent` needs an explicit `alias`. Without it the
  compiler emits `invalid association … does not exist` as a **warning**, the
  module still compiles, and `preload: :event` raises at the call site.
- `Ecto.Query.update/3` does **not** stamp `updated_at`, and here that is right:
  a stamp that moved on every call would answer "when did they last look at it" on
  a column whose meaning is "when did they FIRST see it".
- A private `limit/2` shadows `Ecto.Query.limit/2`, and `min(requested, 100)` is
  an AST to a macro that wants a literal or a variable. Both read as though the
  *query* were malformed.
- `$1::regclass` hands Postgrex's `oid` encoder a string: `you tried to use a
  binary for an oid type … when an integer was expected`.

---

## Pre-existing reds, not caused by this packet

Confirmed by running each checker against `moon/cafaye/courier` at the **same
commit** (`e3e6699`):

- `core/harness/bin/tenancy-check` — **27 failures on both**. Every one is
  `tenancy.denial-missing`, i.e. `tenancy.yml` points `negative.line` at lines that
  no longer carry the assertion they name. `db-isolation-check` fails on both too.

I did **not** re-derive `tenancy.yml`. It declares `rls.databaseEnforced: false`
with an empty table list, which is stale — three tables *are* enforced and now
five are — and `REPORT-courier-app-role.md` records that re-deriving it is
"whoever owns the checker's" call, not a side effect of a connection change. The
same reasoning applies harder to adding entry points here: every
`negative.line` in that file would need re-reading against the current tree, and a
declaration I cannot make green is worse than one that is honestly stale. **The
new tables' boundary is declared and asserted by
`NotificationsBoundaryTest` and by `prove.sh` §6b/§6c**, which are the mechanical
half; `tenancy.yml` is the narrative half and it needs its own packet.

---

## Open questions for the manager

1. **`tenancy.yml`.** 27 findings on master, 27 here, all `denial-missing`. Do
   they want that as a packet? It is `cafaye/core`'s declaration format against
   six drifted files and it is not courier's to fix alone.
2. **The route.** `parlor` needs one to render an inbox. The decision this packet
   deliberately left open is the **body shape**: whether `params` keys are rendered
   by `parlor` against a per-type partial, or whether courier gains a
   `notification_body` vocabulary. The first keeps courier API-only; the second
   puts a rendering contract in the notification service and is the thing this
   packet refused to port.
3. **Retry-safety of `record/2`.** A caller that retries after a timeout writes a
   second event and a second notification. This packet did **not** add idempotency
   here, deliberately: courier's answer to that is `Courier.Idempotency`, which is
   an HTTP-layer credential, and inventing a second idempotency mechanism in a
   library is exactly the kind of second-thing-to-get-wrong this repository writes
   about. Worth confirming that is the intended reading rather than a gap.

---

## The environment note, because it cost time

`bin/gate-db up` reports healthy and then the suite cannot connect. The reason is
that this machine already has a **Homebrew PostgreSQL 17.11 listening on
127.0.0.1:5432**, and it shadows the container OrbStack published on the same
port — `docker ps` shows `courier-gate-pg` healthy while every connection to
127.0.0.1:5432 reaches the Homebrew server, which has **no `postgres` role**. The
first run died with

    ** (DBConnection.ConnectionError) [Elixir.Courier.OwnerRepo] connection not
       available and request was dropped from queue after 5993ms

which names a pool and not a port. Removing the container does not help; the
shadowing server is the one that answers.

The working invocation on this machine is the four variables `config/test.exs`
already reads, against that server:

```sh
export COURIER_DB_OWNER_USER=kaka
export COURIER_DB_OWNER_PASSWORD=kaka
export COURIER_APP_DB_PASSWORD=kaka
```

`COURIER_TEST_PG_PORT` stays at its 5432 default. `mix ecto.create`/`mix
ecto.migrate` must be given `-r Courier.OwnerRepo` by hand: `mix ecto.migrate`
without it runs as `courier_app` and answers `42501 permission denied for schema
public`, which reads as a missing grant rather than as the wrong credential. The
`test` **alias** already does the right thing, so `mix test` and `mise run prime`
need none of this beyond the three variables.