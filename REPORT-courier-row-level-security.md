# REPORT — `courier-row-level-security-02`

**Branch:** `worker/courier-row-level-security` (not pushed)
**Inherited:** `50ced88` — the migration and the substrate, recovered from a
worker that died at 33 minutes having written 1,107 lines and committed nothing.
**Outcome:** the migration applies, the boundary is installed, and it has been
observed refusing a cross-account read on all three protected tables and observed
succeeding at that read once the policy is broken on purpose.

Two of the three things this packet set out to find turned out to be bugs in the
inherited work, not gaps in it, and the third — the red proof — is the whole
deliverable. A fourth finding, which nobody asked for and which changes what
"safe to land" means, is in §4.

---

## 1. The splitter had never run, and it had six ways not to

`mix ecto.migrate` against a real PostgreSQL 18.4 fails. The first failure is
the least interesting of the six.

The migration reaches kit's 795-line substrate through `execute_all/1`, which
splits it into one statement per `execute/1`. It has to: `execute/1` reaches
Postgrex as a prepared statement and the server answers `42601 cannot insert
multiple commands into a prepared statement`. That splitter could not work. Each
of the following is measured, not inferred, and each was invisible because no
gate had ever run against the file.

### 1.1 `until_dollar/3` could never find a closing delimiter

The clause put `^tag` in the **first element** position, so a pinned charlist
was compared against a single character:

```elixir
tag = ~c"$"                       # this is the LIST [36]
case ~c"$;\n" do [^tag | _] -> :matched; _ -> :no_match end
#=> :no_match                      # element is the INTEGER 36; [36] != 36
```

So it ate every `$` in the file and ran off the end, raising
`FunctionClauseError` on `[]` 38 characters into the first dollar-quoted body —
which is `provision_login_role/0`'s `create role` block. The stack trace blamed
the migration's own helper rather than the file it was reading.

### 1.2 The `--` clause was a two-element list pattern, not a cons

`[?- = ?-, rest]` constrains element zero and binds element one. It therefore
matched a list of exactly two dashes — and kit's substrate ends in a run of
dashes — binding `rest` to the integer `45` and raising `CaseClauseError` inside
`until_newline/2`. On any real comment it never ran at all, which is how the 18
`--` comment lines containing `;` were splitting statements mid-comment.

`[?/ = ?*, rest]` is worse: that is `47 = 42`, a contradiction, so the
block-comment clause was dead code and the compiler printed *pattern cannot
possibly match* on every compile. Nothing had ever compiled this migration, so
nobody saw the warning the compiler was repeating.

### 1.3 `statements/1` called a function that does not exist

`Enum.to_string/1` is not an Elixir function.
`function_exported?(Enum, :to_string, 1)` is `false`. The lexer could have been
perfect and this alone would have raised.

### 1.4 The dollar-quote delimiter was rebuilt one `$` short

`Enum.reverse(tag)` is the delimiter *minus* the opening `$`: `$$` came out as
`$` and `$cafe$` as `$fac`. Postgres rejects both. This was hidden behind 1.1 —
fixing the search without the reconstruction only moved the crash to
`42601 syntax error at or near "kit"`.

### 1.5 Comment text was emitted backwards

Comments were pushed with `Enum.reverse(skip)` into an accumulator whose
contract is already reversed, so every comment came out reversed. Measured on
the broken build: statement 0 began
`.esabatad s'ecivres eno edisni yradnuob TNUOCCA eht`.

### 1.6 `--` and the newline were not re-emitted at all

Two failures in sequence, and both are the same mistake: a line comment is only
a line comment if the line ends.

| emitted | Postgres |
| --- | --- |
| comment text with no `--` | `42601 syntax error at or near "kit"` |
| `--` with no newline, so it ran on into the SQL | `42601 syntax error at or near "returns"` |

### 1.7 What the splitter does now

Provenance is confirmed and now **enforced**. `git -C ../kit show
15cee0e1:templates/database/tenancy/substrate.sql` is byte-identical to this
copy; both sides are
`e2b4917be2a7f7c48964bd40fea0da93db503b4c736a42a44e44425cfbf7bf5e`.
`@substrate_sha` was previously *set and never read* — the compiler said so — so
the provenance claim in the migration's header was prose. `substrate/0` now
verifies the digest and refuses to run with both digests named.

