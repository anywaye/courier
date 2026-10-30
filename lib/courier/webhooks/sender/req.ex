defmodule Courier.Webhooks.Sender.Req do
  @moduledoc """
  The sender courier ships: `Req`, one POST, and the spec's headers.

  Three choices in here are the spec's, not Req's defaults:

    * **`redirect: false`.** §Delivery success and failure says a `3xx` is a
      failure and that following redirects "causes unnecessary load on both the
      sender and the receiver, it's therefore recommended to update the webhook
      URL instead". So courier records the redirect as the failure it is. The
      default would be to chase it, which is the one thing the spec asks not to do
      and also the SSRF risk a redirect to `169.254.169.254` would create.
    * **A timeout from configuration.** §Request timeouts asks for 15–30s. A
      webhook that hangs holds a worker that another endpoint could be using, and
      the consumer is told nothing by a courier that never answers them.
    * **The body is a raw binary, not a term to encode.** The spec's warning is
      about exactly this, so the request map has `:body` set to the bytes the
      signature was computed over.

  A transport failure is a value, not an exception. A consumer that is down is
  an ordinary state for a webhook sender, and the delivery pipeline's job is to
  record it and decide whether to try again — not to crash a worker.
  """

  @behaviour Courier.Webhooks.Sender

  require Logger

  alias Courier.Webhooks.Sender
  alias Courier.Webhooks.Signature

  @impl Sender
  def send(request) do
    headers =
      Signature.headers(request.secret, request.msg_id, request.timestamp, request.payload)

    options = [
      method: :post,
      url: request.url,
      headers: Map.merge(headers, %{"content-type" => "application/json"}),
      body: request.payload,
      redirect: false,
      retry: false,
      receive_timeout: timeout_ms(),
      connect_timeout: connect_timeout_ms(),
      decode_body: false,
      decode_json: false
    ]

    started = System.monotonic_time(:millisecond)

    case Req.request(options) do
      {:ok, response} ->
        answered = %Sender.Result{
          success?: response.status in 200..299,
          status_code: response.status,
          duration_ms: System.monotonic_time(:millisecond) - started,
          retry_after_seconds: retry_after(response.headers)
        }

        {:ok, answered}

      {:error, error} ->
        Logger.warning("webhook delivery to #{host(request.url)} failed: #{inspect(error)}")

        {:ok,
         %Sender.Result{
           success?: false,
           status_code: nil,
           duration_ms: System.monotonic_time(:millisecond) - started,
           error: error
         }}
    end
  end

  defp retry_after(headers) do
    case Req.Response.get_header(headers, "retry-after") do
      [value | _rest] ->
        case Integer.parse(value) do
          {seconds, ""} -> seconds
          _not_delta_seconds -> nil
        end

      [] ->
        nil
    end
  end

  defp host(url) do
    URI.parse(url).host
  rescue
    ArgumentError -> "an unparseable url"
  end

  defp timeout_ms, do: config()[:timeout_ms] || 15_000
  defp connect_timeout_ms, do: config()[:connect_timeout_ms] || 5_000

  defp config, do: Application.get_env(:courier, :webhooks, [])
end
