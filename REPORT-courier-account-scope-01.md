# REPORT — `courier-account-scope-01`

**Branch:** `worker/courier-account-scope-01` (not pushed)
**Base:** `93811f4`
**Outcome:** `account_scope.yml` exists, `core`'s checker reads it and exits `0`,
**0 undeclared, 0 stale**, 9 account-scoped and 10 not-account-scoped. It has been
lied to on purpose and **all nine lies went red**, each naming a file and a line;
the same check has then been deleted from a throwaway copy of the checker and the
liar **passes clean**. The declaration is load-bearing in the direction that
matters.

Two findings about `courier`'s own code came out of writing it, both re-derived by
a command in §6, and neither is fixed here: **nothing in this repository enqueues
the queue** (§6.1), and **one Oban worker reads a protected table by
`account_id` with no database identity on its path** (§6.2). Four findings about
the contract are in §7, and the sharpest is that the checker **cannot check a
queue consumer at all** — which it says so, out loud, on every run.

---

## 1. The control, before and after

**Before.** The command the packet quotes, run against this worktree:

```
$ cd cafaye/core && python3 harness/account_scope_check.py ../wt-m39-courier-scope-01
FAIL account-scope.declaration-missing: account_scope.yml is not in /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01
    fix: write account_scope.yml; the format is documented in docs/account-scope.md and the schema is schemas/account-scope.schema.json

FAIL /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01: 0 account-scoped, 0 not-account-scoped, 0 stale, 0 undeclared — 1 failure(s), 0 warning(s), so nothing was left unproven silently
EXIT=1
```

**After.** Same command, same tree, plus the one file:

```
$ cd cafaye/core && python3 harness/account_scope_check.py ../wt-m39-courier-scope-01
WARN account-scope.contradiction-unreadable: process-outbox-worker: declared accountScoped: false and this checker could not read the code behind it — no registration on the declared surface matched this row
    fix: name the router's middleware and controller modules the way this repository already spells them, and if a module is in another repository say so in a comment on the row — a checker that cannot resolve a symbol says so rather than trusting the declaration
WARN account-scope.contradiction-unreadable: dispatch-webhooks-worker: declared accountScoped: false and this checker could not read the code behind it — no registration on the declared surface matched this row
    fix: name the router's middleware and controller modules the way this repository already spells them, and if a module is in another repository say so in a comment on the row — a checker that cannot resolve a symbol says so rather than trusting the declaration
WARN account-scope.contradiction-unreadable: deliver-webhook-worker: declared accountScoped: false and this checker could not read the code behind it — no registration on the declared surface matched this row
    fix: name the router's middleware and controller modules the way this repository already spells them, and if a module is in another repository say so in a comment on the row — a checker that cannot resolve a symbol says so rather than trusting the declaration

  account-scoped     GET /v1/notification_preferences/{user_id}  (lib/courier_web/router.ex:136)
  account-scoped     PUT /v1/notification_preferences/{user_id}  (lib/courier_web/router.ex:137)
  account-scoped     GET /v1/webhook_endpoints  (lib/courier_web/router.ex:139)
  account-scoped     GET /v1/webhook_endpoints/{id}  (lib/courier_web/router.ex:140)
  account-scoped     PATCH /v1/webhook_endpoints/{id}  (lib/courier_web/router.ex:141)
  account-scoped     DELETE /v1/webhook_endpoints/{id}  (lib/courier_web/router.ex:142)
  account-scoped     POST /v1/webhook_endpoints  (lib/courier_web/router.ex:157)
  account-scoped     POST /v1/webhook_endpoints/{id}/test  (lib/courier_web/router.ex:158)
  account-scoped     POST /v1/messages  (lib/courier_web/router.ex:166)
  not-account-scoped Courier.Workers.DeliverWebhookWorker  (lib/courier/workers/deliver_webhook_worker.ex:1)
  not-account-scoped Courier.Workers.DispatchWebhooksWorker  (lib/courier/workers/dispatch_webhooks_worker.ex:1)
  not-account-scoped Courier.Workers.ProcessOutboxWorker  (lib/courier/workers/process_outbox_worker.ex:1)
  not-account-scoped GET /internal/v1/errors/healthz  (lib/courier_web/error_router.ex:114)
  not-account-scoped POST /api/{project_id}/envelope/  (lib/courier_web/error_router.ex:124)
  not-account-scoped GET /healthz  (lib/courier_web/router.ex:112)
  not-account-scoped GET /readyz  (lib/courier_web/router.ex:113)
  not-account-scoped POST /inbound/resend  (lib/courier_web/router.ex:212)
  not-account-scoped GET /unsubscribe/{token}  (lib/courier_web/router.ex:273)
  not-account-scoped POST /unsubscribe/{token}  (lib/courier_web/router.ex:274)

  not verified: 1 pipeline symbol(s) the router names that resolve to no code in this repository — plug accepts, which is not defined in this repository

OK /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01: 9 account-scoped, 10 not-account-scoped, 0 stale, 0 undeclared — 0 failure(s), 3 warning(s); warnings do not move the exit code
EXIT=0
```

