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
      System.put_env("COURIER_OTEL_ENDPOINT", "")

      assert Telemetry.endpoint() == "http://otel-collector:4318"
    end

    test "the compose file and the code name the same default" do
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
      for value <- ~w(nottrue false yes enabled 1) do
        System.put_env("OTEL_SDK_DISABLED", value)
        assert Telemetry.enabled?(), "enabled? was false with OTEL_SDK_DISABLED=#{value}"
      end
    end

    test "all THREE per-signal switches are checked, not just traces" do
      signals = ~w(OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER)

      for name <- signals do
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
      assert Telemetry.no_op_reason() == ""
    end
  end

  describe "sdk_config/0" do
    test "names the W3C propagators explicitly rather than inheriting a default" do
      assert :trace_context in Telemetry.sdk_config()[:text_map_propagators]
      assert :baggage in Telemetry.sdk_config()[:text_map_propagators]
    end

    test "the sampler respects the caller's decision" do
      assert {:parent_based, %{root: :always_on}} = Telemetry.sdk_config()[:sampler]
    end

    test "the enabled path builds a batch processor pointed at the endpoint" do
      System.put_env("COURIER_OTEL_ENDPOINT", "https://otlp.example.com:4318")
      assert {:otel_batch_processor, config} = Telemetry.sdk_config()[:span_processor]

      assert {:opentelemetry_exporter, %{endpoints: ["https://otlp.example.com:4318"]}} =
               config.exporter
    end

    test "the disabled path BOOTS, and this is not the same claim as the one above" do
      System.put_env("OTEL_SDK_DISABLED", "true")
      config = Telemetry.sdk_config()

      refute Keyword.has_key?(config, :span_processor)

      assert config[:processors] == []

      assert :trace_context in config[:text_map_propagators]
      assert :baggage in config[:text_map_propagators]
    end

    test "the disabled path builds NO exporter at all" do
      System.put_env("OTEL_SDK_DISABLED", "true")

      refute Keyword.has_key?(Telemetry.sdk_config(), :span_processor)
      assert Telemetry.sdk_config()[:processors] == []
    end

    test "it is a keyword list, because Config.config/2 accepts only a keyword list" do
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
      System.put_env("COURIER_TENANT_ID", "tenant-abc")

      assert Telemetry.resource().tenant_id == "tenant-abc"
      refute "tenant_id" in Courier.Observability.allowed_span_attributes()
    end

    test "an unset variable is ABSENT rather than an empty string" do
      System.put_env("DEPLOYMENT_ENVIRONMENT", "production")

      resource = Telemetry.resource()

      assert resource.deployment == "production"
      refute Map.has_key?(resource, :tenant_id)
    end

    test "the version is read at RUNTIME, not from Mix" do
      System.put_env("OTEL_SERVICE_VERSION", "1.2.3")

      assert Telemetry.resource().service.version == "1.2.3"
    end
  end

  describe "exporter/0" do
    test "is the SDK's own OTLP exporter, except in test" do
      assert Telemetry.exporter() == Courier.TestSpanExporter
      assert Application.get_env(:courier, :otel_exporter) == Courier.TestSpanExporter
    end
  end

  describe "the tracer rebuild" do
    test "installs courier's own span processor, because the SDK cannot start one" do
      {module, record} = Telemetry.tracer()

      assert module == :otel_tracer_default
      assert is_tuple(record)

      fields = record |> Tuple.to_list() |> Enum.drop(1)
      on_end_index = Enum.find_index(Telemetry.tracer_fields(), &(&1 == :on_end_processors))
      on_end = Enum.at(fields, on_end_index)

      assert is_function(on_end, 1)

      assert elem(:erlang.fun_info(on_end, :module), 1) == Courier.SpanCollector
    end

    test "the SDK's tracer record has the shape courier expects, or the rebuild raises" do
      {module, record} = :otel_tracer_provider.get_tracer(:courier_probe, nil, nil)

      assert elem(record, 0) == :tracer
      assert length(Tuple.to_list(record)) == length(Telemetry.tracer_fields()) + 1
      assert is_atom(module)
    end
  end
end
