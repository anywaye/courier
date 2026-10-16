# HANDOFF — boot-lines-visible

**Branch:** `fix/boot-lines-visible`
**Worktree:** `/Users/kaka/Code/any/moon/wt/boot-lines` (the only worktree used;
no second repository was touched)

## The packet, in one line

The two operator-facing notices `config/runtime.exs` emitted were dropped in a
release boot, because that file is evaluated before the `:logger` application
is up. They are now composed there and emitted once by
`Courier.StartupNotices.log_startup/0`, called from `Courier.Application.start/2`.

## Commits

- `83f8c46` — `test(startup): the boot notices need an emitter the logger can
  reach` (RED: 4 failures, module undefined).
- `226351c` — `fix(boot): emit the operator notices once the logger can carry
  them` — the module, the composition in `config/runtime.exs`, the wiring in
  `lib/courier/application.ex`, the rewritten assertions in
  `release_migrate_config_test.exs`, and the floor raise.

## The measurement this packet is on the far side of

```
kubectl logs | grep -c 'mailer:\|inbound:'  -> 0   (fresh box, 32 lines)
kubectl logs | grep -c 'mailer:\|inbound:'  -> 0   (Contabo, 544 lines)
```

The running node's config was correct (`adapter:
Courier.Adapters.CloudflareEmail`, `inbound_secrets: %{}`), so this is a
visibility defect: `config/runtime.exs` runs before `:logger`, and a `Logger.*`
call there has no handler. It is pre-existing for the `mailer:` line and
load-bearing for the inbound warning.

## The mechanism, and why the naive call cannot work

No arrangement of `Logger.*` inside `config/runtime.exs` can work, because the
failure is about WHEN the file is evaluated relative to the logger. The notices
are COMPOSED in that file (where the resolved adapter and the inbound decision
already are) and carried in application env to
`Courier.StartupNotices.log_startup/0`, which `Courier.Application.start/2`
calls. `:logger` is in `mix.exs`'s `extra_applications`, so it is up before
courier's own supervisor starts. The idiom is the repo's own:
`Courier.Nats.log_startup/0` and `Courier.Telemetry.log_startup/0` are called
from the same place.

## The exact text of both lines now (unchanged)

```
mailer: #{Courier.MailerAdapter.describe(mailer_adapter)}
inbound: no provider configured — a hard bounce or a spam complaint is discarded and courier goes on mailing an address that has said it is gone; set COURIER_INBOUND_RESEND_SECRET to enable Resend inbound reports
```

`describe/1` names presence, never a value; the inbound line names the provider
and never the secret. Both rules are asserted (`ReleaseMigrateConfigTest` on the
composed content, `MailerAdapterCredentialsTest` on the descriptions).

## What was PROVED, locally and honestly

**A real release boot.** `MIX_ENV=prod mix release --overwrite`, then
`_build/prod/rel/courier/bin/courier start` with prod's serving variables set
(cloudflare adapter, no `COURIER_INBOUND_RESEND_SECRET`), and the log read back:

```
21:05:29.432 [info] mailer: adapter=cloudflare token=set account_id=set
21:05:29.432 [warning] inbound: no provider configured — a hard bounce or a
spam complaint is discarded and courier goes on mailing an address that has
said it is gone; set COURIER_INBOUND_RESEND_SECRET to enable Resend inbound
reports
grep -c = 2
```

Both lines, exactly once, in the release's own stdout. This is the proof the
brief said a unit test could not be.

**Unit tests.** `test/courier/startup_notices_test.exs` (4) proves content and
level under `capture_log`, plus that `Courier.Application.start/2` replays the
notices (a sentinel at `:warning`, calling `start/2` and reading the emitted
log). `release_migrate_config_test.exs` now asserts the composed content.

## What could NOT be proved here, and how the manager proves it

- The unit tests cannot reproduce the timing, and say so in their moduledoc.
  The release-boot run above is the local substitute; the box-level proof is
  still `kubectl logs | grep -c 'mailer:\|inbound:'` after a roll, which the
  manager runs.

## Blocking condition the manager must know about

**The full gate could not be made green on this box, and it is not this
packet's fault.** Load average was 46–60 (many workers). The whole suite fails
`Courier.CloudflareDeliveryTest` with
`:ets.new(:courier_cloudflare_requests) ... table name already exists` — a race
in `test/support/cloudflare_server.ex` (`start_link`, linked, not supervised;
the server outlives its test under load). Reproduced on the **untouched base
with this packet's implementation stashed**: base run `1763/1773 passed`, the
same 6 Cloudflare failures; the file alone passes (`29 passed`). Measured
counts on this tree: whole **1773**, no-database **814** (38 files, exit 0),
database **959** (55 files, unchanged). Floors raised to those numbers in
`gate.yml` and `.github/workflows/ci.yml` together.

## Files changed

- `lib/courier/startup_notices.ex` (new)
- `lib/courier/application.ex` (one call)
- `config/runtime.exs` (compose instead of log)
- `test/courier/startup_notices_test.exs` (new)
- `test/courier/release_migrate_config_test.exs` (assert composed content)
- `gate.yml`, `.github/workflows/ci.yml` (floors)