The block-comment clause is **deleted** rather than repaired. kit's substrate
contains zero `/*` (measured), the clause could never have executed, and now
that the sha256 is pinned, an edit that introduced a `/*` fails the digest check
before the splitter is reached — so the missing branch cannot become a silent
mis-split. It becomes a migration that refuses to run and names the file.

Measured after the fix:

```
fresh database  -> 11 migrations applied, exit 0
re-run          -> "Migrations already up", exit 0
catalog         -> relrowsecurity=t relforcerowsecurity=t on exactly
                   idempotency_keys, notification_preferences, webhook_endpoints
                 -> 12 policies
                 -> outbox_events, email_suppressions, unsubscribe_tokens,
                    webhook_deliveries: relrowsecurity=f
```

---

## 2. The red proof and the control, all three tables

`reports/courier-row-level-security/prove.sh` — 18 probes, **exit 0**.
`reports/courier-row-level-security/prove.log` — its literal output, committed
so the next reader is reading measurements.

Five probes per table, none of them the same statement as another:

| | probe | expected |
| --- | --- | --- |
| A | identity=A, `count(account_id=A)` | `1` |
| B | identity=A, `count(account_id=B)` | `0` |
| C | identity=A, the sensitive column for A | the real value |
| D | identity=A, a write against B's row | succeeds, row unchanged |
| E | identity=A, move A's **own** row into B | `42501` |

A is what makes B mean something: **a policy that refuses everything also
satisfies "B returned no rows"**, and only A distinguishes a scoped policy from
an unreadable table. C reads the actual value — `BODY-FOR-ACCOUNT-A`,
`SECRET-FOR-ACCOUNT-A`, `f` — rather than a count, so the control is not a
tautology about row visibility.

### 2.1 The packet asked for 42501 on the cross-account read. It is not what comes back.

This is reported as measured, not adjusted to fit the ask. **A `SELECT` whose
policy does not match yields NO ROWS, not an error.** An `UPDATE` or `DELETE`
whose `USING` clause does not match yields a **successful** statement that
matched nothing — it does not raise. Both are refusals; neither is `42501`.

`42501` is what a `WITH CHECK` produces, so it is asserted on probe E, on all
three tables:

```
ERROR:  42501: new row violates row-level security policy for table "idempotency_keys"
ERROR:  42501: new row violates row-level security policy for table "notification_preferences"
ERROR:  42501: new row violates row-level security policy for table "webhook_endpoints"
```

Probe D asserts the **effect** rather than the exit status: the write succeeds,
and the row is then re-read *as the owner* and found unchanged. Reading it back
through the same filtered path would make "unchanged" and "invisible" the same
claim.

### 2.2 The deliberate breakage, and the check is not a tautology

```
alter table idempotency_keys disable row level security;

-- the statement that returned 0 in probe B:
set role courier_app;
select cafaye.begin_account('11111111-…'::uuid);
select count(*) from idempotency_keys where account_id = '22222222-…';
--> 1        exit code 0
```

Reverted. Catalog reads `relrowsecurity=true relforcerowsecurity=true` and probe
B returns `0` again.

### 2.3 Two ways this harness passed for the wrong reason while being written

Both are the fleet's own recorded failure modes, and both are why the harness
now asserts more than it first did.

* **`42501` is not specific to tenancy.** `permission denied for sequence
  notification_preferences_id_seq` is *also* `42501`, so a check on the code
  alone accepts a privilege failure as a tenancy refusal. An early version of
  probe E asserted only the code, and passed on a sequence denial. The harness
  now requires `42501` **and** `violates row-level security policy`.
* **The first red/green pair was one statement twice.** Both cases ran
  `count(*)` with the same identity, so the "control" was the "red". Each probe
  is now a different statement.

---

## 3. The measurement the migration cites

The migration's moduledoc points here for "the measurement, which is the reason
this file is safe to land alone". This is that measurement.

