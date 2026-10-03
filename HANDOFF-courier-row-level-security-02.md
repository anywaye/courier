# HANDOFF — `courier-row-level-security-02`

**Branch:** `worker/courier-row-level-security` — 3 commits on top of `50ced88`,
**not pushed**.

```
8dfe82d  the report, and a finding that changes what "safe to land" means
dc11169  the red proof, run against a migrated database, all three tables
ff60323  the substrate splitter had never run, and it had six ways not to
```

Everything the packet asked for is done and measured. Four things remain, and
**the first one is a decision that is not mine to make.**

---

## 1. BLOCKING — this migration must not be applied on kit's cluster alone

`protect_table` writes each policy `to current_user, <login_role>` and applies
`FORCE ROW LEVEL SECURITY`. So the role that ran the migration is a policy
subject, and FORCE is the setting that removes the owner's exemption.

kit's cluster creates the owner `NOSUPERUSER`
(`kit/templates/compose/postgres/initdb/10-cluster.sh:219`) and courier
connects as it (`docker-compose.yml:253`). So on the deployed stack this
migration makes courier read **zero rows** from `idempotency_keys`,
`notification_preferences` and `webhook_endpoints` on its next query.

Measured, not predicted —
`reports/courier-row-level-security/prove-owner-not-superuser.sh`, 5 probes,
exit 0:

```
set role rls_probe_owner;                 -- NOSUPERUSER, as kit creates it
select count(*) from idempotency_keys;     --> 0     (of 2; before: 2)
select count(*) from webhook_endpoints;    --> 0
select count(*) from idempotency_keys;     --> 2     as postgres (superuser)
```

I did not act on it: the packet forbids changing the application's role here,
and it also says `begin_account/1` is the next packet. Both were honoured, so
the conflict is reported. **The next packet cannot be "flip a role" in
isolation — the migration and the switch land together, or the migration
waits.** Full reasoning in `REPORT-courier-row-level-security.md` §4.

## 2. No test covers these policies

`mix test` passes with the policies present **and** would pass with every one of
them deleted. The proof is a SQL harness, because
`Ecto.Adapters.SQL.Sandbox` would wrap the `42501` rather than expose it.

So the honest CI step today is the harness, not a test file:

```sh
createdb courier_test_rls
MIX_ENV=test MIX_TEST_PARTITION=_rls mix ecto.migrate
PGHOST=127.0.0.1 PGPASSWORD=postgres PGDATABASE=courier_test_rls \
  bash reports/courier-row-level-security/prove.sh
```

Both harnesses exit non-zero on any deviation and leave the database as they
found it, so they drop into `gate.yml` unchanged. Wiring them in is not done —
`gate.yml` and `.github/workflows/ci.yml` were not touched, because the tier
floors in this repository have to move in the same commit as a test count and
that is a bigger change than this packet's budget allowed.

The better fix is an ExUnit test that connects as `courier_app` rather than
through the sandbox, and it is the first thing I would do next.

## 3. `protect_table` grants DML and never grants the sequence

`notification_preferences` has a `bigserial` primary key, and `protect_table`
grants `select/insert/update/delete` on the **table** without granting `USAGE`
on `notification_preferences_id_seq`. So `courier_app` cannot insert into that
table at all, even into its own account:

```
ERROR:  42501: permission denied for sequence notification_prepressions_id_seq
```

This blocks the packet that switches the role. It lives in kit's shared
substrate, so fixing it in courier means forking the substrate — not done.
It needs an upstream kit change. Probe 3b of `prove.sh`.

Note how nearly shipped a wrong answer: `permission denied for sequence` is
*also* SQLSTATE `42501`, so the first version of that probe passed while
measuring a privilege error instead of a tenancy refusal. The harness now
requires both the code **and** the message `violates row-level security policy`.

## 4. `kit.ref` predates the substrate — reported, not moved

`kit.ref` pins `f6d3b74`; the tenancy templates landed in kit later, in
`e8605c9`. The substrate in `priv/repo/` is therefore newer than the pinned
kit. Moving the pin changes the whole stack, so it is the manager's call.

Mitigated, not resolved: `substrate/0` now verifies the file's sha256 against
the `@substrate_sha` the migration claims and refuses to run with both digests
named, so a provenance drift is now a loud failure rather than prose. Verified
byte-identical to
`git -C ../kit show 15cee0e1:templates/database/tenancy/substrate.sql`.

---

## State left behind

Nothing. The databases this packet created (`courier_test_rls`,
`courier_rls_owner_probe`) and the role `rls_probe_owner` are dropped; the
owner harness removes its own via a `trap`. The shared cluster's pre-existing
`courier_test` and `courier_dev` were never touched — every mix invocation ran
under `MIX_TEST_PARTITION=_rls`, which is a different database.

## What was verified before finishing

| check | result |
| --- | --- |
| `mix ecto.migrate`, fresh database | exit 0, 11 migrations, **no warnings** |
| `mix ecto.migrate`, re-run | exit 0, "Migrations already up" |
| `mix compile --warnings-as-errors` | exit 0 |
| `mix format --check-formatted` on the migration | exit 0 |
| `reports/…/prove.sh` | 18/18, exit 0 |
| `reports/…/prove-owner-not-superuser.sh` | 5/5, exit 0 |
| 7 files touching the three protected tables | 219 passed |
| the 19 cross-tenant tests, at their exact mapped `file:line` | all 19 present |
| `core/harness/tenancy_check.py` | 0 failures, 3 warnings, exit 0 |

The whole suite was not run — the packet said narrow tests only — so I am not
claiming it green.