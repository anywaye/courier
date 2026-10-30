defmodule Courier.ErrorRelay.Sink.Req do
  @moduledoc """
  The shipped sink: a Sentry envelope POSTed to a GlitchTip instance.


  A DSN is `scheme://public_key:secret_key@host:port/project_id`. GlitchTip's
  envelope endpoint is `POST /api/{project_id}/envelope/` and it authenticates
  with `X-Sentry-Auth: Sentry sentry_version=7, sentry_client=…,
  sentry_key={public_key}`.

  So a DSN is a credential and this module treats it as one: it is parsed in
  `init/1`, the components are kept in the sink's options, and every refusal
  below reports a **symbol** rather than the URL it came from. A relay that logs
  its own DSN puts a GlitchTip write key in a log store, which is the exact leak
  this packet is about — committed by the thing built to prevent it.


  `receive_timeout` is set, and there is exactly one attempt. The same rule the
  collector's exporters follow with `sending_queue: {enabled: false}` and
  `retry_on_failure: {enabled: false}`, for the same reason: a queue is a memory
  leak with a telemetry-shaped trigger, and a retry loop against a dead store is
  a thread waking on a timer for the life of the process, invisible in every
  dashboard because nothing is being recorded. **A lost error is strictly better
  than a growing process.** The store is at-least-once from the reporter's point
  of view only because the reporter retries, and a reporter that has given up
  has bigger problems than one missing crash.

  A 4xx is counted the same as a 5xx, and logged at the same level, on purpose:
  the store rejecting a malformed envelope is a bug in the relay, and the relay
  is going to find out from the counter rather than from a log line somebody
  reads once.
  """

  @behaviour Courier.ErrorRelay.Sink

  require Logger

  @sentry_auth_version "7"
  @client "anywaye-error-relay/1"

  @impl Courier.ErrorRelay.Sink
  def forward(envelope, opts) do
    case target(opts) do
      {:ok, url, headers} ->
        post(url, headers, envelope)

      {:error, reason} ->
        {:error, reason}
    end
  end


  @doc """
  Turn a DSN into the URL and headers the store wants.

  `{:ok, url, headers}` or `{:error, reason}`. The reasons are symbols for the
  reason in the moduledoc: a DSN is a credential, and a parse failure that
  included the string being parsed would put half a write key in a log.

  `http` is accepted and `https` is **not required**, because a self-hoster
  running GlitchTip on the compose network reaches it over plain HTTP and
  refusing that would make the supported deployment the unsupported one. What
  this does *not* do is follow a redirect: `Req` defaults to not following them,
  and a redirect from an error-ingestion endpoint is a way to make the relay
  POST an envelope somewhere else, so the option is stated rather than left to a
  default that could change.
  """
  @spec parse_dsn(String.t()) :: {:ok, String.t(), [{String.t(), String.t()}]} | {:error, atom()}
  def parse_dsn(dsn) when is_binary(dsn) do
    with {:ok, uri} <- URI.new(dsn),
         {:ok, scheme} <- fetch_scheme(uri),
         {:ok, host} <- fetch_host(uri),
         {:ok, key} <- fetch_key(uri),
         {:ok, project} <- fetch_project(uri) do
      url = "#{scheme}://#{host}/api/#{project}/envelope/"

      {:ok, url,
       [
         {"X-Sentry-Auth",
          "Sentry sentry_version=#{@sentry_auth_version}, sentry_client=#{@client}, sentry_key=#{key}"},
         {"Content-Type", "application/x-sentry-envelope"}
       ]}
    end
  end

  def parse_dsn(_other), do: {:error, :dsn_not_a_string}

  defp fetch_scheme(%URI{scheme: scheme}) when is_binary(scheme) and scheme != "",
    do: {:ok, scheme}

  defp fetch_scheme(_uri), do: {:error, :dsn_has_no_scheme}

  defp fetch_host(%URI{host: host} = uri) when is_binary(host) and host != "" do
    {:ok, "#{host}:#{uri.port}"}
  end

  defp fetch_host(_uri), do: {:error, :dsn_has_no_host}

  defp fetch_key(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "" do
    case String.split(userinfo, ":", parts: 2) do
      [key | _rest] when key != "" -> {:ok, key}
      _other -> {:error, :dsn_has_no_key}
    end
  end

  defp fetch_key(_uri), do: {:error, :dsn_has_no_key}

  defp fetch_project(%URI{path: "/" <> project}) when project != "", do: {:ok, project}
  defp fetch_project(_uri), do: {:error, :dsn_has_no_project}


  defp post(url, headers, envelope) do
    case Req.post(url,
           headers: headers,
           body: envelope,
           receive_timeout: 5_000,
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("[error-relay] the store answered #{status}")
        {:error, :store_refused}

      {:error, exception} ->
        Logger.warning("[error-relay] the store is unreachable: #{inspect(exception.__struct__)}")
        {:error, :store_unreachable}
    end
  end

  defp target(opts) do
    case Keyword.get(opts, :sink_dsn) do
      dsn when is_binary(dsn) -> parse_dsn(dsn)
      _absent -> {:error, :no_sink_dsn}
    end
  end
end
