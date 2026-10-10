# REPORT-tga2-tenancy-close.md — courier's tenancy declaration, closed

Packet TG-A2: `tenancy-check .` at zero failures for courier.

## What was measured at dispatch

```
$ bash /Users/kaka/Code/any/moon/cafaye/core/harness/bin/tenancy-check .
FAIL tenancy.scope-lost                          x 5
FAIL tenancy.denial-missing                      x 3
WARN tenancy.enumeration-partial                 x 1
WARN tenancy.rls-unreadable                      x 1
WARN tenancy.scope-key-unused                    x 1
FAIL ...: 8 failure(s), 3 warning(s)
```

## What was done

Ten commits' worth of drift in one declaration file. `417d14a` repointed 27
stale lines; these eight moved after it, and **none of them moved because a
boundary moved** — two packets reflowed the files around them:

* `d05ad55` (w3p1, the Cloudflare Email adapter) reflowed
  `lib/courier/webhook_endpoints.ex`'s signatures, shifting four
  `enforced.line` values.
* `c012e12` / `17ab319` (the email-change notices) shifted the three arms in
  `test/courier/notification_preferences_test.exs`.

### The eight repointed lines

| entry point | was | now | what the old line actually was |
| --- | --- | --- | --- |
| `webhook-endpoints-get` | 95 | **99** | the docstring's closing `"""` |
| `webhook-endpoints-list` | 110 | **114** | a docstring |
| `webhook-endpoints-enabled` | 124 | **128** | a docstring |
| `webhook-endpoints-page` | 156 | **160** | `with {:ok, limit} <- validate_limit(limit),` |
| `idempotency-keys-fetch` | 151 | **164** | the `@doc """` above `fetch/3` |
| notif-prefs-list other-account | 225 | **233** | the blank line closing `update/3`'s describe |
| notif-prefs-list own-account | 47 | **55** | the body of the `stored/3` helper |
| notif-prefs-update other-account | 246 | **254** | the `update(@other_account, …)` call itself |

Each new line is the one line in the function that carries the account. Two of
the old lines were wrong rather than merely stale, and both are named in the
declaration's own comments so the next reader does not repeat them:

* **`webhook-endpoints-page` at 156 was the `validate_limit/1` line.** A cursor
  check is not a tenancy check, and the declaration said it was one. The
  predicate is at 160.
* **notif-prefs-update other-account at 246 was the refused write's own return
  value.** The comment above it promised a read of the victim's row and the line
  did not carry one — which is exactly the unpaired denial
  `tenancy.denial-unpaired` exists to catch, arriving by a different road. The
  read-back is at 254.

### One mechanism corrected, which the checker was green on

`webhook-deliveries-dispatch` declared `mechanism: query-filter` at
`lib/courier/workers/dispatch_webhooks_worker.ex:128`, which is
`Tenancy.with_account(Repo, event.account_id, fn -> … end)`. That line carries
the key, so `check_enforcement` passed, and the vocabulary was wrong: a
`query-filter` is a predicate on a statement, and this opens the transaction
that puts the account on the connection as
`set_config('cafaye.account_id', …, is_local := true)`. Changed to
`middleware`, which is the schema's own fourth description ("the point where the
request's account is resolved onto the context every later read reads from")
rather than its first. The predicate this fan-out really runs is one line below
and is already its own entry point (`webhook-endpoints-enabled`), so naming it
twice would have been the double description. **The four mechanisms are treated
identically by the checker — this is a reader-accuracy fix, not a gate.**

## What is verified, with the real commands

```
$ bash /Users/kaka/Code/any/moon/cafaye/core/harness/bin/tenancy-check .
OK /Users/kaka/Code/any/moon/wt/courier-tga2: 0 failure(s), 3 warning(s) — warnings do not move the exit code
$ echo $?
0
```

Every file the declaration names, run as `mix test` on courier's own gate
postgres (`COURIER_TEST_PG_PORT=5432`, container `courier-gate-pg`):

```
$ COURIER_TEST_PG_PORT=5432 mise exec -- mix test \
    test/courier/notification_preferences_test.exs \
    test/courier/webhook_endpoints_test.exs \
    test/courier/idempotency_test.exs \
    test/courier/workers/dispatch_webhooks_worker_test.exs \
    test/courier_web/controllers/webhook_endpoints_controller_test.exs \
    test/courier_web/controllers/notification_preferences_controller_test.exs \
    test/courier_web/controllers/messages_controller_test.exs \
    test/courier/workers/dispatch_webhooks_worker_identity_test.exs
Result: 253 passed
```

