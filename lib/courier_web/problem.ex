defmodule CourierWeb.Problem do
  @moduledoc """
  The error envelope, which is core's and not courier's
  (`core/docs/openapi-conventions.md`, RFC 9457). No service invents its own
  error body, so this module is the one place courier builds one and there is no
  second shape to drift into.

      %{
        "type" => "https://docs.cafaye.com/errors/validation_failed",
        "title" => "Validation failed",
        "status" => 422,
        "detail" => "...",
        "instance" => "/v1/notification_preferences/6f5d...",
        "code" => "validation_failed",
        "trace_id" => "...",
        "errors" => [%{"field" => "preferences[0].notification_type", "code" => "invalid_format"}]
      }

  `type` is the machine-readable contract and `code` is its last segment;
  `title` is a fixed summary for the code and `detail` is specific to this
  occurrence and is not parsed by clients. `trace_id` is always present and
  always matches the `X-Trace-Id` response header, which
  `CourierWeb.Plugs.Trace` sets before the router runs — so it is there for a
  request that matched no route, which is exactly the request support asks
  about.

  `errors` is the per-field list, and it appears only when there is one. The
  `field` is the path in the *request* (`preferences[0].notification_type`), not
  the changeset key: the caller sent a body, and the body is what they can fix.

  ## Codes

  Core's reserved list, plus `bad_request` and `not_acceptable`. Core names the
  reserved list for the statuses it enumerates and says 400 is for malformed
  syntax the client could not have known; it does not name a slug for it, and a
  body that is not JSON at all still needs a stable `code` for the same reason
  every other code is stable. The same is true of 406, which Phoenix's `:accepts`
  plug raises on every request whose `Accept` excludes `json`, and which core
  does not enumerate.

  `not_acceptable` is here because 406 used to fall through to the `:internal`
  default. A client that asked for `text/html` and was answered
  `{"status": 406, "code": "internal", "title": "Internal server error"}` had its
  own `Accept` header reported back to it as courier failing. Core reserves
  `internal` for 500, so a 406 wearing that slug is a lie in the
  machine-readable contract — and it is the kind of lie a generated client turns
  into a retry loop, because "internal" is the one code every client retries.

  **Two of the codes share 409, and core's own reserved list does the same**:
  `conflict` and `idempotency_key_reused` are both listed at 409, and
  `CourierWeb.Plugs.Idempotency` sends each for a different reason. A client
  branches on `code` and not on the status, so the two are distinguishable; the
  consequence to be aware of is only that `for_status/1` cannot recover which of
  them a bare 409 meant, and it is never asked — nothing in Phoenix raises a 409,
  so that function is only ever the fallback for a status that arrived from
  outside a controller.

  Everything else still falls back to `internal`, so an unlisted status answers
  with courier's envelope rather than Phoenix's. `for_status/1` is the seam, and
  every status courier can be made to return has a line in the table above it;
  `test/courier_web/openapi_error_responses_test.exs` is what keeps the two in
  step.
  """

  import Plug.Conn

  @type code :: atom()

  @codes %{
    bad_request: {400, "Bad request"},
    unauthorized: {401, "Unauthorized"},
    forbidden: {403, "Forbidden"},
    not_found: {404, "Not found"},
    not_acceptable: {406, "Not acceptable"},
    conflict: {409, "Conflict"},
    idempotency_key_reused: {409, "Idempotency key reused"},
    unsupported_media_type: {415, "Unsupported media type"},
    validation_failed: {422, "Validation failed"},
    rate_limited: {429, "Rate limited"},
    internal: {500, "Internal server error"},
    unavailable: {503, "Service unavailable"}
  }

  @doc """
  The status and title for `code`, and for a status with no code of its own.
  """
  @spec for_code(code()) :: {pos_integer(), String.t()}
  def for_code(code), do: Map.get(@codes, code, Map.fetch!(@codes, :internal))

  @doc """
  The code for `status`, which is how a request that failed before courier chose
  a code (a malformed body, an unknown route) still gets a stable one.
  """
  @spec for_status(pos_integer()) :: code()
  def for_status(status) do
    Enum.find_value(@codes, :internal, fn {code, {mapped, _title}} ->
      if mapped == status, do: code
    end)
  end

  @doc """
  Builds the envelope for a request.

  `assigns` is `conn.assigns` — which is where `CourierWeb.Plugs.Trace` put the
  trace id and the path, and it is also what `CourierWeb.ErrorJSON` is handed
  when Phoenix renders an error the request never reached a controller for. One
  argument, two callers, one shape.
  """
  @spec build(map(), pos_integer(), code(), String.t(), [map()]) :: map()
  def build(assigns, status, code, detail, fields \\ []) do
    {_status, title} = for_code(code)

    %{
      "type" => "https://docs.cafaye.com/errors/#{code}",
      "title" => title,
      "status" => status,
      "detail" => detail,
      "instance" => assigns[:instance],
      "code" => code,
      "trace_id" => assigns[:trace_id]
    }
    |> put_fields(fields)
  end

  @doc """
  Sends the envelope as `application/problem+json` and halts nothing: the
  caller decides, because a controller action that has already replied has
  nothing left to do.
  """
  @spec send(Plug.Conn.t(), pos_integer(), code(), String.t(), [map()]) :: Plug.Conn.t()
  def send(conn, status, code, detail, fields \\ []) do
    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, Jason.encode!(build(conn.assigns, status, code, detail, fields)))
  end

  # Core: `errors[]` appears only when there are per-field failures to list.
  defp put_fields(envelope, []), do: envelope
  defp put_fields(envelope, fields), do: Map.put(envelope, "errors", fields)
end
