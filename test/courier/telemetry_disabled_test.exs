defmodule Courier.TelemetryDisabledTest do
  @moduledoc """
  THE KILL SWITCH TURNS TELEMETRY OFF, and this file is what says so.

  ## The seventh defect, and why six green packets missed it

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

  ## The mechanism, which is two SDK facts and no courier bug at all

  `OTEL_SDK_DISABLED=true` does two things inside the SDK, and courier's rebuild
  assumed the first did not happen.

  1. `opentelemetry_sup:init/1` has a clause for `sdk_disabled := true` that
     returns `{ok, {#{}, []}}` — **no children**. Not "no processors": no
     `otel_span_sup`, no `otel_tracer_provider_sup`, nothing.
  2. So `otel_tracer_provider_sup` was never started, and
     `:otel_tracer_provider.get_tracer/4` catches its own `exit:{noproc, _}` and
     answers the no-op tracer:

         handle_call({get_tracer, _Name, _Vsn, _SchemaUrl}, _From,
                     State=#state{shared_tracer=undefined}) ->
             {reply, {otel_tracer_noop, []}, State};

  That answer is **correct and it is the SDK's contract**: no SDK, no recording,
  no export. `[]` is `:otel_tracer_noop`'s own tracer context — the module's own
  `-define(NOOP_TRACER_CTX, [])` — and `otel_tracer_noop` implements the whole
  `otel_tracer` behaviour over it.

  courier's `build_tracer/0` destructures that answer and reaches for fields that
  only a real `#tracer{}` record has:

      {module, record} = :otel_tracer_provider.get_tracer(service_name(), nil, nil)
      {tag, fields} = record |> Tuple.to_list() |> then(&{hd(&1), tl(&1)})

  `Tuple.to_list([])` raises, in the request path, on every request.

  So the defect is not that courier built a tracer wrongly. It is that courier
  **treated a legitimate answer as a broken SDK**: the `raise` in `build_tracer/0`
  exists for one reason — to catch an SDK whose `#tracer{}` record has changed
  shape — and the no-op tracer is not that. It is the SDK saying "there is no SDK,
  and that is fine", which is exactly what the switch asked for.

  ## Why every existing test stayed green

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

  ## What these tests do and do not claim

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
      # THE DEFECT. `build_tracer/0` reaches for a `#tracer{}` record's fields and
      # `[]` is not a tuple, so this raised — inside the request path, on every
      # request, with the startup line having already said telemetry was off.
      #
      # `put_tracer/1` is handed the SDK's own answer rather than a hand-written
      # one; `tracer_noop/0` returns the same constant and `normalize_tracer/1`
      # is the branch under test. The assertion is that `start_span/4` ANSWERS,
      # because that is what `CourierWeb.Plugs.Telemetry.call/2` does first and
      # what a raise there does to the response. `/healthz` was a 500.
      tracer = Telemetry.put_tracer(Telemetry.tracer_noop())

      assert tracer == Telemetry.tracer()

      span = :otel_tracer.start_span(:undefined, tracer, "courier.web.request", %{kind: :server})

      assert span != :undefined

      # Not recording, which is the WHOLE of what "disabled" means: the span is
      # created and thrown away, and `Courier.Observability.record/2` no-ops on
      # it rather than writing to it.
      assert :otel_span.is_recording(span) == false

      # And `end_span/1` answers, which is what the `before_send` hook calls on
      # every request that got that far. This is the call the measured stack
      # trace stopped short of.
      #
      # `otel_span_ets:end_span/3` returns the span context, and the no-op
      # tracer's own `end_span/2` answers `true` — the two are different
      # functions over the same span, and the one courier's plug calls is
      # `:otel_span.end_span/1`. What is asserted is that it ANSWERS, and that
      # the span it hands back is the non-recording one: a zero trace id and
      # `is_recording: false`, which is the shape of a span nobody is recording.
      ended = :otel_span.end_span(span)

      assert :otel_span.is_recording(ended) == false
      assert :otel_span.hex_trace_id(ended) == "00000000000000000000000000000000"
    end

    test "courier's exporter is never asked to encode a span it did not record" do
      # The half that makes the first test a fix rather than a silencing. A no-op
      # tracer's spans are not recording spans, so nothing reaches
      # `Courier.SpanCollector.on_end/1`, so the queue stays empty and there is no
      # dial — which is the whole promise the disabled branch of `sdk_config/0`
      # makes and the reason it is written at all.
      Telemetry.put_tracer(Telemetry.tracer_noop())

      SpanCollector.clear_pending()
      assert SpanCollector.pending() == 0

      span = :otel_tracer.start_span(:undefined, Telemetry.tracer(), "probe", %{})

      assert :otel_span.end_span(span) != :error
      assert SpanCollector.pending() == 0

      # And the flush is not an export attempt. `flush/0` goes through
      # `do_export/0`, which answers `:ok` for both "exported" and "nothing to
      # export" — so the assertion that nothing was handed to the exporter is made
      # where it can be observed, which is `export_pending/1`'s own answer.
      assert SpanCollector.export_pending(fn _spans -> flunk("the exporter was called") end) ==
               :nothing_pending
    end
  end

  describe "a real request, with telemetry disabled" do
    test "GET /healthz is a 200, not a 500" do
      # The regression, over the real router and the real endpoint. `/healthz` is
      # named rather than a /v1 route because it is the request an operator makes
      # when telemetry is the thing they suspect, and it is the one that answered
      # 500.
      #
      # BOTH halves of the disabled state are installed, and neither is simulated
      # past the point courier can tell:
      #
      #   * the environment variable, so `Telemetry.enabled?/0` reads it through
      #     the same code path a deployment does;
      #   * the tracer the SDK answers with when that variable is set, because
      #     the suite's own `:opentelemetry` application booted at a time when the
      #     variable was unset and cannot be restarted into a different boot.
      #
      # The second is what the live run measured and what this asserts: a real
      # request, through the real router, against the tracer the SDK hands back
      # when there is no SDK.
      System.put_env("OTEL_SDK_DISABLED", "true")
      Telemetry.put_tracer(Telemetry.tracer_noop())

      assert Telemetry.enabled?() == false
      assert Telemetry.tracer() == Telemetry.tracer_noop()

      conn = get(build_conn(), "/healthz")

      assert conn.status == 200
    end

    test "GET /readyz is not a 500 either" do
      # `/readyz` consults the database, so its status here is the database's
      # business. What is courier's business is that a raise in the telemetry plug
      # turned it into a 500 *regardless* — measured at 503 for a missing database
      # and 500 for the raise, which is how the two were told apart.
      System.put_env("OTEL_SDK_DISABLED", "true")
      Telemetry.put_tracer(Telemetry.tracer_noop())

      conn = get(build_conn(), "/readyz")

      refute conn.status == 500,
             "a disabled telemetry SDK must not 500 the readiness probe: #{conn.status}"

      # Whatever the database answered, it was a probe answer rather than a crash.
      assert conn.status in [200, 503]
    end
  end

  describe "the rebuild, and what it must still catch" do
    test "a REAL tracer is still rebuilt with courier's span processor" do
      # The fix is not "stop rebuilding". A courier with no processor creates
      # spans, records attributes onto them, and destroys them on `end_span` — the
      # reason the rebuild exists at all (see `Courier.SpanCollector`). This is
      # the same assertion `telemetry_test.exs` makes, and it must keep passing:
      # a fix that returned the no-op tracer for every input would satisfy the
      # tests above and export nothing at all.
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
