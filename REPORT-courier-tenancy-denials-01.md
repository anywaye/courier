# REPORT — courier: the 27 tenancy-check failures

Branch `courier-tenancy-denials-01` off `master` @ `99796e9`. Packet
`moon/prompts/m41-courier-tenancy-denials-01.md`.

## What this is

`tenancy.yml` declared 27 arms whose `negative.line` (and, for three entry
points, `enforced.line`) pointed at lines that do not carry the assertion the
declaration says they do. Every one was a **stale line number, not a missing
test**: the assertions exist, on other lines, and each was read and confirmed
before the declaration was repointed at it. No test was written, no arm was
deleted, no `expects` token was changed, and `gate.yml`'s floor is unmoved.

## The count, because it is the most informative output of this task

**24 repointed, 0 written.** All 24 `tenancy.denial-missing` findings were case
**(a)**: the assertion already exists in the named file, on a line that
genuinely carries it. Not one of the 24 needed a new test, and not one was
repointed at the nearest line — every repointed line was read and its
assertion confirmed to be the arm's own (the table below is the map, each row
verified against the file, not against the ticket).

**3 `tenancy.scope-lost` repointed**, all "the scoping moved, the declaration
did not", each to the line that carries the tenancy key:

| entry point | was | now | because |
| --- | --- | --- | --- |
| `notification-preferences-list` | `notification_preferences.ex:150` | **`:152`** | `:150` is a comment; `defp addressable(account_id, user_id)` is at 152 |
| `notification-preferences-update` | `notification_preferences.ex:150` | **`:152`** | same line, same root cause, one fix — both entry points share the `addressable/2` enforcement |
| `webhook-deliveries-dispatch` | `dispatch_webhooks_worker.ex:80` | **`:128`** | `:80` is a comment mid-moduledoc; the scoping is the `Tenancy.with_account(Repo, event.account_id, …)` wrapper at 128 |

### The 24, arm by arm

| entry point | arm | expects | was | now | the assertion now pointed at |
| --- | --- | --- | --- | --- | --- |
| webhook-endpoints-get | no-identity | `halted` | 101 | **106** | `assert conn.halted` — inside the loop over all six actions |
| webhook-endpoints-get | other-account | `nil` | 176 | **188** | `WebhookEndpoints.get(endpoint.id, @other_account_id) == nil` |
| webhook-endpoints-get | own-account | `id` | 168 | **180** | `WebhookEndpoints.get(endpoint.id, @account_id).id == endpoint.id` |
| webhook-endpoints-list | no-identity | `halted` | 101 | **106** | same loop |
| webhook-endpoints-list | other-account | `[]` | 211 | **229** | `WebhookEndpoints.list(@other_account_id) == []` |
| webhook-endpoints-list | own-account | `id` | 204 | **222** | `Enum.map(found, & &1.id) == [mine.id, theirs.id]` |
| webhook-endpoints-enabled | no-identity | `halted` | 101 | **106** | same loop |
| webhook-endpoints-enabled | other-account | `[]` | 254 | **272** | `WebhookEndpoints.enabled(@other_account_id) == []` |
| webhook-endpoints-enabled | own-account | `id` | 241 | **259** | `found.id == enabled.id` |
| webhook-endpoints-page | no-identity | `halted` | 101 | **106** | same loop |
| webhook-endpoints-page | other-account | `[]` | 250 | **256** | `%{"data" => []} = json_response(conn, 200)` |
| webhook-endpoints-page | own-account | `id` | 241 | **247** | `%{"data" => [%{"id" => id}]} = json_response(conn, 200)` |
| idempotency-keys-fetch | no-identity | `unauthorized` | 111 | **116** | `envelope["code"] == "unauthorized"` |
| idempotency-keys-fetch | other-account | `nil` | 110 | **133** | the `== nil` closing the `as_account(@other_account, …)` call |
| idempotency-keys-fetch | own-account | `id` | 95 | **104** | `found.id == claim.id` |
| notification-preferences-list | no-identity | `halted` | 94 | **99** | `assert conn.halted` — inside the loop over both verbs |
| notification-preferences-list | other-account | `not_found` | 221 | **225** | `NotificationPreferences.list(@other_account, @one) == {:error, :not_found}` |
| notification-preferences-list | own-account | `email_enabled` | 43 | **47** | `Enum.all?(preferences, &(&1.email_enabled and &1.push_enabled))` |
| notification-preferences-update | no-identity | `halted` | 94 | **99** | same loop |
| notification-preferences-update | other-account | `push_enabled` | 242 | **246** | `found.push_enabled == true` — the victim's row read back as its owner |
| notification-preferences-update | own-account | `email_enabled` | 177 | **198** | `%{"email_enabled" => false}` — the **owner's** own row, read back as the owner |
| webhook-deliveries-dispatch | no-identity | `count` | 123 | **128** | `Repo.aggregate(WebhookDelivery, :count) == 0` |
| webhook-deliveries-dispatch | other-account | `count` | 78 | **83** | `Repo.aggregate(WebhookDelivery, :count) == 0` |
| webhook-deliveries-dispatch | own-account | `count` | 58 | **63** | `Repo.aggregate(WebhookDelivery, :count) == 2` |

