defmodule Courier.TelemetryTest do
  @moduledoc """
  The endpoint contract, asserted directly.

  These are the rules `config/runtime.exs` delegates to, so they are tested here
  rather than by reading the file. The environment is set and cleared explicitly
  per test because the contract IS the environment — and a test that mutated the
  process environment without restoring it would leave the next test in this file
  asserting something the last one changed.
  """

  use ExUnit.Case, async: false

  alias Courier.Telemetry

  @contract [
    "COURIER_OTEL_ENDPOINT",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_SDK_DISABLED",
    "OTEL_TRACES_EXPORTER",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_SERVICE_VERSION",
    "DEPLOYMENT_ENVIRONMENT",
    "COURIER_TENANT_ID"
  ]

  setup do
    saved = Map.new(@contract, fn name -> {name, System.get_env(name)} end)
    Enum.each(@contract, fn name -> System.delete_env(name) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "the endpoint contract is one variable" do
    test "unset falls back to the collector that ships with the stack" do
      # That is the whole of "a deployer gets traces without assembling them": the
      # default address IS kit's collector, over the compose network.
      assert Telemetry.endpoint() == "http://otel-collector:4318"
    end

    test "the anywaye variable wins over the standard one, and the precedence is written down" do
      System.put_env("COURIER_OTEL_ENDPOINT", "https://otlp.example.com:4318")
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://other.example.com:4318")

      assert Telemetry.endpoint() == "https://otlp.example.com:4318"
    end

    test "the standard variable works for generic tooling" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://other.example.com:4318")

      assert Telemetry.endpoint() == "https://other.example.com:4318"
    end

    test "an empty value is a missing value" do
      # An empty endpoint exported nowhere while the startup line said telemetry
      # started, and that is the failure this whole file exists to rule out.
      System.put_env("COURIER_OTEL_ENDPOINT", "")

      assert Telemetry.endpoint() == "http://otel-collector:4318"
    end

    test "the compose file and the code name the same default" do
      # Two places naming one value is the cost of the code having to work when
      # nobody runs compose at all. This is what keeps the two from drifting, and
      # it is a one-line diff when one of them moves.
      compose = File.read!(Path.join(File.cwd!(), "docker-compose.yml"))
      default = "http://otel-collector:4318"

      assert compose =~ default,
             "docker-compose.yml no longer names #{default} for COURIER_OTEL_ENDPOINT"

      assert Telemetry.endpoint() == default
    end
  end

  describe "the kill switches are the specification's own" do
    test "OTEL_SDK_DISABLED wins in every casing" do
      for value <- ~w(true TRUE True) do
        System.put_env("OTEL_SDK_DISABLED", value)
        refute Telemetry.enabled?(), "enabled? was true with OTEL_SDK_DISABLED=#{value}"
      end
    end

    test "a value that merely CONTAINS the word is not the switch" do
      # `OTEL_SDK_DISABLED=nottrue` reading as disabled is a service that has
      # silently stopped exporting because somebody typed a word.
      for value <- ~w(nottrue false yes enabled 1) do
        System.put_env("OTEL_SDK_DISABLED", value)
        assert Telemetry.enabled?(), "enabled? was false with OTEL_SDK_DISABLED=#{value}"
      end
    end

    test "all THREE per-signal switches are checked, not just traces" do
      # A no-op that only covers traces is a service that still phones home, and
      # that is the failure discovered by a customer's invoice rather than by a test.
      signals = ~w(OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER)

      for name <- signals do
        # ONE at a time, deleting the previous. The first version set all three
        # inside the loop without clearing, so iteration two saw
        # `TRACES=none, METRICS=none` and the assertion for "METRICS=none" was
        # really asserting about two switches. A test that reports a narrower claim
        # than the one it makes is a test that cannot fail for the right reason.
        Enum.each(signals, fn variable -> System.delete_env(variable) end)
        System.put_env(name, "none")

        refute Telemetry.enabled?(), "enabled? was true with #{name}=none"
        assert Telemetry.no_op_reason() == "#{name}=none"
      end

      Enum.each(signals, fn variable -> System.put_env(variable, "none") end)

      assert Telemetry.no_op_reason() ==
               "OTEL_TRACES_EXPORTER,OTEL_METRICS_EXPORTER,OTEL_LOGS_EXPORTER=none"
    end

    test "the reason is empty on the ENABLED path" do
      # The startup line is only ever for the disabled path. Silence is the
      # contract there: a warning per export attempt fills courier's own log store
      # with the fact that telemetry is off, which is how a self-hoster discovers
      # that turning it off is not supported.
      assert Telemetry.no_op_reason() == ""
    end
  end

  describe "sdk_config/0" do
    test "names the W3C propagators explicitly rather than inheriting a default" do
      # The default IS W3C today, and a service that depends on a default it never
      # wrote down breaks silently the first time a library changes it.
      assert :trace_context in Telemetry.sdk_config()[:text_map_propagators]
      assert :baggage in Telemetry.sdk_config()[:text_map_propagators]
    end

    test "the sampler respects the caller's decision" do
      # A service that samples independently produces traces with holes, which are
      # worse to debug than no traces at all.
      assert {:parent_based, %{root: :always_on}} = Telemetry.sdk_config()[:sampler]
    end

    test "the enabled path builds a batch processor pointed at the endpoint" do
      System.put_env("COURIER_OTEL_ENDPOINT", "https://otlp.example.com:4318")
      assert {:otel_batch_processor, config} = Telemetry.sdk_config()[:span_processor]

      assert {:opentelemetry_exporter, %{endpoints: ["https://otlp.example.com:4318"]}} =
               config.exporter
    end

    test "the disabled path BOOTS, and this is not the same claim as the one above" do
      # `sdk_config/0` returning the right keyword list is not a boot. This asserts
      # the shape that `otel_configuration:processors/2` actually accepts, which is
      # a DIFFERENT shape from the one this file used to assert — see the note on
      # `processors: []` in `Courier.Telemetry.sdk_config/0`.
      #
      # It is here, and not only there, because the defect was invisible to every
      # other assertion in this file: `config/runtime.exs` guards the SDK block with
      # `config_env() != :test`, so nothing in the suite ever evaluated the disabled
      # configuration against a running SDK. An assertion about a configuration is
      # not a boot.
      System.put_env("OTEL_SDK_DISABLED", "true")
      config = Telemetry.sdk_config()

      # NO `span_processor` key at all. The key's value is wrapped in a
      # one-element list and mapped over as `{Name, Opts}` PAIRS, so a bare atom
      # and an empty list both raise FunctionClauseError inside the SDK:
      #
      #     span_processor: :otel_simple_processor -> anonymous fn(:otel_simple_processor)
      #     span_processor: []                     -> anonymous fn([])
      #     both at otel_configuration.erl:179
      refute Keyword.has_key?(config, :span_processor)

      assert config[:processors] == []

      # And the propagators survive, because the no-op is about EXPORTING and not
      # about parsing: a request carrying a traceparent still continues its trace
      # with telemetry switched off.
      assert :trace_context in config[:text_map_propagators]
      assert :baggage in config[:text_map_propagators]
    end

    test "the disabled path builds NO exporter at all" do
      # Not an exporter pointed at nothing and left to retry, not a batch processor
      # with a queue behind it. A queue that accepts spans and holds them is a memory
      # leak with a telemetry-shaped trigger; a retry loop against an endpoint that
      # is not there is a process waking on a timer for the life of the release,
      # invisible in every dashboard because nothing is being recorded.
      #
      # `:otel_simple_processor` holds no queue and exports nowhere, and it keeps
      # every `[:telemetry, :span]` call in the codebase valid, so no call site
      # needs an `if telemetry_enabled?` around it.
      System.put_env("OTEL_SDK_DISABLED", "true")

      refute Keyword.has_key?(Telemetry.sdk_config(), :span_processor)
      assert Telemetry.sdk_config()[:processors] == []
    end

    test "it is a keyword list, because Config.config/2 accepts only a keyword list" do
      # The first version returned a map: it type-checks in isolation and then
      # raises inside `Config` at boot, which is the worst place to find out.
      assert Keyword.keyword?(Telemetry.sdk_config())
    end
  end

  describe "resource/0" do
    test "carries service identity, and the tenant only when it is set" do
      resource = Telemetry.resource()

      assert resource.service.name == "courier"
      assert resource.service.version == "0.0.0"
      refute Map.has_key?(resource, :tenant_id)
    end

    test "the tenant goes on the RESOURCE and not on a measurement" do
      # core's metrics schema puts `tenant_id` in both lists with opposite
      # meanings: PROHIBITED as a measurement attribute, REQUIRED on the resource.
      # Resource attributes are exempt from the 2000-attribute-combination cap, so
      # a per-tenant total stays answerable after the measurement has folded. Move it
      # onto a measurement and every per-tenant breakdown silently undercounts while
      # the total stays right, with no error anywhere.
      System.put_env("COURIER_TENANT_ID", "tenant-abc")

      assert Telemetry.resource().tenant_id == "tenant-abc"
      refute "tenant_id" in Courier.Observability.allowed_span_attributes()
    end

    test "an unset variable is ABSENT rather than an empty string" do
      # `service.version=""` is not a tidier version than no version: a collector
      # that groups by it gets a second service row distinguished by an empty
      # string, and an operator looking at a service list sees the same service
      # twice with one of them reporting no builds.
      System.put_env("DEPLOYMENT_ENVIRONMENT", "production")

      resource = Telemetry.resource()

      assert resource.deployment == "production"
      refute Map.has_key?(resource, :tenant_id)
    end

    test "the version is read at RUNTIME, not from Mix" do
      # A compile-time `Mix.Project.config()` call makes this module unloadable by
      # plain `elixir`, so a module nobody can load is a module nobody can check —
      # and kit's gate checks these modules by loading them.
      System.put_env("OTEL_SERVICE_VERSION", "1.2.3")

      assert Telemetry.resource().service.version == "1.2.3"
    end
  end

  describe "exporter/0" do
    test "is the SDK's own OTLP exporter, except in test" do
      # In production it is the SDK's real encoding rather than a
      # reimplementation, which is what makes courier's spans readable by anything
      # speaking OTLP. In test it is the in-memory one named in `config/test.exs`,
      # and THIS test is the one that says so — an exporter chosen by
      # `MIX_ENV` rather than by configuration would pick the test one inside a
      # RELEASE, where `MIX_ENV` is unset, and courier would export nothing while
      # its startup line said telemetry was on.
      assert Telemetry.exporter() == Courier.TestSpanExporter
      assert Application.get_env(:courier, :otel_exporter) == Courier.TestSpanExporter
    end
  end

  describe "the tracer rebuild" do
    test "installs courier's own span processor, because the SDK cannot start one" do
      # The reproduction is in `Courier.SpanCollector`, and it is two commands
      # against every published version of the Erlang SDK. A tracer with no
      # processor creates spans, records attributes onto them, and then destroys them
      # on `end_span`.
      {module, record} = Telemetry.tracer()

      assert module == :otel_tracer_default
      assert is_tuple(record)

      fields = record |> Tuple.to_list() |> Enum.drop(1)
      on_end_index = Enum.find_index(Telemetry.tracer_fields(), &(&1 == :on_end_processors))
      on_end = Enum.at(fields, on_end_index)

      # A FUNCTION of arity 1, which is the SDK's declared type, and it must be
      # courier's — the whole point is that the SDK's own (empty) list is replaced.
      assert is_function(on_end, 1)

      # `:erlang.fun_info/2`, not `on_end.__info__(:module)`: a capture is a FUNCTION,
      # not a module, and calling `__info__` on one is an `:erlang.apply` on a
      # non-atom.
      assert elem(:erlang.fun_info(on_end, :module), 1) == Courier.SpanCollector
    end

    test "the SDK's tracer record has the shape courier expects, or the rebuild raises" do
      # An SDK that renames a field takes courier down at boot with a message naming
      # it. That is the safe outcome: exporting nothing while the startup line says
      # telemetry is on is the failure the whole arrangement exists to prevent.
      {module, record} = :otel_tracer_provider.get_tracer(:courier_probe, nil, nil)

      assert elem(record, 0) == :tracer
      assert length(Tuple.to_list(record)) == length(Telemetry.tracer_fields()) + 1
      assert is_atom(module)
    end
  end
end
