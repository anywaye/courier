defmodule CourierWeb.ErrorEnvelopeHealthController do
  @moduledoc """
  Liveness of the error relay, and nothing else.


  It answers `200 {"status":"ok"}` whenever this endpoint is dispatching. It does
  not check GlitchTip, the database, the queue depth, or the throttle table.

  A relay that cannot reach its store has **lost errors**. It is not unhealthy,
  and it is certainly not *this process's* health: courier's job is sending mail,
  and restarting courier because the error store is down converts an observability
  outage into a notification outage, which is the exact trade every health check
  in this platform refuses to make. Core's `probes.schema.json` says the same
  thing about `/healthz` on the main endpoint and constrains `checks` to
  `maxItems: 0` so a declaration cannot quietly give liveness a dependency.


  `Courier.ErrorRelay.stats/1` — `forwarded`, `throttled`, `queue_full`,
  `sink_failures`, `unclassified`. A relay that is up and dropping everything has
  `forwarded` flat and `queue_full` or `sink_failures` climbing, which is a
  diagnosable state. A relay that restarts itself has no counter at all, which is
  a different diagnosable state. A liveness probe that answered `503` for the
  first would produce neither, and would take courier down while doing it.

  There is no `/readyz` on this router, and the absence is deliberate: a readiness
  check here would be a *traffic* signal, and there is no traffic to withhold —
  nothing routes to the error endpoint for its own sake. Envelopes arriving during
  a store outage are dropped and counted, which is the correct behaviour for a
  best-effort sink and not something a load balancer needs to know about.
  """

  use CourierWeb, :controller

  @doc "`200 {\"status\":\"ok\"}` whenever the error endpoint is dispatching."
  def healthz(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
