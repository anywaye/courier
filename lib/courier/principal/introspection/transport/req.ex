defmodule Courier.Principal.Introspection.Transport.Req do
  @moduledoc """
  The transport that ships: `POST /v1/introspections` over `Req`.


    * `retry: false` — **one attempt, no retry.** Introspection is on the request
      path of every authenticated call, so a retry loop here is a retry loop on the
      hot path of the whole API, and `Req`'s default is to retry idempotent
      requests on a dropped connection. This one is not idempotent from identity's
      side: it records a `last_used_at` touch on the credential. The caller is the
      retry policy here, and it already has one — a 503 with the same token.
    * `redirect: false` and `max_redirects: 0` — stated rather than left to a
      default, and belt and braces on the same property. A redirect from an
      authentication endpoint is a way to make courier send a credential
      somewhere else, and `Courier.ErrorRelay.Sink.Req` refuses them for the same
      reason.
    * `receive_timeout: 2_000` — identity's answer is one indexed lookup on a
      hashed token, so 2s is generous; what it is really bounding is how long a
      Bandit connection is held by a dependency that is not answering. Past that
      the caller gets a 503 and retries, which is the cheaper outcome for both
      sides.
    * `decode_body: false` — courier decodes the answer itself, in
      `Courier.Principal.Introspection.Document`. See the comment at the call site.


  Every `{:error, reason}` below is a **symbol**, and every `Logger` line names
  the status or the symbol rather than the request. The caller's token is in the
  body and courier's is in the header, so a reason string built from either would
  put a customer's credential or a service credential in a log store — which is
  the leak `Courier.ErrorRelay` exists to prevent, committed by the thing
  authenticating the caller. `test/courier/principal/introspection_test.exs`
  captures real log output and asserts both are absent.
  """

  @behaviour Courier.Principal.Introspection.Transport

  require Logger

  @receive_timeout_ms 2_000

  @impl Courier.Principal.Introspection.Transport
  def post(url, headers, body) do
    options =
      Keyword.merge(req_options(),
        headers: headers,
        body: body,
        receive_timeout: @receive_timeout_ms,
        retry: false,
        redirect: false,
        max_redirects: 0,
        decode_body: false
      )

    case Req.post(url, options) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, status, to_string(response_body)}

      {:error, exception} ->
        Logger.warning("[principal] identity is unreachable: #{inspect(exception.__struct__)}")

        {:error, :unreachable}
    end
  end

  @doc """
  Req options for the introspection call, from `:introspection_req_options`.

  Empty in every environment but test. Exposed rather than read inline so a reader
  can see that nothing else reaches this call.
  """
  @spec req_options() :: keyword()
  def req_options, do: Application.get_env(:courier, :introspection_req_options, [])

  @doc """
  The dial timeout, in milliseconds, so a test can assert the number rather than
  the fact that one exists.
  """
  def receive_timeout_ms, do: @receive_timeout_ms
end
