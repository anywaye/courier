# REPORT — `courier-queue-identity-01`

**Worktree:** `cafaye/wt-m39-courier-queue-01`
**Branch:** `worker/courier-queue-identity-01` (to `master`; **not pushed**)
**Base:** `3204a94`, byte-identical to `master` at the time of writing.

The packet asked three things: measure whether the silent zero-row read on
`DispatchWebhooksWorker` is live or inert; fix it if live, without widening the
policy; and add a check that can be seen to fail. This report does those, and
then lists what is still unmeasured.

**The short answer: it was live.** On the stack courier actually deploys to, the
webhook fan-out read **0 of 2** endpoint rows, created **0** deliveries,
returned `{:ok, %{dispatched: 0}}`, wrote **0** log lines, and exited 0. It is
fixed, and the fix is a `with_account/3` wrapper on the worker's read path.

---

## 0. The three greps the packet asked me to reproduce

```
$ cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-queue-01
$ grep -n "WebhookEndpoints.enabled" lib/courier/workers/dispatch_webhooks_worker.ex
80:    WebhookEndpoints.enabled(event.account_id)
$ grep -n "def enabled" lib/courier/webhook_endpoints.ex
122:  def enabled(account_id) do
$ grep -n "protect_table('" priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs
111:    execute("select cafaye.protect_table('idempotency_keys', 'courier_app')")
121:    execute("select cafaye.protect_table('notification_preferences', 'courier_app')")
126:    execute("select cafaye.protect_table('webhook_endpoints', 'courier_app')")
```

All three reproduce, on this branch, before any change of mine. The inherited
finding is accurate about the tree. What it said it could not settle — whether
courier's **deployed** role is subject to those policies — is §1.

---

## 1. THE MEASUREMENT: it is live, and here is the number

### 1.1 Why the suite could not answer this, stated as a measurement

```
$ psql -X -q -h 127.0.0.1 -U postgres -d postgres -c "select rolname, rolsuper, rolbypassrls from pg_roles where rolname in ('postgres','courier_app') order by 1;"
 rolname  | rolsuper | rolbypassrls
----------+----------+-------------
 courier_app | f | f
 postgres   | t | t
```

`config/test.exs` connects as `postgres`, and on this cluster that role is
`rolsuper = t, rolbypassrls = t`. **A superuser bypasses RLS whatever `FORCE`
says.** So every one of courier's tests runs the entire boundary switched off,
and a row-count assertion about tenancy would be green whether the identity was
set or not. `REPORT-courier-row-level-security.md` §3 measured this from the
other direction; `courier_tenant_identity` measured it from this one. It is now
measured on the queue.

kit's cluster does not create the owner that way —
`kit/templates/compose/postgres/initdb/10-cluster.sh:219` creates it
`NOSUPERUSER`, and courier connects as it. **So the harness builds that role
rather than arguing about it.**

### 1.2 The harness

`reports/courier-queue-identity/prove-queue-identity.sh` (+ `driver.exs`, run via
`mix run --no-start` so the repo is re-pointed at the probe role before it
starts). It:

1. creates `courier_queue_probe_role` (`login nosuperuser nobypassrls
   nocreatedb nocreaterole noreplication`) and a database it owns — kit's shape;
2. runs **courier's own migration set** as that owner, so `protect_table` writes
   its policies `TO current_user, courier_app` and `FORCE` takes the owner's
   exemption away;
3. seeds two accounts, one endpoint and one outbox event each, **under an
   identity** — an insert with no identity is refused by the policy's
   `WITH CHECK`, which is the substrate working rather than a broken fixture;
4. calls `DispatchWebhooksWorker.perform/1` three ways.

The catalog it produced, read from `pg_class` and `pg_policies`:

```
idempotency_keys  relrowsecurity=true  relforcerowsecurity=true
notification_preferences  relrowsecurity=true  relforcerowsecurity=true
webhook_endpoints  relrowsecurity=true  relforcerowsecurity=true

webhook_endpoints  SELECT-policy -> courier_app,courier_queue_probe_role
  USING (account_id = ( SELECT cafaye.current_account_id() AS current_account_id))
```

### 1.3 The three arms — the finding, as numbers