**The three warnings are not noise and they are not mine to suppress.** Each one is
`account-scope.contradiction-unreadable` on one of the three `kind: job` rows: the
contradiction check needs a `Registered` off the declared surface, a queue consumer
has none, so a `false` row it cannot read is a row nobody checked — and it says so
rather than passing it. §7.1 is the write-up.

**The `not verified:` line is about `plug :accepts`**, which is
`Phoenix.Controller.accepts/2` imported into the router rather than defined in it.
It is reported once per repository and is not a finding.

---

## 2. The declaration, and the three things in it that are a decision

`account_scope.yml`, 19 rows. Full reasoning is in the file's own header; what
follows is the short form of the three choices a reader would otherwise have to
reverse-engineer.

### 2.1 `surface.sources` names BOTH routers, and the second one is on its own port

`lib/courier_web/router.ex` (14 routes) and `lib/courier_web/error_router.ex`
(2 routes). The second is `CourierWeb.ErrorRouter` behind `CourierWeb.ErrorEndpoint`
— the Sentry-compatible error ingest, on a listener of its own. It is courier's
surface exactly as `/v1` is, and `undeclared` is structurally unable to see a
whole endpoint that `surface.sources` does not name.

Two files rather than the `lib/courier_web` directory: a directory drags in the
endpoint and the plugs, and a route added to a plug would move a floor that is
supposed to mean something about routes.

### 2.2 `surface.minimum: 16` is what the checker finds, and it is a decrease-detector

The number is 16 and, unusually for this fleet, **it is also the number of routes
courier serves** — because every route in both routers is a string literal on one
line and nothing is registered through a constant. `identity`'s floor is 41 against
54 routes for exactly that reason, and `identity`'s file names the thirteen it
cannot see one by one. `courier` has no such list, and §4.1 is the command that
shows there is nothing to list.

The floor is load-bearing rather than asserted, which matters more here than the
number does:

```
$ work=/tmp/courier-account-scope-falsify/floor; rm -rf "$work"; mkdir -p "$work"
$ ( cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01 && git archive HEAD ) | tar -x -C "$work"
$ grep -c '^  minimum: 16$' "$work/account_scope.yml"
1
$ sed -i '' 's/^  minimum: 16$/  minimum: 17/' "$work/account_scope.yml"
$ python3 /Users/kaka/Code/any/moon/cafaye/core/harness/account_scope_check.py "$work" | grep -E '^(FAIL|OK)'
FAIL account-scope.surface-thin: the declared sources register 16 entry point(s) and surface.minimum is 17
FAIL /private/tmp/courier-account-scope-falsify/floor: 9 account-scoped, 10 not-account-scoped, 0 stale, 0 undeclared — 1 failure(s), 3 warning(s); warnings do not move the exit code
EXIT=1
```

### 2.3 `via: with_account` is `Courier.Tenancy.with_account/3`, written bare — and why

The packet asked for `cafaye.with_account/3` in `accountFrom.via`. **That string
cannot be written in the field.** The schema's `via` pattern is
`^[A-Za-z_][A-Za-z0-9_]*$` and the checker enforces the same
(`SYMBOL_PATTERN`), because it matches `via` on two lines of text and "a path
through the code is not text". So the bare function name is what is declared and
the module-qualified name is in a comment beside it.

The choice of *that* symbol over the plug is the substantive one, and courier's own
moduledoc decides it rather than taste: `lib/courier/tenancy.ex` says *"`with_account/3`
is the only way to obtain an identity"*, and it is the only function in the tree
that opens the transaction the identity lives in. The plug
(`CourierWeb.Plugs.TenantIdentity`) is the wiring; `with_account/3` is the function
that resolves the account **as the database sees it**, which is what "resolves the
caller's account" has to mean on a service whose row-level-security policies key
on `cafaye.account_id`. One call site, and it is the plug:

