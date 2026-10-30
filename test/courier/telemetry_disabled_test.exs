defmodule Courier.TelemetryDisabledTest do
  @moduledoc """
  THE KILL SWITCH TURNS TELEMETRY OFF, and this file is what says so.


  `Courier.Telemetry.sdk_config/0`'s disabled path was fixed in `c80128c` and the
  fix was correct as far as it went: the SDK's `otel_configuration:processors/2`
  wanted `{Name, Opts}` PAIRS and courier handed it a bare atom, so
  `OTEL_SDK_DISABLED=true` took the release down at boot rather than turning
  telemetry off. Omitting `span_processor` and setting `processors: []` fixed
  exactly that.

  It fixed the BOOT. It did not fix the SERVICE, and the gap is one layer out on
  the other side of the same switch:

      $ OTEL_SDK_DISABLED=true COURIER_OTEL_ENDPOINT=http://192.168.158.7:4318 \
            mix phx.server
      [info] telemetry off (OTEL_SDK_DISABLED=true); spans stay in this node
      [info] Running CourierWeb.Endpoint with Bandit 1.12.5 at 127.0.0.1:4000
      $ curl -i localhost:4000/healthz
      HTTP/1.1 500 Internal Server Error

      [error] ** (ArgumentError) errors were found at the given arguments:
        * 1st argument: not a tuple
          :erlang.tuple_to_list([])
        (courier 0.1.0) lib/courier/telemetry.ex:254: Courier.Telemetry.build_tracer/0
        (courier 0.1.0) lib/courier_web/plugs/telemetry.ex:91: CourierWeb.Plugs.Telemetry.call/2

  So courier boots, logs that telemetry is off, and then answers **500 to every
  request it serves** — including `/healthz`, which is the one request an operator
  reaches for when telemetry is misbehaving. A kill switch whose disabled state is
  an outage is not a kill switch, and the damage lands on the exact deployment
  that turned telemetry off *because* something had gone wrong with it.


  `OTEL_SDK_DISABLED=true` does two things inside the SDK, and courier's rebuild
  assumed the first did not happen.

  1. `opentelemetry_sup:init/1` has a clause for `sdk_disabled := true` that
     returns `{ok, {
     `otel_span_sup`, no `otel_tracer_provider_sup`, nothing.
  2. So `otel_tracer_provider_sup` was never started, and
     `:otel_tracer_provider.get_tracer/4` catches its own `exit:{noproc, _}` and
     answers the no-op tracer:

         handle_call({get_tracer, _Name, _Vsn, _SchemaUrl}, _From,
                     State=
             {reply, {otel_tracer_noop, []}, State};

  That answer is **correct and it is the SDK's contract**: no SDK, no recording,
  no export. `[]` is `:otel_tracer_noop`'s own tracer context — the module's own
  `-define(NOOP_TRACER_CTX, [])` — and `otel_tracer_noop` implements the whole
  `otel_tracer` behaviour over it.

  courier's `build_tracer/0` destructures that answer and reaches for fields that
  only a real `

      {module, record} = :otel_tracer_provider.get_tracer(service_name(), nil, nil)
      {tag, fields} = record |> Tuple.to_list() |> then(&{hd(&1), tl(&1)})

  `Tuple.to_list([])` raises, in the request path, on every request.

  So the defect is not that courier built a tracer wrongly. It is that courier
  **treated a legitimate answer as a broken SDK**: the `raise` in `build_tracer/0`
  exists for one reason — to catch an SDK whose `
  shape — and the no-op tracer is not that. It is the SDK saying "there is no SDK,
  and that is fine", which is exactly what the switch asked for.


  Because `enabled?/0` reads `OTEL_SDK_DISABLED` from the environment and the
  suite runs with it unset. `telemetry_test.exs` and `otel_export_test.exs` both
  assert the DISABLED *configuration* —

      refute Keyword.has_key?(config, :span_processor)
      assert config[:processors] == []

  — and that assertion is true, and it is still true after the fix. It is also
  true of a courier whose every request 500s, because a keyword list is the same
  keyword list whether or not anything ever consumes it.

  **An assertion about a configuration is not a boot**, which is the sentence
  `sdk_config/0`'s own moduledoc already carries about the sixth defect. This is
  the same sentence again, one layer out: an assertion about a configuration is
  also not a REQUEST. So the assertion here is on the request, over the real
  router, with the switch genuinely on.


  They drive real requests through the real endpoint and read the real status
  code, with `OTEL_SDK_DISABLED=true` set in the environment the tracer is built
  in. That is the same shape of claim as `otel_export_test.exs`'s, and it is
  narrower than "the kill switch works": it says a disabled SDK produces spans
  that are never recorded and requests that are served, rather than requests that
  are 500s.

  The suite cannot restart the `:opentelemetry` application to make the SDK
  genuinely disabled, because `config/runtime.exs` writes
  `config :opentelemetry, ...` once at boot and a test that stopped and restarted
  it would be testing a VM nobody deploys. What IS testable — and what is tested
  below — is courier's own half: given the answer the SDK gives when telemetry is
  off, does courier serve the request? That answer is
  `Telemetry.tracer_noop/0`, which is `{otel_tracer_noop, []}` read straight out
  of `otel_tracer_server:handle_call/2` and asserted against the SDK's own module
  rather than written out by hand.
  """

  use CourierWeb.ConnCase

  import Phoenix.ConnTest

  alias Courier.SpanCollector
  alias Courier.Telemetry

  setup do
    on_exit(fn ->
      System.delete_env("OTEL_SDK_DISABLED")
      Telemetry.forget_tracer()
    end)

    :ok
  end

  describe "the answer the SDK gives when it is disabled" do
    test "is the no-op tracer, and courier serves requests against it" do
      tracer = Telemetry.put_tracer(Telemetry.tracer_noop())

      assert tracer == Telemetry.tracer()

      span = :otel_tracer.start_span(:undefined, tracer, "courier.web.request", %{kind: :server})

      assert span != :undefined

      assert :otel_span.is_recording(span) == false

      ended = :otel_span.end_span(span)

      assert :otel_span.is_recording(ended) == false
      assert :otel_span.hex_trace_id(ended) == "00000000000000000000000000000000"
    end

    test "courier's exporter is never asked to encode a span it did not record" do
      Telemetry.put_tracer(Telemetry.tracer_noop())

      SpanCollector.clear_pending()
      assert SpanCollector.pending() == 0

      span = :otel_tracer.start_span(:undefined, Telemetry.tracer(), "probe", %{})

      assert :otel_span.end_span(span) != :error
      assert SpanCollector.pending() == 0

      assert SpanCollector.export_pending(fn _spans -> flunk("the exporter was called") end) ==
               :nothing_pending
    end
  end

  describe "a real request, with telemetry disabled" do
    test "GET /healthz is a 200, not a 500" do
      System.put_env("OTEL_SDK_DISABLED", "true")
      Telemetry.put_tracer(Telemetry.tracer_noop())

      assert Telemetry.enabled?() == false
      assert Telemetry.tracer() == Telemetry.tracer_noop()

      conn = get(build_conn(), "/healthz")

      assert conn.status == 200
    end

    test "GET /readyz is not a 500 either" do
      System.put_env("OTEL_SDK_DISABLED", "true")
      Telemetry.put_tracer(Telemetry.tracer_noop())

      conn = get(build_conn(), "/readyz")

      refute conn.status == 500,
             "a disabled telemetry SDK must not 500 the readiness probe: #{conn.status}"

      assert conn.status in [200, 503]
    end
  end

  describe "the rebuild, and what it must still catch" do
    test "a REAL tracer is still rebuilt with courier's span processor" do
      {module, record} = Telemetry.tracer()

      assert module == :otel_tracer_default
      assert is_tuple(record)

      fields = record |> Tuple.to_list() |> Enum.drop(1)
      on_end_index = Enum.find_index(Telemetry.tracer_fields(), &(&1 == :on_end_processors))
      on_end = Enum.at(fields, on_end_index)

      assert is_function(on_end, 1)
      assert elem(:erlang.fun_info(on_end, :module), 1) == Courier.SpanCollector
    end
  end
end
