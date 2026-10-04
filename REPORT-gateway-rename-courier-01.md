# REPORT — gateway-rename-courier-01

`courier`, branch `worker/gateway-rename-courier`, base `cd00ed3`. Two commits,
five lines, no test added, deleted, or skipped. The packet is done; the
sweep behind it was wrong by two, and that is the part worth reading.

## What the defect was

The service that was named `guard` is named `gateway`. In `courier` the word
`guard` is overwhelmingly a *different* word — the `Courier.Webhooks.UrlGuard`
SSRF tripwire, and Elixir's own pattern guards — so a blind sweep breaks a
real module and produces sentences that are wrong. The packet's job was four
comment lines that name the service, and nothing else.

## What I changed

**Commit `360d2c3` — the packet's four edits, exactly as the handoff wrote them out.**

```
lib/courier/principal/introspection/document.ex            49, 185
test/courier/principal/introspection/document_test.exs     89, 233
```

All four are the MD7 dual-claim reasoning (`scopes` and `scope` are both
read, because the fleet has not agreed on one). `identity`'s copy of these
sentences was renamed in `worker/gateway-rename-identity`.

One of them is load-bearing beyond tidiness. `document_test.exs:233`
**quotes** identity's own document:

> the value is a string and not an array because "gateway's verifier refuses
> a non-string claim"