**Nothing in courier's own read or write path changed, and the reason is
measurable rather than asserted.** The boundary is installed on three tables and
is **inert for courier's application**, for two independent reasons:

1. `Courier.Repo` connects as `postgres`, and on the database this ran against
   `postgres` is `rolsuper=true`, `rolbypassrls=true`. **A superuser bypasses RLS
   unconditionally**, whatever `FORCE` says. Measured, in the proof log:

   ```
   select count(*) from idempotency_keys where account_id = '<account-B>';
   --> 1        exit code 0
   current_user=postgres rolsuper=true rolbypassrls=true
   ```

   That is the identical statement that returned `0` as `courier_app`. The
   difference is the role and nothing else.

2. The application never calls `cafaye.begin_account/1`, so there is no identity
   to filter on even for a role that would be filtered.

Tests, on the migrated database:

| scope | result |
| --- | --- |
| the 7 files that read or write the three protected tables | **219 passed** |
| the 19 cross-tenant tests from `REPORT-courier-tenancy-declare.md` §1 | **all 19 still present and passing** — re-ran the seven files above; every mapped `file:line` is in one of them and none was deleted |
| `core/harness/tenancy_check.py` | **0 failures, 3 warnings**, exit 0 |

That is the whole of the claim, and it is deliberately a modest one: **the
migration installs a boundary and no request uses it yet.** `identity` made the
same split in the same order. Nothing here should be read as courier being
isolated today — it is courier having the mechanism in place, with §4 below being
the reason that distinction matters.

---

## 4. FINDING — on this cluster the boundary is inert, and on kit's cluster it will not be

This is the one finding that changes what "safe to land alone" means, and it is
not in the inherited work.

`protect_table` writes each policy `to current_user, <login_role>` — so the role
that ran the migration is **itself a policy subject** — and applies `FORCE ROW
LEVEL SECURITY`, which is precisely the setting that removes the owner's
exemption. kit's substrate says so itself:

> Once a table is protected, the OWNER reads zero rows from it too — no policy
> names the owner, and FORCE removed the exemption that used to let it through.

So for a non-superuser owner the boundary is **live on the migration's own path**:
a `courier` role that is `rolsuper=false` would read **zero rows** from all three
tables the moment this migration lands, with no identity set.

This packet ran against a cluster where `postgres` happens to be a superuser,
which masks that. **kit's cluster does not create the owner that way.**
Measured, `kit/templates/compose/postgres/initdb/10-cluster.sh:219`:

```sql
CREATE ROLE :"svc" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
```

and courier connects as that role — `docker-compose.yml:253`:

```
DATABASE_URL: ecto://courier:…@postgres:5432/courier
```

**So on the stack this repository actually deploys, the owner is not a
superuser, and this migration makes courier read zero rows from all three
protected tables on its very next query.** That is not a prediction; it is
measured, in
`reports/courier-row-level-security/prove-owner-not-superuser.sh` (5 probes,
exit 0, log committed as `prove-owner-not-superuser.log`), which builds a
`NOSUPERUSER` owner exactly as kit does, runs the substrate against it as that
owner, and then reads:

```
set role rls_probe_owner;
select count(*) from idempotency_keys;          --> 0   (of 2 rows, before: 2)
select count(*) from notification_preferences;  --> 0
select count(*) from webhook_endpoints;         --> 0

-- and the same read as a superuser, which is the whole reason this went unseen:
select count(*) from idempotency_keys;          --> 2
```

The two statements in the packet's own constraints pull in opposite directions
and I have honoured both, but the next reader should know they conflict:

* *"This packet must not make courier's application read through the restricted
  role"* — honoured. The application's role was not changed.
* *"`cafaye.begin_account/1` per request is the NEXT packet"* — also honoured.

The consequence is that **the migration and the role switch cannot both be
separate, low-risk packets on kit's cluster.** On this development cluster they
can, because the test role happens to be a superuser. On kit's cluster they
cannot. I did not act on this; it is reported.

**The recommendation, for whoever picks up the next packet:** do not treat it as
"flip a role". Treat it as "the switch and the migration land together, or the
migration waits". Neither `mix ecto.migrate` nor the 219 green tests here would
have caught this, because **both were run as the superuser** — which is now a
measured statement rather than a caveat.