| arm | role | identity | return value | deliveries | log lines |
| --- | --- | --- | --- | --- | --- |
| **`without`** | `NOSUPERUSER` owner | none | `{:ok, %{dispatched: 0}}` | **0** | **0** |
| **`with`** | same role | `with_account/3` | `{:ok, %{dispatched: 2}}` | **2** | 0 |
| **`superuser`** | `postgres` | none | `{:ok, %{dispatched: 2}}` | **2** | 0 |

Verbatim, from `reports/courier-queue-identity/prove.log` on the **unfixed**
tree (that file is committed at commit `90aa07b`, before the fix landed):

```
role:                              courier_queue_probe_role rolsuper=false rolbypassrls=false
identity before perform/1:         nil
webhook_endpoints visible to it:   0 of 2
perform/1 returned:                {:ok, %{dispatched: 0}}
log lines emitted by perform/1:    0
webhook_deliveries created:        0
```

**"Zero rows, exit 0, no log line" — stated as a measurement, not a reading of
the SQL.** The three arms are what make it a measurement rather than an
observation:

* **`with` is the control.** The *only* difference from `without` is the
  identity — same role, same fixture, same code path. It produces 2 where
  `without` produces 0. So the difference is the identity, not the seed, not the
  clock, not the harness.
* **`superuser` is the explanation.** Identical code, identical rows, different
  role: 2 deliveries. This is why 1297 green tests could not see it.
* **The log capture is in the same breath as the number**, because
  "nothing in the log" is half the finding. `with_log/2` wraps the `perform/1`
  call and the harness prints `log lines emitted by perform/1: 0` next to
  `deliveries created: 0`.

**It is live.** Not inert, not masked, not hypothetical.

---

## 2. The decision, and what it was decided against

### 2.1 What was chosen

`Courier.Tenancy.with_account/3` around the worker's read path, **per event**:

```elixir
defp fan_out(event) do
  {:ok, endpoints} =
    Tenancy.with_account(Repo, event.account_id, fn ->
      WebhookEndpoints.enabled(event.account_id)
    end)

  Enum.count(endpoints, fn endpoint ->
    WebhookDeliveries.insert!(endpoint, event.id)
    true
  end)
end
```

Four lines of behaviour. `lib/courier/workers/dispatch_webhooks_worker.ex` is
the only file in `lib/` this packet changes.

### 2.2 Why per event and not per batch

**Per event is the load-bearing word.** One batch spans several accounts — that
is the whole point of a queue-level dispatcher, and `claim/0` deliberately scans
across accounts. A single identity for the batch would be **one account's
endpoints read on another account's behalf**: a cross-tenant read wearing the
costume of a fan-out, which is precisely the failure the packet forbids
introducing. The test that catches it is
`"two accounts in one batch are read under two DIFFERENT identities"`, which
asserts the identity set is exactly `{account_a, account_b}` and not one value.

### 2.3 Why not a policy granting the worker a scoped read — the packet's explicit prohibition

A policy that lets an unidentified worker read the table would make the harness
green and the product worse. It converts a silent failure into a fan-out that
reads **every** account's endpoints — including their sealed signing secrets —
with no identity behind it, so nothing downstream could attribute a delivery to
an account. **The point of the boundary is that the identity exists.** A policy
that does not require one removes the requirement while leaving the appearance
of it, which is the failure `Courier.Tenancy`'s moduledoc calls "the boundary
was installed and inert."

### 2.4 Justification against `with_account/3`'s own moduledoc

The moduledoc's load-bearing claim is that `is_local := true` is
transaction-local, so the identity cannot outlive its transaction:

> A session-level `set_config` on a pooled connection hands account A's identity
> to whoever is handed the connection next, and account B then reads account A's
> rows. **Transaction-local cannot do that**: `COMMIT` and `ROLLBACK` both
> discard it, in the database, without courier's cooperation.

This is why the fix is this wrapper rather than a `Repo.checkout` +
`set_config` of one's own: a worker opens a connection per transaction from a
pool, exactly as the HTTP surface does, and the connection is handed back and
reused. A session-scoped setting here would be a cross-tenant leak with a
high probability and no error message. The wrapper's cost is stated in that
moduledoc and accepted: one connection held for the read, and a nested
`Repo.transaction` becoming a SAVEPOINT inside `fan_out`'s own transaction.