`identity`'s `openapi/v1.yaml:3325` reads, verbatim: *rather than an array
because gateway's verifier refuses a non-string claim*. After identity's
rename that quotation was **stale** — a comment misquoting the contract it
explains. I assert the match by unwrapping the `# ` prefix and comparing the
phrase, and I checked the check bites: the pre-rename phrase does not match.
(My first attempt at that check reported `NO MATCH` twice for the wrong
reason — `grep -F` cannot span courier's line-wrapped comment, and `tr -d
'\n'` then glued "refuses a" to "non-string". The edit was fine both times;
the check was wrong, which is the failure mode this fleet warns about.)

Also worth knowing: `document.ex` was already half-migrated. Line 187 of the
same function already read "a token **the gateway** will not parse at all",
eight lines from the sentence that named it the other way.

**Commit `59d9558` — `AGENTS.md:1009`, which the handoff did not find.**

## The handoff was wrong by two, and how

`gateway-rename-consumers-01` reported "four of ~193 occurrences name the
service". Re-run over the whole tree, `guard` is on **166 lines in 45
files** (193 counted occurrences, not lines — the two numbers are
consistent), and **six** lines name the service:

| line | names the service | action |
| --- | --- | --- |
| `document.ex:49` | yes | renamed — `360d2c3` |
| `document.ex:185` | yes | renamed — `360d2c3` |
| `document_test.exs:89` | yes | renamed — `360d2c3` |
| `document_test.exs:233` | yes | renamed — `360d2c3` |
| **`AGENTS.md:1009`** | **yes** | **renamed — `59d9558`** |
| `priv/repo/substrate.sql:71` | yes | **left to kit** — see below |

The handoff scoped courier from `lib/` and `test/`. That misses `AGENTS.md`
and `priv/`, and in a repository that argues its decisions at length in
`AGENTS.md`, those are not the quiet places. **`AGENTS.md:1009` is the
sentence that restates the moduledoc the packet edited** — left alone, the
repo would hold two names for one verifier eight lines from itself, and the
packet's own success criterion would be false while it stood. That criterion
is why I fixed it: this is the criterion being met, not scope being widened.
It matters more than a comment usually does, because `AGENTS.md` is the file
the next worker reads before anything else.

`priv/repo/substrate.sql:71` says *"guard verifies JWKS bearer JWTs"* and
names the service too. **Left alone deliberately.** It is byte-identical to
`kit/templates/database/tenancy/substrate.sql:71` at the same line number,
its own header reads "kit template", and `bin/dev` merges kit over this file
on every sync. kit's own packet has already done it — `worker/gateway-rename-kit`
(`67051e4`) renames that exact line upstream, with
`templates/database/contract.json` and `DECISIONS.md`. Editing courier's copy
would diverge from the template it is generated from and be clobbered by the
next `bin/dev`. It arrives on its own.

## Full classification of all 166 lines

Buckets are disjoint and sum to the total — I checked, because my first
attempt at this classification left 29 of 167 lines unaccounted for, and a
classification with a remainder is not a classification.

| bucket | lines | what it is |
| --- | --- | --- |
| historical records | 40 | `REPORT-*`, `CHANGELOG.md`, `HANDOFF-*` — records of past dispatches |
| the `UrlGuard` SSRF tripwire | 44 | the real module, its 9-line test, `config/test.exs:84`, `ci.yml`'s SSRF step |
| Elixir the language sense, and non-service "guard"s | 81 | pattern guards in `case`/`fn`, `guarded/2` in `CourierWeb.Plugs.Idempotency`, the `config_env()` guard in `config/runtime.exs`, "operations the router guards" in the openapi tests, the `git diff --exit-code` lockfile guard in ci.yml, Phoenix's own "reserved for guards" at `AGENTS.md:1337` |
| the service | 1 | `priv/repo/substrate.sql:71`, kit's, already fixed upstream |

`git grep -cE 'guard'` in the two files the handoff named returns **zero**.
There is no identifier anywhere in the tree named `guard`; every remaining
hit is prose, and the only code-shaped ones are `UrlGuard.validate/2` calls.

## Measurements

Before and after, same command both times, nothing else changed between them:

```
before  ./bin/prime  exit 0   Result: 1317 passed          (floor 1308)
after   ./bin/prime  exit 0   Result: 1317 passed          (floor 1308)
after   mix precommit exit 0   Result: 1317 passed
final   ./bin/prime  exit 0   Result: 1317 passed          (floor 1308)
        bin/assert-suite on the final log, exit 0: 1317 passed (floor 1308)
        git diff --exit-code -- mix.lock, exit 0: lockfile unmoved
        summary lines naming skipped/excluded/invalid: 0
```

1317 before and 1317 after. **No test was added, deleted, or skipped, so no
floor in `.github/workflows/ci.yml` or `gate.yml` moves — both stay at 1308.**
The measured 1317 rather than the floor is the point of the measurement: both
floors are decrease detectors, so a rename that had quietly deleted a test
would still have gone green.

## One number that came back wrong first

My first baseline came back **`1316/1317 passed`**, failing
`CourierWeb.Plugs.IdempotencyTest` with a PostgreSQL **deadlock (40P01)**
naming two backend PIDs.

Cause: **another session ran `bin/prime` in this same worktree at the same
time.** Two ExUnit runs inserting `idempotency_keys` into one `courier_test`
database deadlock each other. Re-run with nothing else running: 1317 passed,
zero exclusions, twice more since. Recorded because the number that first
arrived was not the number that is true, and a reader given only the green
one would not know a concurrent run exists in this worktree. **Anyone
running courier's suite here should check for a second `bin/prime` first.**

## What I did not do

- **Did not touch the SSRF tripwire** — `url_guard.ex`, `url_guard_test.exs`,
  `AGENTS.md:72`/`:172`, `config/test.exs:84`, `webhook_endpoints.ex:232`.
  Renaming any of them breaks a module name.
- **Did not touch `priv/repo/substrate.sql:71`.** kit owns it and has shipped
  the fix upstream.
- **Did not move any floor.** Adding or deleting a test would require it;
  renaming a comment does not.
- **Did not re-wrap `AGENTS.md:1009`** at 82 columns. Its paragraph
  neighbours already run 80 and 81, and the file has 448 lines over 79 —
  re-wrapping would be a reformat of nothing in a rename packet.

## What I would do next

Hand `priv/repo/substrate.sql:71` to whoever merges
`worker/gateway-rename-kit` — nothing to do, but it is the one line that
will still read `guard` in courier until a `bin/dev` kit sync, and the merge
note should say so rather than let a reviewer find it. Then, for the rest of
the fleet's `gateway` rename: **scope every sweep by content over the whole
tree, not by `lib/` and `test/`.** This packet cost two extra lines because
the sweep that handed it off looked in the two directories where code lives
and not in the two where this repository argues. `AGENTS.md`, `priv/`,
`CHANGELOG.md` and `docs/` are where a rename hides.