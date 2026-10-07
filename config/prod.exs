import Config

# NO `force_ssl` HERE, AND THE ABSENCE IS THE POINT.
#
# This file used to set compile-time `force_ssl` excluding only
# `localhost`/`127.0.0.1` and the two probes. The launch compose network talks
# courier-to-courier over plain HTTP on a private network, so that redirect
# 307'd every `POST /v1/messages` on a non-localhost peer — verify, reset and
# invitation mail all RED in the site loop-proof.
#
# It cannot be fixed by widening the exclusion list: that is exactly the
# allowlist that keeps rotting. And it cannot be fixed by reading an env var
# here, because `force_ssl` is COMPILE-time endpoint configuration
# (Phoenix.Endpoint: compile-time config "has no effect on config/runtime.exs")
# — a release bakes whatever this file said, whatever the environment holds.
#
# So the redirect lives in `CourierWeb.Plugs.ForceSSL`, enforced per request
# and gated on the `COURIER_FORCE_SSL` runtime opt-in that `config/runtime.exs`
# reads at boot. Genuine prod sets it; everything without it serves plain
# HTTP. The probes stay exempt regardless.
#
# Do not re-add `force_ssl` here: a release would redirect again with no
# signal set, and no test of the plug could see it — the plug's own suite
# reads this file to assert the absence.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
