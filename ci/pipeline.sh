#!/usr/bin/env bash
# ci/pipeline.sh — courier's pipeline, on the instabox backend or any other.
#
# A backend's job is only to provide an environment and call this script; the
# gate is courier's. Which backend ran is recorded in `ci/backend`, and
# switching is one line — `github-actions` keeps `.github/workflows/ci.yml` as
# the runner (kit's `backends/README.md` is the contract).
#
# WHERE EVERY COMMAND COMES FROM: `.github/workflows/ci.yml` IN THIS
# REPOSITORY. That file is the source of truth; when it changes, change this
# file with it.
#
#   1. THE GATE is `./bin/prime`, verbatim and unmodified — the `gate` job's
#      step runs `./bin/prime 2>&1 | tee "$log"`. (`mix local.hex --force`,
#      `mix deps.get`, `mix ecto.setup`, `mix test` — mix.exs aliases test to
#      create+migrate first, so a runner with no postgres aborts before the
#      first test.) The per-tier re-runs, the lockfile guard and the coverage
#      floor around it stay in the workflow; they re-run the suite and assert
#      its size, which is CI's job rather than the pipeline's.
#   2. THE TOOLCHAIN is the `[tools]` pin in `mise.toml`
#      (`elixir 1.20.4-otp-29`, `erlang 29.1.1`). CI reads the same pin with
#      `bin/toolchain-pins` into `erlef/setup-beam` and then checks kit's
#      `versions:` input still equals it; here `mise install` materializes the
#      pin and the gate runs under `mise exec`, and the same `--check` runs
#      below. `gate.yml` declares the command as `[mise, run, prime]` for the
#      same reason: `bin/prime`'s first act is `mix`, which exists only under
#      the pinned toolchain.
#   3. NO PATH ENTRIES: no step in `.github/workflows/*.yml` appends to
#      `$GITHUB_PATH`, so `PATHS` below is empty. If a workflow ever gains one,
#      copy it there in the same order.
#
# WHAT THE BACKEND PROVIDES (kit `backends/README.md`): WORKSPACE, GH_TOKEN,
# CI. Anything else this pipeline needs it declares below, and the backend
# materializes it from its own secret store.
set -euo pipefail

# ---------------------------------------------------------------------------
# identity
# ---------------------------------------------------------------------------
# The repository root is derived from this file, not from the caller's cwd. The
# agent resets the checkout to the fetched commit before calling us, and the
# pipeline does the same itself so that a hand-run is identical to a polled one.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
REPO_NAME="$(basename "$REPO_DIR")"

WORKSPACE="${WORKSPACE:-$(cd "$REPO_DIR/../.." && pwd)}"
BRANCH="${CI_BRANCH:-master}"
export CI="${CI:-1}"
export WORKSPACE

log() { printf '\n== %s\n' "$1"; }

log "pipeline: $REPO_NAME at $REPO_DIR"

# The gate CI names. `./bin/prime`, verbatim — see the header.
GATE=(./bin/prime)

# No `echo … >> $GITHUB_PATH` line in `.github/workflows/*.yml` — verified, so
# this stays empty rather than carrying a guess.
PATHS=()

if [ "${#PATHS[@]}" -gt 0 ]; then
  for d in "${PATHS[@]}"; do
    export PATH="$d:$PATH"
  done
fi

# ---------------------------------------------------------------------------
# the database
# ---------------------------------------------------------------------------
# The gate does NOT read `DATABASE_URL` or `TEST_DATABASE_URL`. `mix test` is
# aliased to create+migrate first, and `config/test.exs` points at fixed
# localhost credentials (`postgres`/`postgres`, overridable only through
# `COURIER_DB_OWNER_USER`, `COURIER_DB_OWNER_PASSWORD` and
# `COURIER_APP_DB_PASSWORD`). So the backend's PostgreSQL must answer at
# localhost:5432 with those credentials; until the kit database packet wires
# the fleet names, a gate run that cannot reach postgres fails honestly at
# `ecto.create` — and mapping some other variable onto these credentials here
# would be faking a wiring that does not exist yet.
for var in DATABASE_URL TEST_DATABASE_URL; do
  if [ -z "${!var:-}" ]; then
    echo "pipeline: $var is not set by the backend (the gate does not read it; see above)"
  else
    echo "pipeline: $var is set by the backend (the gate does not read it; see above)"
  fi
done

log "the toolchain the repository pins"
# `mise install` materializes the versions in mise.toml; `mise exec` runs the
# gate under them. When there is no mise, the gate runs on whatever this
# machine ships and dies at `mix: command not found` — reported, not hidden.
if [ -f mise.toml ] && command -v mise >/dev/null 2>&1; then
  mise install
  # The workflow's own check: the pins CI would install must equal mise.toml.
  # Offline and cheap, and it fails here rather than three minutes into deps.
  ./bin/toolchain-pins --check .github/workflows/ci.yml
  GATE=(mise exec -- "${GATE[@]}")
elif [ -f mise.toml ]; then
  echo "pipeline: mise.toml is present and mise is NOT on PATH — the gate runs on the machine's own toolchain"
fi

log "the gate"
# The command is a list, so nothing here is re-parsed.
"${GATE[@]}"

# ---------------------------------------------------------------------------
# ship
# ---------------------------------------------------------------------------
# This tree carries a chart (`chart/Chart.yaml`) but no `bin/publish`, and the
# kit template for one is not vendored here — shipping is not wired on this
# backend yet (the release job's prod build and boot contract stay in the
# workflow). The gate is the whole run until it is. If `bin/publish` ever
# lands, this block ships through it; until then a green gate that also tried
# to push would be a pipeline failing for a reason unrelated to the tree.
if [ "${CI_DRY_RUN:-0}" = "1" ]; then
  log "gate passed; CI_DRY_RUN=1, not shipping"
  exit 0
fi

SHIPPED=""
if [ -f chart/Chart.yaml ] && [ -x bin/publish ]; then
  log "publish image + chart"
  ./bin/publish --service-dir .
  chart_name="$(sed -n 's/^name: *//p' chart/Chart.yaml | head -1)"
  chart_version="$(sed -n 's/^version: *//p' chart/Chart.yaml | head -1)"
  SHIPPED="image+chart ${chart_name}:${chart_version}"
else
  echo "pipeline: no bin/publish in this tree — nothing to publish; the gate is the whole run"
fi

# ---------------------------------------------------------------------------
# the last line a log tail reads
# ---------------------------------------------------------------------------
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$SHIPPED" ]; then
  log "pipeline: shipped $REPO_NAME $SHIPPED at $COMMIT"
else
  log "pipeline: passed $REPO_NAME at $COMMIT (nothing published)"
fi
