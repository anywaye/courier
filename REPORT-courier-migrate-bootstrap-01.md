# REPORT — courier: migrate needs no serving credential (roll/c5-courier-migrate)

**The packet.** The substrate's migrations step runs each service's migrate
entrypoint as a one-shot pod *before* the stack is up, and on a Contabo box
courier's Job died at boot on `COURIER_IDENTITY_TOKEN is missing` — a variable
`config/runtime.exs` requires and the substrate mints in a **later** step, once
identity is serving. So a fresh box could never migrate courier, by construction.
This packet makes the migrate path validate the subset of the config a migration
actually needs, while the server keeps refusing.

Branch `roll/c5-courier-migrate`, worktree
`/Users/kaka/Code/any/moon/wt/roll-c5-courier-migrate`, cut from current master.
Nothing pushed, nothing merged, no other repo touched, no subagent spawned.

## The shape chosen, and why

**A `config/runtime.exs` branch keyed on `RELEASE_COMMAND`.** The file computes

```elixir
serving? = System.get_env("RELEASE_COMMAND") != "eval"
```

once, and the serving-only raises are gated on it.

**Why `RELEASE_COMMAND` and not a variable courier invents.** The release's own
`bin/<name>` script sets it from its first argument and exports it before the VM
starts: `start` for `bin/server`, `eval` for `bin/migrate`. Crucially the script
**overwrites** any inherited value, so `RELEASE_COMMAND=eval bin/server` cannot
make the server skip its contract — `bin/server` sets the value to `start`
itself. A new courier-specific variable (`COURIER_MIGRATE_ONLY=1`) would be a
variable a server could carry by accident; the release's own signal cannot.

**What is gated, and what is deliberately not:**

- `if config_env() == :prod and serving?` around the identity-token raise and
  the whole mailer/secret-box/inbound-secret block. Those are the serving
  contract; a migration reads none of them.
- `DATABASE_URL`, `SECRET_KEY_BASE` and `COURIER_ERROR_RELAY_TOKEN` raises become
  `... || if serving? do raise ... end` — the value is allowed to be absent in a
  migrate boot, the refusal stays for the server.
- `Courier.OwnerRepo` is configured **outside** the gate. It is the one
  credential a migration needs (`COURIER_OWNER_DATABASE_URL`), and it does not
  raise: an absent owner DSN fails later, in `bin/migrate`, with Ecto's own
  "could not find Ecto repo config for Courier.OwnerRepo under :courier" — which
  names the module an operator needs.

Smaller gate, not a bigger one: `DATABASE_URL` is the app role (`courier_app`),
which a migration may not use and does not start, so requiring it for a
migration was requiring DDL's opposite. The migrate boot now needs
`COURIER_OWNER_DATABASE_URL` and nothing else.

**Why not a `MIX_ENV` distinction.** A release is compiled as `:prod`; the
distinction the failure needs is *which subcommand of the same release booted*,
which `MIX_ENV` cannot express.

**The entrypoints are held to it by a test.** `rel/overlays/bin/migrate` runs
`courier eval Courier.Release.migrate`; `rel/overlays/bin/server` runs
`courier start` and sets `PHX_SERVER=true`. Both now carry a comment saying why
the word matters, and `test/courier/release_migrate_config_test.exs` reads the
two files and fails if either word changes.

## Proof 1 — the migrate path completes with no serving credential

A real release (`MIX_ENV=prod mix release`) on a fresh database, run with `env -i`
(so the environment holds **nothing** but PATH/HOME/TERM and the one credential a
migration reads):

