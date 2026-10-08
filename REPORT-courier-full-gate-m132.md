# REPORT — courier full gate (m132, existing-behavior release-readiness)

- Worktree: `/Users/kaka/Code/any/moon/wt/courier-m132-gate` (branch `m132-courier-gate`)
- HEAD: `688371761b1aceab19c07ccb8d12590aa7633fd7`
  (`6883717 Align courier verification floors with tenant-scope suite`)
- Master match: `git -C /Users/kaka/Code/any/moon/cafaye/courier rev-parse master`
  returns the same SHA. Tree was clean (`git status --short` empty) before and
  after the gate, apart from this report.
- Note: local `master` is 3 commits ahead of `origin/master` (`8064319`);
  the worktree matches local master HEAD as briefed. No merge, no push.

## Preconditions (read-only)

- Documented PostgreSQL at `127.0.0.1:5432`: `accepting connections`
  (`pg_isready`). No container was started; Site launch Postgres was not used.
- `courier_test` exists (alongside `courier_dev`, `courier_dbg`,
  `courier_test_mgr_verify`, `courier_test_mgr_verify2`, `courier_test_ti`);
  confirmed test-only via `config/test.exs` (`database: "courier_test..."`,
  sandbox pool). Inspection was read-only (`\l`, `pg_database` select).
  No databases or volumes were dropped.
- No product or test source was changed; no gates loosened.

## Gate (single run, no rerun)

- Command: `./bin/prime` (the file behind gate.yml's declared
  `command: [mise, run, prime]` / `entrypoint: bin/prime`).
- Started: 2026-10-08T02:27:29Z. Finished: 2026-10-08T02:29:46Z.
- Gate exit code: `0`. Total wall time: **137s** (cold: hex/deps resolve,
  compile, `ecto.setup`, then the suite).
- Suite line: `Finished in 6.7 seconds (3.1s async, 3.6s sync)`
- Proof line: **`Result: 1600 passed`**
- Floor: `gate.yml` `minimum: 1600` → **PASS, exactly at floor**.
- Skips / excluded / failures: none. The proof shape `Result: N passed`
  (no fraction, no parenthetical breakdown) is what `bin/assert-suite`
  accepts; any skipped/excluded/failing shape would have failed the gate.
- The `[warning]` / `[error]` lines in the log (readiness-check failures
  against non-running repos, provider-unavailable sends, refused error
  envelopes, consumer `:missing_acceptance_url`) are expected negative-path
  test output, not failures.

## Credentials

Redacted. No secrets are recorded in this report; only role/database names
from committed config are referenced.

## Outcome

Green. This commit adds only this report. No push (manager merges).