And every file under the two directories the declaration touches:

```
$ COURIER_TEST_PG_PORT=5432 mise exec -- mix test test/courier/workers/ test/courier_web/
Result: 541 passed
```

Each of the 25 arms was also read back off disk by line, so the claim "the
declared line carries the token" is a statement about text that was printed, not
about a checker that said so.

## The finding that is courier's and not the declaration's

**The `notification_preferences` boundary is held in two places and the
declaration used to leave a reader to work out which was which.**
`REPORT-courier-app-role.md` §2 already says the 404 is gone and that
`tenancy.yml` "still names `expects: not_found`" — and then stops, because
reconciling a published document needs a manager decision. This packet does not
make that decision either; it records the split precisely enough that the next
one can.

`addressable/2` compares the acting account against the stored row's
`account_id`. `test/courier/notification_preferences_test.exs` sets its
`@moduletag account:` identity to the **owner**, so `owner/1` is permitted and
the comparison runs, and `{:error, :not_found}` comes back. As `courier_app` —
the role the suite connects as since the app-role packet — a policy subject's
read returns nothing, so the comparison **never runs**, and the answer is
200-with-defaults.

So the two halves are two different tests, and both already exist:

| half | where |
| --- | --- |
| the Elixir comparison | `notification_preferences_test.exs:233`, `:254` — run as the owner |
| the database policy | `notification_preferences_controller_test.exs:135` — a real request, another real credential, 200-with-defaults byte-identical to a user nobody has written for (`:190`); `:205` for the write, 404 with the victim's row read back (`:233`) |

The declaration keeps the owner-identity arms on the library file, because those
are the lines carrying this language's spelling of nothing and the schema asks an
absent arm for one, and it names the controller lines in the comment rather than
in an arm — because **200-with-defaults is not a spelling of nothing**, and
forcing a token onto it would be the faking rule wearing a disguise.

## A gap in core's format, for TG-B1

`negative.cases[].expects` for an `absent` arm is specified as "this language's
spelling of nothing: `nil`, `None`, `NotFound`, `ErrNotFound`, `not_found`, or
the empty list". Courier's cross-tenant read is now answered with
**200-with-defaults, deliberately indistinguishable from a user who does not
exist** — which is the *stricter* form of nonexistence and leaks strictly less
than the 404 it replaced. There is no token for it, and a service that returns
"the same thing as for a nonexistent thing" cannot say so in the one field whose
job is to say what the denial arm asserts.

The checker's `ABSENCE_TOKENS` and the schema's field description both encode
the same assumption: **that a denied read comes back as an empty result.** That
is true of a `Repo.all` returning `[]`, and it is not true of a read whose answer
is "here are the defaults" — where the leak-free answer and the
nothing-to-see answer are the same bytes. This is the same shape as D41 and D47
in `DECISIONS.md`: a format that cannot express a true answer is the defect, not
the service that cannot declare it. **No workaround was attempted here.**

## Deliberately not done

* **`openapi.yaml`'s 404 for `GET /v1/notification_preferences/{user_id}` is
  still declared and is still wrong.** It predates this packet, it is a published
  contract rather than a declaration, and `openapi_document_test.exs` holds the
  document to the router in both directions — so editing it is a contract change
  and not a stale-line fix. Reported, not reconciled.
* **No source file was changed.** Tenancy.yml is a comment-carrying declaration
  and nothing else; `git diff 3cb7184 --stat` is one file.
* **No test was added, weakened or re-pointed.** Every arm already pointed at a
  line that exists and passes; the two that pointed at lines carrying nothing
  now point at lines that do.
* **The three warnings were left as warnings.** `enumeration-partial`,
  `rls-unreadable` and `scope-key-unused` are the honest "this scanner reads SQL
  and courier is Ecto, and this scanner reads DDL and courier's DDL is inside a
  `select cafaye.protect_table(…)` string" ones. Making any of them go away would
  have meant either writing a second, SQL copy of the queries that would then
  drift from the Ecto ones, or declaring `rls.databaseEnforced: true` against
  policies a scanner that cannot follow `protect_table/2` would report absent.
  Both would have been a declaration describing a boundary nobody looked at.
* **`core/harness/tenancy_check.py`, `core/schemas/*.json` and
  `core/harness/tenancy_findings.json` were not touched.** Nothing found in this
  packet needed them changed — the checker was right about all eleven failures.
