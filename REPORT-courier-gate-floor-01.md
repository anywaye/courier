# courier-gate-floor-01 — the ratchet did not move with the thing it measures

`worker/courier-gate-floor-01`. **1297 tests measured on a freshly migrated
database, `bin/prime` green, 15 tests recovered by a floor move that should have
happened in the merge.** One number in `gate.yml`, two in
`.github/workflows/ci.yml`, and a finding about the gate's blind spot that is
more important than the diff.

---

## 1. What was actually wrong

`gate.yml:162` carried `minimum: 1276` against a measured 1282 — the deliberate
margin of 6. Merge `4eb7585` (`worker/courier-tenant-identity`) added 15 tests.
Nothing moved. So for one merge the floor sat **21 below the measurement instead
of 6**, and the gate stayed green.

**The green is the finding, not a reassurance.** `minimum` is a decrease-detector:
it fails when the measurement falls *below* the floor. A floor that is stale is
silent by construction, so the gate structurally cannot report this class of
drift. The only thing that ever catches it is the convention — *the floor moves in
the same commit that changes what courier verifies* — which has now held across
eleven raises and did not hold on the twelfth.

## 2. The measurement, on a database that did not exist

Three partitions, all through `bin/prime` unmodified, all after an explicit
`mix ecto.drop` on a name that was confirmed absent from `pg_database` first:

| partition | command | result |
| --- | --- | --- |
| `courier_test_gf01` | `MIX_TEST_PARTITION=_gf01 ./bin/prime` | **`Result: 1297 passed`**, exit 0 |
| `courier_test_gf01b` | `MIX_TEST_PARTITION=_gf01b ./bin/prime` | **`Result: 1297 passed`**, exit 0 |
| `courier_test_gf01` | tier steps, same partition | 619 / 678 / 62 |

```
Finished in 4.8 seconds (1.8s async, 3.0s sync)

Result: 1297 passed
```

Zero failures, zero exclusions, `bin/prime` exit 0, and 11 rows in
`schema_migrations` on the fresh partition — so the schema the tests ran against
was built from scratch by `bin/prime`'s own `ecto.setup`, not inherited. The
second partition is the post-change tree and reported the same 1297, which is the
control that says the YAML edits changed no test.

The merge commit's own message claims 1297, and it is right.

## 3. The arithmetic, and where the margin of 6 comes from

```
measured  1297
margin      -6      <- the standing convention, verified below
floor      1291
```

**The margin was verified, not assumed.** The comment records eight floor/measured
pairs — 1128/1134, 1067/1073, 672/678, 722/728, 816/822, 912/918, 1150/1156,
1276/1282 — and **every one differs by exactly 6**. I then checked the value
history of the `minimum:` line itself, oldest first, which is the thing the
comment could have drifted from:

```
4df0544 530   4b134ae 560   889753b 610   acdffa6 624   d806bad 672
ec4c6be 724   5b700c7 722   7c22550 912   a760ddd 1021  cb1d23b 1067
25893b7 1128  06cd732 1150  ba3358f 1212  c93d280 1276  4eb7585 1276
```

Eleven distinct raises, and the one value the current comment's list omits —
`a760ddd`'s **1021** — pairs with a measured **1027** recorded in that same
commit's comment. 1027 − 6 = 1021. The convention holds without a single
exception, so 1297 − 6 = **1291**.

**One thing the history settled that I did not expect.** CI's whole-suite floor
and `gate.yml`'s `minimum` were *not* always the same number, and the difference
is the margin:

| commit | `gate.yml` | CI whole suite | relationship |
| --- | --- | --- | --- |
| `7c22550` | 912 | 918 | CI held the **measured** number |
| `ba3358f` | 1212 | 1212 | aligned on measured − 6 |
| `c93d280` | 1276 | 1276 | aligned on measured − 6 |

Before courier-23, CI's floor was the measured count and `gate.yml`'s was
measured − 6; from courier-23 on, CI's floor is set equal to `gate.yml`'s. So
**both are decrease detectors either way and both are satisfied** — this is not a
latent red, it is two copies of one ratchet. I set CI to 1291 rather than 1297
because the later convention is the better one, and because of the reason in §5.

## 4. The tier split, and whether the parts still sum to the whole

Both new files are the **database tier**, read off the same case templates CI's
own tier steps derive from — not guessed:

| file | template | tier |
| --- | --- | --- |
| `test/courier/tenancy_test.exs` | `use Courier.DataCase, async: true` | database |
| `test/courier_web/plugs/tenant_identity_config_test.exs` | `use CourierWeb.ConnCase, async: false` | database |

