defmodule CourierWeb.HealthController do
  @moduledoc """
  Probe endpoints for orchestrators, load balancers, and humans curling the
  service.

  `healthz` is liveness: it answers as long as this VM can dispatch a request,
  and never touches a dependency. `readyz` is readiness: it answers 503 while
  the service cannot do work, so a deploy can hold traffic back instead of
  serving errors.

  Both sit at the root, outside `/api` (see `CourierWeb.Router`): probes run
  before routing, auth, or any other anywaye service is in play.
  """

  use CourierWeb, :controller

  alias Courier.Health

  @doc """
  Liveness. `200 {"status":"ok"}` whenever the endpoint is dispatching.
  """
  def healthz(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc """
  Readiness. `200 {"status":"ok"}` when the database answers, `503` otherwise.
  """
  def readyz(conn, _params) do
    case Health.ready?() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        # The reason is logged by Courier.Health and deliberately not returned:
        # a probe response is read by orchestrators and, in a public repo,
        # by anyone.
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", checks: %{database: "unavailable"}})
    end
  end
end
