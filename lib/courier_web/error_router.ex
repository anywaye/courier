defmodule CourierWeb.ErrorRouter do
  @moduledoc """
  The router for the error-ingestion endpoint. Separate from
  `CourierWeb.Router` on purpose — see `CourierWeb.ErrorEnvelopeController`.

  Two routes, and the second is the one that makes the first safe to expose:

    * `POST /api/:project_id/envelope/` — an envelope, behind the ingest secret.
    * `GET  /internal/v1/errors/healthz` — liveness of the **relay**, not of
      courier. It touches nothing, answers `200` whenever the endpoint is
      dispatching, and deliberately does not check the store: a relay that cannot
      reach GlitchTip has *lost errors*, it is not unhealthy, and a liveness check
      that failed on it would restart courier — taking the notification service
      down with the error store. That is the same reasoning core's
      `probes.schema.json` gives for why `healthz` must consult no dependency,
      applied to the component that most needs it.


  `POST /api/:project_id/envelope/` is not a naming preference. **A Sentry SDK does
  not let you choose an ingest path.** `Sentry.DSN.parse/1` splits the DSN's path,
  pops the last segment off as the project id, and rebuilds the URL as
  `<base>/api/<project_id>/envelope/` — see `deps/sentry/lib/sentry/dsn.ex`,
  `pop_project_id/1`. So a DSN written the way an operator expects,
  `http://<token>@courier:4003/1`, is sent to `/api/1/envelope/`, and the relay
  that served `/internal/v1/errors` would answer `404` to every envelope of the
  very service that hosts it.

  Every client of this relay is an SDK — courier's own, identity's Go SDK,
  billing's sentry-ruby — and taking the SDK's path is what lets all three
  reach it **without a bespoke HTTP client on either side**. That is the relay
  argument in one line: the reporters speak the Sentry protocol unmodified, and
  the only thing courier adds is authentication, redaction and throttling.

  The path is also **symmetric with the relay's own output**.
  `Courier.ErrorRelay.Sink.Req` parses the store DSN into
  `<scheme>://<host>/api/<project_id>/envelope/` and posts there, so the URL that
  comes in is the URL that goes out and the relay is transparent.


  `pop_project_id/1` *splits* the path, so `http://<token>@host/errors/1` derives
  `/errors/api/1/envelope/` — and that path is not served, deliberately. The
  surface is on its own port, published nowhere, and its shape should not be
  whatever a token holder's DSN says it is; a configurable prefix on an ingestion
  surface is a router built from config, for a feature no deployment uses. A
  prefixed DSN gets a `404` and the fix is a character in the operator's DSN, not
  a code change. `CourierWeb.ErrorRelayEndpointTest` holds both halves.


  Worth stating plainly, because it reads like a bug otherwise: the relay does
  **not** route on `:project_id`. All three services report into **one** GlitchTip
  project, named by `COURIER_ERROR_SINK_DSN`, and the id in the path is the
  framing every SDK insists on. Honouring a caller-supplied project id would mean
  either a sink DSN per project or a caller choosing which store its crash lands
  in, and neither is worth a store per service — the thing that separates one
  service's errors from another's is the `error.type` vocabulary and the service
  tag on the event, both of which the relay sets from the envelope itself.


  `core`'s probe contract pins `/healthz` and `/readyz` on the service's own
  endpoint, and this is neither: it is the health of one optional component, on
  its own port, for whoever is watching that port. Keeping it at a courier-shaped
  path rather than under `/api` also means it can never be reached by a
  DSN-derived URL.
  """

  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller

  pipeline :ingest do
    plug :accepts, ["json"]
    plug CourierWeb.Plugs.IngestToken
    plug :put_error_relay
  end

  defp put_error_relay(conn, _opts) do
    case Map.fetch(conn.assigns, :error_relay) do
      {:ok, _relay} ->
        conn

      :error ->
        assign(
          conn,
          :error_relay,
          Application.get_env(:courier, :error_relay_name, Courier.ErrorRelay)
        )
    end
  end

  scope "/internal/v1", CourierWeb do
    get "/errors/healthz", ErrorEnvelopeHealthController, :healthz
  end

  scope "/api", CourierWeb do
    pipe_through :ingest

    post "/:project_id/envelope/", ErrorEnvelopeController, :create
  end
end