Both assert over a live database — one over the transaction that sets and
discards the tenant identity, one over real requests through the real endpoint —
so both match `grep -rlE 'use (Courier\.DataCase|CourierWeb\.ConnCase)'`.

Measured on the same fresh partition, with CI's exact tier commands:

| tier | files | measured | floor was | floor now |
| --- | --- | --- | --- | --- |
| no database | 27 (unchanged) | **619** | 619 | 619 — **re-measured, not assumed** |
| database | 33 → **35** | **678** | 663 | **678** |
| SSRF table | 1 | **62** | 62 | 62 |

**`619 + 678 = 1297`.** The consistency restatement holds, and no file has fallen
outside both tiers. This is the check that genuinely had to be re-run: had either
new file matched neither grep, the whole suite would have reported 1297 while the
tiers summed to 1282, and the missing 15 would have sat in a tier nobody counts.

**The tier floors carry no margin, and that is not an inconsistency.** Historically
they are the exact measured count: `405 + 513 = 918`, `623 + 595 = 1218`,
`619 + 663 = 1282` — three independent instances, each summing to its own
whole-suite measurement. The margin belongs to the whole-suite ratchet, whose job
is to stay clear of the flakiness in a full run; a tier step is deterministic, so
holding it at the measured count is the tighter and more useful floor. The
no-database tier not moving is therefore a real measurement, not a leftover: an
unchanged floor that was never re-run is not evidence.

## 5. What the floors are, in total

| where | was | now |
| --- | --- | --- |
| `gate.yml` `proof.minimum` | 1276 | **1291** (measured 1297, margin 6) |
| `ci.yml` whole suite | 1276 | **1291** (kept equal to `gate.yml`) |
| `ci.yml` no-database tier | 619 | **619** (re-measured) |
| `ci.yml` database tier | 663 | **678** |
| `ci.yml` database tier file count | 33 | **35** |
| `ci.yml` run-summary table | 1282 / 619 / 663 | **1297 / 619 / 678** |

**Why the two whole-suite floors are 1291 and not 1297.** Both are decrease
detectors and both are satisfied either way. But a floor that is right in one
place and slack in another is *worse* than one uniformly slack, because a reader
who checks the one that was updated concludes the rest are fine. Keeping them
equal makes "did someone move the ratchet?" a single question with one answer.

**The tier floors moved in this commit**, not only the total — they were wrong by
exactly the same 15, and leaving them would have been the specific failure this
packet exists to repair.

## 6. The guard was live: what a contaminated measurement would have produced

I did not have to imagine this. While validating, I ran core's own
`floors-check --repo .`, which invokes the gate itself — **with no
`MIX_TEST_PARTITION`, so on the shared `courier_test`.** It reproduced the
contamination exactly as the packet described:

```
Result: 1289/1297 passed
Failed: 8 tests
[prime] ERROR task failed          # exit 2
```

and named them:

```
1) test retention an expired claim is discarded, so a day-old key behaves as a new one (Courier.IdempotencyTest)
2) test retention purge_expired/0 removes expired claims and keeps live ones (Courier.IdempotencyTest)
3) test retention an unexpired claim is NOT discarded by another claim of the same triple (Courier.IdempotencyTest)
4) test the scope of a key the same key under another account is a different key (CourierWeb.Plugs.IdempotencyTest)
5) test a key that is not a uuid is refused before the endpoint exists, and claims nothing (CourierWeb.Plugs.IdempotencyTest)
6) test a request without a key is processed normally, and records nothing (CourierWeb.Plugs.IdempotencyTest)
7) test a key that is not a uuid a header sent twice is treated as no header at all (CourierWeb.Plugs.IdempotencyTest)
8) test a request that did not succeed leaves no row, so the same key can be used again (CourierWeb.Plugs.IdempotencyTest)

     code:  assert claims() == 0
     left:  1
     right: 0
```

Eight, the same file family, `left: 1, right: 0` — stale `idempotency_keys` rows
from earlier runs that no longer belong to the test asserting them. **These are
not regressions:** they appear on this tree, whose only difference from master is
two YAML files that no test reads (verified — `grep` for `gate.yml`/`ci.yml`/
`workflows` across `test/` returns two prose mentions in moduledocs and nothing
else).

**Had that been my measurement, here is exactly what I would have written:**

> The measurement came out contaminated — `1289/1297 passed`, `Failed: 8`, exit
> 2. **The floor stays at 1276.** A floor moved on a dirty measurement is worse
> than a stale floor, because the contamination is now baked into the number and
> nobody will look at it again.