---

## 5. FINDING — `protect_table` grants DML and never grants the sequence

`notification_preferences` has a `bigserial` primary key. `protect_table` grants
`select/insert/update/delete` on the **table** and does not grant `USAGE` on
`notification_preferences_id_seq`. So `courier_app` cannot insert into that table
at all:

```
set role courier_app;
insert into notification_preferences (…) values (…, '<account-A>');
ERROR:  42501: permission denied for sequence notification_preferences_id_seq
```

That is into account A's **own** account, so it is not a tenancy refusal at all.
`idempotency_keys` and `webhook_endpoints` use uuid keys and are unaffected.

This is a real gap for the packet that switches the application to
`courier_app`: a write to `notification_preferences` would fail on a privilege
rather than on tenancy, which is a confusing way to discover the difference. It
is measured in its own right as probe 3b of the harness. Not fixed here — it
lives in kit's shared substrate, and editing the substrate is a fork.

---

## 6. Confirmed and deliberately not changed

* **`outbox_events` stays unprotected, and `cafaye.unprotected_tables()` agrees.**
  The sweep names exactly one table on the migrated database:
  `public.outbox_events — row level security is not enabled`. The relay scans
  `webhooks_dispatched_at IS NULL` across all accounts, and the column is
  nullable because a user-scoped `email.delivered` has no account. The
  migration's argument is correct and is now backed by the sweep's own output.
* **`kit.ref` predates the substrate — reported, not moved.** `kit.ref` is
  `f6d3b74`; the tenancy templates arrived in kit later, in `e8605c9`. The
  substrate here is therefore *newer* than the commit this repository pins.
  Moving the pin changes the whole stack, so it is the manager's call. The
  sha256 is now pinned inside the migration, which converts a silent
  provenance drift into a migration that refuses to run.
* **The migration's decision not to call `begin_account/1` is correct** and is
  honoured. §4 is about the environment, not about the decision.
* **`tenancy_check.py` gained a third warning** from this packet:
  `tenancy.rls-unreadable` cannot parse
  `20261003090000_protect_account_scoped_tables.exs:13`. It is a warning, not a
  failure, exit 0; the checker says it cannot settle a migration written as
  another language's string. The declaration is consistent with the change — it
  already named the file — so nothing here contradicts `tenancy.yml`.

---

## 7. What this packet did not do

* Did not change the role courier's application connects as. The 19 cross-tenant
  tests are intact and their count did not drop.
* Did not add a test file. The packet's instruction was "narrow tests only: the
  tenancy tests, not the whole suite", and the proof is a SQL harness rather
  than an ExUnit one — the thing being measured is `42501` from Postgres, which
  `Ecto.Adapters.SQL.Sandbox` would wrap rather than expose. **This is a real
  gap and I am flagging it rather than letting the green suite imply otherwise:
  nothing in `mix test` fails if these policies are deleted.**
* Did not touch `kit.ref`, `tenancy.yml`, or the substrate's contents.
* Did not push.

---

## 8. Reproduce

```sh
# the §4 finding: the owner is not a superuser on kit's cluster
bash reports/courier-row-level-security/prove-owner-not-superuser.sh

# the database
createdb courier_test_rls
MIX_ENV=test MIX_TEST_PARTITION=_rls mix ecto.migrate

# the proof: 18 probes, exit 0
PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres \
  PGDATABASE=courier_test_rls \
  bash reports/courier-row-level-security/prove.sh

# the tests
MIX_ENV=test MIX_TEST_PARTITION=_rls mix test \
  test/courier/principal/introspection_test.exs \
  test/courier/idempotency_test.exs \
  test/courier/webhook_endpoints_test.exs \
  test/courier/notification_preferences_test.exs \
  test/courier_web/plugs/idempotency_test.exs \
  test/courier_web/controllers/notification_preferences_controller_test.exs \
  test/courier_web/controllers/webhook_endpoints_controller_test.exs
```

The proof harness leaves the database as it found it and prints its own pass and
fail counts. It exits non-zero if any probe deviates, so it is usable as a CI
step as it stands.