defmodule Courier.MailerAdapterTest do
  @moduledoc """
  courier will not boot into a configuration that cannot send mail.

  The property under test is the one the previous configuration violated: a
  released courier accepted every send, reported a provider-shaped message id,
  and mailed nobody. So these are not tests about a configuration function being
  tidy. Each one is a shape a real deployment takes, and the claim is that courier
  refuses it at boot rather than starting and looking healthy.

  The refusals are asserted as RAISES because that is what refuses a boot. A
  function returning `{:error, :no_adapter}` would leave the caller to decide
  whether to continue, and the caller is `config/runtime.exs`, which either
  configures the adapter or does not start.
  """

  use ExUnit.Case, async: false

  alias Courier.MailerAdapter

  @sentinel "courier-test-only-not-a-real-secret"

  setup do
    previous_env =
      Map.new(
        ~w(
        COURIER_MAIL_ADAPTER COURIER_SMTP_HOST COURIER_SMTP_PORT
        COURIER_SMTP_USERNAME COURIER_SMTP_PASSWORD COURIER_SMTP_AUTH
        COURIER_SMTP_TLS COURIER_SMTP_SSL COURIER_POSTMARK_API_TOKEN
        COURIER_CLOUDFLARE_API_KEY COURIER_CF_ACCOUNT_ID
      ),
        fn name -> {name, System.get_env(name)} end
      )

    Enum.each(Map.keys(previous_env), &System.delete_env/1)

    previous_adapter = Application.get_env(:courier, Courier.Mailer)
    Application.delete_env(:courier, Courier.Mailer)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Application.put_env(:courier, Courier.Mailer, previous_adapter)
    end)

    :ok
  end

  describe "an unset adapter is refused, not guessed" do
    test "adapter!/0 raises in prod when COURIER_MAIL_ADAPTER is missing" do
      assert_raise RuntimeError, ~r/COURIER_MAIL_ADAPTER is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the refusal names the value to set, and the variable to set it in" do
      error =
        assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      message = Exception.message(error)

      assert message =~ "COURIER_MAIL_ADAPTER=smtp"
      assert message =~ "COURIER_SMTP_HOST"
    end

    test "an unset adapter is refused in dev too, not only in prod" do
      assert_raise RuntimeError, ~r/COURIER_MAIL_ADAPTER is missing/, fn ->
        MailerAdapter.adapter!(:dev)
      end
    end
  end

  describe "an adapter that cannot deliver is refused" do
    test "COURIER_MAIL_ADAPTER=none raises in prod" do
      System.put_env("COURIER_MAIL_ADAPTER", "none")

      assert_raise RuntimeError, ~r/none is not permitted in production/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the prod refusal says WHY, so it reads as a fault and not as a policy" do
      System.put_env("COURIER_MAIL_ADAPTER", "none")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      assert message =~ "opens no socket"
      assert message =~ "reports every send as delivered"
    end

    test "COURIER_MAIL_ADAPTER=none is still allowed in dev" do
      System.put_env("COURIER_MAIL_ADAPTER", "none")

      assert [adapter: Swoosh.Adapters.Local] = MailerAdapter.adapter!(:dev)
    end

    test "an unknown adapter name is refused rather than resolved" do
      System.put_env("COURIER_MAIL_ADAPTER", "smtpp")

      assert_raise RuntimeError, ~r/is not an adapter courier ships/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "an adapter named as a module atom is refused — names, not modules" do
      System.put_env("COURIER_MAIL_ADAPTER", "Swoosh.Adapters.Local")

      assert_raise RuntimeError, ~r/is not an adapter courier ships/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the silent adapters are refused by name in dev too, not only in prod" do
      for env <- [:dev, :test] do
        System.put_env("COURIER_MAIL_ADAPTER", "Swoosh.Adapters.Local")

        assert_raise RuntimeError, ~r/is not an adapter courier ships/, fn ->
          MailerAdapter.adapter!(env)
        end
      end
    end

    test "the unknown-adapter refusal lists every provider in the table" do
      System.put_env("COURIER_MAIL_ADAPTER", "smtpp")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      assert message =~ "smtp"
      assert message =~ "postmark"
      assert message =~ "cloudflare"
      assert message =~ "Swoosh.Adapters.SMTP"
      assert message =~ "Swoosh.Adapters.Postmark"
      assert message =~ "Courier.Adapters.CloudflareEmail"
    end
  end

  describe "SMTP is configured from the environment" do
    setup do
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.example-provider.test")
      System.put_env("COURIER_SMTP_USERNAME", "apikey")
      System.put_env("COURIER_SMTP_PASSWORD", @sentinel)
      :ok
    end

    test "a complete configuration produces the adapter Swoosh will call" do
      config = MailerAdapter.adapter!(:prod)

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example-provider.test"
      assert config[:port] == 587
      assert config[:username] == "apikey"
      assert config[:password] == @sentinel
      assert config[:auth] == :always
      assert config[:tls] == :always
      assert config[:ssl] == false
    end

    test "every setting is overridable from the environment" do
      System.put_env("COURIER_SMTP_PORT", "2525")
      System.put_env("COURIER_SMTP_AUTH", "never")
      System.put_env("COURIER_SMTP_TLS", "never")
      System.put_env("COURIER_SMTP_SSL", "true")

      config = MailerAdapter.adapter!(:prod)

      assert config[:port] == 2525
      assert config[:auth] == :never
      assert config[:tls] == :never
      assert config[:ssl] == true
    end

    test "auth: never needs no credentials at all" do
      System.put_env("COURIER_SMTP_AUTH", "never")

      config = MailerAdapter.adapter!(:prod)

      refute Keyword.has_key?(config, :username)
      refute Keyword.has_key?(config, :password)
    end

    test "a missing host is a boot failure naming the variable" do
      System.delete_env("COURIER_SMTP_HOST")

      assert_raise RuntimeError, ~r/COURIER_SMTP_HOST is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "a missing password is a boot failure naming the variable" do
      System.delete_env("COURIER_SMTP_PASSWORD")

      assert_raise RuntimeError, ~r/COURIER_SMTP_PASSWORD is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "an empty host is treated as missing, not as a host named \"\"" do
      System.put_env("COURIER_SMTP_HOST", "")

      assert_raise RuntimeError, ~r/COURIER_SMTP_HOST is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "an empty password is treated as missing, not sent to the relay" do
      System.put_env("COURIER_SMTP_PASSWORD", "")

      assert_raise RuntimeError, ~r/COURIER_SMTP_PASSWORD is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "a non-numeric port is a boot failure naming the variable and the value" do
      System.put_env("COURIER_SMTP_PORT", "not-a-port")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      assert message =~ "COURIER_SMTP_PORT"
      assert message =~ "not-a-port"
      assert message =~ "587"
    end

    test "an out-of-enum TLS value is a boot failure naming the variable and the choices" do
      System.put_env("COURIER_SMTP_TLS", "sometimes")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      assert message =~ "COURIER_SMTP_TLS"
      assert message =~ ":always"
      assert message =~ ":never"
    end

    test "an out-of-enum AUTH value is a boot failure naming the variable" do
      System.put_env("COURIER_SMTP_AUTH", "maybe")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      assert Exception.message(error) =~ "COURIER_SMTP_AUTH"
    end

    test "an out-of-range boolean SSL value is a boot failure naming the variable" do
      System.put_env("COURIER_SMTP_SSL", "perhaps")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      assert Exception.message(error) =~ "COURIER_SMTP_SSL"
    end

    test "an enum value in a different case is accepted" do
      System.put_env("COURIER_SMTP_TLS", "Always")

      assert MailerAdapter.adapter!(:prod)[:tls] == :always
    end
  end

  describe "Postmark is configured from the environment" do
    setup do
      System.put_env("COURIER_MAIL_ADAPTER", "postmark")
      System.put_env("COURIER_POSTMARK_API_TOKEN", @sentinel)
      :ok
    end

    test "a complete configuration produces the adapter Swoosh will call" do
      config = MailerAdapter.adapter!(:prod)

      assert config[:adapter] == Swoosh.Adapters.Postmark
      assert config[:api_key] == @sentinel
    end

    test "a missing token is a boot failure naming the variable" do
      System.delete_env("COURIER_POSTMARK_API_TOKEN")

      assert_raise RuntimeError, ~r/COURIER_POSTMARK_API_TOKEN is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the refusal names the adapter the variable belongs to" do
      System.delete_env("COURIER_POSTMARK_API_TOKEN")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      assert Exception.message(error) =~ "COURIER_POSTMARK_API_TOKEN"
      assert Exception.message(error) =~ "postmark"
    end

    test "an empty token is treated as missing, not sent to the provider" do
      System.put_env("COURIER_POSTMARK_API_TOKEN", "")

      assert_raise RuntimeError, ~r/COURIER_POSTMARK_API_TOKEN is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "Postmark is deliverable" do
      assert MailerAdapter.deliverable?(Swoosh.Adapters.Postmark)
    end

    test "the Swoosh HTTP client is wired for Postmark and not for SMTP" do
      assert MailerAdapter.api_client(Swoosh.Adapters.Postmark) == Swoosh.ApiClient.Req
      assert MailerAdapter.api_client(Swoosh.Adapters.SMTP) == nil
      assert MailerAdapter.api_client(nil) == nil
      assert MailerAdapter.api_client(Swoosh.Adapters.Local) == nil
    end
  end

  describe "Cloudflare is configured from the environment" do
    setup do
      System.put_env("COURIER_MAIL_ADAPTER", "cloudflare")
      System.put_env("COURIER_CLOUDFLARE_API_KEY", @sentinel)
      System.put_env("COURIER_CF_ACCOUNT_ID", "test-account-id")
      :ok
    end

    test "a complete configuration produces the adapter Swoosh will call" do
      config = MailerAdapter.adapter!(:prod)

      assert config[:adapter] == Courier.Adapters.CloudflareEmail
      assert config[:api_key] == @sentinel
      assert config[:account_id] == "test-account-id"
    end

    test "a missing key is a boot failure naming the variable" do
      System.delete_env("COURIER_CLOUDFLARE_API_KEY")

      assert_raise RuntimeError, ~r/COURIER_CLOUDFLARE_API_KEY is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the refusal names the adapter the variable belongs to" do
      System.delete_env("COURIER_CLOUDFLARE_API_KEY")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      assert Exception.message(error) =~ "COURIER_CLOUDFLARE_API_KEY"
      assert Exception.message(error) =~ "cloudflare"
    end

    test "an empty key is treated as missing, not sent to the provider" do
      System.put_env("COURIER_CLOUDFLARE_API_KEY", "")

      assert_raise RuntimeError, ~r/COURIER_CLOUDFLARE_API_KEY is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "a missing account id is a boot failure naming the variable" do
      System.delete_env("COURIER_CF_ACCOUNT_ID")

      assert_raise RuntimeError, ~r/COURIER_CF_ACCOUNT_ID is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "an empty account id is treated as missing" do
      System.put_env("COURIER_CF_ACCOUNT_ID", "")

      assert_raise RuntimeError, ~r/COURIER_CF_ACCOUNT_ID is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "Cloudflare is deliverable" do
      assert MailerAdapter.deliverable?(Courier.Adapters.CloudflareEmail)
    end

    test "the Swoosh HTTP client is wired for Cloudflare" do
      assert MailerAdapter.api_client(Courier.Adapters.CloudflareEmail) == Swoosh.ApiClient.Req
    end
  end

  describe "the adapter courier ships can deliver" do
    test "SMTP is deliverable" do
      assert MailerAdapter.deliverable?(Swoosh.Adapters.SMTP)
    end

    test "the silent adapters are not deliverable" do
      refute MailerAdapter.deliverable?(Swoosh.Adapters.Local)
      refute MailerAdapter.deliverable?(Swoosh.Adapters.Test)
    end

    test "an unset adapter is not deliverable" do
      refute MailerAdapter.deliverable?(nil)
    end

    test "the silent adapters are named in one place, and it is the two" do
      assert Enum.sort(MailerAdapter.silent_adapters()) ==
               Enum.sort([Swoosh.Adapters.Local, Swoosh.Adapters.Test])
    end
  end

  describe "the second gate: the effective adapter at boot" do
    setup do
      previous = Application.get_env(:courier, Courier.Mailer)
      on_exit(fn -> Application.put_env(:courier, Courier.Mailer, previous) end)
      :ok
    end

    test "verify_boot!/0 raises in prod when the effective adapter is Local" do
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Local)

      assert_raise RuntimeError, ~r/cannot deliver mail/, fn ->
        MailerAdapter.verify_boot!(:prod)
      end
    end

    test "verify_boot!/0 raises in prod when the effective adapter is Test" do
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Test)

      assert_raise RuntimeError, ~r/cannot deliver mail/, fn ->
        MailerAdapter.verify_boot!(:prod)
      end
    end

    test "verify_boot!/0 raises in prod when no adapter is configured at all" do
      Application.put_env(:courier, Courier.Mailer, [])

      assert_raise RuntimeError, ~r/cannot deliver mail/, fn ->
        MailerAdapter.verify_boot!(:prod)
      end
    end

    test "the refusal says what is wrong, so it reads as a fault" do
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Local)

      message =
        try do
          MailerAdapter.verify_boot!(:prod)
        rescue
          error -> Exception.message(error)
        end

      assert message =~ "Swoosh.Adapters.Local"
      assert message =~ "COURIER_MAIL_ADAPTER"
      assert message =~ "COURIER_SMTP_HOST"
    end

    test "verify_boot!/0 passes in prod for SMTP" do
      Application.put_env(:courier, Courier.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example-provider.test"
      )

      assert MailerAdapter.verify_boot!(:prod) == :ok
    end

    test "verify_boot!/0 passes in prod for Cloudflare" do
      Application.put_env(:courier, Courier.Mailer,
        adapter: Courier.Adapters.CloudflareEmail,
        api_key: "cloudflare-test-key"
      )

      assert MailerAdapter.verify_boot!(:prod) == :ok
    end

    test "verify_boot!/0 does not fire in test, where the Test adapter is correct" do
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Test)

      assert MailerAdapter.verify_boot!(:test) == :ok
    end

    test "the application controller calls the gate" do
      source = File.read!(Path.join([File.cwd!(), "lib", "courier", "application.ex"]))

      assert source =~ "Courier.MailerAdapter.verify_boot!()",
             "Courier.Application.start/2 does not call the adapter boot gate"
    end
  end

  describe "the default port is the submission port" do
    test "587, not 25" do
      assert MailerAdapter.default_port() == 587
    end
  end

  describe "SMTP TLS options are the reason the hosted stack could sign up a user" do
    setup do
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.example-provider.test")
      System.put_env("COURIER_SMTP_USERNAME", "apikey")
      System.put_env("COURIER_SMTP_PASSWORD", @sentinel)
      :ok
    end

    test "STARTTLS (the shipped default) carries tls_options and no sockopts" do
      config = MailerAdapter.smtp_adapter()

      assert config[:tls] == :always
      assert config[:ssl] == false
      assert Keyword.has_key?(config, :tls_options)
      refute Keyword.has_key?(config, :sockopts)
    end

    test "tls_options pins modern versions only" do
      config = MailerAdapter.smtp_adapter()

      assert config[:tls_options][:versions] == [:"tlsv1.2", :"tlsv1.3"]
    end

    test "tls_options verifies the peer, with the OS store" do
      config = MailerAdapter.smtp_adapter()

      assert config[:tls_options][:verify] == :verify_peer
      cacerts = config[:tls_options][:cacerts]
      assert is_list(cacerts)
      assert length(cacerts) > 0
      assert config[:tls_options][:cacerts] == :public_key.cacerts_get()
    end

    test "tls_options presents SNI as the relay host" do
      config = MailerAdapter.smtp_adapter()

      assert config[:tls_options][:server_name_indication] ==
               String.to_charlist("smtp.example-provider.test")

      System.put_env("COURIER_SMTP_HOST", "smtp.other.test")
      config2 = MailerAdapter.smtp_adapter()
      assert config2[:tls_options][:server_name_indication] == ~c"smtp.other.test"
    end

    test "tls_options carries depth and hostname check" do
      config = MailerAdapter.smtp_adapter()

      assert is_integer(config[:tls_options][:depth])
      assert config[:tls_options][:depth] > 0

      assert Keyword.has_key?(config[:tls_options], :customize_hostname_check)

      assert config[:tls_options][:customize_hostname_check][:match_fun] ==
               :public_key.pkix_verify_hostname_match_fun(:https)
    end

    test "implicit TLS (ssl: true) carries sockopts instead of tls_options" do
      System.put_env("COURIER_SMTP_SSL", "true")

      config = MailerAdapter.smtp_adapter()

      assert config[:ssl] == true
      assert Keyword.has_key?(config, :sockopts)
      refute Keyword.has_key?(config, :tls_options)
      assert config[:sockopts][:versions] == [:"tlsv1.2", :"tlsv1.3"]
      assert config[:sockopts][:verify] == :verify_peer

      assert config[:sockopts][:server_name_indication] ==
               String.to_charlist("smtp.example-provider.test")
    end

    test "tls: never carries neither upgrade option" do
      System.put_env("COURIER_SMTP_TLS", "never")

      config = MailerAdapter.smtp_adapter()

      assert config[:tls] == :never
      refute Keyword.has_key?(config, :tls_options)
      refute Keyword.has_key?(config, :sockopts)
    end

    test "the STARTTLS handshake succeeds with the shipped options" do
      System.put_env("COURIER_SMTP_HOST", "smtp.gmail.com")
      config = MailerAdapter.smtp_adapter()

      result =
        :gen_smtp_client.send_blocking(
          {"from@test.com", ["to@test.com"], "Subject: test\r\n\r\ntest"},
          relay: "smtp.gmail.com",
          port: 587,
          tls: :always,
          auth: :never,
          no_mx_lookups: true,
          tls_options: config[:tls_options],
          retries: 0,
          timeout: 10_000
        )


      case result do
        {:error, :retries_exceeded, {:temporary_failure, _, :tls_failed}} ->
          flunk(
            "STARTTLS handshake failed with shipped tls_options: #{inspect(result)}. " <>
              "Expected to get past TLS to an SMTP-level refusal."
          )

        {:error, _, {:temporary_failure, _, :tls_failed}} ->
          flunk("STARTTLS handshake failed with shipped tls_options: #{inspect(result)}")

        _other ->
          :ok
      end
    end

    test "verify is never :verify_none" do
      for {env_tls, env_ssl} <- [{nil, nil}, {"always", nil}, {nil, "true"}] do
        if env_tls,
          do: System.put_env("COURIER_SMTP_TLS", env_tls),
          else: System.delete_env("COURIER_SMTP_TLS")

        if env_ssl,
          do: System.put_env("COURIER_SMTP_SSL", env_ssl),
          else: System.delete_env("COURIER_SMTP_SSL")

        config = MailerAdapter.smtp_adapter()

        tls_opts = config[:tls_options] || config[:sockopts]

        if tls_opts do
          refute tls_opts[:verify] == :verify_none,
                 "tls_options/sockopts must not be :verify_none (tls=#{inspect(env_tls)}, ssl=#{inspect(env_ssl)})"
        end
      end
    end
  end
end