Two of these deserved the care the brief asked for, and got it:

- **`idempotency-keys-fetch` / other-account → 133.** The comment above the
  call (lines 120–130) is why the test is worth anything: run as the file's own
  account, the RLS `select` policy hides the row by itself and the assertion
  passes for free. The repointed line is the `== nil` that closes the
  `as_account(@other_account, …)` call — the only identity under which the
  assertion can fail for the reason it claims.
- **`notification-preferences-update` / own-account → 198, not 195.** Line 195
  asserts on `other` (the other account's answer) — the wrong identity for an
  own-account arm, and the faking rule wearing a disguise. Line 198 reads the
  owner's own row back as the owner, which is what the arm means.

## The `rls` block: enforced, and the declaration says so now

**Verdict: the database half is real.** Five tables are row-level-security
FORCED, by `cafaye.protect_table/2` calls — `idempotency_keys`,
`notification_preferences`, `webhook_endpoints` in
`20261003090000_protect_account_scoped_tables.exs:111,121,126` and
`notification_events`, `notifications` in
`20261006120000_create_notifications.exs:237,238`. kit's substrate
(`templates/database/tenancy/substrate.sql:861,897-900`) writes
`alter table … force row level security` and four policies per table —
`_cafaye_select`, `_cafaye_insert`, `_cafaye_update`, `_cafaye_delete` — each
qualified on `cafaye.current_account_id()`. The suite connects as `courier_app`,
a policy subject rather than a superuser, so the policies are enforced against
the role courier actually runs as.

**What the declaration says, and why it does not say that:** `databaseEnforced:
false` stays, with an empty `tables` list. Not because the database does nothing
— because this checker's DDL scanner cannot parse an `.exs` migration, so it
cannot see the `protect_table/2` calls, and the `tenancy.rls-unreadable` warning
names exactly those two files. Declaring `true` in the shape the schema requires
was measured (by the packet author, and the check logic re-read for this report)
to produce `tenancy.rls-policy-absent`: the scanner finds no relation in sources
it cannot read, and a hand-written `.sql` copy of the DDL fails too, because the
policies are created by a function call the scanner cannot follow. A declaration
pointing at a file that does not exist in this repository is the same defect
this file exists to prevent.

So the comment now carries the truth the format cannot express: **the database
enforces on five tables; the declaration says what this checker can prove, not
what the database does.** The stale sub-claims in the same block were fixed on
their own merits: there are **thirteen** migrations, not ten, and the old claim
that "none mentions `row level security`, `create policy`…" was literally true
and misleading in intent — the DDL is inside a `select cafaye.protect_table(…)`
string, so a text scan for the DDL's own words finds nothing while the database
is forced.

## The checker, after

```
$ ../core/harness/bin/tenancy-check . ; echo $?
WARN tenancy.enumeration-partial: this checker reads SQL statements and account-key predicates, and it could not classify 48 account-scoped site(s): idempotency-keys-fetch at lib/courier/idempotency.ex:151 (the scanner could not read this line as a select); lib/courier/idempotency.ex:147 at no statement within 4 lines; lib/courier/idempotency.ex:151 at no statement within 4 lines; lib/courier/idempotency.ex:222 at no statement within 4 lines; lib/courier/idempotency.ex:224 at no statement within 4 lines; lib/courier/idempotency.ex:85 at no statement within 4 lines; lib/courier/notification_preferences.ex:111 at no statement within 4 lines; lib/courier/notification_preferences.ex:112 at no statement within 4 lines; lib/courier/notification_preferences.ex:115 at no statement within 4 lines; lib/courier/notification_preferences.ex:117 at no statement within 4 lines; lib/courier/notification_preferences.ex:152 at no statement within 4 lines; lib/courier/notification_preferences.ex:155 at no statement within 4 lines; lib/courier/notification_preferences.ex:167 at no statement within 4 lines; lib/courier/notification_preferences.ex:179 at no statement within 4 lines; lib/courier/notification_preferences.ex:180 at no statement within 4 lines; lib/courier/notification_preferences.ex:327 at no statement within 4 lines; lib/courier/notification_preferences.ex:334 at no statement within 4 lines; lib/courier/notification_preferences.ex:392 at no statement within 4 lines; lib/courier/notification_preferences.ex:394 at no statement within 4 lines; lib/courier/notification_preferences.ex:80 at no statement within 4 lines; lib/courier/notification_preferences.ex:81 at no statement within 4 lines; lib/courier/notification_preferences.ex:85 at no statement within 4 lines; lib/courier/webhook_endpoints.ex:101 at no statement within 4 lines; lib/courier/webhook_endpoints.ex:108 at no statement within 4 lines; lib/courier/webhook_endpoints.ex:110 at no statement within 4 lines; lib/cour... (line truncated to 2000 chars)
    fix: read the named files by hand and confirm each one is declared; the checker's scanner reads SQL and account-key predicates only
WARN tenancy.rls-unreadable: the declared row-level-security sources hold 2 file(s) this checker does not parse: priv/repo/migrations/20261003090000_protect_account_scoped_tables.exs:13 (a file this checker does not parse, carrying row-level-security DDL); priv/repo/migrations/20261006120000_create_notifications.exs:230 (a file this checker does not parse, carrying row-level-security DDL). The database half of this declaration is NOT proven closed, and this is a warning rather than a failure because no stdlib text scanner can settle a migration written as a Ruby or a Python string — read the named files and confirm each policy and force bit is declared
    fix: read the named files and confirm each policy and force bit are declared; a Rails service's migrations are .rb files, and being named here is the difference between 'I cannot see this' and a confident zero
WARN tenancy.scope-key-unused: no account-scoped statement this scanner can read carries 'account_id'. That is not proof the service has no scoping — it is usually a key spelled differently from the column it is really scoping by, and on a service written in a language this scanner cannot classify it is what an honest 'I cannot see this' looks like
    fix: check scope.key against the column or parameter this service really scopes by; a key nothing matches is either spelled differently or lives in a language this scanner cannot classify

OK /Users/kaka/Code/any/moon/cafaye/courier: 0 failure(s), 3 warning(s) — warnings do not move the exit code
0
```

**`denial-missing` at zero, `scope-lost` at zero, all three warnings still
printed.** The warning set is compositionally unchanged: the same 48
unclassifiable sites (only the declared-line annotations moved, 150→152 and
80→128, with the repoints), the same two unparseable `.exs` files named, the
same `scope-key-unused` — which is the correct answer for an Elixir service and
was left alone, as were the other two. No warning disappeared; nothing was
weakened to silence one.

## The gate

```
$ mise run prime ; echo $?
...
Finished in 4.9 seconds (2.4s async, 2.5s sync)

Result: 1409 passed
0
```

**1409 passed, floor unmoved at `minimum: 1409`.** Zero tests were added, so
the floor did not move — and the gate was green on the first try, which is the
expected outcome of a repoint-only change.

## What was not done, and why

- **No test was written.** Every assertion the 24 arms declare already exists;
  writing one would have been a test that proves nothing the suite does not
  already prove.
- **No arm was deleted and no `expects` token changed.** The schema requires
  three arms per entry point, and the tokens were all correct — only the lines
  were stale.
- **`scope.key` was not renamed** to something the scanner happens to match.
  `account_id` is the column; the scanner reads SQL and an Ecto query is none of
  those. `tenancy.scope-key-unused` is the honest answer and stays.
- **`databaseEnforced` was not flipped to `true`.** It cannot pass today, and
  the reason is written into the block rather than left for a reader to
  rediscover.
- **`tenancy_check.py` and `core/` untouched**, as instructed.
