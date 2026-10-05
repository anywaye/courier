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

  ## No sockets, and why that is not a dodge

  The requirement is that courier EXPORTS, and this file never opens a socket.
  `:opentelemetry_exporter.init/1` starts an in-process `httpc` profile and
  `:otel_otlp_traces.to_proto/2` is the function that builds the exact protobuf
  body courier POSTs. Asserting on the encoded body asserts on the request a
  collector receives. A collector-in-the-loop test would additionally prove that
  `:httpc` can reach a socket, which is `opentelemetry_exporter`'s business and
  would make this suite a network test — which courier's suite rule forbids.

  ## Why this file is its own file and `async: false`

  It swaps `:courier, :otel_exporter` for `:opentelemetry_exporter` in `setup`,
  because the defect is in the PRODUCTION exporter and the suite is configured
  with `Courier.TestSpanExporter`. Application environment is VM-wide, so this is
  the case `AGENTS.md` reserves for a `*ConfigTest` file: its own file,
  `async: false`, and a comment saying why.

  ## The three defects, in the order they bite

  1. **The exporter was never initialized.** `Courier.SpanCollector` called
     `export(:traces, spans, resource, %{})`. The fourth argument is an
     `#state{}` RECORD, and `otel_exporter_traces_otlp:export/3` pattern-matches
     `#state{}` fields in each of its three real clauses. `%{}` matched none of
     them, so every flush took the catch-all and answered `{:error,
     :unimplemented}`. Measured before the fix, on a span courier had genuinely
     recorded:

         PROBE 1  export(:traces, tab, resource, %{})  [today's call]
         result: {:error, :unimplemented}

  2. **The spans were not in the shape the exporter reads.** The SDK's exporter
     takes an ETS table whose KEY is an `#instrumentation_scope{}` and whose
     VALUE is a `#span{}` record, and reads it with `ets:lookup/2` on that scope.
     courier was about to hand it a LIST of spans with no scope at all, so the
     second probe raised inside the exporter:

         PROBE 2  export with a real #state{}
         ** (FunctionClauseError) no function clause matching in :otel_otlp_traces.to_proto/1
             # 1
             {-576460752303345823, {:span, 250261861607385731661550453041408069235, ...}}

     That negative integer is `:erlang.unique_integer()`. courier was keying by a
     counter and the exporter was asking for a scope.

  3. **The resource was not a resource.** `otel_resource:attributes/1` matches an
     `#opentelemetry_resource{}` record and returns `undefined` for anything
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
    # The production exporter, because the production exporter is what was never
    # initialized. Restored on the way out: application environment outlives this
    # process and the rest of the suite asserts on it.
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
      # The shape IS the defect. `export/3` pattern-matches on `#state{}` fields
      # and `%{}` matches none of them, so this asserts the thing that made
      # courier's export a no-op for its entire life.
      state = Telemetry.exporter_state()

      assert is_tuple(state),
             "the exporter state is not a record, so export/3 takes its catch-all " <>
               "clause and answers {:error, :unimplemented}: " <> inspect(state)

      assert elem(state, 0) == :state,
             "expected the exporter's own #state{} record, got: #{inspect(state)}"
    end

    test "pointed at courier's endpoint, and on the port the contract names" do
      # Read back out of the INITIALIZED state, not out of `Telemetry.endpoint/0`.
      # The latter is a pure function of the environment: it was already correct,
      # and it told courier nothing about whether the address reached the wire.
      assert [%{host: ~c"otel-collector", port: 4318, scheme: ~c"http"} | _] =
               SpanCollector.exporter_endpoints(),
             "no usable endpoint in the initialized exporter state: " <>
               inspect(SpanCollector.exporter_endpoints())

      # And the path the exporter appends. `otel_exporter_otlp` appends `v1/traces`
      # to a bare `otlp_endpoint`, and a collector only answers OTLP on that path —
      # so an endpoint with an empty path is an exporter that would get a 404 and
      # report it as `error`, which is exactly the indistinguishable refusal the
      # classification tests above are about.
      assert [%{path: path} | _] = SpanCollector.exporter_endpoints()
      assert to_string(path) =~ "v1/traces"
    end

    test "so the REAL exporter no longer answers :unimplemented" do
      # The direct call, with a span courier actually recorded and the spans in the
      # shape the encoder reads. This is byte for byte what a flush does.
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

      # NOT `:ok`, and that is the point. There is no collector in this suite, so
      # the POST cannot succeed and the exporter answers `error`. What must not
      # happen is `{:error, :unimplemented}` — the catch-all clause an
      # uninitialized exporter state fell into for the life of this service, which
      # failed before a socket was ever opened and so cannot be distinguished from
      # a refused POST by any caller.
      refute match?({:error, :unimplemented}, answer),
             "the exporter took its catch-all clause: no state, nothing encoded"

      # And it got as far as ENCODING, which is what `:unimplemented` skipped:
      # a refused POST means the body was built and the address refused it.
      assert :otel_otlp_traces.to_proto(spans, Telemetry.otel_resource()) != :empty
    end
  end

  describe "the bytes courier would ship" do
    test "the real encoder finds courier's span and does not return empty" do
      # `:otel_otlp_traces.to_proto/2` returns a bare `empty` when it finds
      # nothing, and `to_proto/2`'s caller treats that as success. So "the encoder
      # saw no spans" and "the export succeeded" are the same answer, which is why
      # this asserts on the encoded body rather than on a return value.
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
      # `service.name` is how HyperDX groups by `service.name=<svc>`, which is the
      # whole point of this packet. Flat and dotted, on the resource, because both
      # the collector's redaction and the store's index read it from there.
      attributes = :otel_resource.attributes(Telemetry.otel_resource())

      assert attr(attributes, "service.name") == "courier"
      assert is_binary(attr(attributes, "service.version"))
    end

    test "the tenant reaches the resource, and never as a measurement attribute" do
      # core's metrics schema puts `tenant_id` in both lists with OPPOSITE
      # meanings: prohibited on a measurement, required on the resource. Resource
      # attributes are exempt from the 2000-attribute-combination cap, so a
      # per-tenant total stays answerable after the measurement has folded.
      System.put_env("COURIER_TENANT_ID", "tenant-abc")
      on_exit(fn -> System.delete_env("COURIER_TENANT_ID") end)

      assert attr(:otel_resource.attributes(Telemetry.otel_resource()), "tenant_id") ==
               "tenant-abc"
    end

    test "the deployment environment reaches the resource under its own name" do
      # `deployment.environment` is the name core froze, and it is the only one of
      # the three courier renames on the way out.
      System.put_env("DEPLOYMENT_ENVIRONMENT", "production")
      on_exit(fn -> System.delete_env("DEPLOYMENT_ENVIRONMENT") end)

      assert attr(:otel_resource.attributes(Telemetry.otel_resource()), "deployment.environment") ==
               "production"
    end

    test "an unset variable is ABSENT from the resource rather than empty" do
      # `service.name=""` is not a tidier name than no name: a store grouping by
      # it gets a second courier row distinguished by an empty string, and an
      # operator sees the same service twice with one of them reporting no spans.
      attributes = :otel_resource.attributes(Telemetry.otel_resource())

      refute attr(attributes, "tenant_id")
      refute attr(attributes, "deployment.environment")
    end
  end

  describe "a refused export" do
    # These do NOT go through the shared queue, and the reason is worth stating.
    # The collector's flush timer runs every 5s and drains and re-queues that same
    # table, so a background flush landing mid-test moves `pending/0` for reasons
    # that have nothing to do with the code under test. Suspending the collector
    # was the first answer and it is worse: `suspend_process/1` leaves a process
    # suspended across the failure that follows, so every later test's teardown
    # raised `process is not suspended or is not alive` and the report named the
    # teardown rather than the defect. Handing the classifier an explicit list of
    # spans removes the shared state instead of arranging for nobody to touch it.

    test "keeps the spans queued and does not raise" do
      # The exporter answers a BARE `error` atom, not `{:error, reason}`:
      # `otel_exporter_otlp:export_http/6` returns `ok | error`. An arm for
      # `{:error, reason}` and none for `error` is a `CaseClauseError` swallowed
      # by a catch-all, so a refused POST and a broken exporter were
      # indistinguishable in the log.
      SpanCollector.record_one_span()
      before = SpanCollector.pending()

      assert {:error, :error} = SpanCollector.export_pending(fn _s -> :error end)
      assert SpanCollector.pending() == before, "a refused export dropped the spans"

      assert {:error, {:error, :timeout}} =
               SpanCollector.export_pending(fn _s -> {:error, :timeout} end)

      assert SpanCollector.pending() == before
    end

    test "an exporter that RAISES is a refused export, not a dead collector" do
      # An `httpc` profile that was not started, an endpoint the exporter's own
      # parser refuses, an OS-level failure: none of those are courier's to raise
      # into a request, and a crash in the flush would take the collector — and
      # with it every later flush — down.
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
      # `sdk_config/0` on the disabled path, asserted against what
      # `otel_configuration:processors/2` accepts rather than against what reads
      # well. It used to be `:otel_simple_processor`, a bare ATOM; the SDK wraps
      # whatever `span_processor` holds in a one-element list and maps `{Name,
      # Opts}` pairs over it, so a courier booted with `OTEL_SDK_DISABLED=true`
      # did not boot:
      #
      #     ** (FunctionClauseError) no function clause matching in anonymous fn/1
      #        in :otel_configuration.processors/2
      #         (opentelemetry 1.7.0) src/otel_configuration.erl:179
      #     ** (Mix) Could not start application opentelemetry
      #
      # The kill switch took the release down instead of turning telemetry off.
      System.put_env("OTEL_SDK_DISABLED", "true")
      on_exit(fn -> System.delete_env("OTEL_SDK_DISABLED") end)

      config = Telemetry.sdk_config()

      refute Keyword.has_key?(config, :span_processor)
      assert config[:processors] == []
    end

    test "an empty queue is not an export attempt" do
      # Calling the exporter with nothing to send is what makes `to_proto/2`
      # answer `empty`, and `empty` is indistinguishable from success. Skipping
      # the call keeps "nothing to export" and "exported nothing" apart.
      assert :nothing_pending = SpanCollector.export_pending(fn _s -> flunk("called") end)
    end
  end

  describe "traceparent, per kit's codec rules" do
    # The packet's requirement 3, asserted on the parser and the span rather than
    # through a router, so it is a claim about PROPAGATION and not about Phoenix.
    @valid "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"

    test "a valid inbound traceparent is CONTINUED, same trace id" do
      context = CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", @valid}])

      assert hex_trace_id(context) == @trace_id
    end

    test "a traceparent with NO tracestate beside it is still continued" do
      # The regression, isolated. `otel_tracestate:decode_header/1` matches
      # `undefined` and has no clause for `nil`, and the composite propagator
      # CATCHES an extractor's exception and returns the context unchanged — so a
      # getter answering `nil` for the absent `tracestate` threw inside the SDK and
      # discarded the perfectly valid `traceparent` next to it. Measured:
      #
      #     ** (FunctionClauseError) no function clause matching in :string.lexemes_m/3
      #         # 1
      #         nil
      #     (opentelemetry_api 1.5.0) src/otel_tracestate.erl:104
      #
      # Which means every request through courier that carried a traceparent and no
      # tracestate — the overwhelmingly common shape — started a new trace.
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
      # §3.2.2.3: ignore it. Correlation metadata that can take a customer's
      # request down is a denial-of-service vector aimed at courier's own surface.
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
      # A carrier matching only lowercase starts a new trace on every request
      # through such a proxy, which reads as "propagation does not work" and is
      # very hard to see.
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
      # The regression, isolated from the parse. `extract/5` folds over the
      # extractor list, and an empty list is not "use the default" — it is
      # "extract nothing", returned as the context unchanged. So a
      # perfectly valid traceparent produced `%{}` and every request started a
      # new trace. This is the assertion that names it.
      assert :trace_context in CourierWeb.Plugs.Telemetry.propagators()
      assert :baggage in CourierWeb.Plugs.Telemetry.propagators()

      refute CourierWeb.Plugs.Telemetry.propagators() == []
    end

    test "and the getter is called NAME-FIRST, which is what the SDK does" do
      # Reversed, this is not a wrong value: `otel_propagator_baggage:extract/5`
      # raises inside `Enum.find_value/1`, the composite propagator CATCHES it, and
      # the context comes back unchanged. A mistyped getter is indistinguishable
      # from "no traceparent was sent".
      context =
        CourierWeb.Plugs.Telemetry.extract_context([
          {"traceparent", @valid},
          {"tracestate", "vendor=value"},
          {"baggage", "k=v"}
        ])

      assert hex_trace_id(context) == @trace_id
      assert to_string(:otel_tracestate.get("vendor", tracestate(context))) == "value"

      # `baggage`, not `tracestate`. The two are different headers and only
      # `baggage` is the baggage propagator's business: `tracestate` travels in
      # the span context's own field, and a context carrying only a `tracestate`
      # has no baggage key at all. Measured:
      #
      #     %{{:otel_tracer, :span_ctx} => {...}}                       # tracestate only
      #     %{:"$__otel_baggage_ctx_key" => %{"k" => {"v", []}},
      #       {:otel_tracer, ...} => {...}}                             # with baggage
      assert :otel_ctx.get_value(context, :"$__otel_baggage_ctx_key", %{})["k"] == {"v", []}
    end

    test "and the CONTINUED trace reaches the span courier opens" do
      # The parser alone is not the contract: the requirement is that a request
      # carrying a traceparent is served INSIDE the caller's trace. This is the
      # join, and it is the assertion that fails if the plug ever opens a root
      # span while still parsing the header correctly.
      context = CourierWeb.Plugs.Telemetry.extract_context([{"traceparent", @valid}])

      span =
        :otel_tracer.start_span(
          context,
          Telemetry.tracer(),
          "courier.web.request",
          %{kind: :server}
        )

      # `set_current_span/1` because `start_span/4` does NOT make a span current —
      # the request plug calls it one line later, and that line is why a continued
      # trace becomes a CHILD of the caller's trace rather than a second root span
      # beside it. Reproduced here as the plug does it, in the plug's order.
      :otel_tracer.set_current_span(span)

      assert span_trace_id() == @trace_id
    end

    test "and the continued span is exportable, with the parent's link intact" do
      # The join AND the export, because a continued trace that cannot be encoded
      # would satisfy every assertion above and produce no trace in the store.
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

  # --- helpers -------------------------------------------------------------

  # The exact call the exporter makes, minus the HTTP request itself.
  # `extract_context/1` returns an `otel_ctx` — a MAP keyed by `{module, key}` — not
  # a span context. `otel_tracer:start_span/4` takes that map and resolves it, so
  # a test that wants the parsed trace id has to resolve it the same way. Measured:
  #
  #     extract_context: %{
  #       {:otel_tracer, :span_ctx} => {:span_ctx, 100985939111033328018442752961257817910,
  #         "4bf92f3577b34da6a3ce929d0e0e4736", 67667974448284343, "00f067aa0ba902b7",
  #         1, {:tracestate, []}, true, true, false, :undefined}}
  #
  # Two things that assertion depends on and neither is obvious: the trace id is an
  # INTEGER here and only becomes the 16 bytes a wire carries on the way out, and
  # `{}` is the answer when there was no header to parse.
  # The 16 bytes a trace id occupies on the wire, for the encoded assertions. An
  # integer becomes these only on the way out — `otel_otlp_traces:to_proto/2` does
  # `<<TraceId:128>>` — so a test that compares a parsed header against an encoded
  # span has to convert one side.
  # The parsed `#tracestate{}` inside a span context. `otel_tracestate:get/2` is
  # KEY-FIRST (`get("vendor", Tracestate)`), which is not the shape of anything
  # else in this file, and getting it backwards reads as "the tracestate was
  # dropped".
  # One lookup for an attribute whatever `:otel_attributes.map/1` spelled the key
  # in. It is not consistent: `otel_resource:create/1` keeps a key that is a valid
  # ATOM as an atom (`tenant_id`) and leaves a dotted one as a binary
  # (`"service.name"`), so a test written against one spelling silently reads `nil`
  # for the other. Measured:
  #
  #     %{tenant_id: "tenant-abc", "service.name": "courier",
  #       "service.version": "0.0.0", "deployment.environment": "production"}
  defp attr(attributes, name) do
    map = :otel_attributes.map(attributes)

    case Map.fetch(map, name) do
      {:ok, value} ->
        value

      :error ->
        # `:erlang.binary_to_existing_atom/1` rather than `String.to_existing_atom/1`,
        # because a name that was never an atom anywhere in the VM raises
        # ArgumentError — and `refute attr(attributes, "tenant_id")` on a machine
        # where nothing has mentioned that atom is a crash, not an absence.
        try do
          Map.get(map, :erlang.binary_to_existing_atom(name))
        rescue
          ArgumentError -> nil
        end
    end
  end

  # The CURRENT span's trace id, from the process dictionary.
  # `otel_tracer:start_span/4` does not make a span current — `set_current_span/1`
  # does, and the request plug calls it — so "the span courier opened" and "the
  # span that is current" are different questions and only the second one is what a
  # downstream span would parent onto.
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