```
$ cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01
$ grep -rn "Tenancy.with_account\|with_account(" lib | grep -v "^lib/courier/tenancy.ex"
lib/courier_web/plugs/tenant_identity.ex:84:    case Tenancy.with_account(Courier.Repo, account_id, fn -> conn end) do
$ grep -n "def with_account" lib/courier/tenancy.ex
129:  def with_account(repo, account_id, fun) when is_function(fun, 0) do
```

That one grep is also the whole justification for the three `false` rows that are
most likely to be questioned: `/inbound/resend`, `GET /unsubscribe/{token}` and
`POST /unsubscribe/{token}` pipe through `:api` and never through
`:authenticated`, so `with_account/3` is not on their path. They reach
`email_suppressions`, `unsubscribe_tokens` and `outbox_events` and they resolve no
account — and §3.1 shows the checker independently agrees, seven rows out of seven,
with **zero false positives**.

---

## 3. The falsification

Two halves, both on a **copy**. `git archive` reads a commit and writes only into
`$work`; nothing in this worktree or in `cafaye/core` is touched by either, and §8
prints `git status` for both.

### 3.1 THE LIAR — nine routes that really are account-scoped, declared `false`

```
$ wt=/Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01
$ core=/Users/kaka/Code/any/moon/cafaye/core
$ work=/tmp/courier-account-scope-falsify
$ rm -rf "$work"; mkdir -p "$work/tree"
$ ( cd "$wt" && git archive HEAD ) | tar -x -C "$work/tree"
$ grep -c '^    accountScoped: true$' "$work/tree/account_scope.yml"
9
$ grep -c '^    accountFrom: { via: with_account' "$work/tree/account_scope.yml"
9
```

The mutation, applied by a script that **refuses to run unless it finds exactly
nine sites** and prints how many it found:

```python
lie   = "    accountScoped: true\n    accountFrom: { via: with_account, file: lib/courier/tenancy.ex, line: 129 }\n"
truth = "    accountScoped: false\n    reason: public\n"
applied = text.count(lie)
print(f"mutation sites found: {applied}")
if applied != 9:
    raise SystemExit(f"expected 9 sites, found {applied}")
path.write_text(text.replace(lie, truth))
```

```
mutation sites found: 9
grep-confirm AFTER:   accountScoped: true = 0   accountScoped: false = 19   reason: public = 11
```

`reason: public` is the crudest lie available — it asserts no credential is looked
up on nine routes that 401 without one — so the finding has to survive being wrong
about the *reason* as well as the boolean.

