defmodule CourierWeb.ErrorEnvelopeController do
  @moduledoc """
  The door every service's error path comes through, and the only place a Sentry
  envelope is accepted.

  ## Why this is on its own endpoint and not on `CourierWeb.Router`

  Two reasons, and the second is the one that matters.

  It is **not a customer API operation.** It takes no anywaye principal, it is not
  in `openapi.yaml`, and a generated client should not have it. Putting it on the
  public router would mean either giving it a principal requirement the Sentry SDK
  cannot satisfy — the SDK holds a DSN, not a JWT — or adding a third exclusion to
  `CourierWeb.OpenAPIDocumentTest`'s exclusion list, and the brief is explicit
  that weakening an existing check to make something simpler is not allowed.

  It is **not authenticated the way the rest of courier is.** Everything on
  `/v1` is a caller's request, authenticated by a principal resolved from a bearer
  token, and a wrong answer there is a `401`. This is a machine posting a batch
  of crash reports, authenticated by a shared ingest secret, and a wrong answer
  there is also a `401` but it is a *different* `401` with a different threat
  model: a leaked secret lets somebody fill the error store, not read anybody's
  data. Two authorisation domains, two surfaces, one port each — and the second
  surface is not reachable from the public ingress, which is a deployment
  decision an operator makes rather than a property this module can assert.

  ## What it does with a body it does not like

  It answers `200 {}` and counts a reason. That is not politeness, it is the only
  correct answer: the Sentry SDK retries any non-2xx, so a `400` for a malformed
  envelope means the sender retries a body this relay will never accept, and a
  `500` for a redaction failure means a bug in the redaction boundary becomes a
  retry storm in the service that hit it. The counters in
  `Courier.ErrorRelay.stats/1` are how an operator finds out; the sender's
  experience of a discarded error is silence, which is the correct experience
  for a best-effort store.

  ## Body size is bounded before anything is read

  `max_body_bytes` is enforced in this module rather than left to a `Plug.Parsers`
  limit, because the envelope is **not** a form and not JSON: it is
  newline-delimited binary framing, so the parser pipeline is bypassed entirely
  and `read_body/2` with a `:length` option is the only bound in the path. An
  unbounded read here is an unauthenticated-ish endpoint that a caller can make
  allocate as much memory as it likes, and the ingest secret is a shared secret
  rather than a per-caller credential, so "authenticated" does not mean
  "trusted".
  """

  use CourierWeb, :controller

  require Logger

  alias Courier.ErrorRelay
  alias Courier.ErrorRelay.Sink

  @default_max_body_bytes 1_048_576

  @doc """
  `POST /api/:project_id/envelope/` — one Sentry envelope, in the Sentry protocol.

  `:project_id` is ignored: the relay writes to the one project
  `COURIER_ERROR_SINK_DSN` names, and the id in the path is the framing a Sentry
  SDK cannot be talked out of. See `CourierWeb.ErrorRouter`.
  """
  def create(conn, _params) do
    case read(conn) do
      {:ok, raw, conn} ->
        accept(conn, raw)

      # The three-tuple shape, carrying the connection forward, because
      # `read_body/2` has already read (part of) the body and a controller that
      # answered from the *original* conn would render on a connection whose
      # adapter had already been told the body was sent — a 200 whose body the
      # test adapter never wrote. The first version of this clause matched a
      # two-tuple and the oversized case raised `WithClauseError` from inside
      # `create/2`, which is a 500 on the error path: the one surface that must
      # never fail.
      {:error, reason, conn} ->
        discard(conn, reason)

      {:error, reason} ->
        discard(conn, reason)
    end
  end

  defp accept(conn, raw) do
    case Sink.parse_envelope(raw) do
      {:ok, items} ->
        # A cast. The `200` below is written before anything is forwarded, so a
        # store that is down cannot add a millisecond to a request in another
        # service. See the moduledoc.
        ErrorRelay.ingest(conn.assigns.error_relay, items)
        json(conn, %{})

      {:error, reason} ->
        discard(conn, reason)
    end
  end

  # `200 {}` and a log line, for every reason. Never a non-2xx: see the moduledoc.
  defp discard(conn, reason) do
    Logger.info("[error-relay] discarded an envelope: #{inspect(reason)}")
    json(conn, %{})
  end

  # `read_body/2` with `:length` **truncates** rather than refusing, so the
  # truncation has to be detected: a silently half-read envelope is a real
  # payload that parses into a real event and gets stored missing its stack
  # frames, which looks exactly like a service that stopped reporting file and
  # line. `read_body/2` reports what it actually read, and comparing that with
  # the declared length is the check.
  defp read(conn) do
    max = max_body_bytes(conn)
    declared = content_length(conn)

    if is_integer(declared) and declared > max do
      {:error, :too_large}
    else
      case read_body(conn, length: max, read_length: max) do
        {:ok, raw, conn} ->
          if byte_size(raw) >= max and not is_nil(declared) and declared > max do
            {:error, :too_large}
          else
            {:ok, raw, conn}
          end

        {:more, _partial, conn} ->
          # `:more` is what `read_body/2` returns when the body is longer than
          # `:length`. Discarding is safe: the body is still being streamed and
          # courier has said it will not read it.
          {:error, :too_large, conn}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value] -> parse_length(value)
      _absent_or_repeated -> nil
    end
  end

  defp parse_length(value) do
    case Integer.parse(value) do
      {bytes, ""} when bytes >= 0 -> bytes
      _other -> nil
    end
  end

  defp max_body_bytes(conn) do
    conn.assigns[:error_max_body_bytes] ||
      Application.get_env(:courier, :error_relay_max_body_bytes, @default_max_body_bytes)
  end
end