`with_account/3` returns `{:ok, value} | {:error, reason}`, and an `{:error, _}`
here would mean `fun` rolled back — which `WebhookEndpoints.enabled/1` cannot
do. The `{:ok, ...}` match is therefore total, and it matches the file's
existing idiom (`dispatch/0` already matches `{:ok, dispatched}` and
`{:ok, created}` the same way).

### 2.5 The deliveries are written outside the wrapper, on purpose

They go into `webhook_deliveries`, which carries no `account_id` and no policy —
`protect_table` refuses a table with no tenancy column by name, and the
protection migration names both this table and `outbox_events` in its own
moduledoc as the two it deliberately leaves alone. Widening the wrapper to cover
the inserts would be harmless but would obscure which statement RLS actually
governs here. The **read** is the thing under an identity.

---

## 3. The check, and proving it can fail

### 3.1 Why a row-count test was not possible — and what replaced it

`test/courier/workers/dispatch_webhooks_worker_identity_test.exs` asserts **the
identity on the connection, at the moment the read ran**, captured through
Ecto's `[:courier, :repo, :query]` telemetry and read back with
`Tenancy.current_account_id/1`.

That is *stronger* than a row count, not weaker, and the direction matters:

* a worker that read the right rows **without** an identity would pass a row
  count and **fail** this;
* a worker that read under the **wrong** account would pass a row count and
  **fail** this.

It is also the only kind of assertion that works in a suite whose role is a
superuser: `cafaye.current_account_id()` reports what a policy *would* compare
against, and it does not care whether the role would have been filtered.

### 3.2 The mutation, and the three tallies side by side

Delete the `with_account/3` call. Nothing else changes. Both artifacts committed
(`reports/courier-queue-identity/prove-mutated-no-identity.log` is the mutated
harness run):

| | fixed tree | identity deleted |
| --- | --- | --- |
| `prove-queue-identity.sh` | **15 passed, 0 failed** (exit 0) | **13 passed, 2 failed** (exit 1) |
| `dispatch_webhooks_worker_identity_test.exs` | **4 passed** | **1 passed, 3 failed** |
| `dispatch_webhooks_worker_test.exs` | **17 passed** | **17 passed** ← |

**The third row is the finding.** The worker suite that has been green for the
whole life of this defect **stays green with the identity deleted**, because it
connects as `postgres`. A suite that cannot fail is not evidence, and this is
the measurement of that rather than an assertion about it.

The new file's red was also watched before the fix, for the expected reason:

```
left:  [{"b1c2d3e4-5f60-4718-8293-a4b5c6d7e8f9", true}]
right: [nil: true]
```

`nil` where the account belongs. That was on the *first* run, before the fix —
tests first, red shown.

### 3.3 The four tests, and what each one is for