```
$ python3 "$core/harness/account_scope_check.py" "$work/tree"
FAIL account-scope.declaration-contradicts-code: messages-create (POST /v1/messages) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: webhook-endpoints-index (GET /v1/webhook_endpoints) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: webhook-endpoints-show (GET /v1/webhook_endpoints/{id}) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: webhook-endpoints-update (PATCH /v1/webhook_endpoints/{id}) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: webhook-endpoints-delete (DELETE /v1/webhook_endpoints/{id}) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: webhook-endpoints-create (POST /v1/webhook_endpoints) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: webhook-endpoints-ping (POST /v1/webhook_endpoints/{id}/test) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: notification-preferences-show (GET /v1/notification_preferences/{user_id}) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
FAIL account-scope.declaration-contradicts-code: notification-preferences-update (PUT /v1/notification_preferences/{user_id}) is declared accountScoped: false with reason 'public', and the scope pipes through CourierWeb.Plugs.Principal, and lib/courier_web/plugs/principal.ex:97 resolves an account: `assign(conn, :current_account, account_id)` — resolved account evidence at lib/courier_web/plugs/principal.ex:97
    fix: change `accountScoped` to `true` and name the line the evidence is on in `accountFrom` — or, if the route really is not account-scoped, remove what the evidence names, because the finding prints the file and line it found
WARN account-scope.contradiction-unreadable: process-outbox-worker: declared accountScoped: false and this checker could not read the code behind it — no registration on the declared surface matched this row
    fix: name the router's middleware and controller modules the way this repository already spells them, and if a module is in another repository say so in a comment on the row — a checker that cannot resolve a symbol says so rather than trusting the declaration
WARN account-scope.contradiction-unreadable: dispatch-webhooks-worker: declared accountScoped: false and this checker could not read the code behind it — no registration on the declared surface matched this row
    fix: name the router's middleware and controller modules the way this repository already spells them, and if a module is in another repository say so in a comment on the row — a checker that cannot resolve a symbol says so rather than trusting the declaration
WARN account-scope.contradiction-unreadable: deliver-webhook-worker: declared accountScoped: false and this checker could not read the code behind it — no registration on the declared surface matched this row
    fix: name the router's middleware and controller modules the way this repository already spells them, and if a module is in another repository say so in a comment on the row — a checker that cannot resolve a symbol says so rather than trusting the declaration
WARN account-scope.nothing-scoped: all 19 declared entry point(s) are accountScoped: false
    fix: check the routes that read a customer row and are declared `false`; a service that holds other people's data and says so nowhere is the D18 defect in a form a checker can now see

  not-account-scoped Courier.Workers.DeliverWebhookWorker  (lib/courier/workers/deliver_webhook_worker.ex:1)
  not-account-scoped Courier.Workers.DispatchWebhooksWorker  (lib/courier/workers/dispatch_webhooks_worker.ex:1)
  not-account-scoped Courier.Workers.ProcessOutboxWorker  (lib/courier/workers/process_outbox_worker.ex:1)
  not-account-scoped GET /internal/v1/errors/healthz  (lib/courier_web/error_router.ex:114)
  not-account-scoped POST /api/{project_id}/envelope/  (lib/courier_web/error_router.ex:124)
  not-account-scoped GET /healthz  (lib/courier_web/router.ex:112)
  not-account-scoped GET /readyz  (lib/courier_web/router.ex:113)
  not-account-scoped GET /v1/notification_preferences/{user_id}  (lib/courier_web/router.ex:136)
  not-account-scoped PUT /v1/notification_preferences/{user_id}  (lib/courier_web/router.ex:137)
  not-account-scoped GET /v1/webhook_endpoints  (lib/courier_web/router.ex:139)
  not-account-scoped GET /v1/webhook_endpoints/{id}  (lib/courier_web/router.ex:140)
  not-account-scoped PATCH /v1/webhook_endpoints/{id}  (lib/courier_web/router.ex:141)
  not-account-scoped DELETE /v1/webhook_endpoints/{id}  (lib/courier_web/router.ex:142)
  not-account-scoped POST /v1/webhook_endpoints  (lib/courier_web/router.ex:157)
  not-account-scoped POST /v1/webhook_endpoints/{id}/test  (lib/courier_web/router.ex:158)
  not-account-scoped POST /v1/messages  (lib/courier_web/router.ex:166)
  not-account-scoped POST /inbound/resend  (lib/courier_web/router.ex:212)
  not-account-scoped GET /unsubscribe/{token}  (lib/courier_web/router.ex:273)
  not-account-scoped POST /unsubscribe/{token}  (lib/courier_web/router.ex:274)

  not verified: 1 pipeline symbol(s) the router names that resolve to no code in this repository — plug accepts, which is not defined in this repository

FAIL /private/tmp/courier-account-scope-falsify/tree: 0 account-scoped, 19 not-account-scoped, 0 stale, 0 undeclared — 9 failure(s), 4 warning(s); warnings do not move the exit code
EXIT=1
```

**Every lie named, and every one with a file and a line:**

```
=== every lie named, with a file and a line ===
  lies named = 9 of 9
  each names a file:line = 9
  exit = 1 (1 required)

=== and the rows that are HONESTLY false are not accused ===
  not accused               healthz (GET /healthz)
  not accused               readyz (GET /readyz)
  not accused               inbound-resend (POST /inbound/resend)
  not accused               unsubscribe-show (GET /unsubscribe/{token})
  not accused               unsubscribe-create (POST /unsubscribe/{token})
  not accused               error-relay-healthz (GET /internal/v1/errors/healthz)
  not accused               error-envelope-ingest (POST /api/{project_id}/envelope/)
  false positives = 0 of 7
```

Two things in that run are worth more than the nine.

**The summary listing printed all nineteen as `not-account-scoped` while the run
exited 1.** The listing is a rendering of the declaration's *answer*; the finding is
the disagreement between that answer and the code. A reader who reads only the table
is reading a liar's table. That is a property of the format, not a bug, and it is
the argument for why the finding has to be a `fail` and not a warning.

**`core`'s own documentation measured this check on 14 of courier's routes — 9 true
positives, 0 false positives, and 5 correctly not named. `courier` is the first
adopter where the error router's two rows are in scope as well, and both are
correctly not accused**, which is the first time those two routes have been put
through it at all.

### 3.2 THE BREAKING — the check deleted from the source, and the liar passes

The call is **deleted from the source of a copy**, not configured off with an
environment variable, and the harness is copied **whole** because it refuses to run
a partial copy — which is the correct behaviour and cost one run to discover:

```
$ cp /Users/kaka/Code/any/moon/cafaye/core/harness/*.py "$work/checker/"
$ ls "$work/checker" | wc -l
11
```

