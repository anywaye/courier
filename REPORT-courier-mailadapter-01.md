# REPORT — courier-mailadapter-01

**The dev stack could not start courier.** The compose file never told courier
which mail adapter to use, and courier refuses to guess. That is the packet's
stated defect and it is fixed.

The finding that matters more: **the adapter was one of six.** Every one of them
is a boot requirement in `config/runtime.exs`, the dev stack supplied two, and
they are refused *inside the container, one at a time, as crash-loops*. The
packet brief lists three failures because three is how many a developer sees
before they stop looking — the other three were behind the third.

---

## 1. The decision: B, and why

Both answers in the brief are coherent. I took **B — give the dev stack something
to deliver to** — and added `axllent/mailpit` to courier's own compose.

A's case is the one I expected to win: it is smaller, it matches the existing
`${VAR:?…}` idiom, and it needs no new service. What decided it is the shape of
the failure itself. courier refuses to guess because a wrong guess is
*undetectable* — `Swoosh.Adapters.Local` accepts every send, opens no socket, and
returns a provider-shaped id. A's answer keeps that property in the dev loop: a
developer who has not supplied SMTP credentials gets a compose error naming a
variable, fixes it with a real relay's credentials, and is then sending **real
email from their laptop** with the platform's sending domain and reputation
attached. B's answer makes the wrong outcome impossible instead of unlikely:
there is no credential to supply, and nothing leaves the machine.

The brief's own framing agrees: the catcher "is the deeper half of this problem
and probably the real one."

### Does the catcher belong in kit, or in courier?

**Courier's compose**, which is the narrower change and the one made. The
argument for kit is real — a second mail sender would otherwise hand-add its own
mailpit — but it is an argument about a service that does not exist, and putting
it in kit means every service in the fleet starts a container it never reads.
The override model already exists for exactly this: a service adds its own
dependencies without touching the shared template, and a second sender adds its
own mailpit the same way. **If a second sender appears, promote it then** — and
the note belongs in kit, not here.

One thing B does *not* solve, and it is the honest cost: **`bin/dev` does not
print the catcher's URL.** `print_urls` in `bin/dev` is a fixed list of kit's
services with no per-service hook, and `bin/dev` is kit's script (courier's copy
is `templates/bin/dev.sh` from a kit release, and it is already behind the pinned
ref — it lacks `db grant`). So a developer gets a healthy stack and a catcher
running on `localhost:15025` that nothing tells them about. That is a real gap in
the payoff and the fix belongs in kit's `print_urls`. It is why the port is
`${KIT_MAILPIT_PORT:-15025}` — kit's convention is that the published port block
is deliberately *not* the well-known numbers (postgres 15500, nats 15600, redis
15800, grafana 15000), so 15025 keeps mailpit in that scheme and out of the way
of anything expecting 8025.

---

## 2. What the test proves, and the bug it found in itself

`test/courier/compose_config_test.exs`, 14 tests, no database, `ExUnit.Case`.

Measured, not asserted:

