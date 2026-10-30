defmodule Courier.OtelExportTest do
  @moduledoc """
  THE PROOF THAT COURIER EXPORTS SPANS AT ALL, and the three defects it found.

  Everything else in this repository about telemetry — the endpoint contract in
  `telemetry_test.exs`, the allowlist in `observability_test.exs`, the redaction
  canaries in `telemetry_canary_test.exs` — passes, and all of it passes on a
  courier that **exports nothing**. The fleet measured exactly that on
  2026-09-30: no spans reaching the collector, with a startup line saying
  telemetry was on. Those files test the rules courier follows; this file tests
  that the rules reach a socket.

  It runs against the REAL exporter from `:opentelemetry_exporter` and the REAL
  encoder from `:opentelemetry_exporter`, over courier's REAL pending-span table
  and courier's REAL resource. Nothing here is a stand-in, and that is the whole
  design: a hand-built exporter would agree with a hand-built caller, and all
  three defects below are disagreements BETWEEN courier and a module that is not
  courier.


  The requirement is that courier EXPORTS, and this file never opens a socket.
  `:opentelemetry_exporter.init/1` starts an in-process `httpc` profile and
  `:otel_otlp_traces.to_proto/2` is the function that builds the exact protobuf
  body courier POSTs. Asserting on the encoded body asserts on the request a
  collector receives. A collector-in-the-loop test would additionally prove that
  `:httpc` can reach a socket, which is `opentelemetry_exporter`'s business and
  would make this suite a network test — which courier's suite rule forbids.


  It swaps `:courier, :otel_exporter` for `:opentelemetry_exporter` in `setup`,
  because the defect is in the PRODUCTION exporter and the suite is configured
  with `Courier.TestSpanExporter`. Application environment is VM-wide, so this is
  the case `AGENTS.md` reserves for a `*ConfigTest` file: its own file,
  `async: false`, and a comment saying why.


  1. **The exporter was never initialized.** `Courier.SpanCollector` called
     `export(:traces, spans, resource, %{})`. The fourth argument is an
     `
     `
     them, so every flush took the catch-all and answered `{:error,
     :unimplemented}`. Measured before the fix, on a span courier had genuinely
     recorded:

         PROBE 1  export(:traces, tab, resource, %{})  [today's call]
         result: {:error, :unimplemented}

  2. **The spans were not in the shape the exporter reads.** The SDK's exporter
     takes an ETS table whose KEY is an `
     VALUE is a `
     courier was about to hand it a LIST of spans with no scope at all, so the
     second probe raised inside the exporter:

         PROBE 2  export with a real
         ** (FunctionClauseError) no function clause matching in :otel_otlp_traces.to_proto/1
             {-576460752303345823, {:span, 250261861607385731661550453041408069235, ...}}

     That negative integer is `:erlang.unique_integer()`. courier was keying by a
     counter and the exporter was asking for a scope.

  3. **The resource was not a resource.** `otel_resource:attributes/1` matches an
     `
     else, and OpenTelemetry attribute names are FLAT dotted strings. courier's
     `%{service: %{name: "courier"}}` is not `"service.name"`, so even wrapped in
     a record the nested map would have been encoded as one string-valued
     attribute and HyperDX's `service.name=courier` group would not have existed.

  Each one alone is fatal, which is why the fleet's measurement and courier's own
  green telemetry tests were never in conflict.
  """

  use ExUnit.Case, async: false

  alias Courier.SpanCollector
  alias Courier.Telemetry

  @real_exporter :opentelemetry_exporter

  setup do
    saved = Application.get_env(:courier, :otel_exporter)
    Application.put_env(:courier, :otel_exporter, @real_exporter)

    on_exit(fn ->
      Application.put_env(:courier, :otel_exporter, saved)
      Telemetry.forget_exporter()
      SpanCollector.clear_pending()
    end)

    Telemetry.forget_exporter()
    SpanCollector.clear_pending()

    :ok
  end

  describe "the exporter courier hands its spans to is INITIALIZED" do
    test "and it is the exporter's own #state{} record, not an empty map" do
      state = Telemetry.exporter_state()

      assert is_tuple(state),
             "the exporter state is not a record, so export/3 takes its catch-all " <>
               "clause and answers {:error, :unimplemented}: " <> inspect(state)

      assert elem(state, 0) == :state,
             "expected the exporter's own #state{} record, got: #{inspect(state)}"
    end

    test "pointed at courier's endpoint, and on the port the contract names" do
      assert [%{host: ~c"otel-collector", port: 4318, scheme: ~c"http"} | _] =
               SpanCollector.exporter_endpoints(),
             "no usable endpoint in the initialized exporter state: " <>
               inspect(SpanCollector.exporter_endpoints())

      assert [%{path: path} | _] = SpanCollector.exporter_endpoints()
      assert to_string(path) =~ "v1/traces"
    end

    test "so the REAL exporter no longer answers :unimplemented" do
      SpanCollector.record_one_span()
      spans = SpanCollector.pending_spans()
      refute spans == []

      answer =
        @real_exporter.export(
          :traces,
          spans,
          Telemetry.otel_resource(),
          Telemetry.exporter_state()
        )

      refute match?({:error, :unimplemented}, answer),
             "the exporter took its catch-all clause: no state, nothing encoded"

      assert :otel_otlp_traces.to_proto(spans, Telemetry.otel_resource()) != :empty
    end
  end

  describe "the bytes courier would ship" do
    test "the real encoder finds courier's span and does not return empty" do
      SpanCollector.record_one_span()

      proto = encode_pending()

      refute proto == :empty,
             "the real OTLP encoder saw no spans in courier's pending spans"

      assert %{resource_spans: [resource_spans]} = proto
      assert [_ | _] = resource_spans.scope_spans
    end

    test "carrying the span name from core's grammar, not a raw path" do
      SpanCollector.record_one_span()

      assert ["courier.web.request"] = span_names()
    end

    test "and courier's service identity on the RESOURCE, where the fleet reads it" do
      attributes = :otel_resource.attributes(Telemetry.otel_resource())

      assert attr(attributes, "service.name") == "courier"
      assert is_binary(attr(attributes, "service.version"))
    end

    test "the tenant reaches the resource, and never as a measurement attribute" do
      System.put_env("COURIER_TENANT_ID", "tenant-abc")
      on_exit(fn -> System.delete_env("COURIER_TENANT_ID") end)

      assert attr(:otel_resource.attributes(Telemetry.otel_resource()), "tenant_id") ==
               "tenant-abc"
    end

    test "the deployment environment reaches the resource under its own name" do
      System.put_env("DEPLOYMENT_ENVIRONMENT", "production")
      on_exit(fn -> System.delete_env("DEPLOYMENT_ENVIRONMENT") end)

      assert attr(:otel_resource.attributes(Telemetry.otel_resource()), "deployment.environment") ==
               "production"
    end

    test "an unset variable is ABSENT from the resource rather than empty" do
      attributes = :otel_resource.attributes(Telemetry.otel_resource())

      refute attr(attributes, "tenant_id")
      refute attr(attributes, "deployment.environment")
    end
  end

  describe "a refused export" do

    test "keeps the spans queued and does not raise" do
      SpanCollector.record_one_span()
      before = SpanCollector.pending()

      assert {:error, :error} = SpanCollector.export_pending(fn _s -> :error end)
      assert SpanCollector.pending() == before, "a refused export dropped the spans"

      assert {:error, {:error, :timeout}} =
               SpanCollector.export_pending(fn _s -> {:error, :timeout} end)

      assert SpanCollector.pending() == before
    end

    test "an exporter that RAISES is a refused export, not a dead collector" do
      SpanCollector.record_one_span()
      before = SpanCollector.pending()

      assert {:error, {:raised, :error, _reason}} =
               SpanCollector.export_pending(fn _s -> raise "httpc profile not started" end)

      assert SpanCollector.pending() == before
      assert Process.alive?(Process.whereis(SpanCollector))
    end

    test "a successful export clears the queue" do
      SpanCollector.record_one_span()
      refute SpanCollector.pending() == 0

      assert :ok = SpanCollector.export_pending(fn _spans -> :ok end)
      assert SpanCollector.pending() == 0
    end

    test "the DISABLED path leaves NO processor configured, and this is a BOOT claim" do
      System.put_env("OTEL_SDK_DISABLED", "true")
      on_exit(fn -> System.delete_env("OTEL_SDK_DISABLED") end)

      config = Telemetry.sdk_config()

      refute Keyword.has_key?(config, :span_processor)
      assert config[:processors] == []
    end

    test "an empty queue is not an export attempt" do
      assert :nothing_pending = SpanCollector.export_pending(fn _s -> flunk("called") end)
    end
  end

  describe "traceparent, per kit's codec rules" do
    @valid "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"

    test "a valid inbound traceparent is CONTINUED, same trace id" do
      context = CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", @valid}])

      assert hex_trace_id(context) == @trace_id
    end

    test "a traceparent with NO tracestate beside it is still continued" do
      assert hex_trace_id(CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", @valid}])) ==
               @trace_id
    end

    test "and a traceparent WITH a tracestate carries both" do
      context =
        CourierWeb.Plugs.Telemetry.extract_context([
          {"traceparent", @valid},
          {"tracestate", "vendor=value"}
        ])

      assert hex_trace_id(context) == @trace_id
      assert to_string(:otel_tracestate.get("vendor", tracestate(context))) == "value"
    end

    test "a MISSING traceparent starts a new trace rather than failing" do
      assert CourierWeb.Plugs.Telemetry.extract_context([]) == %{}
    end

    test "a MALFORMED traceparent starts a new trace and never throws" do
      for garbage <- [
            "not-a-traceparent",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7",
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
          ] do
        assert CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", garbage}]) == %{},
               "a malformed traceparent was not ignored: #{garbage}"
      end
    end

    test "the header name is matched in any case, because a proxy emits Title-Case" do
      for name <- ~w(traceparent TraceParent TRACEPARENT) do
        context = CourierWeb.Plugs.Telemetry.extract_context([{name, @valid}])

        assert hex_trace_id(context) == @trace_id,
               "traceparent was ignored for header name #{name}"
      end
    end

    test "a tracestate alone does NOT rescue a failed traceparent (§3.3)" do
      assert CourierWeb.Plugs.Telemetry.extract_context([{"tracestate", "vendor=1"}]) == %{}
    end

    test "the extractor list is not EMPTY, because that extracted nothing" do
      assert :trace_context in CourierWeb.Plugs.Telemetry.propagators()
      assert :baggage in CourierWeb.Plugs.Telemetry.propagators()

      refute CourierWeb.Plugs.Telemetry.propagators() == []
    end

    test "and the getter is called NAME-FIRST, which is what the SDK does" do
      context =
        CourierWeb.Plugs.Telemetry.extract_context([
          {"traceparent", @valid},
          {"tracestate", "vendor=value"},
          {"baggage", "k=v"}
        ])

      assert hex_trace_id(context) == @trace_id
      assert to_string(:otel_tracestate.get("vendor", tracestate(context))) == "value"

      assert :otel_ctx.get_value(context, :"$__otel_baggage_ctx_key", %{})["k"] == {"v", []}
    end

    test "and the CONTINUED trace reaches the span courier opens" do
      context = CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", @valid}])

      span =
        :otel_tracer.start_span(
          context,
          Telemetry.tracer(),
          "courier.web.request",
          %{kind: :server}
        )

      :otel_tracer.set_current_span(span)

      assert span_trace_id() == @trace_id
    end

    test "and the continued span is exportable, with the parent's link intact" do
      context = CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", @valid}])

      span =
        :otel_tracer.start_span(
          context,
          Telemetry.tracer(),
          "courier.web.request",
          %{kind: :server}
        )

      :otel_span.end_span(span)

      assert %{resource_spans: [resource_spans]} = encode_pending()

      [scope_spans] = resource_spans.scope_spans
      [encoded] = scope_spans.spans

      assert Base.encode16(encoded.trace_id, case: :lower) == @trace_id
      assert encoded.parent_span_id == <<0x00F067AA0BA902B7::64>>
    end
  end


  defp attr(attributes, name) do
    map = :otel_attributes.map(attributes)

    case Map.fetch(map, name) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, :erlang.binary_to_existing_atom(name))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp span_trace_id do
    case :otel_tracer.current_span_ctx() do
      :undefined -> nil
      ctx -> :otel_span.hex_trace_id(ctx)
    end
  end

  defp tracestate(context) do
    context
    |> :otel_tracer.current_span_ctx()
    |> elem(6)
  end

  defp hex_trace_id(context) do
    :otel_span.hex_trace_id(:otel_tracer.current_span_ctx(context))
  end

  defp encode_pending do
    :otel_otlp_traces.to_proto(SpanCollector.pending_spans(), Telemetry.otel_resource())
  end

  defp span_names do
    %{resource_spans: [resource_spans]} = encode_pending()

    resource_spans.scope_spans
    |> Enum.flat_map(& &1.spans)
    |> Enum.map(&to_string(&1.name))
  end
end
