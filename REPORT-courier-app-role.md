# courier-app-role — courier connects as `courier_app`, and what that turned on

`worker/app-role-runtime`. **1317 tests, exit 0. Whole suite, both tiers, the SSRF
table, and the independent RLS proof at 18/18.** The headline is not the DSN
switch; it is that switching it exposed a cross-tenant code path in courier that
had never run, and a **contract change** that needs a decision this packet did not
take.

---

## What landed

Two credentials, and the runtime one is the app login role.

| | credential | used by |
| --- | --- | --- |
| `Courier.Repo` | **`courier_app`** — owns nothing, subject to every RLS policy | the endpoint, the workers, **the whole test suite** |
| `Courier.OwnerRepo` | the owner — `postgres` locally, `courier` on a kit cluster | `mix ecto.create`, `mix ecto.migrate`, `bin/migrate` |

`Courier.OwnerRepo` is **not in `:ecto_repos` and not in the supervision tree**, so
no running release holds a connection that bypasses courier's account boundary.

**Two modules, not one repo key with a switch.** The rejected version was a single
`config :courier, Courier.Repo` key that `COURIER_OWNER_DATABASE_URL` overrode at
the top of the file. That does not "make migrations run as the owner" — it makes
**the test run** run as the owner, because there is one key and `mix test` starts
the application. The suite goes green with the boundary switched off, which is
the failure this packet exists to end. Two modules make the phase a compile-time
fact.

## Diff summary

| file | change |
| --- | --- |
| `lib/courier/owner_repo.ex` | **new.** The owner, and the note on why `priv:` must be in the environment (measured: `use Ecto.Repo, priv:` is ignored — `init_config/4` reads `Application.get_env`) |
| `config/test.exs`, `config/dev.exs` | `Courier.Repo` → `courier_app`; a second, commented `Courier.OwnerRepo` block; the owner variable is explicit and says it must never be the runtime credential |
| `mix.exs` | every `ecto.*` task that needs privileges names `-r Courier.OwnerRepo`; `test` runs create+migrate as the owner and the suite as the app role |
| `docker-compose.yml` | `DATABASE_URL` names `courier_app`; `COURIER_OWNER_DATABASE_URL` added for migrations |
| `config/runtime.exs` | prod configures `Courier.OwnerRepo` from `COURIER_OWNER_DATABASE_URL`, and does **not** require it at boot |
| `lib/courier/release.ex` | `migrate/0` ran `:ecto_repos` — a bug this packet's own first commit would have shipped; it runs `Courier.OwnerRepo` |
| `config/deploy.yml` | the owner DSN in `env.secret`, with the reasoning that it is not a boot contract |
| `priv/repo/migrations/20261005120000_…` | **new.** The six unprotected tables, minimally, plus the two sequences |
| `lib/courier/notification_preferences.ex` | `store_all/3` translates one RLS refusal into `:not_found` — **a real behaviour fix, see below** |
| `test/support/data_case.ex` | `@moduletag account:` and `as_account/2` |
| `test/support/conn_case.ex` | imports `Ecto.Query` and `Courier.DataCase`; moduledoc on why it delegates to `DataCase.setup_sandbox/1` |
| 16 test files | the tag, four `as_account/2` seeding sites, four per-account read-backs, one per-account count pair, one owner-repo migration read |
| `AGENTS.md`, `README.md`, `reports/courier-row-level-security/prove.sh` | the prose that stated or implied the runtime role |
| `gate.yml`, `.github/workflows/ci.yml` | the floors, remeasured |

---

## The three findings

### 1. A cross-tenant path that had never run, and a 500 where a 404 was documented

`Courier.NotificationPreferences.addressable/2` decided the cross-tenant case by
**reading** the stored row's `account_id` and comparing it in Elixir. As the
database owner that read sees every account's rows, so the comparison ran. As
**`courier_app`** the read is a subject of the `select` policy
(`account_id = cafaye.current_account_id()`), so:

```
-- as courier_app, identity = the other account
select account_id from notification_preferences where user_id = '<theirs>';
-- 0 rows. The policy hides it.

insert into notification_preferences (...) on conflict do update …;
ERROR:  new row violates row-level security policy (USING expression)
        for table "notification_preferences"
```

**`addressable/2` is structurally unreachable for this case.** The write is then
refused by the database, and an unhandled `42501` is a **500** where the module
documents `{:error, :not_found}` → 404. A 500 for a cross-tenant write is wrong
twice: it is not retryable, and the substrate deliberately *raises nothing* on an
absent identity precisely so an answer never tells a caller it was
unauthenticated.

`store_all/3` now translates that one refusal. **Matched on the message, not the
SQLSTATE** — `42501` is also `permission denied for schema public` for a missing
grant, and those two want opposite answers: the policy refusal is courier's
boundary and becomes a 404, a missing grant is a deployment fault and must stay
loud. The test asserts both halves, and the non-matching half re-raises with its
stack.

**Nothing was widened to make this work.** Widening the role, or relaxing the
policy, is the thing this packet exists to stop; the fix belongs in the code that
asks the boundary a question.