```
$ psql -h localhost -U postgres -c "CREATE DATABASE courier_migrate_proof OWNER postgres;"
CREATE DATABASE
$ env -i PATH=/usr/bin:/bin HOME="$HOME" TERM=dumb \
    COURIER_OWNER_DATABASE_URL="ecto://postgres:postgres@localhost:5432/courier_migrate_proof" \
    _build/prod/rel/courier/bin/migrate
00:42:24.694 [info] == Running 20260930030239 Courier.Repo.Migrations.CreateNotificationPreferences.change/0 forward
...
00:42:25.292 [info] == Migrated 20261006140000 in 0.0s
$ echo $?
0
$ psql -h localhost -U postgres -d courier_migrate_proof -tAc \
    "select count(*) || ' tables, ' || (select count(*) from schema_migrations) || ' migrations'
       from information_schema.tables where table_schema='public';"
13 tables, 14 migrations
```

Not one of `COURIER_IDENTITY_TOKEN`, `COURIER_SECRET_BOX_KEY`,
`COURIER_INBOUND_RESEND_SECRET`, `COURIER_ERROR_RELAY_TOKEN`,
`COURIER_MAIL_ADAPTER`, `COURIER_SMTP_*`, `DATABASE_URL` or `SECRET_KEY_BASE` was
set, and every migration applied. `env -i` is the point rather than a flourish:
it is the difference between "we did not set them" and "there is nothing to set".

## Proof 2 — the server still refuses, naming the variable

The **same** bare environment, the server entrypoint instead:

```
$ env -i PATH=/usr/bin:/bin HOME="$HOME" TERM=dumb \
    COURIER_OWNER_DATABASE_URL="ecto://postgres:postgres@localhost:5432/courier_migrate_proof" \
    _build/prod/rel/courier/bin/server
ERROR! Config provider Config.Reader failed with:
** (RuntimeError) environment variable COURIER_IDENTITY_TOKEN is missing.

It is courier's own credential for identity's introspection endpoint —
the scoped API token an operator mints with
POST /v1/accounts/{account_id}/api-keys — and courier presents it as the
Authorization header when it asks "who is calling?".
...
Runtime terminating during boot (...)
$ echo $?
1
```

The refusal is intact and names the variable. The migrate boot and the server
boot differ by exactly one thing — `RELEASE_COMMAND` — and the difference between
their outcomes is the whole packet.

## A finding this packet fixed, because its own test exposed it

The full suite went **red** on the first run — 6 failures, all in the new file —
with `FunctionClauseError: no function clause matching in Keyword.merge/2` at the
NATS block of `config/runtime.exs`, not at anything the test asserted. The cause
is a real fragility, not the test's:

- several test files capture `Application.get_env(:courier, :nats)` (which is
  `nil`, because no environment configures it) and restore it with
  `Application.put_env(:courier, :nats, original)` — which leaves the key
  **present and nil**;
- `Application.get_env(:courier, :nats, [])` returns `nil` in that state, because
  the three-argument form's default applies only when the key is **absent**;
- `Keyword.merge(nil, url: …)` raises.

So any `Config.Reader` evaluation of `runtime.exs` in `:prod` that happened to run
after one of those tests crashed. `test/courier/unsubscribes_test.exs` evaluates
the same file the same way and was equally exposed; it had been winning the
ordering lottery. The fix is one line — `Application.get_env(:courier, :nats) || []`
— and it is the *correct* reading rather than a test workaround: an explicit
`nil` means the same thing an absent key does (no broker), which is the state
`Courier.Nats.supervised_child/0` and `Courier.NatsPublisher.Unconfigured`
already document as supported. It changes nothing in production, where the key is
absent.

## The substrate command line

kit's step 10 (`templates/substrate/install.sh`, `install_migrations`) runs one
one-shot pod per schema-owning service, in that service's own running image, as
its OWNER role. For courier it is:

```
kubectl run kit-migrate-courier -n courier --restart=Never \
  --image="$(kubectl -n courier get deploy courier -o jsonpath='{.spec.template.spec.containers[0].image}')" \
  --env=COURIER_OWNER_DATABASE_URL="postgres://courier:<owner-password>@postgres-role-courier.courier.svc:5432/courier?sslmode=disable" \
  --command -- /app/bin/migrate
```

