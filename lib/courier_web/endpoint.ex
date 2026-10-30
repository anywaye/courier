defmodule CourierWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :courier

  @session_options [
    store: :cookie,
    key: "_courier_key",
    signing_salt: "RHFMuout",
    same_site: "Lax"
  ]


  plug Plug.Static,
    at: "/",
    from: :courier,
    gzip: not code_reloading?,
    only: CourierWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  plug CourierWeb.Plugs.Trace

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :courier
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug CourierWeb.Plugs.ForceSSL

  plug CourierWeb.Plugs.ParseBody,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug CourierWeb.Plugs.Telemetry

  plug CourierWeb.MetricsExporter
  plug CourierWeb.Plugs.ProblemContentType
  plug CourierWeb.Router
end