Three separate signals stopped it, and all three are cheap: the **exit code 2**,
the explicit **`Failed:` line**, and a passed-count that disagrees with a suite
believed clean. Note what the number itself would have done had all three been
ignored: `1289 − 6 = **1283**`, which is **8 below the true floor**. It would have
been green forever — it is a decrease detector — and it would have reproduced
*this exact defect* at a third of the size, one packet later, with no way to tell
the difference. **The contamination was not a rounding error; it was a
floor-poisoning mechanism, and the fresh-partition rule is what stops it.**

The total test count is worth noting for honesty: 1289 + 8 = 1297, so both
databases agree on how many tests exist. The contamination moved pass/fail, not
the count. The count would still have been wrong to trust — a dirty run is not a
measurement, and the reason it happens to agree here is luck, not a property.

## 7. Can this floor catch the next drift of this kind? No.

**It cannot, and nothing in this commit changes that.** `minimum: 1291` is a
decrease-detector: it fires when the suite *shrinks* past the floor and is silent
whenever the floor sits below the measurement. The next merge that adds tests
without moving the floor will be exactly as green as `4eb7585` was — the gate
reports "1297 ≥ 1291, fine" while the ratchet quietly goes slack, and the only
thing that will notice is a human reading this comment. A convention with an
eleven-for-twelve record is a convention, and this packet is the data point that
says so.

**What would actually catch it.** The direction is to make the floor a
**two-sided** check rather than a one-sided one — the declaration already has the
measured number in the proof pattern's capture group, so the machinery for this is
present and unused. The smallest honest version is a **staleness bound**: assert
the measurement is within a window of the floor (say, ≤ 12), so a merge that adds
tests without raising the floor fails the gate for being *ahead* of its own
ratchet. That inverts the current semantics deliberately and is a real design
decision, not a one-line diff: it reddens every in-flight branch that adds a test,
which is the point but is also why it cannot be slipped in here. The fuller
version is mechanical — derive the floors by counting tests from the source
rather than writing them down, so there is no number to forget — which is what
core's `floors-check` is already reaching toward, since it reads a declared floor
and a measured one side by side. **Both are core questions, they affect every
repository in the fleet, and they deserve to be decided on their own evidence.**
Per this packet's scope I changed the numbers and nothing else: not the gate's
structure, not the rules, not the `decrease-detector` semantics, and not the
margin.

## 8. Verified, and not done

**Ran green:** `bin/prime` on two brand-new partitions (1297, exit 0);
`bin/assert-suite` on all four logs against the new floors (4/4 exit 0);
`mix.lock` unchanged (`git diff --exit-code -- mix.lock` clean);
`core/harness/bin/gate-check .` → **0 failures**, 2 warnings, both pre-existing
and about *unproven external requirements* (the checker will not run `mise` or
`mix` for itself) — unrelated to this change;
`bin/gate-self-test` → **10 passed, 0 failed, 1 skipped** (the skip is the real-suite
`--prove`, which needs `GATE_SELF_TEST_STATIC_ONLY` unset), so `gate.yml` can
still fail all nine ways it is supposed to.

**Not done, deliberately:**

- **No push, no merge, no tag.** One commit on `worker/courier-gate-floor-01`.
- **No change to the gate's structure, the rules, the `decrease-detector`
  semantics, or the margin** — §7 is the report of that conclusion, not its
  implementation.
- **`README.md:147` and `AGENTS.md:458` were NOT updated, and this is a
  judgement worth naming.** Both carry counts from the 1156-era packet
  (`1156 tests, 577 of them…` / `577 tests in the 25 files… 579 in the 28 that
  do… 1156`). They are stale by 141 tests, not by 15, and they were already stale
  two packets before this one — so they are **not** the defect this packet was
  sent to fix, and fixing them here would have widened a one-number diff into an
  unrelated prose rewrite. courier-23 set the precedent for correcting labels
  alongside floors, and I am recording that I chose not to, with the measured
  numbers to hand: `1297 / 619 / 678`, no-database 27 files, database 35 files.
  **It is a one-line fix in each file whenever that packet runs.**
- **Historical records untouched**: `CHANGELOG.md`, `REPORT-courier-*.md`, and
  the two files that say *"1276 green tests could not see an inert boundary"*
  (`test/courier/tenancy_test.exs:21`, `lib/courier/tenancy.ex:22`). Those are
  statements about the suite **as it was when the finding was made**; rewriting
  them to 1291 would falsify the record of what the finding was found against.