### 2. A contract change: the 404 for another account's preferences is gone

The same finding on the read path. The 404 branch of `list/2` is now unreachable,
and the answer is **200 with the defaults** — byte-identical to the answer for a
user who does not exist.

**This leaks strictly less than the 404 did.** Core's convention and this
module's own comment both give the reason the 404 existed: *a 403 would confirm
that this user id has preferences at all*. 200-with-defaults confirms nothing —
it is the same response for a user that has never been written for, and for a user
id that does not exist. The two cases became indistinguishable, which is what the
404 was reaching for by a longer road.

**`openapi.yaml` still declares the 404 for `GET /v1/notification_preferences/{user_id}`,
and `tenancy.yml` still names `expects: not_found` at
`notification_preferences_test.exs:221`.** Both are now wrong. Reconciling a
published document is not a mechanical edit, and doing it inside this packet would
have meant shipping a contract change as a side effect of a connection change.
**This is the one thing here that needs a manager decision.** The three tests now
assert the *property* (the same preferences as an unknown user) rather than a
status that no longer applies, so nothing is pinned to the old behaviour — but
neither is the new behaviour pinned by the document.

### 3. `CourierWeb.Plugs.TenantIdentity` changes the *test's* identity

The plug opens a transaction and sets the account. Inside the sandbox that is a
SAVEPOINT, and `RELEASE SAVEPOINT` does not discard a transaction-local setting.
Measured on a driver test:

```
identity at start:          6f5d4c3b-…   (@account)
identity after OWNER post:  6f5d4c3b-…   unchanged
identity after OTHER post:  7a6e5d4c-…   the other account
```

**Not a production leak**, and the difference is the whole of `is_local := true`'s
argument: in production the plug's transaction is the *outermost*, so `COMMIT`
discards the setting in the database with nothing in courier to forget. The
sandbox's transaction sits outside the plug's and nothing commits it until the
test ends.

Four assertions were reading a protected row back from the test body. One of them
— the DELETE test — **passed because the row was invisible rather than because it
survived**, which is the failure mode this repository's own rules call out: a
boundary that refuses everybody satisfies a denial arm for free. Each now asks for
the identity it wants.

---

## The migration, and a kit defect this tree pins

`cafaye.protect_table/2` grants DML on the tables it is given. Six more tables in
this schema had no grant at all, and the measured result of moving the connection
without closing that was a refusal to start — the good shape for a missing grant:

```
ERROR:  permission denied for table oban_jobs
ERROR:  permission denied for table outbox_events
```

`20261005120000_grant_app_role_runtime_dml` grants each table the minimum its own
code needs — **no `DELETE` on courier's four tables, because nothing in `lib/`
deletes from them** — and **no `TRUNCATE` anywhere**, since it is the one DML
privilege with no row filter. Oban's two tables get `DELETE` because
`deps/oban/lib/oban/engines/basic.ex` calls `delete_all` in three places; that is
Oban's requirement, not a widening for convenience.