1. **one account's fan-out reads under THAT account** — the identity, plus the
   **positive** counterpart (a real delivery naming this test's own endpoint), so
   the file is not only a claim about what did not happen.
2. **two accounts in one batch, two DIFFERENT identities** — the cross-tenant
   assertion. A session-scoped setting, or a single identity per batch, fails
   here and nowhere else.
3. **every read is inside a transaction** — `Tenancy.in_transaction?/1` on every
   captured read, because outside one `is_local := true` expires at the end of
   the statement that set it.
4. **an event recorded for a USER never reaches the protected table** — the
   control. `Courier.Deliver` writes `email.delivered` with no `account_id`, so
   `claim/0` skips it; this is the one path where "no identity" is *correct*, and
   a file that only ever saw identities could not tell it from the defect.

The file is `async: false` because it **attaches a telemetry handler**, which is
a registration against the whole VM: every other test emits
`[:courier, :repo, :query]` while it runs. `AGENTS.md`'s rule covers this and
the reason is written above the `use`.

### 3.4 Restore discipline

The mutation was reverted from a byte-copy taken before it was applied, **not**
from `git checkout HEAD` — at that point the fix itself was uncommitted, so
`HEAD` held the pre-fix file and `git checkout HEAD -- <file>` would have
discarded the fix along with the mutation. That is the same trap
`REPORT-pantry-publisher-rewrite-01.md` §5 records, and the reason it says
`restore()` checks out `HEAD` there is that the fix was committed first. Here it
was not, so the copy is the correct instrument. `diff` confirms byte-identity,
and `git status --porcelain` is empty.

---

## 4. `DeliverWebhookWorker`: the same defect, measured, deliberately NOT fixed

Found while measuring the first worker, on the same queue and the same protected
table. It is **live**, and its numbers are in §5 of the harness output:

| arm | return value | deliveries succeeded |
| --- | --- | --- |
| `without` | `{:ok, %{failed: 0, sent: 0, delivered: 0}}` | **0** |
| `with` (identity = account A) | `{:ok, %{failed: 0, sent: 1, delivered: 1}}` | **1** |
| `superuser` | `{:ok, %{failed: 0, sent: 2, delivered: 2}}` | **2** |

Measured, not asserted: the harness prints these under a heading that says they
are not in the tally and that it asserts nothing. They are deliberately outside
`$passes`/`$failures`.

**Why its fix is a different shape, and not the same four lines.** Two reasons,
both measured from the tree:

1. **It has no account to present.** `webhook_deliveries` has **no `account_id`
   column** — `grep -n "account_id" lib/courier/webhook_delivery.ex` returns
   nothing. A delivery row points at `(endpoint_id, event_id)` and nothing else,
   so at the moment the worker needs an identity it does not know one. The
   `with` arm getting **1, not 2** is the direct measurement of this: with an
   identity set, it still reads only the one account whose endpoints it can see,
   because there is no per-delivery account to switch to.
2. **Its first read happens before the account is known.** `due_deliveries/1`
   builds `enabled_endpoint_ids` from `WebhookEndpoint where status = :enabled`
   across **all** accounts, and uses it as a filter. That is a cross-account
   read by construction, and it is also the circuit breaker — dropping the filter
   would send webhooks to endpoints a receiver had disabled. Fixing this means
   changing what the filter is *for*, not wrapping it.

Both would need a decision about what identifies a delivery's account — most
plausibly an `account_id` on `webhook_deliveries`, which is a **migration plus
a schema change plus every read of that table**, and a question about whether
the table should then be protected (it is currently not, and
`protect_table` refuses a table with no tenancy column by name).

**This packet does not make that decision.** It is reported with numbers, it is
asserted nowhere, and §6 says so again. The fix chosen here is the one the
packet named; widening it into the sender would have meant changing a migration
in a packet whose brief says the fix must not widen anything.

---

## 5. The gate

```
$ ./bin/prime
Result: 1301 passed
```

`bin/gate-self-test` — the declaration's ability to fail, nine breakages each
caught by a different check:

```
gate-self-test: 11 passed, 0 failed
     the gate reported: Result: 1301 passed
```

### 5.1 Floors raised in the same commit, re-measured rather than assumed

| tier | before | measured | floor now |
| --- | --- | --- | --- |
| whole suite | 1297 | **1301** | 1291 → **1295** |
| no database (27 files) | 619 | **619** | 619 (unchanged) |
| database (35 → 36 files) | 678 | **682** | 678 → **682** |
| SSRF table | 62 | 62 | 62 (unchanged) |

**1301 = 619 + 682**, so the parts still sum to the whole — the check that has
to be re-run rather than assumed, since a file matching neither grep would make
the whole suite report 1301 while the tiers summed to 1297.

All four tests are in the **database** tier, and the tier's own claim ("these
tests touch `Courier.Repo`") is why: the subject is the transaction the
worker's read runs in. Putting it in the no-database tier would make that
tier's claim false for the same reason `telemetry_canary_test.exs` was moved out
of it. The file list is derived by the same `grep -rLE` CI uses, not written out.

The whole-suite floor is `1301 − 6`, keeping `gate.yml`'s margin of 6 and
keeping the two files' numbers equal — "a floor that is right in one place and
slack in another is worse than one that is uniformly slack, because a reader who
checked the one that was updated concludes the rest are fine."

### 5.2 `mix.lock`

```
$ git diff --exit-code HEAD -- mix.lock && echo "mix.lock: unchanged"
mix.lock: unchanged
```

---

## 6. What this packet does NOT settle

Named explicitly, because the value of §1 and §3 depends on not claiming more
than they measured.

1. **`DeliverWebhookWorker` is still broken.** §4, measured, not fixed. On a
   `NOSUPERUSER` owner it sends **0 of 2** deliveries with **0** log lines and
   returns `{:ok, %{failed: 0, sent: 0, delivered: 0}}` — the same silent
   failure this packet fixed in its sibling. **Whoever fixes it needs the
   `webhook_deliveries.account_id` decision first.**
2. **§6.1 of the inherited report is untouched and still true: nothing enqueues
   the queue.** Reproduced on this branch:
   ```
   $ grep -rn "Oban.insert" lib config priv test rel ops bin | wc -l
   0
   $ grep -rnE "Oban\.(insert|new)|Oban\.Job\{[^}]*worker|new\(Oban\.Job" lib config priv | wc -l
   0
   ```
   Six mentions of `Courier.Workers` outside the workers' own files, all
   inside comments (`lib/courier/events.ex:282`,
   `nats_publisher.ex:7`, `deliver.ex:62`, `outbox_event.ex:13`,
   `messages_controller.ex:22`,
   `priv/repo/migrations/20260930030240_create_outbox_events.exs:7`).
   **How this packet measured its worker without fixing that, as the brief
   required:** it called `perform/1` directly with a hand-built `%Oban.Job{}` —
   the same struct Oban hands a worker — and never went near an insert. **The
   two findings are separate: this packet's is that the fan-out reads without an
   identity; §6.1's is that nothing schedules it.** Fixing the identity does not
   make the queue run, and nothing here should be read as though it did.
3. **The deployed role is not observed, only reproduced.** §1 builds the role
   kit's cluster builds, per `initdb/10-cluster.sh:219`, and courier connects as
   that role per `docker-compose.yml`. It is not a measurement of a running
   deployment; it is a measurement of the configuration that deployment has. The
   residual risk is that the deployed `DATABASE_URL` names a *different* role —
   which would make this inert in production and live in any deployment that
   matches the compose file.
4. **Whether the policies would REFUSE this worker is still not asserted
   anywhere in `mix test`.** This packet asserts the identity is present and
   correct. That the presence produces the right rows is the harness's job, and
   only because `config/test.exs` connects as a superuser. A suite that connected
   as `NOSUPERUSER` could assert the denial directly, and that is a change to
   `config/test.exs` this packet did not make.
5. **`bin/gate-self-test` needs a green run to be meaningful, and one is
   load-bearing.** It runs the real suite in a copy of the committed tree, so it
   inherits every flake in §6.7 below.
6. **`Courier.Suppressions.ingest/1`-shaped questions are untouched.** Whether
   any *other* library read path outside a request holds no identity was not
   surveyed beyond the two workers named here. The grep that would find them is
   `grep -rn "NotificationPreferences\.\|Idempotency\.\|WebhookEndpoints\." lib/courier/workers/`,
   and `idempotency_keys` — protected, and read by `CourierWeb.Plugs.Idempotency`
   inside the request transaction — was checked and is fine.
7. **A pre-existing flake, measured, not introduced and not fixed here.** One
   database-tier run in several fails
   `test/courier/telemetry_canary_test.exs:185` — *"an id in an unmatched path
   reaches nothing at all"*. `AGENTS.md` records the race and its cause:
   `request_spans/0` reads **every** `courier.web.request` span in a table shared
   by the whole VM, so a span from another test is read as this file's. Measured
   rather than asserted here, because "it was already flaky" is exactly the
   claim this fleet distrusts:

   | tree | runs | failing |
   | --- | --- | --- |
   | master, database tier, random seeds | 20 | **3** |
   | this branch, database tier, random seeds | 12 | **3** |
   | this branch, database tier, `--seed 0` | 12 | **0** |

   **The rate is unchanged by this packet** (3/20 on master against 3/12 here),
   and fixing the seed removes it entirely, which is the signature of a
   seed-dependent ordering race rather than of anything this packet added. The
   failing assertion predates this packet and runs against spans this packet does
   not produce. **Not adjusted**, per the standing instruction to prove a
   pre-existing failure rather than absorb it. `moon/DEBT.md` is the manager's
   ledger and was not edited.

### 6.1 Eight failures on the first clean run, and what they were

Recorded because the first `./bin/prime` on this worktree printed
`Result: 1289/1297 passed`, and "the gate was red when I arrived" is a sentence
that needs evidence behind it.

They were **not** on the branch. They were one leftover row in the shared
`courier_test` database, from an earlier aborted run, committed outside the
sandbox:

```
$ psql -X -q -h 127.0.0.1 -U postgres -d courier_test -c "select count(*) from idempotency_keys;"
 idempotency_key_rows
---------------------
                    1
```

All eight are in the two idempotency files, and every one of them counts the
**table** rather than its own rows — the test-level shape of the weakness D18
tracks, and the exact thing `AGENTS.md`'s rule ("mint an account per test that
needs to assert nothing was written, and count that account") exists to prevent.
The residue row's account is `11111111-1111-1111-1111-111111111111`, which is
the `@key` used by both files.

```
$ psql … -c "delete from idempotency_keys;"
$ MIX_ENV=test mix test test/courier/idempotency_test.exs test/courier_web/plugs/idempotency_test.exs
Result: 42 passed
$ ./bin/prime
Result: 1297 passed
```

**The baseline is therefore 1297 green, and the failure was environmental, not
master's and not mine.** It is reported because deleting a row out of a shared
database to make a gate green is exactly the kind of action that should be
written down rather than remembered.

---

## 7. Reproduce

```sh
# 1. THE MEASUREMENT, before the fix. Exits 1; the two FAILs are the defect.
git checkout 90aa07b
bash reports/courier-queue-identity/prove-queue-identity.sh

# 2. THE FIXED TREE. 15 passed, 0 failed, exit 0.
git checkout worker/courier-queue-identity-01
bash reports/courier-queue-identity/prove-queue-identity.sh

# 3. THE FALSIFICATION. There is deliberately no script for this step: the
#    mutation is a deletion, and a script that deletes the fix and re-adds it
#    is a second copy of the fix to keep in step with the first. The committed
#    artifact is the LOG, and the mutation is one edit:
#
#      lib/courier/workers/dispatch_webhooks_worker.ex — replace
#
#        {:ok, endpoints} =
#          Tenancy.with_account(Repo, event.account_id, fn ->
#            WebhookEndpoints.enabled(event.account_id)
#          end)
#
#      with
#
#        endpoints = WebhookEndpoints.enabled(event.account_id)
#
#    Then, on that tree:
#
#      bash reports/courier-queue-identity/prove-queue-identity.sh   # 13 pass, 2 FAIL, exit 1
#      mix test test/courier/workers/dispatch_webhooks_worker_identity_test.exs  # 1 pass, 3 FAIL
#      mix test test/courier/workers/dispatch_webhooks_worker_test.exs          # 17 pass, 0 FAIL
#
#    All three were run in that state; the first is committed verbatim as
#    reports/courier-queue-identity/prove-mutated-no-identity.log, whose footer
#    records the other two. Restore from a copy taken BEFORE the edit, not from
#    `git checkout HEAD` — at that point the fix was uncommitted, so HEAD held
#    the pre-fix file and HEAD would have taken the fix with it (§3.4).

# 4. THE GATE
./bin/prime                    # Result: 1301 passed
bin/gate-self-test             # 11 passed, 0 failed
bin/assert-suite <(./bin/prime 2>&1) "whole suite" 1295
```

Needs a postgres at `localhost:5432` as `postgres/postgres`, and the pinned
toolchain (`mise install`). The harness creates and drops its own role and
database and touches nothing else; the shared `courier_test` is not used by it.

---

## 8. Commits

| commit | what it is |
| --- | --- |
| `90aa07b` | **the measurement, before the fix** — harness, driver, and the red log. No `lib/` change. Its expectations are written against the fixed tree, so it is red here by construction. |
| `1bb8b08` | the fix, the check, the mutated-run log, and the four floors. |

`git diff --stat master...HEAD`: 8 files, 1168 insertions, 9 deletions.
The only `lib/` file is `lib/courier/workers/dispatch_webhooks_worker.ex`.
Nothing pushed. `wt-m39-pantry-27` and `wt-reg-compat-05` untouched.