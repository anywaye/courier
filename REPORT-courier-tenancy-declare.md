# REPORT — courier-tenancy-declare

Branch `worker/courier-tenancy-declare`. One commit:
`courier-27: declare the account boundary courier already enforces`
(`tenancy.yml`, new, 380 lines).

---

## 1. The coverage map — what courier's cross-tenant negative tests actually cover

D18 measures courier at **19** cross-tenant negative tests. This is the map
behind that number, and the number is the least interesting thing about it.

**Counting rule.** A test counts if it holds a row belonging to account **B**,
acts as account **A**, and asserts that A does not get it. Both halves. A test
that seeds another account's row as a *fixture* and then asserts about A's own
rows is a positive control, not a negative one — it is listed below as a
fixture, separately, because the difference is exactly the one that makes a
count lie.

### 19 accounted for, one at a time

| # | file:line | subject | technique | shape |
| --- | --- | --- | --- | --- |
| 1 | `courier/webhook_endpoints_test.exs:171` | `webhook_endpoints` | `get/2` predicate | `nil` |
| 2 | `courier/webhook_endpoints_test.exs:208` | `webhook_endpoints` | `list/1` predicate | `[]` |
| 3 | `courier/webhook_endpoints_test.exs:251` | `webhook_endpoints` | `enabled/1` predicate | `[]` |
| 4 | `courier/notification_preferences_test.exs:215` | `notification_preferences` | `addressable/2` owner compare | `{:error, :not_found}` |
| 5 | `courier/notification_preferences_test.exs:224` | `notification_preferences` | `addressable/2` owner compare | `{:error, :not_found}` **+ row read back unchanged** |
| 6 | `courier/idempotency_test.exs:108` | `idempotency_keys` | `fetch/3` triple predicate | `nil` |
| 7 | `courier/workers/dispatch_webhooks_worker_test.exs:72` | `webhook_deliveries` | `enabled/1` inside the fan-out | count `== 0` |
| 8 | `courier/workers/dispatch_webhooks_worker_test.exs:81` | `webhook_deliveries` | `event.account_id` filter | count `== 0` |
| 9 | `courier_web/controllers/webhook_endpoints_controller_test.exs:127` | `webhook_endpoints` | over HTTP, `get/2` | 404 + body omits the url |
| 10 | `courier_web/controllers/webhook_endpoints_controller_test.exs:245` | `webhook_endpoints` | over HTTP, `page/3` | `{"data" => []}` |
| 11 | `courier_web/controllers/webhook_endpoints_controller_test.exs:328` | `webhook_endpoints` | over HTTP, `get/2` | 404 `not_found` |
| 12 | `courier_web/controllers/webhook_endpoints_controller_test.exs:399` | `webhook_endpoints` | over HTTP, `update/2` | 404 **+ row still `:enabled`** |
| 13 | `courier_web/controllers/webhook_endpoints_controller_test.exs:453` | `webhook_endpoints` | over HTTP, `delete/1` | 404 **+ row still there** |
| 14 | `courier_web/controllers/webhook_endpoints_controller_test.exs:536` | `webhook_endpoints` | over HTTP, `test/2` ping | 404 **+ no POST sent** |
| 15 | `courier_web/controllers/notification_preferences_controller_test.exs:130` | `notification_preferences` | over HTTP, `list/2` | 404 `not_found` |
| 16 | `courier_web/controllers/notification_preferences_controller_test.exs:150` | `notification_preferences` | over HTTP, `update/3` | 404 **+ row's own two flags read back** |
| 17 | `courier_web/controllers/notification_preferences_controller_test.exs:200` | `notification_preferences` | body `account_id` ignored | 200 for owner, 404 for other |
| 18 | `courier_web/plugs/idempotency_test.exs:238` | `idempotency_keys` | key scoped by principal | two 201s, 2 endpoints, 2 claims |
| 19 | `courier/principal/introspection_test.exs:169` | the door itself | `x-courier-account` header refused | `:error` |

### What the map says, which the count does not