**The sequence grant is kit's defect, not courier's.**
`notification_preferences_id_seq` is `USAGE`-granted because
`protect_table` at `@substrate_sha` (`15cee0e1`) grants table DML and no sequence
privilege, so a protected table with a `bigserial` column is **uninsertable** by
the login role. kit fixed exactly this in `63663f8` ("kit-31: protect_table
granted DML and left the login role unable to insert"); this repository's
`kit.ref` predates it. It surfaces as `42501` — the same SQLSTATE the policies
raise — so an assertion checking the code alone cannot tell a working boundary
from a table nobody can write to.

`reports/courier-row-level-security/prove.sh` §3b was asserting that gap and
counting the refusal as a pass. It is now a regression check, measured in both
directions.

---

## Verification

Every command below was run and its exit code observed. The scratch cluster is
the recovered `courier-approle-pg` container on host port 5433, **reused, not
replaced**, carrying the kit substrate and courier's migrations; `COURIER_TEST_PG_PORT=5433`
points `config/test.exs` at it.

| # | command | exit | covers |
| --- | --- | --- | --- |
| 1 | `mix compile --warnings-as-errors` | **0** | dev tree |
| 2 | `mix format --check-formatted` | **0** | — |
| 3 | `MIX_ENV=test COURIER_TEST_PG_PORT=5433 mix ecto.create -r Courier.OwnerRepo` | **0** | the owner credential reaches the cluster |
| 4 | `MIX_ENV=test COURIER_TEST_PG_PORT=5433 mix ecto.migrate -r Courier.OwnerRepo` | **0** | both migrations apply **as the owner** |
| 5 | `COURIER_TEST_PG_PORT=5433 mix test` | **0** | **1317 passed** — whole suite, the alias running create+migrate as the owner and the tests as `courier_app` |
| 6 | same, no-database tier (27 files) | **0** | 619 passed |
| 7 | same, database tier (39 files) | **0** | 698 passed |
| 8 | `mix test test/courier/webhooks/url_guard_test.exs` | **0** | 62 passed |
| 9 | `bash reports/courier-row-level-security/prove.sh` | **0** | **18/18** — the independent RLS proof, `SET ROLE courier_app` |
| 10 | same, with `revoke usage on notification_preferences_id_seq` | **1** | **the mutation.** 18/1 — §3b bites |
| 11 | same, grant restored | **0** | 18/0 |
| 12 | `bin/assert-suite` on runs 5/6/7 against the new floors | **0** | 1317 ≥ 1311, 619 ≥ 619, 698 ≥ 698 |

**619 + 698 = 1317**, so the parts still sum to the whole.

### The live proof, as a transcript

Two rows in `webhook_endpoints`, one per account, inserted by the owner. Then the
same read four ways.

```
$ psql -U courier_app -d courier_test
current_user=courier_app super=false bypassrls=false
identity=(none)
rows_visible=0                      <-- the app role, no identity: ZERO, not an error

$ begin; select cafaye.begin_account('6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061');
identity=6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061
rows_visible=1                      <-- its own row

$ begin; select cafaye.begin_account('7a6e5d4c-3b20-4f90-8d18-2c3e4f506172');
identity=7a6e5d4c-3b20-4f90-8d18-2c3e4f506172
rows_visible=1                      <-- the other account's row, and only that one

$ psql -U courier -d courier_test   <-- the OWNER, after begin_account(A)
identity=6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061
rows_visible=1

$ psql -U postgres -d courier_test  <-- THE CONNECTION THIS PACKET REMOVED
current_user=postgres super=true bypassrls=true
identity=(none)
rows_visible=2                      <-- a superuser reads BOTH with no identity
```

That last block is the finding in one screen. `rolsuper=t, rolbypassrls=t` is why
1276 green tests could not see the boundary, and it is now a fact about the
bootstrap role rather than about the application.

---

## Deliberately not done

- **`openapi.yaml` and `tenancy.yml` still describe the 404.** See finding 2. The
  document and the checker are not mine to change, and a contract change shipped
  as a side effect of a connection change is exactly the kind of quiet thing this
  repository's rules keep refusing.
- **`tenancy.yml`'s `rls.databaseEnforced: false` is not re-derived.** It was
  honest while the suite ran as a superuser. Three tables *are* enforced by
  `protect_table`; the migration list `tenancy_check.py` reads now contains a
  second RLS-bearing file, so the `tenancy.rls-undeclared` silence that declaration
  relies on has to be re-measured by whoever owns the checker. Not guessed at.
- **`kit` was not touched, and `kit.ref` was not moved.** The pinned substrate
  predates kit's sequence-grant fix, so courier carries a one-line grant in its own
  migration instead. Moving `kit.ref` changes the whole stack and is a decision
  this packet did not make — the same call the RLS packet made and recorded.
- **`.kamal/hooks/pre-deploy` was not added.** `AGENTS.md` records that migrations
  are not run by `kamal deploy` and that the hook is courier's to add. Adding it
  would silently change what a deploy does. The owner DSN is in place for whoever
  adds it.
- **`COURIER_DB_OWNER_USER` defaults to `postgres` in dev and test.** A developer's
  plain local postgres and CI's `services: postgres` have exactly one role, and
  creating a database is the one job a `NOSUPERUSER` owner cannot do. It is
  commented, it is explicit, and it is a bootstrap-only credential. A role-provisioning
  step in `bin/gate-db` and in CI's `services:` block would let both default to the
  kit owner — that is the right end state and it is not this packet.
- **The `test/courier/tenancy_test.exs` moduledoc is stale.** It says the suite
  "cannot prove" a cross-account refusal *because it connects as `postgres`*, and
  names `reports/courier-row-level-security/prove.sh` as the place that does. That
  is now wrong in its first half: the suite **can**, and finding 1 is the suite
  finding a thing the prove script never looked for. Left alone rather than edited
  blind — the whole-block rewrite belongs with the `openapi.yaml` decision.
- **No repo-wide sweep.** `grep` for other `username: "postgres"` sites, other
  `Repo.aggregate(..., :count)` whole-table claims, and other reads of protected
  rows would all find things. The tier runs are green, which is the only claim I
  can make; a green suite is not a proof that no such site exists elsewhere.

## Open questions for the manager

1. **The 404 → 200-with-defaults contract change (finding 2).** It leaks less and
   I believe it is right, but it is published in `openapi.yaml` and asserted in
   `tenancy.yml`. Does that get reconciled in this packet's follow-up, or does it
   want a core decision first?
2. **`tenancy.yml`'s `rls.databaseEnforced`.** With the runtime role now a policy
   subject, does that declaration move, and does core's `tenancy_check.py` need to
   read a second RLS-bearing migration before it will?
3. **CI's `services: postgres` and `bin/gate-db` have one role.** Provisioning
   `courier` + `courier_app` there would let the owner default stop being
   `postgres` and would make CI exercise the same two-role shape as the dev
   cluster. Worth a follow-up packet, or folded into the platform's kit work?
4. **The sequence grant will be redundant once `kit.ref` moves past `63663f8`.**
   Leave the explicit grant (harmless, and it is a no-op on a substrate that grants
   it) or drop it and re-pin?