```python
call = "    contradictions = _check_contradictions(repo, points, matched)"
applied = source.count(call)
print(f"mutation sites found: {applied}")
if applied != 1:
    raise SystemExit(f"expected exactly 1 site, found {applied}")
# `Contradictions()`, not `[]`: the call site reads `.findings` and `.unverified`
# off the result, so a two-element list is not a stand-in for it. The patch has
# to defeat the CHECK, not merely the unpacking.
path.write_text(source.replace(call, "    contradictions = Contradictions()", 1))
```

```
=== the deletion, and the grep that says it applied exactly once ===
mutation sites found: 1
grep-confirm  call sites left in the COPY   = 0
grep-confirm  the DEFINITION left in the copy = 1
grep-confirm  call sites left in CORE        = 1
the two files differ by:
1281c1281
<     contradictions = _check_contradictions(repo, points, matched)
---
>     contradictions = Contradictions()
  (that is the whole difference — 2 line(s))
```

Two greps, one each side: the **call** is gone from the copy and the **definition**
is still there, so the copy is not a checker that cannot run the check — it is a
checker that chooses not to. And core's file still calls it.

```
=== the copy, against the CONTROL tree (the honest declaration) ===
OK /private/tmp/courier-account-scope-falsify/control: 9 account-scoped, 10 not-account-scoped, 0 stale, 0 undeclared — 0 failure(s), 0 warning(s), so nothing was left unproven silently
EXIT=0

=== the copy, against the LIAR tree (the same one that went red above) ===
WARN account-scope.nothing-scoped: all 19 declared entry point(s) are accountScoped: false
    fix: check the routes that read a customer row and are declared `false`; a service that holds other people's data and says so nowhere is the D18 defect in a form a checker can now see

  not-account-scoped Courier.Workers.DeliverWebhookWorker  (lib/courier/workers/deliver_webhook_worker.ex:1)
  ... 19 rows, all printed not-account-scoped, the same listing §3.1 printed for
      this tree with nine FAIL findings above it

OK /private/tmp/courier-account-scope-falsify/tree: 0 account-scoped, 19 not-account-scoped, 0 stale, 0 undeclared — 0 failure(s), 1 warning(s); warnings do not move the exit code
EXIT=0
declaration-contradicts-code findings in that output: 0
contradiction-unreadable findings in that output:     0

=== the REAL checker on the same two trees, for the comparison ===
OK /private/tmp/courier-account-scope-falsify/control: 9 account-scoped, 10 not-account-scoped, 0 stale, 0 undeclared — 0 failure(s), 3 warning(s); warnings do not move the exit code
  control EXIT=0
FAIL /private/tmp/courier-account-scope-falsify/tree: 0 account-scoped, 19 not-account-scoped, 0 stale, 0 undeclared — 9 failure(s), 4 warning(s); warnings do not move the exit code
  liar EXIT=1
```

**The liar passes clean with the check gone. That is what makes §3.1 mean
something:** a checker that reports green because it cannot see the defect is worse
than no checker, and the only way to tell the two apart is to remove the check and
watch the red go away.

**And a result I did not expect, which is the sharpest thing in this report.** The
control run under the mutilated checker reports **0 warnings**, where the real
checker reports **3**. So `account-scope.contradiction-unreadable` is emitted *by
`_check_contradictions` itself* — the three warnings on courier's job rows are not
decoration printed alongside the check, they are the check declining to vouch for a
row it cannot read, and deleting the check deletes the decline with it. It is the
best evidence in this packet that those three warnings are worth their cost: a
checker with the honesty removed stops admitting what it does not know, in the same
commit, with no other signal.

---

## 4. TALLIES

Kept apart from the passes above, and every one of them re-derivable by the command
printed beside it. None of these numbers is copied out of §1 or §3.

### 4.1 Routes, counted by something that is not core's recogniser

```
$ cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01
$ grep -cE '^[[:space:]]+(get|post|put|patch|delete|head|options)[[:space:]]+"' \
    lib/courier_web/router.ex lib/courier_web/error_router.ex
lib/courier_web/router.ex:14
lib/courier_web/error_router.ex:2
```

14 + 2 = **16**, and it agrees with what `surface.minimum` declares and with the
`OK … 0 undeclared` line in §1. That agreement is the point: D18's `route_defs=0`
for a service the checker could not read was a *different dialect per framework*
producing a different answer, and here two unrelated readings — a shell grep and
core's `phoenix` recogniser — give the same 16 on the first adopter where they can
be compared at all.

### 4.2 Rows, by kind and by answer

