defmodule Courier.ReleaseMigrateConfigTest do
  @moduledoc """
  `config/runtime.exs` validates the SERVER's credential contract, and only the
  server's — a `bin/migrate` boot is a subset of it, and this file is the proof.


  The substrate runs each service's migrate entrypoint as a one-shot Job **before
  the stack is up**, and mints courier's `COURIER_IDENTITY_TOKEN` in a later step,
  once identity is serving. So a migrate pod that evaluated the whole of
  `config/runtime.exs` died on `COURIER_IDENTITY_TOKEN is missing` — a variable
  that did not exist yet and that a migration never reads. The fix is a
  distinction, not a deletion: the server still refuses.


  `RELEASE_COMMAND`, which the release's own `bin/<name>` script sets from its
  first argument before the VM starts: `start` for `bin/server`, `eval` for
  `bin/migrate`. The release script OVERWRITES any inherited value, so a
  deployment cannot put `RELEASE_COMMAND=eval` in front of `bin/server`.


  This process's merged application env is the SUITE's config, where none of the
  production blocks ran. So each test evaluates `config/runtime.exs` as the
  release does — `Config.Reader.read!/2` with `env: :prod`, and the variables set
  in the REAL environment, because `runtime.exs` calls `System.get_env/1` and
  `Config.Reader`'s `:env` option does not satisfy that (measured; see
  `CourierWeb.ErrorRelayEndpointTest`, which found it first).


  Every test here mutates OS environment variables, which the whole VM shares
  (`System.put_env/2` / `System.delete_env/1`), and a test that runs beside
  another test reading them is a race. The previous values are restored in
  `on_exit`, so the window is closed whatever the assertion does — but the window
  is real, which is why this file gets its own process slot.
  """
  use ExUnit.Case, async: false

  @owner_dsn "ecto://postgres:postgres@localhost/courier_test"

  @serving_variables [
    "COURIER_IDENTITY_TOKEN",
    "COURIER_SECRET_BOX_KEY",
    "COURIER_ERROR_RELAY_TOKEN",
    "COURIER_MAIL_ADAPTER",
    "COURIER_SMTP_HOST",
    "COURIER_SMTP_USERNAME",
    "COURIER_SMTP_PASSWORD",
    "DATABASE_URL",
    "SECRET_KEY_BASE"
  ]

  @commands_that_serve ["start", "daemon", "start_iex", "daemon_iex"]

  setup do
    previous =
      (@serving_variables ++
         [
           "COURIER_OWNER_DATABASE_URL",
           "RELEASE_COMMAND",
           "COURIER_CF_ACCOUNT_ID",
           "COURIER_CLOUDFLARE_API_KEY",
           "COURIER_INBOUND_RESEND_SECRET",
           "COURIER_POSTMARK_API_TOKEN"
         ])
      |> Map.new(&{&1, System.get_env(&1)})

    on_exit(fn -> restore(previous) end)

    Enum.each(@serving_variables, &System.delete_env/1)
    System.put_env("COURIER_OWNER_DATABASE_URL", @owner_dsn)

    :ok
  end

  describe "a one-shot migrate boot (RELEASE_COMMAND=eval)" do
    test "evaluates with no serving credential set, and configures the owner DSN" do
      config = read_config!("eval")

      owner = config[:courier][Courier.OwnerRepo]

      assert owner[:url] == @owner_dsn,
             "the one-shot migrate boot did not configure Courier.OwnerRepo. " <>
               "It got: #{inspect(owner)}. `Courier.Release.migrate/0` runs as " <>
               "this repo and nothing else, so without it a migration has no " <>
               "connection to run on."
    end

    test "the serving variables really were absent, so the test above is a claim" do
      absent = Enum.reject(@serving_variables, &System.get_env/1)

      assert Enum.sort(absent) == Enum.sort(@serving_variables),
             "these serving variables were still set during the migrate test: " <>
               "#{inspect(@serving_variables -- absent)}. The setup is supposed to " <>
               "run on a bare box."
    end

    test "does not require DATABASE_URL, because a migration does not start Courier.Repo" do
      config = read_config!("eval")

      assert config[:courier][Courier.Repo][:url] == nil,
             "the migrate boot configured Courier.Repo with a URL from an unset " <>
               "DATABASE_URL. Got: #{inspect(config[:courier][Courier.Repo])}"
    end

    test "still evaluates when the owner DSN is absent — the refusal is Ecto's, later" do
      System.delete_env("COURIER_OWNER_DATABASE_URL")

      config = read_config!("eval")

      assert config[:courier][Courier.OwnerRepo] == nil,
             "Courier.OwnerRepo was configured with no owner DSN present"
    end
  end

  describe "the server boot without an inbound secret" do
    test "boots with no inbound secret, and configures an empty map" do
      System.put_env("COURIER_IDENTITY_TOKEN", "anywaye_fixture-not-a-real-credential")
      System.put_env("COURIER_SECRET_BOX_KEY", "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE=")
      System.put_env("COURIER_ERROR_RELAY_TOKEN", "test-only-not-a-secret")
      System.put_env("COURIER_MAIL_ADAPTER", "cloudflare")
      System.put_env("COURIER_CLOUDFLARE_API_KEY", "fixture-not-a-credential")
      System.put_env("COURIER_CF_ACCOUNT_ID", "fixture-account-id")
      System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/courier_test")
      System.put_env("SECRET_KEY_BASE", "test-only-not-a-secret-000000000000000000000000000000")

      System.delete_env("COURIER_INBOUND_RESEND_SECRET")
      System.delete_env("COURIER_SMTP_HOST")
      System.delete_env("COURIER_SMTP_USERNAME")
      System.delete_env("COURIER_SMTP_PASSWORD")

      config = read_config!("start")

      assert config[:courier][:inbound_secrets] == %{},
             "a server boot with no inbound secret should configure an empty map, got: #{inspect(config[:courier][:inbound_secrets])}"
    end

    test "an empty inbound secret is the same as unset" do
      System.put_env("COURIER_IDENTITY_TOKEN", "anywaye_fixture-not-a-real-credential")
      System.put_env("COURIER_SECRET_BOX_KEY", "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE=")
      System.put_env("COURIER_ERROR_RELAY_TOKEN", "test-only-not-a-secret")
      System.put_env("COURIER_MAIL_ADAPTER", "cloudflare")
      System.put_env("COURIER_CLOUDFLARE_API_KEY", "fixture-not-a-credential")
      System.put_env("COURIER_CF_ACCOUNT_ID", "fixture-account-id")
      System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/courier_test")
      System.put_env("SECRET_KEY_BASE", "test-only-not-a-secret-000000000000000000000000000000")
      System.put_env("COURIER_INBOUND_RESEND_SECRET", "")

      System.delete_env("COURIER_SMTP_HOST")
      System.delete_env("COURIER_SMTP_USERNAME")
      System.delete_env("COURIER_SMTP_PASSWORD")

      config = read_config!("start")

      assert config[:courier][:inbound_secrets] == %{},
             "an empty COURIER_INBOUND_RESEND_SECRET should be treated as unset"
    end

    test "a set inbound secret configures the resend provider" do
      System.put_env("COURIER_IDENTITY_TOKEN", "anywaye_fixture-not-a-real-credential")
      System.put_env("COURIER_SECRET_BOX_KEY", "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE=")
      System.put_env("COURIER_ERROR_RELAY_TOKEN", "test-only-not-a-secret")
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.test")
      System.put_env("COURIER_SMTP_USERNAME", "fixture")
      System.put_env("COURIER_SMTP_PASSWORD", "fixture")
      System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/courier_test")
      System.put_env("SECRET_KEY_BASE", "test-only-not-a-secret-000000000000000000000000000000")
      System.put_env("COURIER_INBOUND_RESEND_SECRET", "whsec_dGVzdC1vbmx5LWZpeHR1cmU=")

      config = read_config!("start")

      assert config[:courier][:inbound_secrets] == %{"resend" => "whsec_dGVzdC1vbmx5LWZpeHR1cmU="}
    end

    test "boot without inbound composes the cost notice, naming no secret value" do
      System.put_env("COURIER_IDENTITY_TOKEN", "anywaye_fixture-not-a-real-credential")
      System.put_env("COURIER_SECRET_BOX_KEY", "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE=")
      System.put_env("COURIER_ERROR_RELAY_TOKEN", "test-only-not-a-secret")
      System.put_env("COURIER_MAIL_ADAPTER", "cloudflare")
      System.put_env("COURIER_CLOUDFLARE_API_KEY", "fixture-not-a-credential")
      System.put_env("COURIER_CF_ACCOUNT_ID", "fixture-account-id")
      System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/courier_test")
      System.put_env("SECRET_KEY_BASE", "test-only-not-a-secret-000000000000000000000000000000")
      System.delete_env("COURIER_INBOUND_RESEND_SECRET")
      System.delete_env("COURIER_SMTP_HOST")
      System.delete_env("COURIER_SMTP_USERNAME")
      System.delete_env("COURIER_SMTP_PASSWORD")

      notices = read_config!("start")[:courier][:startup_notices]

      assert Enum.any?(notices, fn {_level, message} ->
               message =~ "inbound: no provider configured"
             end),
             "the boot must compose the unconfigured-inbound warning, got: #{inspect(notices)}"

      assert Enum.any?(notices, fn {_level, message} ->
               message =~
                 "a hard bounce or a spam complaint is discarded and courier goes on mailing an address that has said it is gone"
             end),
             "the notice must keep the cost sentence from the old raise"

      assert Enum.any?(notices, fn {_level, message} ->
               message == "mailer: adapter=cloudflare token=set account_id=set"
             end),
             "the boot must also compose the resolved mail-adapter notice, got: #{inspect(notices)}"

      refute inspect(notices) =~ "fixture-not-a-credential",
             "a credential value reached a startup notice:\n#{inspect(notices)}"
    end

    test "boot with inbound composes the verifying notice and no cost" do
      System.put_env("COURIER_IDENTITY_TOKEN", "anywaye_fixture-not-a-real-credential")
      System.put_env("COURIER_SECRET_BOX_KEY", "Y291cmllci10ZXN0LW9ubHkta2V5LTMyLWJ5dGVzISE=")
      System.put_env("COURIER_ERROR_RELAY_TOKEN", "test-only-not-a-secret")
      System.put_env("COURIER_MAIL_ADAPTER", "smtp")
      System.put_env("COURIER_SMTP_HOST", "smtp.test")
      System.put_env("COURIER_SMTP_USERNAME", "fixture")
      System.put_env("COURIER_SMTP_PASSWORD", "fixture")
      System.put_env("DATABASE_URL", "ecto://postgres:postgres@localhost/courier_test")
      System.put_env("SECRET_KEY_BASE", "test-only-not-a-secret-000000000000000000000000000000")
      System.put_env("COURIER_INBOUND_RESEND_SECRET", "whsec_dGVzdC1vbmx5LWZpeHR1cmU=")

      notices = read_config!("start")[:courier][:startup_notices]

      assert Enum.any?(notices, fn {_level, message} ->
               message =~ "inbound: verifying"
             end),
             "a boot with a provider must compose the verifying notice, got: #{inspect(notices)}"

      refute Enum.any?(notices, fn {_level, message} ->
               message =~ "no provider configured"
             end),
             "a boot with a provider must not compose the no-provider warning"

      refute inspect(notices) =~ "whsec_",
             "the notice must not name a secret value even when verifying"
    end
  end

  describe "the server boot" do
    test "refuses without COURIER_IDENTITY_TOKEN, and names the variable" do
      assert_raise RuntimeError, ~r/COURIER_IDENTITY_TOKEN is missing/, fn ->
        read_config!("start")
      end
    end

    test "refuses for every command that serves, not only `start`" do
      for command <- @commands_that_serve do
        assert_raise RuntimeError, ~r/COURIER_IDENTITY_TOKEN is missing/, fn ->
          read_config!(command)
        end
      end
    end

    test "and `mix` (no RELEASE_COMMAND at all) is treated as the server" do
      System.delete_env("RELEASE_COMMAND")

      assert_raise RuntimeError, ~r/COURIER_IDENTITY_TOKEN is missing/, fn ->
        prod_config()
      end
    end
  end

  describe "the entrypoints, held to the split" do
    test "bin/migrate runs the release's `eval` command" do
      migrate = File.read!("rel/overlays/bin/migrate")

      assert migrate =~ "eval Courier.Release.migrate",
             "rel/overlays/bin/migrate no longer runs `eval`. The config split keys " <>
               "on RELEASE_COMMAND=eval, so a migrate entrypoint using `start` would " <>
               "put the server's credential contract back in front of the migrate pod."
    end

    test "bin/server runs `start`, so the contract stays in front of it" do
      server = File.read!("rel/overlays/bin/server")

      assert server =~ "courier start",
             "rel/overlays/bin/server does not run `start`. If it ran `eval` the " <>
               "server would skip the credential contract the migrate path is the " <>
               "only boot allowed to skip."

      assert server =~ "PHX_SERVER=true",
             "rel/overlays/bin/server does not set PHX_SERVER, so its endpoints " <>
               "never listen and nothing reaches the contract this is about."
    end

    test "config/runtime.exs keys the split on RELEASE_COMMAND and on `eval`" do
      runtime = File.read!("config/runtime.exs")

      assert runtime =~ ~s|System.get_env("RELEASE_COMMAND") != "eval"|,
             "config/runtime.exs no longer derives `serving?` from RELEASE_COMMAND. " <>
               "The migrate/server split has to come from the release's own signal, " <>
               "not from a variable a server could carry by accident."
    end
  end


  defp read_config!(command) do
    System.put_env("RELEASE_COMMAND", command)
    prod_config()
  end

  defp prod_config, do: Config.Reader.read!("config/runtime.exs", env: :prod)

  defp restore(previous) do
    Enum.each(previous, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
