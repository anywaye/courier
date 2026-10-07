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

  # `async: false` because these tests mutate the whole VM's environment. The
  # OS environment is the input `Courier.MailerAdapter` reads, so two of these
  # running concurrently could see each other's variables.
  use ExUnit.Case, async: false

  alias Courier.MailerAdapter

  @sentinel "courier-test-only-not-a-real-secret"

  setup do
    # Every variable this module reads, saved and restored. Restoring rather than
    # unsetting: a developer running `mix test` with `COURIER_SMTP_HOST` set in
    # their shell should get their environment back, not an emptied one.
    previous_env =
      Map.new(
        ~w(
        COURIER_MAIL_ADAPTER COURIER_SMTP_HOST COURIER_SMTP_PORT
        COURIER_SMTP_USERNAME COURIER_SMTP_PASSWORD COURIER_SMTP_AUTH
        COURIER_SMTP_TLS COURIER_SMTP_SSL COURIER_POSTMARK_API_TOKEN
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
      # A refusal an operator cannot act on is a support ticket. The message
      # names the variable and the two variables it implies.
      error =
        assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      message = Exception.message(error)

      assert message =~ "COURIER_MAIL_ADAPTER=smtp"
      assert message =~ "COURIER_SMTP_HOST"
    end

    test "an unset adapter is refused in dev too, not only in prod" do
      # Deliberately past the brief, and the reason is in the moduledoc: dev is
      # where somebody proves to themselves that it works. The refusal is the
      # same; the escape hatch is an explicit `none`.
      assert_raise RuntimeError, ~r/COURIER_MAIL_ADAPTER is missing/, fn ->
        MailerAdapter.adapter!(:dev)
      end
    end
  end

  describe "an adapter that cannot deliver is refused" do
    test "COURIER_MAIL_ADAPTER=none raises in prod" do
      # THE case. `none` is what the previous configuration hard-coded in prod:
      # `Swoosh.Adapters.Local`, which renders into memory and returns a
      # provider-shaped id. A courier shipping that would have accepted every
      # send and mailed nobody, with no error anywhere.
      System.put_env("COURIER_MAIL_ADAPTER", "none")

      assert_raise RuntimeError, ~r/none is not permitted in production/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the prod refusal says WHY, so it reads as a fault and not as a policy" do
      System.put_env("COURIER_MAIL_ADAPTER", "none")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      # The two facts an operator needs: it opens no socket, and it reports
      # sends as delivered anyway.
      assert message =~ "opens no socket"
      assert message =~ "reports every send as delivered"
    end

    test "COURIER_MAIL_ADAPTER=none is still allowed in dev" do
      # The escape hatch. A developer working on courier's templates without a
      # relay should be able to run it, and should have had to say so.
      System.put_env("COURIER_MAIL_ADAPTER", "none")

      assert [adapter: Swoosh.Adapters.Local] = MailerAdapter.adapter!(:dev)
    end

    test "an unknown adapter name is refused rather than resolved" do
      # `:string.to_atom/1` on a typo would produce an atom that exists only for
      # the process that made it, and the failure would surface at the socket.
      System.put_env("COURIER_MAIL_ADAPTER", "smtpp")

      assert_raise RuntimeError, ~r/is not an adapter courier ships/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "an adapter named as a module atom is refused — names, not modules" do
      # The value is a NAME from a fixed set. Accepting a module here would let
      # `COURIER_MAIL_ADAPTER=Swoosh.Adapters.Local` name the silent adapter
      # through the front door the refusal was built to close.
      System.put_env("COURIER_MAIL_ADAPTER", "Swoosh.Adapters.Local")

      assert_raise RuntimeError, ~r/is not an adapter courier ships/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "the silent adapters are refused by name in dev too, not only in prod" do
      # The closed set stays closed in EVERY environment. Dev is where a
      # courier is usually pointed at `Local`, and the escape hatch is the
      # explicit `none` — naming the module is a different thing and is refused
      # here exactly as it is in prod, because the unknown-adapter branch has
      # no environment guard. Asserted in both environments rather than
      # assumed: a refusal that only fired in prod would let a developer
      # configure the silent adapter and prove to themselves that "it works".
      for env <- [:dev, :test] do
        System.put_env("COURIER_MAIL_ADAPTER", "Swoosh.Adapters.Local")

        assert_raise RuntimeError, ~r/is not an adapter courier ships/, fn ->
          MailerAdapter.adapter!(env)
        end
      end
    end

    test "the unknown-adapter refusal lists every provider in the table" do
      # The supported-values list is generated from the provider table, so a
      # third provider appears here without a branch in the refusal. Asserted
      # rather than assumed: a hand-written list would go stale the day a
      # provider is added, and the staleness would be invisible.
      System.put_env("COURIER_MAIL_ADAPTER", "smtpp")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      assert message =~ "smtp"
      assert message =~ "postmark"
      assert message =~ "Swoosh.Adapters.SMTP"
      assert message =~ "Swoosh.Adapters.Postmark"
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
      # A relay courier is trusted by the network — a sidecar, a relay on the
      # same network — legitimately has no credentials, and refusing to boot
      # without them would make a valid deployment impossible.
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
      # `gen_smtp` refuses `auth: :always` without both halves with
      # `{:error, :no_credentials}` — at the socket, per send. Catching it here
      # turns a runtime failure into a boot failure.
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
      # `SMTP_PASSWORD=` in a compose file produces "". Sending that to a
      # provider is worse than refusing to start: the provider answers 535 and
      # the operator has no idea why.
      System.put_env("COURIER_SMTP_PASSWORD", "")

      assert_raise RuntimeError, ~r/COURIER_SMTP_PASSWORD is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "a non-numeric port is a boot failure naming the variable and the value" do
      System.put_env("COURIER_SMTP_PORT", "not-a-port")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end
      message = Exception.message(error)

      # Both halves. `String.to_integer/1`'s own error names neither the variable
      # nor the value, so an operator reading it has no idea what to fix.
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
      # `COURIER_SMTP_TLS=Always` is obviously what somebody meant, and refusing
      # it would train people to distrust the refusal.
      System.put_env("COURIER_SMTP_TLS", "Always")

      assert MailerAdapter.adapter!(:prod)[:tls] == :always
    end
  end

  describe "Postmark is configured from the environment" do
    # The second provider, and the proof that "email through more than one
    # provider" is configuration rather than a code change. The shape is
    # SMTP's exactly: the adapter name selects a builder, the builder reads
    # that provider's variables, and a missing one is a boot failure naming
    # the variable.
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
      # An operator reading this at boot needs to know WHICH provider's
      # variable is missing, not just the variable — the same refusal shape
      # SMTP's has, and the reason `required!/2` takes the provider name.
      System.delete_env("COURIER_POSTMARK_API_TOKEN")

      error = assert_raise RuntimeError, fn -> MailerAdapter.adapter!(:prod) end

      assert Exception.message(error) =~ "COURIER_POSTMARK_API_TOKEN"
      assert Exception.message(error) =~ "postmark"
    end

    test "an empty token is treated as missing, not sent to the provider" do
      # `COURIER_POSTMARK_API_TOKEN=` in a compose file produces "". Sending
      # that to Postmark is a 421 the operator cannot explain; refusing to
      # start is not.
      System.put_env("COURIER_POSTMARK_API_TOKEN", "")

      assert_raise RuntimeError, ~r/COURIER_POSTMARK_API_TOKEN is missing/, fn ->
        MailerAdapter.adapter!(:prod)
      end
    end

    test "Postmark is deliverable" do
      # The second boot gate (`verify_boot!/1`) asks this. A provider courier
      # ships has to pass it, or a correct deployment refuses to start — the
      # gate that must NOT fire.
      assert MailerAdapter.deliverable?(Swoosh.Adapters.Postmark)
    end

    test "the Swoosh HTTP client is wired for Postmark and not for SMTP" do
      # SMTP speaks the protocol over `gen_smtp` and never calls Swoosh's HTTP
      # client; Postmark posts through it. `config/runtime.exs` reads this to
      # decide whether to turn the client on — see the provider table.
      assert MailerAdapter.api_client(Swoosh.Adapters.Postmark) == Swoosh.ApiClient.Req
      assert MailerAdapter.api_client(Swoosh.Adapters.SMTP) == nil
      assert MailerAdapter.api_client(nil) == nil
      assert MailerAdapter.api_client(Swoosh.Adapters.Local) == nil
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
      # `nil` rather than a bare `refute` on a module that does not exist: the
      # question "can this deliver anything" has to have an answer for the case
      # where nothing is configured, which is the case this whole module is about.
      refute MailerAdapter.deliverable?(nil)
    end

    test "the silent adapters are named in one place, and it is the two" do
      # A third silent adapter added later would have to be added here. That is
      # the point: the set is asserted rather than assumed, so a new adapter
      # nobody has classified fails this test instead of quietly becoming
      # production's mail path.
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
      # The committed-configuration route to the silent adapter. `runtime.exs`
      # would have raised first if the environment were wrong, but a deployer who
      # set every variable correctly still had a path to here through a file — and
      # this gate reads what courier will actually send through, not the
      # environment.
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
      # An operator seeing this at boot should know it is a configuration problem
      # and which variable to look at, without reading the source.
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Local)

      message =
        try do
          MailerAdapter.verify_boot!(:prod)
        rescue
          error -> Exception.message(error)
        end

      # `describe/1` names the ADAPTER MODULE rather than the `none` alias,
      # because the operator needs to know what courier actually had configured,
      # and "none" is a name courier invented for the environment variable.
      assert message =~ "Swoosh.Adapters.Local"
      assert message =~ "COURIER_MAIL_ADAPTER"
      assert message =~ "COURIER_SMTP_HOST"
    end

    test "verify_boot!/0 passes in prod for SMTP" do
      # The gate that must NOT fire: a correctly configured deployment has to
      # start. A check that refuses everything is as useless as one that refuses
      # nothing.
      Application.put_env(:courier, Courier.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example-provider.test"
      )

      assert MailerAdapter.verify_boot!(:prod) == :ok
    end

    test "verify_boot!/0 does not fire in test, where the Test adapter is correct" do
      # The other half of "not vacuous": a check scoped to prod only. The suite
      # configures `Swoosh.Adapters.Test` deliberately and `assert_email_sent/1`
      # depends on it, so a gate that fired here would make the suite unable to
      # use the adapter it is built on.
      Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Test)

      assert MailerAdapter.verify_boot!(:test) == :ok
    end

    test "the application controller calls the gate" do
      # The gate is worthless if nothing calls it, and a gate that is only called
      # from `config/runtime.exs` would be the same check twice. Asserted against
      # the source rather than by restarting the application, because restarting
      # `:courier` inside the suite would take the Repo, the endpoint and the
      # Oban queue down with it — the situation `Courier.HealthTest` builds
      # deliberately and this file has no business repeating.
      source = File.read!(Path.join([File.cwd!(), "lib", "courier", "application.ex"]))

      assert source =~ "Courier.MailerAdapter.verify_boot!()",
             "Courier.Application.start/2 does not call the adapter boot gate"
    end
  end

  describe "the default port is the submission port" do
    test "587, not 25" do
      # Asserted rather than left implicit because it is the difference between
      # an outbound submission and an inbound relay, and getting it wrong means
      # a connection refused on a port nobody was listening on.
      assert MailerAdapter.default_port() == 587
    end
  end
end
