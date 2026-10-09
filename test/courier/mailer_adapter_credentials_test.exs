defmodule Courier.MailerAdapterCredentialsTest do
  @moduledoc """
  A password never reaches a log.

  This is the test the brief calls worth more than an assertion that something
  was logged, and it is worth more for a specific reason. An SMTP password is
  often an API key — SES, Postmark and Mailgun all issue one and call it a
  username or a password depending on the provider — so a log line carrying it
  is a credential in a store that is replicated, retained, and readable by
  everyone with log access. The failure is also silent in the way that matters:
  nothing breaks, the mail still goes out, and the leak is discovered by somebody
  reading a log.

  So every test here captures real log output and asserts the secret is ABSENT.
  Two of them also assert something else IS present, because a redaction
  boundary that deletes everything passes "no canary" and is useless — the same
  reasoning, and the same three bugs, as `Courier.TelemetryCanaryTest`.

  ## The paths that could leak, and are covered

    * `Courier.MailerAdapter.describe/1` — the startup line.
    * a real failed send through `Swoosh.Adapters.SMTP`, with the credential in
      the adapter configuration, captured across the whole call.
    * the boot refusals, which quote the environment back at the operator.
    * the "no credentials at all" refusals, which must not print what was
      missing by accident.
  """

  # `async: false`: these tests mutate the VM's environment and the shared
  # application environment, and they capture logs — which are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Courier.MailerAdapter
  alias Courier.Mailers
  alias Courier.TestSupport.SmtpServer

  @password "pw-courier-canary-4e1b-DO-NOT-LOG"
  @username "user-courier-canary-4e1b"
  @token "tok-courier-canary-7c2d-DO-NOT-LOG"

  setup do
    names = ~w(
      COURIER_MAIL_ADAPTER COURIER_SMTP_HOST COURIER_SMTP_PORT
      COURIER_SMTP_USERNAME COURIER_SMTP_PASSWORD COURIER_SMTP_AUTH
      COURIER_SMTP_TLS COURIER_SMTP_SSL COURIER_POSTMARK_API_TOKEN
      COURIER_CLOUDFLARE_API_KEY
    )

    previous_env = Map.new(names, fn name -> {name, System.get_env(name)} end)
    previous_adapter = Application.get_env(:courier, Courier.Mailer)

    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Application.put_env(:courier, Courier.Mailer, previous_adapter)
    end)

    :ok
  end

  describe "the startup line" do
    test "describes the relay without the password" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(config())}")
        end)

      refute log =~ @password, "the SMTP password reached a log line:\n#{log}"
    end

    test "describes the relay without the username either" do
      # At SMTP a "username" is very often the API key. Leaving it out is not
      # squeamishness: for every provider courier targets it is a credential, and
      # the startup line does not need it to be useful.
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(config())}")
        end)

      refute log =~ @username, "the SMTP username reached a log line:\n#{log}"
    end

    test "still says which relay courier is pointed at" do
      # The presence assertion. `describe/1` exists so an operator can confirm
      # their deployment without reading a config file; a version that printed
      # nothing at all would pass both refusals above and be useless.
      #
      # `:warning`, not `:info`, because `config/test.exs` sets
      # `config :logger, level: :warning` and `capture_log/1` captures what the
      # logger would have emitted rather than forcing the level. An `:info` line
      # is below the threshold and the capture is empty — which would make this
      # presence assertion pass for the wrong reason while the two refusal
      # assertions above passed vacuously.
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(config())}")
        end)

      assert log =~ "smtp.example-provider.test"
      assert log =~ "587"
      assert log =~ "adapter=smtp"
    end

    test "describe/1 is total — it renders every shape it can be handed" do
      # A function that raises on an unexpected config would take down the
      # startup line, which is the one place an operator is guaranteed to look
      # when a deployment is misbehaving.
      assert MailerAdapter.describe([]) =~ "adapter=unset"
      assert MailerAdapter.describe(adapter: nil) =~ "adapter=none"
      assert MailerAdapter.describe(adapter: SomeOtherAdapter) =~ "SomeOtherAdapter"
      assert MailerAdapter.describe(adapter: Swoosh.Adapters.SMTP) =~ "host=?"
      assert MailerAdapter.describe(adapter: Swoosh.Adapters.Postmark) =~ "adapter=postmark"
      assert MailerAdapter.describe(adapter: Courier.Adapters.CloudflareEmail) =~ "adapter=cloudflare"
    end
  end

  describe "the Postmark startup line" do
    # The second provider's half of the same rule: `describe/1` names the
    # provider and whether its token is set, and never the token. Postmark's
    # credential is an API token, which at a provider is the whole secret —
    # the same class of leak as an SMTP password, so it gets the same test.
    test "describes the provider without the token" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(postmark_config())}")
        end)

      refute log =~ @token, "the Postmark token reached a log line:\n#{log}"
    end

    test "still says which provider courier is pointed at" do
      # The presence assertion, and it is the one that matters: a startup line
      # that printed nothing would pass the refusal above and be useless. The
      # two facts an operator needs are the provider and whether its token is
      # set — neither of which is a secret.
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(postmark_config())}")
        end)

      assert log =~ "adapter=postmark"
      assert log =~ "token=set"
    end

    test "says when the token is unset" do
      # The other half of the presence assertion: an operator who forgot the
      # variable needs the startup line to say so. "token=unset" is the honest
      # answer; a line that looked configured and was not would be the same
      # silent-default failure this module exists to end, one layer out.
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(adapter: Swoosh.Adapters.Postmark)}")
        end)

      assert log =~ "adapter=postmark"
      assert log =~ "token=unset"
    end
  end

  describe "the Cloudflare startup line" do
    # The third provider's half of the same rule: `describe/1` names the
    # provider and whether its key is set, and never the key. The
    # MailChannels API key is the whole secret — the same class of leak as
    # an SMTP password or a Postmark token — so it gets the same test.
    test "describes the provider without the key" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(cloudflare_config())}")
        end)

      refute log =~ @token, "the Cloudflare key reached a log line:\n#{log}"
    end

    test "still says which provider courier is pointed at" do
      # The presence assertion, and it is the one that matters: a startup line
      # that printed nothing would pass the refusal above and be useless. The
      # two facts an operator needs are the provider and whether its key is
      # set — neither of which is a secret.
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(cloudflare_config())}")
        end)

      assert log =~ "adapter=cloudflare"
      assert log =~ "token=set"
    end

    test "says when the key is unset" do
      # The other half of the presence assertion: an operator who forgot the
      # variable needs the startup line to say so. "token=unset" is the honest
      # answer; a line that looked configured and was not would be the same
      # silent-default failure this module exists to end, one layer out.
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(adapter: Courier.Adapters.CloudflareEmail)}")
        end)

      assert log =~ "adapter=cloudflare"
      assert log =~ "token=unset"
    end
  end

  describe "a real send that fails" do
    test "the password is absent from every log line a failing send produces" do
      # The whole point of using a real adapter here rather than a stub: the
      # credential is genuinely in the configuration Swoosh hands to
      # `gen_smtp_client`, and a failure produces genuine output. A stubbed
      # adapter would prove the stub is careful.
      {:ok, server, port} = SmtpServer.start_link_authenticated("the-real-one", @password)

      # Wrong password: `gen_smtp` fails the AUTH exchange and reports it.
      Application.put_env(:courier, Courier.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: "127.0.0.1",
        port: port,
        no_mx_lookups: true,
        tls: :never,
        auth: :always,
        username: @username,
        password: "definitely-not-#{@password}"
      )

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   Mailers.deliver(:welcome, %{
                     user_id: "usr_creds",
                     email: "creds@example.com",
                     name: "Credential Canary"
                   })
        end)

      refute log =~ @password, "the SMTP password reached a log line:\n#{log}"
      assert SmtpServer.messages(server) == []
    end

    test "the password is absent from the log when the relay is unreachable" do
      # The other shape of failure, and the more likely one in practice: a DNS
      # answer or a refused connection rather than a provider refusing us.
      # `gen_smtp` reports the host it could not reach — which is the useful
      # half — and the assertion is that it took nothing else with it.
      Application.put_env(:courier, Courier.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: "no-such-relay.invalid",
        port: 587,
        no_mx_lookups: true,
        tls: :never,
        auth: :always,
        username: @username,
        password: @password
      )

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   Mailers.deliver(:welcome, %{
                     user_id: "usr_creds_unreachable",
                     email: "creds-unreachable@example.com",
                     name: "Unreachable Canary"
                   })
        end)

      refute log =~ @password, "the SMTP password reached a log line:\n#{log}"
    end

    test "a successful send logs nothing at all containing the password" do
      # The positive case: the send succeeds, and a green path is exactly where a
      # debug-level "sent via <adapter config>" line gets added six months from
      # now by somebody debugging a delivery.
      {:ok, server, port} = SmtpServer.start_link_authenticated(@username, @password)

      Application.put_env(:courier, Courier.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: "127.0.0.1",
        port: port,
        no_mx_lookups: true,
        tls: :never,
        auth: :always,
        username: @username,
        password: @password
      )

      log =
        capture_log(fn ->
          assert {:ok, _receipt} =
                   Mailers.deliver(:welcome, %{
                     user_id: "usr_creds_ok",
                     email: "creds-ok@example.com",
                     name: "Green Canary"
                   })
        end)

      refute log =~ @password, "the SMTP password reached a log line:\n#{log}"
      assert [_message] = SmtpServer.take(server)
    end
  end

  describe "the boot refusals" do
    test "a missing password is refused without printing any password" do
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.example-provider.test")
      System.put_env("COURIER_SMTP_USERNAME", @username)
      System.put_env("COURIER_SMTP_PASSWORD", "")

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
        end)

      refute log =~ @password
    end

    test "a refusal raises rather than logging the environment" do
      # A refusal is a RAISE, not a log line. That is the stronger property and
      # the reason `adapter!/1` raises: `config/runtime.exs` calls it, and an
      # exception there stops the boot while a warning there does not.
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.example-provider.test")
      System.put_env("COURIER_SMTP_PASSWORD", @password)
      System.delete_env("COURIER_SMTP_USERNAME")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      # The message quotes the variable that is missing. It must not quote the
      # values of the ones that are present.
      message = Exception.message(error)

      assert message =~ "COURIER_SMTP_USERNAME is missing"
      refute message =~ @password, "the refusal printed the password:\n#{message}"
      refute message =~ @username, "the refusal printed the username:\n#{message}"
    end

    test "a missing Postmark token is refused without printing any token" do
      # The Postmark half of the same rule. The refusal quotes the variable
      # that is missing; it must not quote the value of the one that is
      # present, and there is no present value to leak here — the assertion is
      # that the canary never appears, paired with the raise itself.
      System.put_env("COURIER_MAIL_ADAPTER", "postmark")
      System.put_env("COURIER_POSTMARK_API_TOKEN", "")

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
        end)

      refute log =~ @token
    end

    test "a missing Cloudflare key is refused without printing any key" do
      # The Cloudflare half of the same rule. The refusal quotes the variable
      # that is missing; it must not quote the value of the one that is
      # present, and there is no present value to leak here — the assertion is
      # that the canary never appears, paired with the raise itself.
      System.put_env("COURIER_MAIL_ADAPTER", "cloudflare")
      System.put_env("COURIER_CLOUDFLARE_API_KEY", "")

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
        end)

      refute log =~ @token
    end
  end

  describe "no credential is in the repository" do
    test "no committed config file carries an SMTP credential" do
      # The other half of the rule: a canary belongs in a test file, and the same
      # keys inside `config :courier, Courier.Mailer` in a committed file would
      # mean somebody had wired a real-looking credential into version control.
      #
      # Scoped to the MAILER's blocks, not to every `password:` in `config/`. The
      # repository already commits `password: "postgres"` for the test database —
      # a documented, test-scoped value — and a general scan fails on those. A
      # scan loosened until it goes green is a scan that has stopped looking, so
      # the scope is the one that names the adapter rather than the one that is
      # easiest to keep quiet.
      offenders =
        "config/*.exs"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> mailer_blocks()
          |> Enum.filter(&String.match?(&1, ~r/^\s*(username|password):/m))
          |> Enum.map(&"#{path}: #{String.trim(&1)}")
        end)

      assert offenders == [],
             "a committed config file carries an SMTP credential:\n" <>
               Enum.join(offenders, "\n")
    end

    test "no committed config file names an SMTP relay" do
      # Not only is the credential absent, the whole adapter configuration is.
      # Credentials are read from the environment in every environment, so a
      # committed `relay:` would mean a committed deployment target — somebody's
      # provider, on somebody else's bill, reached by everybody who installed
      # courier.
      offenders =
        "config/*.exs"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> mailer_blocks()
          |> Enum.filter(&String.match?(&1, ~r/^\s*relay:/m))
          |> Enum.map(&"#{path}: #{String.trim(&1)}")
        end)

      assert offenders == [],
             "a committed config file names an SMTP relay:\n" <> Enum.join(offenders, "\n")
    end

    test "no committed config file carries a Postmark token" do
      # The Postmark half of the credential scan. `api_key` is the same class
      # of leak as `username`/`password` at SMTP — a provider credential in
      # version control — so it gets the same scan over the same mailer
      # blocks, and the same presence assertion below keeps it honest.
      offenders =
        "config/*.exs"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> mailer_blocks()
          |> Enum.filter(&String.match?(&1, ~r/^\s*api_key:/m))
          |> Enum.map(&"#{path}: #{String.trim(&1)}")
        end)

      assert offenders == [],
             "a committed config file carries a Postmark token:\n" <>
               Enum.join(offenders, "\n")
    end

    test "the mailer IS configured in a committed file, so the two scans above are not vacuous" do
      # The presence assertion, and it is the one that matters here: both scans
      # above pass trivially if `mailer_blocks/1` finds nothing. `config/test.exs`
      # and `config/dev.exs` both configure the adapter, and this asserts the
      # extractor can see them — so "no credential found" means "looked and found
      # none" rather than "did not look".
      blocks =
        Enum.flat_map(Path.wildcard("config/*.exs"), fn path ->
          path |> mailer_blocks() |> Enum.map(&{path, &1})
        end)

      assert length(blocks) >= 2,
             "expected the mailer to be configured in at least test.exs and dev.exs, found #{length(blocks)}"

      assert Enum.any?(blocks, fn {_path, block} ->
               String.match?(block, ~r/Swoosh\.Adapters\.(Test|Local)/)
             end),
             "no committed mailer block names an adapter: #{inspect(blocks)}"
    end
  end

  # Every `config :courier, Courier.Mailer, ...` expression in a config file, as
  # text.
  #
  # Bracket-balanced rather than line-based, because the blocks are written both
  # ways in this repository — one line in `test.exs`, multi-line in `runtime.exs`
  # — and a line-based extractor would only ever see the first kind. It stops at
  # the closing bracket, so a `password:` on a later line is inside the block.
  defp mailer_blocks(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], nil, 0}, fn line, {blocks, current, depth} ->
      cond do
        current != nil ->
          # Inside a block: accumulate text and track bracket depth, so the block
          # ends at its closing bracket rather than at the next line that happens
          # not to match.
          current = current <> "\n" <> line
          depth = depth + bracket_delta(line)

          if depth <= 0 do
            {blocks ++ [current], nil, 0}
          else
            {blocks, current, depth}
          end

        String.match?(line, ~r/^\s*config\s+:courier,\s*Courier\.Mailer\b/) ->
          # Starting a block. Bracket depth decides whether it continues:
          #
          #   * `config :courier, Courier.Mailer, adapter: X` — no brackets, depth
          #     0. Complete on this line, emitted now. Treating it as "still
          #     open" would swallow the following unrelated line, and then a
          #     credential written on the NEXT line of a genuinely multi-line
          #     block would never be scanned at all.
          #
          #   * `config :courier, Courier.Mailer, [` — depth 1. The `current != nil`
          #     branch above picks it up and closes it on the matching `]`, which
          #     is what catches a `password:` several lines down.
          if bracket_delta(line) > 0 do
            {blocks, line, bracket_delta(line)}
          else
            {blocks ++ [line], nil, 0}
          end

        true ->
          {blocks, nil, 0}
      end
    end)
    |> elem(0)
  end

  defp bracket_delta(line) do
    open = line |> String.graphemes() |> Enum.count(&(&1 == "["))
    close = line |> String.graphemes() |> Enum.count(&(&1 == "]"))
    open - close
  end

  # The adapter configuration with both credentials present, for the `describe/1`
  # assertions. Written out by hand rather than read from the environment, so the
  # test asserts about how `describe/1` handles a configuration — and about the
  # two credentials being in one at all — rather than about the environment
  # reader, which the file above already covers.
  defp config do
    [
      adapter: Swoosh.Adapters.SMTP,
      relay: "smtp.example-provider.test",
      port: 587,
      username: @username,
      password: @password,
      auth: :always
    ]
  end

  # The Postmark adapter configuration with its token present, for the
  # `describe/1` assertions. Written out by hand rather than read from the
  # environment, for the same reason `config/0` is: the test asserts about
  # how `describe/1` handles a configuration, not about the environment
  # reader.
  defp postmark_config do
    [
      adapter: Swoosh.Adapters.Postmark,
      api_key: @token
    ]
  end
end