**Three tables, and the spread is lopsided.** 9 of 19 sit on
`webhook_endpoints`, 4 on `notification_preferences`, 3 on `idempotency_keys`,
2 on the door. **`idempotency_keys` — the table this packet was named after —
has exactly one library-level test (#6) and one over HTTP (#18), and they
exercise two different mechanisms**: #6 is the `fetch/3` predicate and #18 is
the unique index on `(account_id, endpoint, idempotency_key)`. Neither touches
`complete/4` or `release/1`, which reach a row by primary key with no account
predicate at all.

**Four distinct isolation techniques, and one technique is missing.**

| technique | tests | entry points |
| --- | --- | --- |
| query predicate (`where account_id`) | 6 | `get/2`, `list/1`, `enabled/1`, `page/3`, `fetch/3`, fan-out |
| ownership compare in Elixir (`addressable/2`) | 3 | `preferences list/2`, `update/3` |
| unique index on the scoped triple | 2 | `claim/1`, `page/3` |
| plug-level refusal / body-ignored | 6 | the door, `PUT` body, `POST` body, key header |
| **row-level security** | **0** | — courier's database enforces nothing |

**Four of the six `/v1` webhook actions have a denial test; two do not.**
`index` (#10), `show` (#11), `update` (#12), `delete` (#13) and `test` (#14)
are covered. `create` and `ping`… `test` is the ping. So `create` is the one
verb on that surface with **no** cross-tenant negative test — deliberately, in
that an insert cannot reach an existing row (`schemas/tenant-isolation.schema.json`
excludes `insert` from `entryPoints[].operation` for exactly this reason), and
it does have the body-ignored test at :170 and the same-url test at :218.

**The `no-identity` direction is proven once per surface, not per entry point.**
`anonymous is refused on every action, with 401` loops over all six webhook
actions and both preference actions, and `messages_controller_test.exs:118`
covers the send path — but those are **two tests covering eight entry points**,
not eight tests. A future route added to a pipeline gets the plug for free; the
plug is what makes them safe, and that is the correct design rather than a gap.

**The 19 are not 19 independent things.** #9, #11 and #10 are three
`/v1/webhook_endpoints` reads through the same `current_account` assign, and
#1/#2/#3 are the library functions underneath them. Four of the 19 (1, 2, 3, 6)
would all go red from a single dropped `account_id` in `WebhookEndpoints` — the
count flatters a shared predicate. This is the false green the brief names: **19
tests that all exercise one code path reads identically to 19 tests spread
across the surface.** Here, the spread is real but it is 4 predicates behind 19
assertions, and the map above is the only thing that says so.

### Fixtures that are not negative tests

Named so nobody re-counts them: `webhook_endpoints_test.exs:119` and
`:189–204`, `webhook_endpoints_controller_test.exs:218`,
`idempotency_test.exs:72`, `messages_controller_test.exs:531`. Each seeds
another account's row. Two of them (#119, the controller's :218) do assert a
real boundary — that account B can hold the same url as A, which the
`(account_id, url)` unique index owns — but neither is a **refusal**, so under
the rule above they are scope positives.

---

## 2. `tenancy_check.py`, before and after

Run from the fleet root: `/Users/kaka/Code/any/moon/cafaye`.

**Before** (this worktree, no `tenancy.yml`) — reproduced by running against
`courier/`, which is the same tree at `worker/courier-tenancy-declare`'s base:

```
$ python3 core/harness/tenancy_check.py courier
FAIL tenancy.declaration-missing: tenancy.yml is not in /Users/kaka/Code/any/moon/cafaye/courier
    fix: write tenancy.yml; schemas/tenant-isolation.schema.json is the format and docs/tenancy.md is the worked example

FAIL /Users/kaka/Code/any/moon/cafaye/courier: 1 failure(s), 0 warning(s) — no warnings, so nothing was left unproven silently
EXIT=1
```

**After:**

```
$ python3 core/harness/tenancy_check.py wt-m39-courier-tenancy-declare
WARN tenancy.enumeration-partial: this checker reads SQL statements and account-key
predicates, and it could not classify 46 account-scoped site(s): ...
WARN tenancy.scope-key-unused: no account-scoped statement this scanner can read carries
'account_id'. ...

OK /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-tenancy-declare: 0 failure(s), 2 warning(s)
— warnings do not move the exit code
EXIT=0
```

Nothing in core was relaxed, nothing was touched outside this worktree, and no
claim was invented to turn a red green. **The two warnings are the checker
reading Elixir and are not courier's boundary being weak** —
`tenancy_check.py`'s scanner recognises `select … from` / `update … set` /
`delete from`, and an Ecto query is none of those, so zero of courier's 46
`account_id` lines resolve to a statement. That is the exact condition those
two findings were given non-fatal severities for, and it is stated in the
file's own header.

**What the warnings cost, said plainly: the enumeration is NOT proven closed.**
`tenancy_check.py` cannot see one line of courier's account scoping. The file
and `test/courier/**` are what hold it, which is why §1 exists.

### What the declaration claims, and the two directions of the gap

**Declared and proved** (checker verifies each `enforced.line` still carries
`account_id`, each arm's line still carries its token, and the schema holds the
shape):

| entry point | enforcement | no-identity | other-account | own-account |
| --- | --- | --- | --- | --- |
| `webhook-endpoints-get` | `webhook_endpoints.ex:95` `query-filter` | ctrl:101 `halted` | ctx:176 `nil` | ctx:168 `id` |
| `webhook-endpoints-list` | `:110` `query-filter` | ctrl:101 `halted` | ctx:211 `[]` | ctx:204 `id` |
| `webhook-endpoints-enabled` | `:124` `query-filter` | ctrl:101 `halted` | ctx:254 `[]` | ctx:241 `id` |
| `webhook-endpoints-page` | `:156` `query-filter` | ctrl:101 `halted` | ctrl:250 `[]` | ctrl:241 `id` |
| `idempotency-keys-fetch` | `idempotency.ex:151` `query-filter` | msgs:111 `unauthorized` | ctx:110 `nil` | ctx:95 `id` |
| `notification-preferences-list` | `notification_preferences.ex:150` `repository-method` | prefs ctrl:94 `halted` | ctx:221 `not_found` | ctx:43 `email_enabled` |
| `notification-preferences-update` | `:150` `repository-method` | prefs ctrl:94 `halted` | ctx:242 `push_enabled` | prefs ctrl:177 `email_enabled` |
| `webhook-deliveries-dispatch` | `dispatch_webhooks_worker.ex:80` `call` | worker:123 `count` | worker:78 `count` | worker:58 `count` |

**Direction 1 — the declaration claims, the tests do NOT prove:**

1. **`no-identity` is a 401 refusal, not an empty result.** Every arm but the
   worker's names a line proving the pipeline **halted** before a query was
   issued. `schemas/tenant-isolation.schema.json` asks for "reads zero rows" and
   says a refusal is not an acceptable answer; courier has no other answer,
   because the plug stops the request before any statement runs. The alternative
   was to point every arm at a library call with `account_id: nil` — which
   returns `nil` only because the column is `NOT NULL`, not because a boundary
   refused it, and which **no test in this suite drives**. That would have been
   a false green. Documented at length in the file's header; it is a finding for
   core's schema, not a defect in courier.
2. **`idempotency-keys-fetch` claims a table it does not fully describe.**
   `Courier.Idempotency.complete/4` (`Repo.get!(id)`) and `release/1`
   (`where([k], k.id == ^id)`) reach rows by primary key with **no** account
   predicate. Nothing hands either a foreign id — `CourierWeb.Plugs.Idempotency`
   passes the id out of the `claim/1` it just made — so the boundary holds, but
   it is **above the statement, not in it**, and there is no negative test for
   either. Written into `scope.sources`' comment rather than declared as an
   entry point, because declaring it would require three arms that do not exist.
3. **`webhook-endpoints-page` has no library-level negative test.**
   `webhook_endpoints_test.exs` has no `describe "page"` block; both denial arms
   point at the controller test, which is where its only caller is. Said in the
   file.
4. **`notification-preferences-update`'s own-account arm is a read-back, not a
   write's return.** Line 177 is the owner reading its own row after the write.
   True and the strongest token available, but it is one assertion covering two
   tests' work.
5. **`webhook-deliveries-dispatch` is `operation: call`, and `call` has no
   closure check.** The checker says so out loud as `enumeration-partial`. Its
   "no-identity" arm is an event with `account_id: nil` — a real state, since
   `Courier.Deliver` writes `email.delivered` without an account — but the word
   "identity" is being stretched to mean it, and the file says so.

**Direction 2 — the tests prove, the declaration does NOT claim:**

1. **The door.** Six tests (`introspection_test.exs:169`,
   `principal_config_test.exs:179`, both `anonymous is refused …` blocks,
   `introspection_test.exs:134`, `:147`) hold the **tenancy key** — `sub` is
   never used as a fallback, a `no account_id` document is refused, an
   unauthenticated request never dials identity. That is a stronger boundary
   than any query predicate and it is **not an entry point in the file**, because
   `CourierWeb.Plugs.Principal` reaches no row. Named in the header instead.
2. **`idempotency_test.exs:72` and `webhook_endpoints_test.exs:119`** — the
   unique-index collisions (`same key + other account`, `same url + other
   account`). Both are scope positives the declaration has no vocabulary for.
3. **`notification_preferences_test.exs:169`** — `account_id` inside an entry is
   a 422 naming the field, not a silently dropped key.
4. **`messages_controller_test.exs:118`** — `no principal means no mail and no
   row`, which is the `no-identity` arm for a table the declaration does not
   cover at all (`email_suppressions` and `outbox_events` have no boundary to
   declare; `outbox_events.account_id` is a write, `email_suppressions` has no
   account column **by design**).

**The one structural absence, and it is the honest centre of this packet:**
courier's database enforces nothing. `rls.databaseEnforced: false`, `tables: []`,
`scope.sources` naming `priv/repo/migrations` — and measured, not asserted: none
of the ten migrations mentions `row level security`, `create policy`, `force row
level` or `security definer`, which is why `tenancy.rls-undeclared` and
`tenancy.rls-unreadable` are both silent. Every boundary above is one dropped
Elixir predicate away from being gone, with nothing in the database standing in
the way. That is the same shape D18 calls "correct by construction with nothing
holding it in place", and it is the argument for the declaration rather than
against it.

---

## 3. What I deliberately did NOT do, and why

- **No cross-tenant tests.** Explicitly a separate packet; `parlor` is getting
  one because it has zero, and courier has 19. §1 is the accounting, not an
  invitation.
- **No migration, no RLS adoption, no `protect_table` call.** `courier/AGENTS.md`
  forbids a dependency without approval and the fleet has not agreed the
  substrate's role outside `identity`; adding a `cafaye` schema and five
  generated policies is a database change nobody asked for. `databaseEnforced:
  false` is the truth and the truth is declarable.
- **No entry point for `complete/4` or `release/1`.** The schema needs three
  arms each; two of the three do not exist. Declaring them with arms borrowed
  from `fetch/3` would make `tenancy_check.py` green over a boundary nobody
  tested — the exact lie this packet exists to prevent. Written down instead.
- **No `enforced` line moved to suit the checker.** `notification_preferences.ex:150`
  is `^account_id -> :ok` inside `addressable/2`, not a query predicate, and it
  is declared `repository-method` rather than `query-filter`. The vocabulary has
  no word for "compared in Elixir against a value the row carries", and naming
  it `query-filter` would have been a claim about a line that has no predicate.
- **Did not run the full suite.** The brief says the narrowest target will do
  and this change adds no code — it adds a YAML file. See §5.
- **Did not touch core, identity, or any other repository.** `tenancy.yml` is one
  new file in this worktree.

---

## 4. Claims I could not verify, and therefore left out

1. **Whether `Courier.Idempotency`'s boundary survives a caller that reuses an
   id.** I read `CourierWeb.Plugs.Idempotency` and it passes the id out of the
   `claim/1` it just made, in the same request. I did not run a test proving no
   other caller exists, so the claim is in a comment as reasoning, not in
   `entryPoints` as a declaration.
2. **Whether `page/3` is reached anywhere but `GET /v1/webhook_endpoints`.**
   `webhook_endpoints.ex:151` has one caller in `lib/`; I confirmed it by grep
   and did not prove it for the long tail of `test/`.
3. **The exact provenance of D18's 19.** The script that produced that count is
   not in `core/harness/` on this checkout (`account_scope_check.py` exists only
   in `wt-m39-core-tenancy-enum`, and its own docstring quotes a different
   table). I therefore re-derived all 19 by hand against a counting rule stated
   above, and I got 19. **That is corroboration, not reproduction** — the rule
   may not be the rule that produced the number, and §1 says which tests are
   borderline so a reader can apply their own.
4. **That the `no-identity` 401 lines cover the entry point they are declared
   against.** `webhook_endpoints_controller_test.exs:101` loops over six
   actions; `notification_preferences_controller_test.exs:94` over two. Both are
   genuine, but one line standing for eight entry points is thinner evidence
   than eight lines, and the file's header says so.

---

## 5. Verification actually run

```
$ python3 core/harness/tenancy_check.py wt-m39-courier-tenancy-declare
OK ... 0 failure(s), 2 warning(s)      EXIT=0
```

**No Elixir test was run, and none is claimed.** `tenancy.yml` is a YAML file
at the repository root: no `.ex`, no `.exs`, no mix task, no dependency. The
narrowest Mix target covering `Courier.Idempotency` is
`mix test test/courier/idempotency_test.exs`, and it would exercise code this
commit does not change. Running it would have produced a green that says
nothing about this diff. **`bin/prime` and the full suite were NOT run.**

The only claim here that is about running code is the line numbers in
`entryPoints`, and those were verified by reading — then confirmed
mechanically by `tenancy_check.py` itself, which is what makes them a contract:
`tenancy.location-missing` and `tenancy.line-missing` fire on a file or line
that is not there, and `tenancy.scope-lost` fires on an `enforced.line` that no
longer carries `account_id`. **Zero of those fired, so all 32 named locations
exist and all 8 enforcement lines still carry the key.** The negative-arm tokens
are checked the same way (`tenancy.denial-missing`).

---

## 6. Handoff

Work remains, and none of it is in this branch.

**Successor's first move: `test/courier/idempotency_complete_test.exs`, covering
the two entry points §2 direction 1 names as undeclared.**
`Courier.Idempotency.complete/4` and `release/1` reach `idempotency_keys` by
primary key with no account predicate. Nothing hands either a foreign id today,
which is why it is safe and why it is undeclared — and "safe because nothing
calls it that way" is a property of the callers, not of the query. Three tests
is the whole job:

1. `complete/4` with another account's claim id writes nothing (and
   `tenancy.unpaired` is not a thing — read the row back, do not assert an
   absence);