```
$ cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01 && python3 - <<'EOF'
import re
text = open('account_scope.yml').read()
body = text.split('\nentryPoints:', 1)[1]
rows = re.findall(r'^  - id: (\S+)\n    kind: (\S+)\n(.*?)(?=^  - id: |\Z)', body, re.S | re.M)
print(f"rows total      {len(rows)}")
for kind in ('http', 'job', 'internal'):
    print(f"  kind: {kind:9} {sum(1 for r in rows if r[1] == kind)}")
print(f"accountScoped: true  {sum(1 for r in rows if 'accountScoped: true' in r[2])}")
print(f"accountScoped: false {sum(1 for r in rows if 'accountScoped: false' in r[2])}")
EOF
rows total      19
  kind: http    16
  kind: job     3
  kind: internal 0
accountScoped: true  9
accountScoped: false 10
```

`kind: internal` is **0** and that is a real answer rather than an omission: courier
has no function called only by its own code that a caller could arrive at, and the
schema says an entry point of that kind has to be declared *because* a service that
has one should have to say so. `courier` has none.

### 4.3 Reasons used, from a closed list of five

```
$ grep -E '^    reason: ' account_scope.yml | sort | uniq -c | sort -rn
   4     reason: system
   3     reason: unauthenticated-callback
   2     reason: public
   1     reason: none
```

**`platform-admin` is used by no row**, and that is worth saying rather than
leaving: courier exposes no operator surface. There is no admin route, no
impersonation, and no route reached only by the platform's own machinery — the one
candidate, the error ingest, belongs to the fleet's SDKs rather than to an operator,
and `system` is the accurate word for it. `identity`'s file records the same
absence of `platform-admin`, for the related reason that its subjects **are**
accounts, so no row of its 25 is scoped to an operator's own.

### 4.4 `via` symbols used

```
$ grep -E '^    accountFrom: ' account_scope.yml | sort | uniq -c
   9     accountFrom: { via: with_account, file: lib/courier/tenancy.ex, line: 129 }
```

**One symbol, nine times.** Every account-scoped entry point in courier resolves its
account through one function at one line, and the file says so nine times rather
than nine times saying whatever was nearest.

---

## 5. THE DECISION, and why

**The brief's decision, taken as written:** `via: with_account`, bare, with the
module-qualified name in a comment. §2.3 has the reason and the pattern that forces
it.

**A decision the brief did not have to make, which I made and am recording rather
than asking about: `surface.kind: both`, and three `kind: job` rows declared
`accountScoped: false, reason: system`.**

The alternative was `surface.kind: http` and the sixteen route rows with no job rows
at all. That is a declaration that says "this service has no non-request entry
points", and it is false: courier runs three Oban workers, and `kind: job` exists in
the schema precisely because "the entry points that are NOT requests and are exactly
the ones a route grep cannot see" is D18's second half. Declaring a service with a
queue as HTTP-only is the same defect as omitting the declaration, one layer in.

The rows are `false` because **they resolve no account**, and that is measured rather
than asserted: `with_account/3` has exactly one call site (§2.3) and it is the plug,
which is in the `:authenticated` pipeline, which no worker is in. A worker that
reached an account's rows with an identity on its path would need an `accountFrom`,
and none of these three has one to give.

**I declined the tempting wrong answer.** `DispatchWebhooksWorker` reads
`webhook_endpoints` by `event.account_id` (§6.2) — a protected table, one account's
rows — so a declaration of `accountScoped: true` with
`accountFrom: { via: with_account }` would have been *mechanically perfect and
completely false*, and nothing in the checker could have caught it, because
`account-scope.scoping-bypassed` is only decidable where the framework puts the
handler on the registration line and a Phoenix router does not. **A green run I
could only have got by writing a lie into the one field the checker cannot check is
the exact failure this packet exists to prevent.** The closed reason vocabulary has
no member for "reaches one account's rows, resolved from a row rather than from a
caller" — §7.2 is that gap, written up rather than worked around.

**The three warnings are left standing.** Deleting the three `kind: job` rows would
take the run to `0 failure(s), 0 warning(s)`, and that would be a better-looking
report describing a worse file. A warning that says "I could not check this row" is
the honest answer, and §3.2 measured that deleting the check deletes the warning too.

---

## 6. Findings about `courier`'s own code, surfaced by writing the declaration

Neither is fixed here and neither is in this packet's scope. Both are re-derivable
by the command printed.

### 6.1 Nothing in this repository enqueues the queue