`/app/bin/migrate` is this repository's `rel/overlays/bin/migrate`, which runs
`courier eval Courier.Release.migrate` as `Courier.OwnerRepo`.

**`--env=DATABASE_URL=…` is no longer needed and should be dropped.** kit's
current `migration_env_args_for courier` passes both `DATABASE_URL` (the
`courier_app` role) and `COURIER_OWNER_DATABASE_URL`; after this packet the
migrate boot does not read `DATABASE_URL` at all, and handing the migrator the
app role's credential is a credential it must not use. Passing it is harmless —
the release no longer requires it — but the honest arg list is the owner DSN
alone. kit owns that edit (a sibling packet), so this is a report, not a change.

## Tests added, and the floors

`test/courier/release_migrate_config_test.exs` (**10 tests**, plain `ExUnit.Case`,
no database): `env: :prod` evaluates `config/runtime.exs` as a boot under
`RELEASE_COMMAND=eval` and under `start`/`daemon`/`start_iex`/unset, asserting the
migrate boot needs no serving credential and configures the owner DSN, and the
server refuses naming `COURIER_IDENTITY_TOKEN`. Two tests read the shell
entrypoints (`rel/overlays/bin/{migrate,server}`) and fail if either stops naming
the command the split keys on.

`test/courier/compose_config_test.exs` gained a classification for the new
`RELEASE_COMMAND` read — its reader ("every variable runtime.exs reads is either
required or declared optional") caught the new read on its own, which is that
test working rather than being told.

**Floors raised in the same commit, as the repository requires:**
`gate.yml` `minimum` 1663 -> **1673**; CI whole-suite `1663` -> **1673**;
no-database tier `760` -> **770** (35 -> 36 files); database tier unchanged at
**903**. The new file is in the no-database tier for the reason
`backup_config_test.exs` is: a claim about `config/runtime.exs` and two files on
disk is a claim no database can check, so a database-less runner must still
execute it.

Focused run, the command and its output:

```
$ mix test test/courier/release_migrate_config_test.exs
Running ExUnit with seed: 245275, max_cases: 16
..........
Finished in 0.05 seconds (0.00s async, 0.05s sync)

Result: 10 passed
```

Whole gate, the command and its output:

```
$ ./bin/prime
...
Finished in 5.4 seconds (2.8s async, 2.6s sync)

Result: 1673 passed
```

And the tier split, re-measured by running both tiers on this tree rather than by
adding a delta on paper (the repository's own consistency check: the parts must
sum to the whole):

```
$ grep -rLE 'use (Courier\.DataCase|CourierWeb\.ConnCase)' test --include='*_test.exs' | sort > nodb.txt
$ grep -rlE  'use (Courier\.DataCase|CourierWeb\.ConnCase)' test --include='*_test.exs' | sort > db.txt
$ xargs mix test < nodb.txt   # 36 files
Result: 770 passed
$ xargs mix test < db.txt     # 51 files
Result: 903 passed
```

`770 + 903 = 1673`, so no file fell outside both tiers.

## What I deliberately did NOT do

- **Did not weaken the server's fail-closed validation.** The server entrypoint
  still runs `start`, `serving?` is true whenever `RELEASE_COMMAND` is anything
  but `eval`, and the release script overwrites an inherited `RELEASE_COMMAND`.
  Proof 2 is the server refusing.
- **Did not use dummy values for the credential in the migrate path.** The point
  is that it does not need it; Proof 1 sets nothing.
- **Did not add a new environment variable, a second release, or a second config
  file.** The distinction is the release's own `RELEASE_COMMAND`.
- **Did not edit `cafaye/kit`.** kit's step 10 is quoted above unchanged; the one
  improvement (drop `--env=DATABASE_URL`) is a report for the sibling that owns
  the installer.
- **Did not require `DATABASE_URL` in the migrate boot.** That is a deliberate
  behaviour change, not an omission: it names `courier_app`, which a migration
  may not use, and the migrate boot no longer reads it.
