# HANDOFF — gateway-rename-consumers-01, for `courier`

**Status: nothing changed in this repository.** The sweep is scoped down to four
lines in two files and is written out below in full, so the successor's first
move is four substitutions and one gate run.

## The trap, measured

`courier` has ~193 occurrences of the word `guard` in 47 files and **four** of
them name the service. The rest are the SSRF tripwire: `lib/courier/webhooks/url_guard.ex`
is a real module, `test/courier/webhooks/url_guard_test.exs` is its test,
`AGENTS.md:72` calls it "the SSRF guard: resolve, check, return target",
`AGENTS.md:172` lists the test file, and `config/test.exs:84` is "The SSRF
guard's resolver in test". Renaming any of those would break a module name and
produce a sentence that is wrong.

## The four edits

All four are the same two sentences, in a source file and its test:

**`lib/courier/principal/introspection/document.ex`**

- line 49: `` `scopes`, guard's verifier reads `scope`, and identity emits **both, byte for ``
  → `gateway's verifier`
- line 185: `` # sides can read: guard's verifier does `raw.split(/\\s+/)` and refuses a ``
  → `gateway's verifier`

**`test/courier/principal/introspection/document_test.exs`**

- line 89: `` # conventions require `scopes` and guard's verifier reads `scope`. So the ``
  → `gateway's verifier`
- line 233: `` # the value is a string and not an array because "guard's verifier refuses a ``
  → `gateway's verifier`

These are the same MD7 dual-claim reasoning that `identity` carries in
`internal/apikeys/claims.go`, and identity's copy of these sentences was renamed
in `worker/gateway-rename-identity`. Renaming courier's keeps the two services
describing the same contract in the same words.

## Explicitly tripwire, leave alone

`lib/courier/webhook_endpoint.ex:64,65,131` — "the context runs the guard
before this is ever called", "fails the guard", "guard's question". That is the
`url_guard` SSRF check. `lib/courier/webhook_endpoints.ex:232` — "Re-runs the
URL guard". `config/test.exs:84`, `AGENTS.md:72,172`. `REPORT-*.md`,
`CHANGELOG.md` and `HANDOFF-*.md` are records of past dispatches; leave them.

## Why this packet did not do it

Not scope — four lines. **No baseline.** Establishing one means `mix deps.get`
and a first `mix compile` in a fresh worktree, which did not fit in the packet's
clock, and the standing contract is that a rename must be shown not to move a
test count. An unverified four-line commit is worth less than a handoff that
names all four lines.

## First move

```sh
git worktree add -b worker/gateway-rename-courier ../wt-m39-courier-gateway-rename master
cd ../wt-m39-courier-gateway-rename
mix deps.get
mix test                                   # baseline: note the count and the exclusion count
# apply the four edits above
mix test                                   # same count
```

`courier` is Elixir, not Go — the packet brief says "identity and courier are
Go" and that is wrong. `mix.exs` is its manifest and ExUnit prints its own
`N tests, M exclusions`, so unlike identity's Go suite there **is** a countable
floor: read it off the run and hold it. courier's own `bin/assert-suite` takes an
expected count as an argument (parlor uses the same shape), so check whether
`bin/prime` or ci.yml passes one and update it if the sweep is ever more than a
comment.