| state of `docker-compose.yml` | result |
| --- | --- |
| as committed on the base tree | **0/10 passed** (the 10 tests that existed before this session's additions) |
| after removing *only* `SECRET_KEY_BASE` + `COURIER_INBOUND_RESEND_SECRET` | **12/13 passed**, and the failure names `["COURIER_INBOUND_RESEND_SECRET", "SECRET_KEY_BASE"]` and nothing else |
| as committed | **14 passed** |

So the tests bite, and they bite *narrowly* — the partial revert was caught by
name rather than by a count.

### The reader that under-read, which is the real story

The headline test is "every variable `config/runtime.exs` refuses to boot without
is supplied by the dev stack", with the required set **derived from
`config/runtime.exs` itself** rather than hand-written. The first version derived
it by matching `System.get_env("X") || … raise`. It found five and passed.

It was wrong. `COURIER_ERROR_RELAY_TOKEN` is bound to a variable and refused
thirty-odd lines later:

```elixir
error_relay_token = System.get_env("COURIER_ERROR_RELAY_TOKEN")
…
if is_nil(error_relay_token) do
  raise """environment variable COURIER_ERROR_RELAY_TOKEN is missing."""
```

A reader keyed on the `||` shape cannot see that at all — so the assertion passed
**while courier was crash-looping on it**. That is precisely the failure this
repository's own rules name twice: a green check over a partial set reads as
coverage and is worse than no check. It was found by booting the stack, not by
reading it.

The reader now keys on the refusal's own sentence — `environment variable X is
missing` — because every one of these raises names its variable, that message is
the only thing an operator sees at 3am, and it is shape-independent: `|| raise`,
`if is_nil(…) do raise`, `fetch_env!` and a `case` all produce it.

And a second test guards the guard: every `System.get_env("X")` in `runtime.exs`
must be either required or in a declared `@optional_reads` map with a reason. It
immediately found six unclassified reads (`PHX_HOST`, `POOL_SIZE`, `PHX_SERVER`,
`DNS_CLUSTER_QUERY`, and two `SOME_APP_SSL_*` leftovers from the Phoenix
generator), which are now classified. **An unclassified read is the shape that
made the first reader wrong**, and it is now a red test rather than a silence.

### What the test cannot cover, stated plainly

`COURIER_MAIL_ADAPTER` is in the required list **by hand**, because its refusal
lives in `Courier.MailerAdapter.adapter!/1`, which this reader does not parse —
`runtime.exs:200` is a *call*, not a literal. That is a stated gap with its own
assertions above it, not a silent one, but a future third boot-required variable
added to *another* module would not be caught by the derived list.

The suite also cannot prove the *image* honours these variables; it proves the
compose file declares them. `bin/dev up` is the proof of that half, and §4 is
what it found.

### Two flaws in the partial work from the previous attempt, both fixed

The worktree held a half-applied version of this packet. It was **correct in its
decision** (mailpit, courier's compose, the six SMTP variables, the healthcheck)
and I kept it. Two things in it were wrong:

1. **The readers crashed instead of failing.** With no `mailpit` service,
   `scalar_field(nil, "image")` called `String.split(nil, …)` and raised
   `ArgumentError` — a stack trace pointing at a helper, on the one input the
   file exists to catch. Every reader is now nil-safe and lets the assertion
   print what it found. (AGENTS.md's "readers raise rather than under-read" is
   about not returning a vacuous green check, not about answering a missing file
   with a crash.)
2. **`depends_on` was parsed into a map that misdescribed itself.** The nested
   compose form flattened to `%{"postgres" => "", "condition" => "service_healthy"}`,
   so the failure message read `Got: %{"condition" => …}` as evidence mailpit was
   missing — on a file whose `depends_on` was correct. Now a dedicated reader, plus
   an assertion on the `condition:` being `service_healthy` rather than merely the
   service being named.

---

## 3. The six boot-required variables

Read from `config/runtime.exs`, cross-checked against the prose list in
`config/deploy.yml:218-228`.

| variable | how the dev stack gets it | why |
| --- | --- | --- |
| `DATABASE_URL` | literal, `postgres` service | already supplied |
| `COURIER_MAIL_ADAPTER` + `COURIER_SMTP_*` | `smtp` → mailpit | **this packet** |
| `COURIER_SECRET_BOX_KEY` | `${…:?}` | no local substitute; nothing to seal in dev, but a developer cannot invent the right key |
| `COURIER_IDENTITY_TOKEN` | `${…:?}` | only identity can mint one |
| `COURIER_INBOUND_RESEND_SECRET` | `${…:-whsec_…}` | placeholder; overridable |
| `SECRET_KEY_BASE` | committed literal | signs courier's own cookies on a machine with no users |
| `COURIER_ERROR_RELAY_TOKEN` | `${…:?}` | no local substitute |

The line between the three `:?` and the three defaulted is **whether a local
substitute exists**, not convenience. A default is only safe where nothing local
is being impersonated.

`COURIER_INBOUND_RESEND_SECRET` is the sharpest value on that list and got the
longest comment. It is a *provider's* signing secret, so a committed one would be
a version-controlled secret under which anyone who learns the stack's URL can
forge a hard bounce and suppress a real mailbox. It is defaulted on one measured
condition: **courier's port is not published** (no `PORTS` in `compose ps`), so
nothing off the machine can reach `POST /inbound/resend`. The comment says that
explicitly, says what must change if that changes, and the value decodes to a
sentence saying it is a placeholder — the same shape `config/test.exs:136`
already commits.

`COURIER_ERROR_RELAY_TOKEN` uses `${…:?}`, so **`bin/dev up` still needs three
secrets from the developer.** That is unchanged from before this packet and is
not a regression; I am not claiming a zero-credential dev stack, only a
zero-credential *mail* stack.

---

## 4. `bin/dev up`: courier is healthy; the command still exits 1

**The packet's defect is fixed and measured.** `axllent/mailpit:v1.22.0` runs
healthy, courier runs healthy, and the whole stack is up:

```
cafaye-courier-1         Up (healthy)
cafaye-mailpit-1         Up 23 minutes (healthy)    1025/tcp, 0.0.0.0:15025->8025/tcp
cafaye-postgres-1        Up (healthy)   cafaye-identity-1  Up (healthy)
cafaye-otel-collector-1  Up (healthy)   cafaye-grafana-1 / loki / mimir / tempo / nats / redis  healthy
```

Two measurements inside that run:

* The mailpit healthcheck is `["CMD", "/mailpit", "readyz"]` — the full path,
  because a healthcheck's `CMD` form execs the command **directly** and the
  image's `ENTRYPOINT` is *not* prepended. `["CMD", "readyz"]` fails every probe
  with `executable file not found in $PATH` while the server is perfectly fine.
* SMTP (1025) is **not** published, only the web UI. It is only needed by courier
  inside the compose network, and publishing it would let anything on the machine
  send through the catcher.

**`bin/dev up` nevertheless exits 1, at a different step — and this is NOT the
mail adapter.** `GET /readyz` inside the healthy container answers:

```json
{"status":"error","checks":{"database":"unavailable"}}
```

The cause, which is a **separate pre-existing defect and out of this packet's
scope**: `bin/dev`'s `migrate()` finds no `bin/migrate`, falls through to
`bin/ecto.setup`, and runs `mix ecto.create && mix ecto.migrate` **on the host**.
`config/dev.exs:27` hardcodes `hostname: "localhost"`, while the stack publishes
postgres on `${KIT_POSTGRES_PORT:-15500}` (15500). So the host-side migration
targets a port the stack is not on and answers:

```
The database for Courier.Repo has already been created
[error] Could not create schema migrations table.
  * The database does not exist
```

Reported rather than fixed: it is not the mail adapter, it needs a decision about
whether the dev stack's migrations run in the container (against
`COURIER_OWNER_DATABASE_URL`, which compose already sets to the owner dsn) or on
the host against `KIT_POSTGRES_PORT`, and either way it is a different packet.

Exact command, for reproduction:

```bash
export COURIER_SECRET_BOX_KEY="$(openssl rand -base64 32)"
export COURIER_IDENTITY_TOKEN="cafaye_devstack_placeholder_token"
export COURIER_ERROR_RELAY_TOKEN="$(openssl rand -hex 32)"
bin/dev up
```

**Follow-up, found and not fixed:** `PHX_HOST` is unset in the dev stack, and
`Courier.Unsubscribes.base_url/0` builds the RFC 8058 `List-Unsubscribe` header
from `PHX_HOST` via `config/runtime.exs`. In this stack the header therefore
points at `example.com`. Harmless for a dev stack with no real recipients, but a
developer testing a one-click unsubscribe will find the link goes nowhere.

---

## 5. Gate

`mise run prime` green, tail verbatim:

```
[prime] $ ./bin/prime
...
..............................................................................
Finished in 6.0 seconds (2.7s async, 3.3s sync)

Result: 1423 passed
```

The no-database tier, run the way CI derives it — the tier's own grep for the
file list, not arithmetic on a comment:

```console
$ grep -rLE 'use (Courier\.DataCase|CourierWeb\.ConnCase)' test --include='*_test.exs' \
    | sort > /tmp/nodb-tier.txt
$ wc -l < /tmp/nodb-tier.txt
29
$ xargs mix test < /tmp/nodb-tier.txt
..............................................................................
Finished in 5.2 seconds (1.6s async, 3.6s sync)

Result: 659 passed
```

`659 + 764 = 1423`, so the tiers still sum to the whole. Floors re-measured in
the same commit, per the rule in AGENTS.md that adding a test goes red until the
floor moves — and note the previous attempt's floor of **1419 was a prediction,
not a measurement**, and wrong by four. A floor set from a guess either blocks
the next packet or sits under the tree describing it no longer.

---

## 6. Verbatim output

```
$ mix test test/courier/compose_config_test.exs
..............
Finished in 0.1 seconds (0.00s async, 0.00s sync)

Result: 14 passed
```

Container state after `bin/dev up`:

```
cafaye-courier-1         Up (healthy)
cafaye-mailpit-1         Up 23 minutes (healthy)    1025/tcp, 0.0.0.0:15025->8025/tcp
cafaye-postgres-1        Up (healthy)
cafaye-otel-collector-1  Up (healthy)
cafaye-identity-1        Up (healthy)
cafaye-grafana-1         Up (healthy)
cafaye-loki-1            Up (healthy)
cafaye-mimir-1           Up (healthy)
cafaye-tempo-1           Up (healthy)
cafaye-nats-1            Up (healthy)
cafaye-redis-1           Up (healthy)

$ docker exec cafaye-courier-1 … /readyz
{"status":"error","checks":{"database":"unavailable"}}
```

---

## 7. What I would do next, in order

1. **The host-side migration path** (§4). `bin/dev` runs `mix ecto.migrate` on
   the host against `localhost`, and the stack publishes postgres on 15500. This
   is why `bin/dev up` still exits 1 and it is a one-line-per-file decision, not
   a research problem. Until it is fixed the dev loop's last mile is broken in a
   way that looks exactly like the defect this packet just fixed.
2. **`print_urls` in kit** (§1). The catcher is running and nothing tells a
   developer where to look. The fix is a per-service URL hook in kit, not a
   second hardcoded list.
3. **`PHX_HOST` in the dev stack** (§4), so the `List-Unsubscribe` header points
   somewhere a developer can click.
4. **`COURIER_MAIL_ADAPTER` in the derived required list** is hand-added because
   its refusal is in another module (§2). If a third boot requirement ever lands
   in a module other than `runtime.exs`, the derived list will not see it.