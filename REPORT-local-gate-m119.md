# REPORT-local-gate-m119 — courier local gate evidence (verification-only)

- Worktree: `/Users/kaka/Code/any/wt/courier`
- Branch: `worker/m119-local-courier-gate` (manager-owned worktree branch; not merged, not pushed)
- Revision: `8064319` (full `80643192e8fc042ee6ced0f95d4ae44ed11a6cb7`), `master` at dispatch. Tree was clean before the run (`git status --short` empty); no product code touched.
- Date: 2026-10-08. Start 00:21:22Z, gate log mtime 00:21:40Z.

## Gate read before running

- `AGENTS.md`: tests-first house rules, `mix precommit` before commit, gate declared in `gate.yml`, CI gate is `bin/prime` (same command, not a variant), floor-raise rule on suite changes.
- `bin/prime` (4 steps, exact): `mix local.hex --force`, `mix deps.get`, `mix ecto.setup`, `mix test`.
- `gate.yml`: `command: [mise, run, prime]` resolving to `entrypoint: bin/prime` (`mise run prime` runs `./bin/prime`); `timeoutSeconds: 1800`; proof pattern `^Result: ([0-9]+) passed(?: \([^)]*\))?$` with `minimum: 1601`; `selfContained: false` (needs host postgres at localhost:5432 as postgres/postgres, pinned toolchain, one hex fetch on cold checkout).

## Command run (exactly once, no rerun)

```
timeout 1800 ./bin/prime
```

Run once in the background via nohup (bounded by `timeout 1800` as briefed), full log at `/tmp/gate-m119-courier-local.log` (181 lines), start stamp at `/tmp/gate-m119-courier-local.start`. No rerun, no patch, no second invocation.

- Elapsed: 18 s wall (epoch 1791418882 → 1791418900). Warm gate: deps unchanged, database already migrated.
- Exit: 0. Basis: log ends with the single ExUnit summary `Result: 1600 passed`; no failure block, no `N) test` failure markers, no raised errors, no second `Finished in` line. Honesty note: the launcher did not write a separate `.exit` file (my launcher construction omitted the `echo $?` capture the quarterly contract asks for); the 0 is inferred from the clean ExUnit summary line, which Mix only prints with exit 0. Nothing was rerun to re-derive it, per the exactly-once rule.

## Database and environment (untouched where it matters)

- Host postgres at `localhost:5432` was already accepting connections (`pg_isready` before the run). `bin/gate-db` was NOT run (nothing to start). No `site-launch-*` container was started, stopped, modified, or published to; `docker ps` showed the launch stack (`site-launch-postgres-1`, `site-launch-courier-1`, etc.) running before and was left alone. No install/launch/publish/deploy command run.
- `mix ecto.setup` outcome from the log: `The database for Courier.OwnerRepo has already been created`, `Migrations already up` (0 applied), seeds ran. Nothing created, dropped, or re-migrated by this run. (`mix test` alias would additionally `ecto.create --quiet` / `ecto.migrate --quiet` as owner; both were no-ops.)
- Hex/deps: `mix local.hex --force` installed archive hex-2.5.1 into the mise toolchain dir (outside the repo); `mix deps.get` resolved in 0.265 s, all 47 packages `Unchanged`; `mix.lock` untouched (no diff after the run).
- No other courier gate overlapped this run (single invocation; no other `mix test`/`bin/prime` on the host for this repo during the window).

## Test counts, skips, failures

- `Result: 1600 passed` — one summary line, exact shape `Result: 1600 passed` (no `(…)` breakdown).
- Failures: 0 (no failure summary, no failing-test markers in the log).
- Skipped/excluded: 0 — plain `mix test` with no filter flags; log contains no `skipped`/`excluded` summary.
- Suite time: `Finished in 8.6 seconds (4.2s async, 4.3s sync)`, seed 721939, max_cases 16.
- The `[error]`/`[warning]` lines in the log are expected test log noise (refusal-path, provider-failure, and redaction-boundary tests asserting on logged output), not failures.

## Non-fatal warnings observed (not failures; `mix test` is not warnings-as-errors — that is `mix precommit`)

- `test/courier/consumers_test.exs:297,359` — unused variable `event` (x2).
- Unused module attribute `@release_env` (chart/config test area).
- A conditional-expression warning (truncated log line; see `/tmp/gate-m119-courier-local.log:125`).

## Finding: measured count is one below the declared floor

- `gate.yml` proof `minimum: 1601`; this run measured `1600 passed` with 0 failures.
- Consequence: the suite itself is green (exit 0), but core's `gate-check` proof against `gate.yml` would report the count below the floor. This is the stale-floor drift class `AGENTS.md`/`gate.yml` document (a decrease-detector cannot see its own staleness; cf. the `4eb7585` catch-up precedent recorded in `gate.yml`). HEAD `8064319` merges `worker/courier-w105-tenantscope`, the likely source of the -1 delta.
- Not reconciled here: verification-only packet — no code change, no floor edit, no rerun. The floor re-measure belongs to the code owner with a fresh-DB run.

## Commit

This file only (`REPORT-local-gate-m119.md`). Not pushed (manager merges/pushes).

## Evidence

- Full gate log: `/tmp/gate-m119-courier-local.log` (181 lines; `Result: 1600 passed` at line 181).
- Start stamp: `/tmp/gate-m119-courier-local.start` (epoch 1791418882, 2026-10-08T00:21:22Z).
- No credentials or secret-bearing output are included above or in the committed report; the gate log contains only request ids, error atoms, and refusal reasons.
