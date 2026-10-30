defmodule CourierWeb.InboundController do
  @moduledoc """
  `POST /inbound/resend` — the surface `Courier.Suppressions.ingest/1` was written
  for and had no caller.


  `Courier.Suppressions.ingest/1` was written, tested, and documented as "the HTTP
  surface's entry point" — and nothing called it. The suppression table was
  therefore written by nothing but tests, permanently empty in production, and a
  customer whose address hard-bounced went on being mailed forever. That is how a
  sending domain's reputation dies, killed by the list meant to prevent it. This
  controller is the missing caller.


      1. Courier.Inbound.Signature   is this POST really from the provider?
      2. Courier.Inbound.Resend      what does this provider's JSON mean?
      3. Courier.InboundReports      what does courier do about it?

  Step 1 does not return `:ok` until the signature matches, and step 2 is only
  reached then. **An unauthenticated body never reaches a decoder**: not
  `Courier.Inbound.Resend`, and not `Plug.Parsers` either, which is an endpoint
  plug and would otherwise have decoded every body on this route before the
  signature was checked. `CourierWeb.Plugs.ParseBody` skips the paths
  `CourierWeb.Router.signed_body_paths/0` names for exactly that reason.

  The obvious way to write this action is `Courier.Inbound.handle/5`, and it is
  the right function for a caller with no HTTP surface. This one is not that
  caller: a route has to answer **three different statuses for the three
  refusals** — an unauthenticated request is a 401, a payload courier cannot
  classify is a 422, and courier's own misconfiguration is a 500 — and `handle/5`
  returns one `{:error, reason}` for all of them. The two steps are therefore
  called here, in the order `handle/5` documents, so the route can tell them
  apart without pattern-matching on a private reason list.


  | outcome | status | `code` | the provider should |
  | --- | --- | --- | --- |
  | verified, and courier acted | 200 | — | stop |
  | verified, and this report is a repeat | 200 | — (`duplicates`) | stop |
  | the signature did not verify | 401 | `unauthorized` | **stop** — a retry with the same bytes fails again |
  | the body is not JSON | 400 | `bad_request` | stop |
  | courier cannot classify the report | 422 | `validation_failed` | stop, and read `errors[]` |
  | courier has no signing secret configured | 500 | `internal` | retry — this one is courier's |

  **An unauthenticated request is a 401 and not a 400**, even when the body is
  also malformed. A 400 is core's status for "malformed syntax the client could
  not have known", and this provider's syntax is not something the sender chooses
  — and answering 400 for a forged body would tell whoever is forging them that
  courier decoded it. Verification comes first, so an unsigned malformed body is
  the same 401 as an unsigned valid one.

  **A report courier cannot classify is a 422 and not a 200.** A 200 would be
  courier claiming it did something with a report it could not read, which is the
  silence `Courier.Inbound.Resend`'s moduledoc refuses. A 422 tells the provider
  courier understood the request and will not act on it, and `errors[]` names the
  field — the one place a provider can read that without parsing prose.

  **`:invalid_secret` is a 500 and not a 401**, and this is the one that reads
  like a detail. `Courier.Inbound.Signature`'s moduledoc raises the objection
  directly: a route answering 500 to a misconfigured secret is indistinguishable
  from one under attack, "and the operator's first question would be the wrong
  one". So the two are told apart by status. A secret courier does not have is
  courier's own defect, it is logged with the variable to set, and the 401 stays
  available for the case it is actually for. `config/runtime.exs` refuses to boot
  a production courier without it, so this is a deployment that went wrong after
  boot rather than one that got that far.


  Neither the counts nor any refusal carries an address, and the reason is
  `POST /v1/messages`'s: `email_suppressions` has no `account_id`, so a response
  quoting an address is a way to ask courier questions about mailboxes it holds,
  and the table is not exposed through any route at all. The one place a
  suppressed address may appear is courier's own logs, which is why the log lines
  here name the value `Courier.Inbound.Resend` put in the refusal.


  A provider retries a webhook it did not get an answer for, and that is normal
  rather than an error. The deduplication that answers it is
  `email_suppressions`'s unique index on `(provider, provider_event_id)`, which
  `Courier.Inbound.Resend` derives from the report's own content — so a redelivery
  is a 200 saying `duplicates: 1` and writes nothing. The `webhook-id` header
  would be a worse key, and `Courier.InboundReports` says why at length. And
  `CourierWeb.Plugs.Idempotency` is scoped to a principal, which this route has
  none of by design.


  `max_body_bytes/0` bounds what courier reads before verifying, because this is
  an unauthenticated endpoint and an unbounded read is a denial of service
  handed to whoever finds the URL. Every provider report courier accepts is a few
  kilobytes, so the bound is generous for the report and small enough to be
  cheap.
  """

  use CourierWeb, :controller

  require Logger

  alias Courier.Inbound.Resend
  alias Courier.Inbound.Signature
  alias Courier.InboundConfig
  alias Courier.InboundReports, as: Reports
  alias CourierWeb.Problem

  @max_body_bytes 1_048_576

  @doc """
  The body size this route will read before it verifies, in bytes.

  Public because the test that pads a body over it needs the number and a test
  that hard-codes 1_048_576 would be asserting against a copy.
  """
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Takes one provider report, or says exactly why it was refused.
  """
  def create(conn, _params) do
    case signing_secret(conn) do
      {:ok, secret} -> verify(conn, secret)
      {:error, :no_signing_secret} -> not_configured(conn)
    end
  end

  defp verify(conn, secret) do
    case with_body(conn) do
      {:ok, body, conn} -> authenticated(conn, body, secret)
      {:error, :body_too_large} -> body_too_large(conn)
      {:error, {:unreadable_body, reason}} -> unreadable(conn, reason)
    end
  end

  defp authenticated(conn, body, secret) do
    case Signature.verify(body, headers(conn), secret) do
      :ok -> record(conn, body)
      {:error, :invalid_secret} -> not_configured(conn)
      {:error, reason} -> not_authentic(conn, reason)
    end
  end

  defp with_body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :body_too_large}
      {:error, reason} -> {:error, {:unreadable_body, reason}}
    end
  end

  defp headers(conn) do
    Enum.into(conn.req_headers, %{}, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp signing_secret(conn) do
    case InboundConfig.secret(conn.assigns[:inbound_provider]) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _unusable -> {:error, :no_signing_secret}
    end
  end

  defp record(conn, body) do
    case Resend.parse(body) do
      {:ok, events} -> ingest(conn, events)
      {:error, reason} -> unclassifiable(conn, body, reason)
    end
  end

  defp ingest(conn, events) do
    case Reports.record_all(events) do
      {:ok, counts} ->
        json(conn, %{data: counts})

      {:error, reason} ->
        not_recorded(conn, reason)
    end
  end


  defp not_authentic(conn, reason) do
    Logger.warning("inbound report refused, not authentic: #{inspect(reason)}")

    Problem.send(
      conn,
      401,
      :unauthorized,
      "This request did not carry a valid provider signature, so courier did not " <>
        "read it. " <> reason_detail(reason)
    )
  end

  defp reason_detail(:timestamp_out_of_tolerance) do
    "A signature outside courier's replay window is refused even if it is " <>
      "correct, so a report older than that window is not acted on."
  end

  defp reason_detail({:missing_header, name}) do
    "The header #{inspect(name)} is missing."
  end

  defp reason_detail(:malformed_id), do: "The message id header is malformed."
  defp reason_detail(:malformed_timestamp), do: "The timestamp header is not a bare integer."
  defp reason_detail(:signature_mismatch), do: "The signature does not match the body received."
  defp reason_detail(_other), do: ""

  defp not_configured(conn) do
    Logger.error(
      "inbound report refused: this courier has no signing secret configured for the " <>
        "provider that signed it. See COURIER_INBOUND_RESEND_SECRET."
    )

    Problem.send(
      conn,
      500,
      :internal,
      "courier has no signing secret configured for this provider, so it cannot " <>
        "authenticate the request. This is courier's own configuration, not the " <>
        "provider's. See COURIER_INBOUND_RESEND_SECRET."
    )
  end

  defp unreadable(conn, reason) do
    Logger.warning("inbound report refused, the body could not be read: #{inspect(reason)}")

    Problem.send(
      conn,
      400,
      :bad_request,
      "The request body could not be read, so it was not authenticated and nothing " <>
        "was recorded."
    )
  end

  defp body_too_large(conn) do
    Problem.send(
      conn,
      400,
      :bad_request,
      "The request body is larger than courier will read, so it was not authenticated " <>
        "and nothing was recorded."
    )
  end

  defp unclassifiable(conn, body, reason) do
    Logger.warning(
      "inbound report refused, courier cannot act on it: " <>
        "#{describe(reason)}; event type #{inspect(event_type(body))}"
    )

    case status_for(reason) do
      400 ->
        unreadable_json(conn, reason)

      422 ->
        Problem.send(
          conn,
          422,
          :validation_failed,
          "courier could not act on this report. " <> summarise(reason),
          [error_field(reason)]
        )
    end
  end

  defp status_for(:invalid_json), do: 400
  defp status_for(:invalid_payload), do: 400
  defp status_for(_semantically_wrong), do: 422

  defp unreadable_json(conn, :invalid_payload) do
    Problem.send(
      conn,
      400,
      :bad_request,
      "The body is not a JSON object, so there was nothing in it courier could read. " <>
        "Nothing was recorded."
    )
  end

  defp unreadable_json(conn, _reason) do
    Problem.send(
      conn,
      400,
      :bad_request,
      "The body is not valid JSON, so courier could not read it. Nothing was recorded."
    )
  end

  defp event_type(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => type}} when is_binary(type) -> type
      _other -> "unknown"
    end
  end

  defp describe(:unsupported_event) do
    "It is an event type courier has not read, and courier does not act on an event " <>
      "it cannot classify."
  end

  defp describe({:unknown_bounce_type, value}) do
    "Its bounce type #{inspect(value)} is not one of the types courier has read."
  end

  defp describe({:invalid_recipient, address}) do
    "One of the addresses it names, #{inspect(address)}, is not an address courier " <>
      "could send to."
  end

  defp describe({:missing_field, field}) do
    "It has no #{inspect(to_string(field))}, and courier cannot act on a report " <>
      "without one."
  end

  defp describe({:invalid_field, field}) do
    "Its #{inspect(to_string(field))} is not the shape courier reads."
  end

  defp describe(:invalid_payload) do
    "It is not a JSON object, so there is nothing in it courier can read."
  end

  defp describe(reason), do: "The reason is #{inspect(reason)}."

  defp summarise({:invalid_recipient, _address}) do
    "One of the addresses it names is not an address courier could send to."
  end

  defp summarise(reason), do: describe(reason)

  defp error_field({:unknown_bounce_type, _value}),
    do: %{"field" => "bounce", "code" => "unknown_bounce_type"}

  defp error_field(:unsupported_event), do: %{"field" => "type", "code" => "unsupported_event"}

  defp error_field({:invalid_recipient, _a}),
    do: %{"field" => "to", "code" => "invalid_recipient"}

  defp error_field({:missing_field, field}) do
    %{"field" => to_string(field), "code" => "required"}
  end

  defp error_field({:invalid_field, field}) do
    %{"field" => to_string(field), "code" => "invalid_format"}
  end

  defp error_field(_other), do: %{"field" => "type", "code" => "invalid_format"}

  defp not_recorded(conn, reason) do
    Logger.error(
      "inbound report could not be recorded, and nothing was written: #{inspect(reason)}"
    )

    Problem.send(
      conn,
      503,
      :unavailable,
      "courier could not record this report, so nothing was written and no event was " <>
        "published. The report is safe to retry: delivery is at-least-once and the " <>
        "same report recorded twice is one row."
    )
  end
end
