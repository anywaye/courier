# courier-gate-floor-02 — W105 replaced a plug and its tests; the floor follows

`worker/m119-local-courier-gate`. **1600 tests measured (`bin/prime` green,
m119 evidence), floor said 1601. The -1 is a file replaced, not a test lost —
floor moves 1601 -> 1600, database tier 878 -> 877, no-database tier unchanged
at 723.** Three numbers in two files (`gate.yml` minimum, two
`bin/assert-suite` floors in `.github/workflows/ci.yml`), each with the
remeasured paragraph the convention demands.

## 1. Cause: W105 deleted the plug the old tests asserted

Merge `8064319` (`worker/courier-w105-tenantscope`) replaces pipeline-level
tenant identity with per-action scope. Commit `49de49b` deletes
`lib/courier_web/plugs/tenant_identity.ex` and its `:authenticated` pipeline
slot — the plug opened its transaction around `fn -> conn end` and committed
before the controller ran, discarding the transaction-local identity every
authenticated request depended on. In the same commit it deletes that shape's 7
tests (`test/courier_web/plugs/tenant_identity_config_test.exs`: pipeline
order, identity-inside-the-plug's-transaction, three accounts, the 401
negative, the no-identity surfaces) and adds `tenant_scope_test.exs` with 6.
Net -1, all inside the database tier: both files are `CourierWeb.ConnCase`,
so tier file counts do not move (33 / 47, re-run greps on this tree).

Restoring the 7 is refused, not overlooked: the new file's negative guard
asserts no transaction-scoping plug returns to `:authenticated`, which the old
pipeline-order test directly contradicts. Restoring them would mean restoring
the deleted plug — the bug W105 removed.

## 2. Same or stronger: what the 6 prove that the 7 did not

- Idempotency claim (write) + lookup (read) from production's post-COMMIT
  state — the downstream half the old file's moduledoc admitted was
  unprovable in-suite.
- Pool recovery over 32 failed transactions, then a scoped write with no
  sleep and no retry.
- Acceptance: `POST /v1/messages` accepted and its retry replayed
  (`idempotency-replayed`), proving a request reads back the row its own
  scope wrote.
- Route coverage 9 -> 13 `/v1` routes (the four notification-reader routes
  added since), unauthenticated surfaces retained by name.

## 3. Verification (no `bin/prime`, per brief)

- `mix test test/courier_web/plugs/tenant_scope_test.exs` → `Result: 6 passed`.
- `bin/assert-suite /tmp/gate-m119-courier-local.log "whole suite" 1600` →
  exit 0; with `1601` → exit 1 (the guard bites, and its own message names
  the two honest options: put the test back, or lower the floor — this
  report is the evidence the second one was the right call).
- Tier split re-derived, not assumed: 1600 = 723 + 877; SSRF 62 untouched.

## 4. Drive-by noted, not hidden

The CI "what actually ran" summary table still said 1593 / 715 / 32 files —
stale since w100, which raised the floors without updating it. Corrected to
1600 / 723 / 33 files / 877 in the same commit, since it names the same tiers.
