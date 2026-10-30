defmodule Courier.MailerAdapter do
  @moduledoc """
  courier's provider adapter, and the refusal that makes the wrong one unreachable.

  A buyer installs courier, sets their SMTP credentials, sends a notification,
  and it arrives. That sentence was not true before this module existed:
  `Swoosh.Adapters.Local` renders a message into memory and returns a
  provider-shaped id without opening a socket, so a released courier accepted
  every send and mailed nobody. No error, no warning, no email — the worst
  failure a paid product can have, because it looks like success.


  The brief offered three ways to stop the silent default:

    1. **refuse to boot in `:prod`** when the adapter is unset or `Local`
    2. **log a loud warning** at boot
    3. **make the adapter required config with no default**

  This is **(1) with (3) underneath it**, and the reasoning is the asymmetry
  between the failure and the fix. A courier running that cannot send is
  accepting work, recording outbox rows, and publishing `delivered` events for
  mail that was never delivered. Every downstream consumer of those events
  believes a person was told something. A warning does not stop that: it is one
  line in a log nobody reads, and the deployment looks healthy in the dashboard
  that matters. A refusal at boot is a deploy that visibly fails, which is the
  cheapest possible incident — it is caught before the first customer mail, not
  after a support ticket.

  **(3) is what makes (1) enforceable.** An adapter with no default is a
  deployment that cannot start unless somebody chose one, so "refuse to boot" is
  not a special case bolted on; it is the ordinary behaviour of a required
  setting. The prod path below therefore has no `Local` fallback to remove
  later — there is nothing there to remove.


  Everything is read from the environment by `config/runtime.exs`, which is the
  only place that runs in a release before the application starts. The rule
  follows `COURIER_OTEL_ENDPOINT` (core D16): `<SERVICE>_<THING>`, read at boot,
  required rather than defaulted where a default would be a working-but-wrong
  configuration.

      COURIER_MAIL_ADAPTER        smtp | postmark | cloudflare — the adapters that reach a
                                  provider
      COURIER_SMTP_HOST           required when the adapter is smtp
      COURIER_SMTP_PORT           default 587, the submission port
      COURIER_SMTP_USERNAME       required unless COURIER_SMTP_AUTH is `never`
      COURIER_SMTP_PASSWORD       required unless COURIER_SMTP_AUTH is `never`
      COURIER_SMTP_AUTH           always (default) | never | if_available
      COURIER_SMTP_TLS            always (default) | never | if_available
      COURIER_SMTP_SSL            false (default); true for implicit TLS on 465
      COURIER_POSTMARK_API_TOKEN  required when the adapter is postmark
      COURIER_CLOUDFLARE_API_KEY  required when the adapter is cloudflare —
                                   the Cloudflare API token (Email Sending:
                                   Edit) the sending API authenticates with
      COURIER_CF_ACCOUNT_ID       required when the adapter is cloudflare —
                                   the Cloudflare account id that owns the
                                   sending domain


  `describe/1` is the only function in courier that renders adapter
  configuration for a human, and it prints the host, the port and whether auth is
  on for SMTP — never the username and never the password — and for Postmark the
  provider and whether its token is set, never the token. Each provider's builder
  is what the configuration actually receives; `describe/1` is what a startup
  line gets. They are separate functions precisely so that a change to one cannot
  leak into the other, and `test/courier/mailer_adapter_credentials_test.exs`
  asserts the credential is absent from a captured log rather than trusting this
  comment.


  `providers()` is the one table a third provider is added to. Each entry names
  the Swoosh adapter module, the Swoosh HTTP client it posts through (or `nil`
  for one that speaks its own protocol), a builder that reads that provider's
  variables, and a describer for the startup line. `adapter!/1` and `describe/1`
  look the table up; neither has a per-provider branch, so a third provider is an
  entry here plus two functions rather than a fourth branch in the case.
  """

  @default_port 587

  @silent_adapters [Swoosh.Adapters.Local, Swoosh.Adapters.Test]

  @doc "The adapters that cannot deliver. Asserted directly by the test file."
  @spec silent_adapters() :: [module()]
  def silent_adapters, do: @silent_adapters

  @doc "The default SMTP submission port."
  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @doc """
  The Swoosh HTTP client the named adapter posts through, or `nil` for one that
  speaks its own protocol.

  `config/runtime.exs` reads this to decide whether to turn Swoosh's HTTP
  client on. SMTP dials `gen_smtp` directly and never calls it, so leaving it
  off keeps a dependency courier does not use out of the release; Postmark
  posts through `Swoosh.ApiClient.Req`, and a deployment that forgot this
  would boot with the adapter configured and the client dark.
  """
  @spec api_client(module() | nil) :: module() | nil
  def api_client(adapter) do
    case Enum.find(providers(), fn {_, module, _, _, _, _} -> module == adapter end) do
      {_, _, api_client, _, _, _} -> api_client
      nil -> nil
    end
  end

  @doc """
  The `Swoosh` adapter configuration courier runs with, read from the
  environment.

  Returns a keyword list suitable for
  `config :courier, Courier.Mailer, <that list>`.


  Raises when the adapter is unset, or names one that cannot deliver. Both are
  refused rather than defaulted, and the messages say what to do:

    * unset — "`COURIER_MAIL_ADAPTER` is missing" with the value to set.
    * silent — names the adapter and says it never opens a socket.

  A silent adapter is refused in EVERY environment, including `:dev`. That is
  deliberate and it is the one place this module goes past the brief: dev is
  where a courier is usually pointed at `Local` and a developer who then proves
  to themselves that "it works". The escape hatch is `COURIER_MAIL_ADAPTER=none`,
  which is explicit, greppable, and impossible to reach by forgetting a variable.
  """
  @spec adapter!(atom()) :: keyword()
  def adapter!(env \\ config_env()) do
    name = env_string("COURIER_MAIL_ADAPTER")

    case name do
      nil ->
        raise """
        COURIER_MAIL_ADAPTER is missing, and courier will not pick one for you.

        courier sends transactional email for the platform, so the adapter is a
        deployment decision rather than a code change. Without one this process
        would start, accept every send, and deliver nothing.

        Set it to one of:

            COURIER_MAIL_ADAPTER=smtp
            COURIER_SMTP_HOST=smtp.your-provider.com

            COURIER_MAIL_ADAPTER=postmark
            COURIER_POSTMARK_API_TOKEN=...

            COURIER_MAIL_ADAPTER=cloudflare
            COURIER_CLOUDFLARE_API_KEY=...

        `none` is accepted in development only, and means "render into memory and
        open no socket" — see Courier.MailerAdapter.
        """

      "none" when env == :prod ->
        raise """
        COURIER_MAIL_ADAPTER=none is not permitted in production.

        `none` is the Local adapter: it renders a message into memory, returns a
        provider-shaped id, and opens no socket. A courier configured with it
        reports every send as delivered and mails nobody.

        Set COURIER_MAIL_ADAPTER=smtp and the COURIER_SMTP_* variables.
        """

      "none" ->
        [adapter: Swoosh.Adapters.Local]

      other ->
        case Enum.find(providers(), fn {provider, _, _, _, _, _} ->
               to_string(provider) == other
             end) do
          nil ->
            raise """
            COURIER_MAIL_ADAPTER=

            Supported values:

                none    Local, development only. Refused in production.

            See Courier.MailerAdapter.
            """

          {_, _, _, _, build, _describe} ->
            build.()
        end
    end
  end

  @doc """
  Whether `adapter` is one courier can actually deliver through.

  The answer for `:prod` is a hard no for anything in `silent_adapters/0`, which
  is the property `Courier.Application` checks before it starts.
  """
  @spec deliverable?(module() | nil) :: boolean()
  def deliverable?(nil), do: false

  def deliverable?(adapter) do
    Code.ensure_loaded?(adapter) and adapter not in @silent_adapters
  end

  @doc """
  The second gate: refuse to start when the EFFECTIVE adapter cannot deliver.

  Called from `Courier.Application.start/2`, before any child is started. It reads
  `Application.get_env(:courier, Courier.Mailer)` — what courier will actually
  send through — rather than the environment, so it judges the outcome rather than
  the intent.


  `adapter!/1` runs in `config/runtime.exs` and raises on an unset or silent
  adapter named in the environment. That is the earlier refusal and on its own it
  is sufficient. This one catches what that cannot see: an adapter set in a
  committed `config/*.exs` rather than from the environment, which is exactly
  what this repository shipped (`adapter: Swoosh.Adapters.Local` in
  `config/dev.exs` and in `runtime.exs`), and a release built from a tree where
  somebody has configured the silent adapter directly.


  Test configures `Swoosh.Adapters.Test` on purpose — it is the right adapter for
  a suite, and `assert_email_sent/1` depends on it. A check that fired in every
  environment would mean the suite could never use it. The refusal is therefore
  scoped to production, and `MailerAdapterTest` asserts both halves: that `:prod`
  refuses the silent adapters and that `:test` does not.
  """
  @spec verify_boot!(atom()) :: :ok
  def verify_boot!(env \\ config_env()) do
    adapter = Application.get_env(:courier, Courier.Mailer, []) |> Keyword.get(:adapter)

    if env == :prod and not deliverable?(adapter) do
      raise """
      courier refuses to start:

      A courier that cannot send is worse than one that will not start. Running
      anyway means every send reports a message id, every send writes an outbox
      row, and every send publishes a `delivered` event — for mail that was never
      delivered. Downstream consumers of those events believe a person was told
      something.

      Set the environment and courier will resolve the adapter for you:

          COURIER_MAIL_ADAPTER=smtp
          COURIER_SMTP_HOST=smtp.your-provider.com
          COURIER_SMTP_USERNAME=...
          COURIER_SMTP_PASSWORD=...

      Or set COURIER_MAIL_ADAPTER=none to run with mail rendered into memory and
      no socket opened — never in production.

      See Courier.MailerAdapter.
      """
    end

    :ok
  end

  @doc """
  A one-line description of the adapter for a startup log.


  This is the function that exists so an operator can confirm which relay courier
  is pointed at without reading a config file. A username is left out too, and
  for the same reason: at SMTP a "username" is very often the API key, which is
  the credential. What is printed is the host, the port, and whether
  authentication is on — enough to tell two deployments apart, none of which is a
  secret.
  """
  @spec describe(keyword()) :: String.t()
  def describe(config) do
    case Keyword.fetch(config, :adapter) do
      {:ok, nil} ->
        "adapter=none"

      {:ok, adapter} ->
        case Enum.find(providers(), fn {_, module, _, _, _, _} -> module == adapter end) do
          {_, _, _, _, _, describe} -> describe.(config)
          nil -> "adapter=#{inspect(adapter)}"
        end

      :error ->
        "adapter=unset"
    end
  end


  defp describe_smtp(config) do
    "adapter=smtp host=#{Keyword.get(config, :relay, "?")} " <>
      "port=#{Keyword.get(config, :port, @default_port)} " <>
      "auth=#{Keyword.get(config, :auth, :always)}"
  end

  defp describe_postmark(config) do
    token = if Keyword.get(config, :api_key), do: "set", else: "unset"

    "adapter=postmark token=#{token}"
  end

  defp describe_cloudflare(config) do
    token = if Keyword.get(config, :api_key), do: "set", else: "unset"
    account = if Keyword.get(config, :account_id), do: "set", else: "unset"

    "adapter=cloudflare token=#{token} account_id=#{account}"
  end

  defp supported_values do
    providers()
    |> Enum.map(fn {name, module, _api_client, blurb, _build, _describe} ->
      "#{name}  #{inspect(module)} — #{blurb}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  The Swoosh adapter configuration for SMTP, read from the environment.

  Private-ish but public so a test can assert on the shape without going through
  `adapter!/1` and its refusal: `adapter!/1` is the only caller in production and
  this is what it delegates to.

  Takes no environment argument, and the first draft threaded one through seven
  private functions that never read it. That is worse than a missing parameter —
  a parameter that looks like input and is not is a reader's assumption that will
  be wrong. `adapter!/1` takes one because it genuinely branches on `:prod` (to
  refuse `none`); this does not, so it does not take one.
  """
  @spec smtp_adapter() :: keyword()
  def smtp_adapter do
    relay = required!("COURIER_SMTP_HOST", "smtp")
    port = port()
    tls_value = tls()
    ssl_value = ssl()
    auth = auth()
    credentials = credentials(auth)

    tls_options =
      [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(relay),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]

    base =
      [adapter: Swoosh.Adapters.SMTP, relay: relay, port: port, auth: auth] ++
        credentials ++
        [tls: tls_value, ssl: ssl_value]

    cond do
      ssl_value ->
        base ++ [sockopts: tls_options]

      tls_value == :never ->
        base

      true ->
        base ++ [tls_options: tls_options]
    end
  end

  @doc """
  The Swoosh adapter configuration for Postmark, read from the environment.

  Public for the same reason `smtp_adapter/0` is: `adapter!/1` is the only
  caller in production, and a test asserts on the shape without going through
  the refusal. One variable, required rather than defaulted — a default token
  would be a credential in version control that every deployment which forgot
  to set one would send mail under.
  """
  @spec postmark_adapter() :: keyword()
  def postmark_adapter do
    [
      adapter: Swoosh.Adapters.Postmark,
      api_key: required!("COURIER_POSTMARK_API_TOKEN", "postmark")
    ]
  end

  @doc """
  The Swoosh adapter configuration for Cloudflare Email, read from the
  environment.

  Public for the same reason `smtp_adapter/0` and `postmark_adapter/0` are:
  `adapter!/1` is the only caller in production, and a test asserts on the
  shape without going through the refusal. One variable, required rather than
  defaulted — a default key would be a credential in version control that
  every deployment which forgot to set one would send mail under.

  The adapter module is courier's own (`Courier.Adapters.CloudflareEmail`),
  not a Swoosh one: Swoosh ships no Cloudflare adapter, and the sending
  half of a Cloudflare Email connection is Cloudflare's own Email Sending
  REST API (`api.cloudflare.com`). See that module for the contract.
  """
  @spec cloudflare_adapter() :: keyword()
  def cloudflare_adapter do
    [
      adapter: Courier.Adapters.CloudflareEmail,
      api_key: required!("COURIER_CLOUDFLARE_API_KEY", "cloudflare"),
      account_id: required!("COURIER_CF_ACCOUNT_ID", "cloudflare")
    ]
  end

  defp providers do
    [
      {:smtp, Swoosh.Adapters.SMTP, nil,
       "the universal one — every serious provider (SES, Postmark, Mailgun, SendGrid, Resend) speaks SMTP or has an SMTP front",
       &smtp_adapter/0, &describe_smtp/1},
      {:postmark, Swoosh.Adapters.Postmark, Swoosh.ApiClient.Req,
       "transactional-only, API-token auth", &postmark_adapter/0, &describe_postmark/1},
      {:cloudflare, Courier.Adapters.CloudflareEmail, Swoosh.ApiClient.Req,
       "Cloudflare Email Sending — first-party REST API at api.cloudflare.com",
       &cloudflare_adapter/0, &describe_cloudflare/1}
    ]
  end

  defp credentials(:never), do: []

  defp credentials(_auth) do
    [
      username: required!("COURIER_SMTP_USERNAME", "smtp"),
      password: required!("COURIER_SMTP_PASSWORD", "smtp")
    ]
  end

  defp required!(name, provider) do
    case env_string(name) do
      nil ->
        raise """

        courier will not guess a relay or a credential. Without them the adapter
        has nowhere to connect and cannot authenticate, and a send would fail at
        the socket rather than at boot — which is the silent-default failure this
        module exists to end, one layer further out.

        Set
        """

      value ->
        value
    end
  end

  defp port do
    case env_string("COURIER_SMTP_PORT") do
      nil ->
        @default_port

      value ->
        case Integer.parse(value) do
          {port, ""} when port > 0 ->
            port

          _other ->
            raise """
            COURIER_SMTP_PORT=

            courier will not guess. The default is
            unparseable value here would otherwise become an adapter error at the
            socket, once per send, for the life of the deployment.
            """
        end
    end
  end

  defp auth, do: enum!("COURIER_SMTP_AUTH", [:always, :never, :if_available], :always)

  defp tls, do: enum!("COURIER_SMTP_TLS", [:always, :never, :if_available], :always)

  defp ssl, do: boolean!("COURIER_SMTP_SSL", false)

  defp enum!(name, allowed, default) do
    case env_string(name) do
      nil ->
        default

      value ->
        normalised = value |> String.downcase() |> String.trim()

        if normalised in Enum.map(allowed, &to_string/1) do
          Enum.find(allowed, &(to_string(&1) == normalised))
        else
          raise """

          courier will not guess. An unrecognised value here would reach the
          socket as an atom nothing can grep for, and the send would fail with a
          message about TLS rather than about configuration.
          """
        end
    end
  end

  defp boolean!(name, default) do
    case env_string(name) do
      nil ->
        default

      value ->
        case value |> String.downcase() |> String.trim() do
          truthy when truthy in ["true", "1", "yes"] -> true
          falsy when falsy in ["false", "0", "no"] -> false
          _other -> raise "#{name}=#{inspect(value)} is not true or false."
        end
    end
  end

  defp env_string(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc false
  def config_env do
    case Application.get_env(:courier, :environment, nil) do
      nil -> :prod
      environment -> environment
    end
  end
end
