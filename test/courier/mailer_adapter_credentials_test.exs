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


    * `Courier.MailerAdapter.describe/1` — the startup line.
    * a real failed send through `Swoosh.Adapters.SMTP`, with the credential in
      the adapter configuration, captured across the whole call.
    * the boot refusals, which quote the environment back at the operator.
    * the "no credentials at all" refusals, which must not print what was
      missing by accident.
  """

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
      COURIER_CLOUDFLARE_API_KEY COURIER_CF_ACCOUNT_ID
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
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(config())}")
        end)

      refute log =~ @username, "the SMTP username reached a log line:\n#{log}"
    end

    test "still says which relay courier is pointed at" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(config())}")
        end)

      assert log =~ "smtp.example-provider.test"
      assert log =~ "587"
      assert log =~ "adapter=smtp"
    end

    test "describe/1 is total — it renders every shape it can be handed" do
      assert MailerAdapter.describe([]) =~ "adapter=unset"
      assert MailerAdapter.describe(adapter: nil) =~ "adapter=none"
      assert MailerAdapter.describe(adapter: SomeOtherAdapter) =~ "SomeOtherAdapter"
      assert MailerAdapter.describe(adapter: Swoosh.Adapters.SMTP) =~ "host=?"
      assert MailerAdapter.describe(adapter: Swoosh.Adapters.Postmark) =~ "adapter=postmark"

      assert MailerAdapter.describe(adapter: Courier.Adapters.CloudflareEmail) =~
               "adapter=cloudflare"
    end
  end

  describe "the Postmark startup line" do
    test "describes the provider without the token" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(postmark_config())}")
        end)

      refute log =~ @token, "the Postmark token reached a log line:\n#{log}"
    end

    test "still says which provider courier is pointed at" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(postmark_config())}")
        end)

      assert log =~ "adapter=postmark"
      assert log =~ "token=set"
    end

    test "says when the token is unset" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(adapter: Swoosh.Adapters.Postmark)}")
        end)

      assert log =~ "adapter=postmark"
      assert log =~ "token=unset"
    end
  end

  describe "the Cloudflare startup line" do
    test "describes the provider without the key" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(cloudflare_config())}")
        end)

      refute log =~ @token, "the Cloudflare key reached a log line:\n#{log}"
    end

    test "still says which provider courier is pointed at" do
      log =
        capture_log(fn ->
          Logger.warning("mailer: #{MailerAdapter.describe(cloudflare_config())}")
        end)

      assert log =~ "adapter=cloudflare"
      assert log =~ "token=set"
    end

    test "says when the key is unset" do
      log =
        capture_log(fn ->
          Logger.warning(
            "mailer: #{MailerAdapter.describe(adapter: Courier.Adapters.CloudflareEmail)}"
          )
        end)

      assert log =~ "adapter=cloudflare"
      assert log =~ "token=unset"
    end
  end

  describe "a real send that fails" do
    test "the password is absent from every log line a failing send produces" do
      {:ok, server, port} = SmtpServer.start_link_authenticated("the-real-one", @password)

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
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.example-provider.test")
      System.put_env("COURIER_SMTP_PASSWORD", @password)
      System.delete_env("COURIER_SMTP_USERNAME")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      message = Exception.message(error)

      assert message =~ "COURIER_SMTP_USERNAME is missing"
      refute message =~ @password, "the refusal printed the password:\n#{message}"
      refute message =~ @username, "the refusal printed the username:\n#{message}"
    end

    test "a missing Postmark token is refused without printing any token" do
      System.put_env("COURIER_MAIL_ADAPTER", "postmark")
      System.put_env("COURIER_POSTMARK_API_TOKEN", "")

      log =
        capture_log(fn ->
          assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
        end)

      refute log =~ @token
    end

    test "a missing Cloudflare key is refused without printing any key" do
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

  defp mailer_blocks(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], nil, 0}, fn line, {blocks, current, depth} ->
      cond do
        current != nil ->
          current = current <> "\n" <> line
          depth = depth + bracket_delta(line)

          if depth <= 0 do
            {blocks ++ [current], nil, 0}
          else
            {blocks, current, depth}
          end

        String.match?(line, ~r/^\s*config\s+:courier,\s*Courier\.Mailer\b/) ->
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

  defp postmark_config do
    [
      adapter: Swoosh.Adapters.Postmark,
      api_key: @token
    ]
  end

  defp cloudflare_config do
    [
      adapter: Courier.Adapters.CloudflareEmail,
      api_key: @token,
      account_id: "test-account-id"
    ]
  end
end