2. `release/1` likewise;
3. the positive control: the owner's own claim still completes, and the stored
   response is byte-for-byte the one `fetch/3` replays.

When those exist, add two entry points to `tenancy.yml` —
`idempotency-keys-complete` and `idempotency-keys-release`, `operation: update`
and `delete`, `enforced` at `idempotency.ex:163` and `:174` — and **raise
`.github/workflows/ci.yml`'s tier floors in the same commit**, which
`courier/AGENTS.md` requires for any test added or deleted.

**Then, in order:**

- **A cross-tenant test for `WebhookEndpoints.page/3` at the library level.**
  Both of its denial arms are currently one controller test. This is the only
  account-scoped query in the tree with no test of its own.
- **Decide `rls`.** `databaseEnforced: false` is now a written-down decision
  rather than an omission, which is the point — but it is a decision courier
  made by not asking. Adopting `cafaye.protect_table` on `webhook_endpoints` and
  `idempotency_keys` is a `core` + `kit` conversation first.
- **`tenancy.enumeration-partial` will keep naming 46 lines until core's scanner
  reads Ecto.** That is a finding for core, and it is the same finding identity
  recorded for Go's three-to-eight-line `ATTRIBUTION_WINDOW`.

**No handoff file is needed beyond this section** — nothing here is
half-finished. The commit is the deliverable.