```
$ cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01
$ grep -rn "Oban.insert" lib config priv test rel ops bin | wc -l
0
$ grep -rnE "Oban\.(insert|new)|Oban\.Job\{[^}]*worker|new\(Oban\.Job" lib config priv | wc -l
0
$ grep -rn "Courier.Workers" lib config priv | grep -v "^lib/courier/workers/"
lib/courier/events.ex:282:  records and the message `Courier.Workers.ProcessOutboxWorker` publishes are the
lib/courier/nats_publisher.ex:7:  `Courier.Workers.ProcessOutboxWorker`: it configures
lib/courier/deliver.ex:62:  `Courier.Workers.ProcessOutboxWorker`.
lib/courier/outbox_event.ex:13:  `Courier.Workers.ProcessOutboxWorker`, never here.
lib/courier_web/controllers/messages_controller.ex:22:  `Courier.Workers`: a 202 would answer before the suppression check ran, and a
priv/repo/migrations/20260930030240_create_outbox_events.exs:7:  `Courier.Workers.ProcessOutboxWorker`.
```

Every mention outside the workers' own files is **inside a comment** — all six lines
open with a backtick in a moduledoc or a migration comment. `Courier.Deliver`
`Repo.insert`s an `OutboxEvent` row (`lib/courier/deliver.ex:229`) and nothing
enqueues `ProcessOutboxWorker`, so the relay does not run and the outbox rows are
never published.

Writing `account_scope.yml` is what surfaced this: `kind: job` asks *who invokes
this*, and the answer is nobody. It is the same defect one layer out from
`Courier.Suppressions.ingest/1`, which `AGENTS.md` records as "written, tested,
documented as the HTTP surface's entry point — and nothing called it". **A job
consumer nobody enqueues is the same shape, and nothing in the current suite can see
it** because every test drives `perform/1` directly. This belongs to whichever packet
owns the relay, and it is not mine to fix here.

### 6.2 `DispatchWebhooksWorker` reads a protected table by `account_id` with no identity on its path

```
$ grep -n "WebhookEndpoints.enabled" lib/courier/workers/dispatch_webhooks_worker.ex
80:    WebhookEndpoints.enabled(event.account_id)
$ grep -n "def enabled" lib/courier/webhook_endpoints.ex
122:  def enabled(account_id) do
$ grep -n "protect_table('" priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs
111:    execute("select cafaye.protect_table('idempotency_keys', 'courier_app')")
121:    execute("select cafaye.protect_table('notification_preferences', 'courier_app')")
126:    execute("select cafaye.protect_table('webhook_endpoints', 'courier_app')")
```

`webhook_endpoints` is one of the three tables `FORCE ROW LEVEL SECURITY` protects,
and `enabled/1` filters it by `account_id` while the worker holds **no** database
identity — `with_account/3` has one call site (§2.3) and it is the plug. Under the
policy, an absent identity reads **zero rows**: not an error, nothing in the log,
exactly the shape `Courier.Tenancy`'s moduledoc describes for `GET /v1/webhook_endpoints`
before the plug existed. **So in a deployment whose application role is subject to
those policies, the webhook fan-out silently fans out to nothing.**

**And I am not claiming to know that this is broken in production, because I cannot
measure it from here and it is not this packet's question.** `courier`'s compose
file sets `DATABASE_URL: ecto://courier:…@postgres:5432/courier`, the policies are
written `TO courier_app`, and `REPORT-courier-row-level-security.md` §7 records that
the role courier's application connects as was deliberately not changed. Whether the
deployed role is subject to those policies, and therefore whether this is a live
zero-row bug or an inert one, needs a migrated Postgres and is somebody else's
packet. **What is not in doubt and is measurable from this tree is the asymmetry:
the HTTP surface has an identity and the queue does not.**

`DeliverWebhookWorker` reads `webhook_deliveries`, which has no `account_id` at all
— the protection migration names that as the reason it stays unprotected — so it is
not affected.

---

## 7. Findings about the contract, for `core`

### 7.1 The contradiction check cannot check a queue consumer, and it says so — which is the whole of its value

`contradiction/5` returns `row_gap="no registration on the declared surface matched
this row"` for any `false` row with no `Registered`, and a job has none by
construction: the six recognisers describe *request* registrations, and `kind: job`
is in the schema for the entry points they cannot see. So **every `false` job row in
every adopting service will produce this warning**, and it is correct to produce it.

What makes it worth reporting rather than muting is §3.2's measurement: the warning
is emitted *inside* `_check_contradictions`, so it is not an independent second
opinion that survives the check being weakened — it disappears with it. That is the
right coupling for a decline (a decline nobody asked for is not a decline), and it is
also why the warning cannot be treated as a cost the check pays: it is the check
saying what it does not know.

