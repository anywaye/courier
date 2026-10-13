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

<!-- FILL: command + output -->

## Proof 2 — the server still refuses, naming the variable

<!-- FILL: command + output -->

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

`test/courier/release_migrate_config_test.exs` (N tests, plain `ExUnit.Case`,
no database): `env: :prod` evaluated `config/runtime.exs` as a boot under
`RELEASE_COMMAND=eval` and under `start`/`daemon`/`unset`, asserting the migrate
boot needs no serving credential and configures the owner DSN, and the server
refuses naming `COURIER_IDENTITY_TOKEN`.

`test/courier/compose_config_test.exs` gained a classification for the new
`RELEASE_COMMAND` read — the reader that checks "every variable runtime.exs reads
is either required or declared optional" caught it, which is that test working.

<!-- FILL: floors moved, gate output -->

## What I deliberately did NOT do

<!-- FILL -->

- Did not weaken the server's fail-closed validation. The server entrypoint is
  unchanged in kind (still `start`), and Proof 2 shows it refusing.
- Did not use dummy values for the credential in the migrate path. The point is
  that it does not need it.
- Did not edit `cafaye/kit`. The substrate command line above is a report.
- Did not add a new environment variable, a second release, or a second config
  file.
