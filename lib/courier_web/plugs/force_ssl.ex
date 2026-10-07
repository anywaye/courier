defmodule CourierWeb.Plugs.ForceSSL do
  @moduledoc """
  `force_ssl`, gated on a runtime opt-in rather than on a compile-time guess.

  Genuine prod sets `COURIER_FORCE_SSL=true` (read at boot by
  `config/runtime.exs` into `:force_ssl_enabled`); everything without it —
  local compose, the launch tier, CI — serves plain HTTP. No hostname
  allowlist: `config/prod.exs` used to exclude `localhost`/`127.0.0.1`, which
  is exactly the list that kept rotting — the compose stack talks
  courier-to-courier over plain HTTP on a private network, and the redirect
  307'd every `POST /v1/messages` on a non-localhost peer.

  A plug and not `force_ssl:` in `config/prod.exs`, because that key is
  COMPILE-time endpoint configuration (Phoenix.Endpoint: compile-time config
  "may be set on config/dev.exs, config/prod.exs and so on, but has no effect
  on config/runtime.exs"). A release bakes whatever prod.exs said, so no env
  var read at boot could ever switch it — prod.exs therefore says nothing,
  and this plug enforces the redirect per request, gated on the runtime flag.

  The probes stay exempt regardless: `/healthz` and `/readyz` pass through
  even with the signal present, because an orchestrator that gets a redirect
  reads courier as dead.
  """

  @behaviour Plug

  # The probes answer plain HTTP in every environment — an orchestrator that
  # gets a redirect reads courier as dead and stops routing to it. Nothing but
  # the two probes is exempt, and the exemption is by path rather than by
  # host: a peer exclusion list is the allowlist that kept rotting.
  @exempt_paths ["/healthz", "/readyz"]

  def init(opts), do: opts

  def call(conn, _opts) do
    if enabled?() and conn.request_path not in @exempt_paths do
      Plug.SSL.call(conn, Plug.SSL.init(ssl_opts()))
    else
      conn
    end
  end

  @doc """
  Whether the SSL redirect is on. Read off application env — set at boot by
  `config/runtime.exs` from `COURIER_FORCE_SSL` — rather than off the
  environment per request, so tests toggle a value instead of the process's
  surroundings.
  """
  def enabled?, do: Application.get_env(:courier, :force_ssl_enabled, false)

  # `rewrite_on: [:x_forwarded_proto]` because genuine prod sits behind a
  # TLS-terminating proxy (kamal-proxy, Traefik): the container sees plain
  # HTTP either way, and the header is what tells the two apart. The `exclude`
  # repeats the path check above inside the delegated plug, so a future edit
  # that calls `Plug.SSL` without the guard keeps the probes exempt.
  defp ssl_opts do
    [rewrite_on: [:x_forwarded_proto], exclude: [paths: @exempt_paths]]
  end
end