`courier` is the first adopter where `kind: job` and `kind: internal` have any rows
at all, so this is the first run that produces these three.

### 7.2 The reason vocabulary has no member for a worker that reaches one account's rows

`public`, `platform-admin`, `system`, `unauthenticated-callback`, `none`. The
sentence `system` covers is "reached only by this fleet's own machinery and carries
no caller identity", and `DispatchWebhooksWorker` satisfies both halves — and then
reads a protected table filtered by one account's id. `accountScoped` is a boolean
and the two answers are `true` (with an `accountFrom` that would have to name a
function the worker never calls) and `false` (with a reason that reads as "reaches
nothing").

`identity` hit the neighbouring version of this and recorded it in its own file:
twelve of its twenty-five `false` rows are "authenticated, and the subject is
derived from the caller's own credential", which the vocabulary also has no member
for, and it chose `none` as the member that does not over-claim. **The same choice
applies here and it is the same defect**, one entry point kind further out. This is
a finding for the vocabulary, not a gap courier worked around: `false` with a
comment naming the real answer is available to a reader and
`true`-with-a-fabricated-`via` is not available at all.

### 7.3 `via` cannot spell a qualified name, and courier's own answer is a qualified name

`SYMBOL_PATTERN` is `^[A-Za-z_][A-Za-z0-9_]*$`, so `cafaye.with_account/3` — the
answer the packet asked for, and the one `lib/courier/tenancy.ex` itself uses in prose
— is not writable. The reason for the pattern is stated in the schema and it is
sound ("matched on a word boundary, so `requireAccount` does not match
`requireAccountID`"), and the cost is that the field cannot say *which* function in
*which* module. Every other adopter's `via` has been unambiguous (`requireAccount`,
`tenantGuard`), so this is the first time the ambiguity has a cost. A `via` that
accepted `Module.function` and matched on the last segment would fix it; that is
`core`'s call and not a change I can make from this worktree.

### 7.4 Incidental: `core_version.py:34` raises a `SyntaxWarning` on import

Every run of the checker in this packet printed

```
/…/core_version.py:34: SyntaxWarning: "\^" is an invalid escape sequence. …
  Go   ^(\^|~|>=)?([0-9]+)\.([0-9]+)\.([0-9]+)$     constraintPattern
```

A regex literal in a plain Python string, not a raw one. **It appears whenever the
module is COMPILED rather than loaded from a `__pycache__`**, which is why it showed
up in §3.2's copied-harness run — that directory has no cached bytecode — and not in
the runs against core's own tree, which does. So it is invisible to exactly the
developer who has run this harness before. Cosmetic, but a check that prints a
warning about its own source is a warning a reader learns to scroll past.

---

## 8. What this packet did not do, and the tree

* **Did not edit `cafaye/core`.** The disabled checker was a copy in `/tmp`, and
  core's tree is clean.
* **Did not edit `tenancy.yml`.** The two files agree on `service: courier`, so
  `account-scope.service-disagrees` is silent, and nothing here changes which
  *statements* are scoped — that is `tenancy.yml`'s question and
  `harness/tenancy_check.py`'s.
* **Did not fix §6.1 or §6.2.** Both are other packets' and both need a decision
  this one should not take alone.
* **Did not add `account_scope.yml` to any gate.** `courier`'s `gate.yml` is
  untouched; whether `core`'s checker becomes a `bin/prime` step for a service that
  has adopted the declaration is a decision above this packet.
* **Did not push.** `worker/courier-account-scope-01` is local.

```
$ cd /Users/kaka/Code/any/moon/cafaye/wt-m39-courier-scope-01 && git status --short
(no output)
$ git diff --name-only master
REPORT-courier-account-scope-01.md
account_scope.yml
$ git diff --name-only master HEAD
REPORT-courier-account-scope-01.md
account_scope.yml
$ git log --format='%s' -2   # subjects, not hashes: an amend rewrites the hash,
                            # and a report quoting its own commit can never be current
courier-account-scope-01: the liar, the breaking, and two findings about courier
courier-account-scope-01: the declaration, 16 routes and 3 workers, zero undeclared
$ cd /Users/kaka/Code/any/moon/cafaye/core && git status --short
(no output)
```

Two commits, and the falsification is the second one so a partial result is still a
result. The falsification runs were mutations on `git archive` output under
`/tmp/courier-account-scope-falsify`; the intended change is `account_scope.yml`
plus this report, and the diff above is those two files and nothing else.
