defmodule CourierWeb.ErrorEndpoint do
  @moduledoc """
  A second Phoenix endpoint, on its own port, serving `CourierWeb.ErrorRouter`.


  The error path carries a **shared ingest secret**, not a caller's bearer token,
  and that difference is a deployment boundary rather than a code detail:

    * The public endpoint is what a customer's ingress publishes. The error
      endpoint is not — it listens on the compose network and nowhere else, so a
      self-hosting customer's load balancer never routes to it. That is
      configuration, but it is configuration that can only exist if the surface is
      a separate listener, and a separate listener is a separate `Endpoint`.
    * The two have different blast radii. A bug on the public endpoint is courier
      not sending mail. A bug that put the ingest surface on the public port would
      be anybody holding a leaked shared secret writing to the error store at the
      rate they liked, with no per-caller identity to rate-limit against.
    * A body limit on the ingest surface is a memory bound on an endpoint that
      accepts a caller-chosen amount of binary. It should not share a listener
      with the one that has to stay available.

  `CourierWeb.Endpoint` is untouched. Its config, its probes, its `force_ssl`
  exclusions and its `openapi.yaml` all continue to describe the customer API,
  and `CourierWeb.OpenAPIDocumentTest` — which holds the router and the document
  to each other in both directions — is not weakened, extended or excepted by
  anything here. That was the deciding consideration: the alternative was a third
  entry in that test's exclusion list, and the brief is explicit that an existing
  check does not get relaxed to accommodate new code.


  A Sentry envelope is newline-delimited binary framing, not a form and not JSON,
  and it is read with `read_body/2` in `CourierWeb.ErrorEnvelopeController`. If
  `Plug.Parsers` ran first it would have already consumed the body, and the
  controller would read an empty one — so the parsers are absent rather than
  configured to pass this content type through. `Plug.Conn.read_body/2` is
  idempotent about nothing, which is why a pipeline that both parses and reads has
  to be designed so only one of them reads.

  `Plug.Session` is absent for the same kind of reason: nothing on this surface
  has a user, and a session cookie on an ingestion endpoint is a credential with
  no owner. `CourierWeb.Plugs.Trace` **is** present, because an error report about
  the error path needs the same trace id as everything else in the process.
  """

  use Phoenix.Endpoint, otp_app: :courier

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :error_endpoint]
  plug CourierWeb.Plugs.Trace
  plug Plug.Head
  plug CourierWeb.ErrorRouter
end
