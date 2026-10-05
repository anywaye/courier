defmodule Courier.Telemetry do
  @moduledoc """
  The endpoint contract, the resource, and the SDK configuration courier runs on.

  ## What this module is, and why the wiring is not in it

  The Erlang OpenTelemetry SDK is configured through the `:opentelemetry`
  application environment and started by the application controller, which runs
  BEFORE `Courier.Application.start/2`. So the wiring itself has to live in
  `config/runtime.exs` — there is no code path that could set it earlier.

  What lives HERE is everything that can be a pure function of the environment:
  the endpoint, whether telemetry is on, why it is off, the resource, and the SDK
  configuration derived from all three. So the contract and its no-op path are in
  one readable, testable place with a comment on each, and
  `config/runtime.exs` is one line that calls into it rather than a second copy of
  the rules. `test/courier/telemetry_test.exs` asserts on this module directly,
  which is only possible because the logic is here.

  ## The contract, and it is one variable

  `<SERVICE>_OTEL_ENDPOINT` is the WHOLE of it (core D16):

    * `COURIER_OTEL_ENDPOINT` set — export there. The collector that ships with
      the stack, or Datadog, or Honeycomb, or Grafana Cloud, or anything speaking
      OTLP. Bring-your-own is a **supported deployment, not a degraded mode**.
    * unset — the collector that ships with the stack, which is the whole of
      "a deployer gets traces without assembling them".

  `OTEL_EXPORTER_OTLP_ENDPOINT` is honoured as a fallback so the release also
  works with generic OTel tooling, and the cafaye name wins when both are set.
  That precedence is written down here rather than discovered later, because a
  contract with an undocumented precedence order is a bug report.

  ## The kill switches are the SPEC'S, and courier does not reimplement them

  `OTEL_SDK_DISABLED` and `<SIGNAL>_EXPORTER=none` are the OpenTelemetry
  specification's own, and the Erlang SDK reads both from the environment
  directly (`otel_configuration:merge_with_os/1`). Re-implementing "disabled" in
  six languages is how six services acquire six different definitions of it, and
  the difference between them is somebody's production incident.

  So `enabled?/0` and `no_op_reason/0` here decide the SDK's span processor and
  produce one startup line — they do not gate anything the SDK does not already
  gate. When telemetry is off the configuration below is `:otel_simple_processor`,
  which holds no queue and exports nowhere, so every `[:telemetry, :span]` call in
  the codebase stays valid and no call site needs an `if telemetry_enabled?`
  around it.

  A queue that accepts spans and holds them is a memory leak with a
  telemetry-shaped trigger; a retry loop against an endpoint that is not there is
  a process waking on a timer for the life of the release, invisible in every
  dashboard because nothing is being recorded. A "disabled" path that still dials
  out is worse than no telemetry support at all, so the no-op is the ABSENCE of
  the exporter rather than the exporter aimed at nothing.

  ## Why there is no meter here

  courier emits **traces**, and the fleet's metrics are derived from them by the
  `spanmetrics` connector in kit's collector, which runs AFTER the redaction
  processor. That is not a shortcut around a missing feature; it is measured. The
  Erlang OpenTelemetry SDK has no metrics API at all:

      $ ls deps/opentelemetry/src | grep -c metric
      0

  and `opentelemetry_exporter` exports `metrics/4` only as a gRPC service stub
  with no producer in the SDK to call it. courier therefore *cannot* emit metrics
  from its own SDK, and the connector is not a workaround — it is the only path,
  and it is the better one: a metric derived from an ALREADY-REDACTED span cannot
  carry a dimension the boundary would have stripped.

  What courier loses by not having its own meter is stated rather than glossed: a
  GAUGE. Spans give rate, error rate and latency; they cannot answer "how many are
  waiting right now", so a stalled outbox relay — courier's background work, which
  produces no spans when it finds nothing — is invisible on the metrics signal.
  That is a gap in the SDK rather than a choice made here, and it is recorded in
  the packet's report.
  """

  use Supervisor

  require Logger

  @service_name "courier"
  @default_endpoint "http://otel-collector:4318"
  @endpoint_variable "COURIER_OTEL_ENDPOINT"
  @tenant_variable "COURIER_TENANT_ID"

  @per_signal ~w(OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER)

  @doc """
  Where finished spans go.

  In production this is `:opentelemetry_exporter`, which is the SDK's own OTLP
  encoding over the same endpoint the whole fleet uses. In test it is
  `Courier.TestSpanExporter`, named in `config/test.exs` — a test that opened a
  socket would be a network call in a suite whose rule is no sockets, and a suite
  that phones an observability backend is a suite that phones an observability
  backend.

  Read from the application environment rather than from `MIX_ENV` because
  `MIX_ENV` is not set inside a RELEASE, and a release that quietly picked the test
  exporter would export nothing while saying telemetry is on. `config/test.exs` is
  the only place that sets it.
  """
  def exporter do
    if Application.get_env(:courier, :otel_exporter) do
      Application.get_env(:courier, :otel_exporter)
    else
      :opentelemetry_exporter
    end
  end

  @doc """
  courier's tracer, with courier's own span processor installed.

  ## Why this rebuilds the SDK's tracer record

  The SDK cannot start a span processor at all — see `Courier.SpanCollector` for
  the reproduction, which is two commands and applies to every published version of
  the Erlang SDK. A tracer with no processor creates spans, records attributes onto
  them, and then destroys them on `end_span`, and courier's startup line would say
  telemetry is on.

  `#tracer{}` carries `on_end_processors :: fun((span()) -> boolean() | …)`, and
  `get_tracer/3` hands that record back, so the fix is to rebuild it with
  `Courier.SpanCollector.on_end/1` in that field. One function, one place, and a
  loud failure at boot if the record's shape ever changes.

  The record is an Erlang RECORD — `{:tracer, module, on_start_processors,
  on_end_processors, sampler, id_generator, instrumentation_scope}` — not a keyword
  list, which is what it looks like in a `gen_server` state and what
  `Keyword.keys/1` raises a FunctionClauseError on. The tag is element 0, so the
  field at index 2 of `tracer_fields/0` is element 3 of the tuple. Both offsets are
  computed from the one list rather than written twice.

  Cached in `:persistent_term` because `get_tracer/3` is a `gen_server` call and
  this runs on every inbound request — and because the tracer is immutable once
  built, which is exactly what `:persistent_term` is for.
  """
  @tracer_key {__MODULE__, :tracer}

  @tracer_fields [
    :module,
    :on_start_processors,
    :on_end_processors,
    :sampler,
    :id_generator,
    :instrumentation_scope
  ]

  def tracer do
    case :persistent_term.get(@tracer_key, nil) do
      nil ->
        tracer = build_tracer()
        :persistent_term.put(@tracer_key, tracer)
        tracer

      tracer ->
        tracer
    end
  end

  @doc "The `#tracer{}` field list, in order. For a test that checks the rebuild."
  def tracer_fields, do: @tracer_fields

  @doc "Forget the cached tracer. For a test that replaced the provider."
  def forget_tracer, do: :persistent_term.erase(@tracer_key)

  @exporter_state_key {__MODULE__, :exporter_state}

  @doc """
  The exporter, INITIALIZED, and ready to be handed spans.

  ## Why this exists at all

  The Erlang SDK initializes an exporter by calling `Exporter.init(Config)` and
  keeps the returned state, and `export/4` then takes that state as its fourth
  argument. courier was calling

      :opentelemetry_exporter.export(:traces, tab, resource, %{})

  — passing `%{}` where the state belongs. That argument is an Erlang RECORD and
  `otel_exporter_traces_otlp:export/3` pattern-matches four `#state{}` fields in
  each of its three real clauses. `%{}` matches none of them, so every clause
  fell through to the catch-all and the exporter answered `{:error,
  :unimplemented}`, on every flush, for the life of the service.

  This is not a hypothetical. `test/courier/otel_export_test.exs` drives the real
  module and records the answer.

  ## Why the endpoint is passed HERE rather than left to the environment

  `:opentelemetry_exporter.init/1` reads `OTEL_EXPORTER_OTLP_ENDPOINT` from the
  OS environment and gives it PRECEDENCE over the `endpoints:` option
  (`otel_exporter_otlp:merge_with_environment/8` puts the environment's value into
  `endpoints` unconditionally). So courier's own resolution is passed explicitly
  and wins in every case courier's contract says it should: `COURIER_OTEL_ENDPOINT`
  alone, and neither variable set.

  The one case it does not cover is both variables set to DIFFERENT values, where
  courier's documented precedence says the cafaye name wins and the exporter's
  environment read wins. That is a contradiction between two upstream contracts
  and it is reported rather than papered over — see the packet report. The
  alternative was for courier to mutate its own process environment at boot,
  which is worse: it makes a global, is a race, and is invisible in a diff that
  says what courier reads.
  """
  def init_exporter(config \\ nil) do
    case exporter() do
      :opentelemetry_exporter ->
        :opentelemetry_exporter.init(config || %{endpoints: [endpoint()]})

      module ->
        # `:otel_exporter` behaviour: `init/1` must answer `{:ok, state}` or
        # `:ignore`, and there is no catch-all, so a bare `:ok` is a TryClauseError
        # inside the SDK's gen_statem and the processor is dropped with a log at
        # `info`. `Courier.TestSpanExporter` says so in its own moduledoc.
        module.init(config || %{endpoints: [endpoint()]})
    end
  end

  @doc """
  The state from `init_exporter/1`, or `:not_initialized`.

  Cached in `:persistent_term` because it is built once and read on every flush,
  and because the exporter's state holds an `httpc` profile named after the
  process that built it — so it belongs to the process that started it, not to
  whichever one later wants to export.
  """
  def exporter_state do
    case :persistent_term.get(@exporter_state_key, :not_initialized) do
      :not_initialized ->
        case init_exporter() do
          {:ok, state} ->
            :persistent_term.put(@exporter_state_key, state)
            state

          other ->
            other
        end

      state ->
        state
    end
  end

  @doc "Forget the initialized exporter. For a test that changed the exporter."
  def forget_exporter, do: :persistent_term.erase(@exporter_state_key)

  defp build_tracer do
    {module, record} = :otel_tracer_provider.get_tracer(service_name(), nil, nil)
    {tag, fields} = record |> Tuple.to_list() |> then(&{hd(&1), tl(&1)})
    on_end_index = Enum.find_index(@tracer_fields, &(&1 == :on_end_processors))

    if tag != :tracer or length(fields) != length(@tracer_fields) or
         not is_function(Enum.at(fields, on_end_index), 1) do
      raise """
      the OpenTelemetry SDK's tracer record is not the shape courier expects.

      expected the record :tracer with #{length(@tracer_fields)} fields \
      #{inspect(@tracer_fields)}, got tag #{inspect(tag)} with #{length(fields)} and \
      on_end_processors = #{inspect(Enum.at(fields, on_end_index))}

      courier rebuilds that record to install its own span processor, because the SDK \
      cannot start one itself (see Courier.SpanCollector for the reproduction). If the \
      record's shape has changed, this raise is the safe outcome: exporting nothing \
      while the startup line says telemetry is on is exactly the failure this \
      arrangement exists to prevent.
      """
    end

    fields = List.replace_at(fields, on_end_index, &Courier.SpanCollector.on_end/1)
    {module, List.to_tuple([tag | fields])}
  end

  @doc "The emitting service's name. The prefix on every span courier opens."
  def service_name, do: @service_name

  @doc "The `<SERVICE>_OTEL_ENDPOINT` variable name, named rather than repeated."
  def endpoint_variable, do: @endpoint_variable

  @doc """
  The OTLP endpoint. This is the whole of the contract.
  """
  def endpoint do
    System.get_env(@endpoint_variable)
    |> presence(System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"))
    |> presence(@default_endpoint)
  end

  @doc """
  Whether there is anywhere to export to, for ANY signal.

  All three per-signal switches are checked, not just the traces one: a no-op that
  only covers traces is a service that still phones home, which is the failure
  discovered by a customer's invoice rather than by a test.
  """
  def enabled? do
    # NOT `disabled_by_sdk?() or Enum.any?(...)` — which is what the first version
    # said, and which reads as plausible at a glance because both sides are about
    # switches. It means "enabled when the SDK is DISABLED or a signal is OFF", so
    # with a completely clean environment `enabled?/0` returned FALSE and courier
    # shipped with telemetry off and a startup line saying so.
    #
    # The suite caught it: `sdk_config/0` built `:otel_simple_processor` on a clean
    # environment, and the test that asserts a CLEAN environment gets a batch
    # processor pointed at the endpoint is the one that failed. A default that is
    # quietly off is invisible to every test that only checks the off path.
    not (disabled_by_sdk?() or Enum.any?(@per_signal, &exporter_off?/1))
  end

  @doc """
  One line for the startup log, and only ever on the DISABLED path.

  Silence is the contract there: a warning per export attempt fills courier's own
  log store with the fact that telemetry is off, which is how a self-hoster
  discovers that turning it off is not supported — the opposite of the intent.
  One line at startup is not spam, and it is the difference between "telemetry is
  off" and "telemetry is broken", which look identical from outside.
  """
  def no_op_reason do
    if disabled_by_sdk?() do
      "OTEL_SDK_DISABLED=true"
    else
      off = Enum.filter(@per_signal, &exporter_off?/1)

      # `if` and NOT a `cond` clause with an inline guard, and this is the second
      # time this function has been wrong in a way that only a test caught.
      #
      # The first version was `cond do ... off = Enum.filter(...) -> ... ; true -> "" end`,
      # and in Elixir `[]` is TRUTHY, so the `=none` clause matched on the ENABLED
      # path and every request in a healthy deployment logged "telemetry off
      # (=none)". The second attempt put the emptiness test INSIDE the clause body,
      # which changes nothing: a `cond` clause matches on the truthiness of its
      # VALUE, and this clause's value is the joined string, which is always truthy.
      #
      # So: an `if`, with the emptiness decided before anything is built.
      if off == [], do: "", else: Enum.join(off, ",") <> "=none"
    end
  end

  @doc """
  Process identity, attached once per process rather than once per span.

  It is the correct home for `tenant_id` and it is EXEMPT from OpenTelemetry's
  2000-attribute-combination metric cap. Put a tenant on a MEASUREMENT instead
  and the moment that stream overflows, every per-tenant breakdown silently
  undercounts while the total stays right — the worst shape a bug can have,
  because the dashboard still renders and looks fine.

  `service.version` is read at RUNTIME, not from `Mix.Project.config()`, and the
  reason is that a compile-time `Mix` call makes this module unloadable by plain
  `elixir` — so a snippet nobody can load is a snippet nobody can check, and
  kit's gate checks these modules by loading them.
  """
  def resource do
    %{
      service: %{
        name: @service_name,
        version: System.get_env("OTEL_SERVICE_VERSION") || "0.0.0"
      }
    }
    |> maybe_put(:deployment, System.get_env("DEPLOYMENT_ENVIRONMENT"))
    |> maybe_put(:tenant_id, System.get_env(@tenant_variable))
  end

  @doc """
  `resource/0` in the shape the OTLP EXPORTER accepts.

  ## Why this is a second function and not a change to `resource/0`

  `resource/0` is courier's declaration of identity and it is tested as a nested
  map. It is what a human reads. This is what
  `:opentelemetry_exporter` can encode, and the two differ in two ways that
  between them dropped everything courier emitted:

    * `otel_resource:attributes/1` matches an `#opentelemetry_resource{}` record
      and returns `undefined` for anything else — so a plain map produced
      `undefined` attributes and a resource with no `service.name` on it;
    * OpenTelemetry attribute names are FLAT dotted strings. courier's
      `%{service: %{name: "courier"}}` is not `"service.name"`, and even wrapped
      in a record the exporter would have encoded the whole nested map as one
      string-valued attribute. HyperDX groups by `service.name`, so the group
      this packet exists to create would not have existed.

  ## The name mapping, and why it is written out rather than derived

  | courier | OpenTelemetry |
  |---------|---------------|
  | `service.name` | `service.name` |
  | `service.version` | `service.version` |
  | `deployment` | `deployment.environment` |
  | `tenant_id` | `tenant_id` |

  `deployment.environment` is the only one that moves, and it moves because that
  is the name core's resource schema froze. Deriving it — joining a prefix onto
  each key — would produce `service.name` and `tenant_id` correctly and
  `deployment` incorrectly, so the one table above is the whole of the mapping.
  """
  def otel_resource do
    %{service: service} = courier = resource()

    :otel_resource.create(
      Map.merge(
        %{
          "service.name" => service.name,
          "service.version" => service.version
        },
        compact(%{
          "deployment.environment" => Map.get(courier, :deployment),
          "tenant_id" => Map.get(courier, :tenant_id)
        })
      )
    )
  end

  @doc """
  The `:opentelemetry` application environment, as a keyword list.

  Returned rather than applied so `config/runtime.exs` can write
  `config :opentelemetry, Courier.Telemetry.sdk_config()` and so a test can assert
  on it without starting anything.

  A KEYWORD LIST rather than a map, because `Config.config/2` accepts only the
  former. The first version of this returned a map: it type-checks fine in
  isolation and then raises inside `Config` at boot, which is the worst place to
  find out.

  Four decisions, and each has a reason that is not "this is the default":

    * `text_map_propagators: [:trace_context, :baggage]` — named explicitly rather
      than left to the SDK's default. The default IS W3C today, and a service
      that depends on a default it never wrote down breaks silently the first time
      a library changes it.
    * `sampler: {:parent_based, %{root: :always_on}}` — a service that samples
      independently produces traces with holes, which are worse to debug than no
      traces at all. The caller's decision is carried.
    * The batch processor's 5s delay and 2048-entry queue are the SDK's own
      defaults, STATED rather than inherited, so that the two numbers an operator
      is most likely to want to change are visible in this file.
    * `register_loaded_applications: false` and `create_application_tracers: false`
      — courier names its own tracer, so the SDK's per-application tracers are two
      mechanisms for one thing and every span would be recorded twice.

    ## The DISABLED path is an EMPTY processor list, and that is the sixth defect

    It used to be `:otel_simple_processor`, which reads like "export nowhere,
    cheaply" and is a BARE ATOM. `otel_configuration:processors/2` maps over the
    processor list expecting `{Name, Opts}` PAIRS and has no clause for a bare
    atom, so a courier booted with `OTEL_SDK_DISABLED=true` did not boot at all:

        [notice] Application opentelemetry exited: exited in: :opentelemetry_app.start(:normal, [])
            ** (EXIT) an exception was raised:
                ** (FunctionClauseError) no function clause matching in anonymous fn/1
                   in :otel_configuration.processors/2
                    (opentelemetry 1.7.0) src/otel_configuration.erl:179
        ** (Mix) Could not start application opentelemetry

    So the kill switch — the one setting whose whole job is to let somebody turn
    telemetry OFF — took the release down instead, which is the failure mode this
    module's own moduledoc says it exists to prevent. `[]` is a true no-op: no
    processor is started, no queue exists, no dial happens, and every
    `[:telemetry, :span]` call in the codebase stays valid because courier's own
    `Courier.SpanCollector.on_end/1` is what installs the processor, not the SDK.

    It is worth naming WHY nothing caught this: `config/runtime.exs` guards the
    whole SDK block with `config_env() != :test`, so the disabled path was never
    booted by the suite — `telemetry_test.exs` asserted the keyword list and
    nothing ever evaluated it against a running SDK. An assertion about a
    configuration is not a boot.
  """
  def sdk_config do
    if enabled?() do
      [
        text_map_propagators: [:trace_context, :baggage],
        sampler: {:parent_based, %{root: :always_on}},
        span_processor:
          {:otel_batch_processor,
           %{
             exporter: {:opentelemetry_exporter, %{endpoints: [endpoint()]}},
             scheduled_delay_ms: 5_000,
             max_queue_size: 2048
           }},
        register_loaded_applications: false,
        create_application_tracers: false
      ]
    else
      [
        text_map_propagators: [:trace_context, :baggage],
        # `processors: []`, and `span_processor` OMITTED rather than set. Both
        # halves are load-bearing, and the reasons are the same one:
        # `otel_configuration:processors/2` takes `span_processor` first, wraps
        # whatever it finds in a single-element list, and maps `{Name, Opts}` pairs
        # over it — so ANY value for that key is either a pair (fine) or a crash.
        # Measured on the two shapes this tried:
        #
        #     span_processor: :otel_simple_processor
        #       ** (FunctionClauseError) ... :otel_configuration.processors/2
        #           anonymous fn(:otel_simple_processor) ... otel_configuration.erl:179
        #     span_processor: []
        #       ** (FunctionClauseError) ... :otel_configuration.processors/2
        #           anonymous fn([]) ... otel_configuration.erl:179
        #
        # Omitting the key entirely is the third option and the only one that
        # boots: `transform/2` answers `undefined`, so the SDK falls through to
        # `processors`, and an empty list there starts no processor at all. No
        # queue, no dial, no process — and `Courier.SpanCollector.on_end/1`, which
        # is what actually installs courier's processor, is a function on the
        # tracer record rather than something the SDK starts, so it is unaffected.
        processors: [],
        register_loaded_applications: false,
        create_application_tracers: false
      ]
    end
  end

  @doc """
  One line for the startup log, on whichever path this process took.

  Called from `Courier.Application.start/2` rather than from configuration, because
  `config/runtime.exs` cannot write into the log store an operator reads.
  """
  def log_startup do
    case no_op_reason() do
      "" ->
        Logger.info(
          "telemetry started: service=#{@service_name} endpoint=#{redact_endpoint(endpoint())}"
        )

      reason ->
        Logger.info("telemetry off (#{reason}); spans stay in this node")
    end

    :ok
  end

  @doc "Supervisor entry point, named for `Courier.Application`."
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Flush the collector on the way out.

  Missing it loses the last batch, which is usually the batch containing the error
  you were restarting to look at.
  """
  # Not `@impl true`: `terminate/2` is a GenServer callback and this is a
  # Supervisor, whose callback set is `init/1`. Supervisor does call `terminate/2`
  # on its children on shutdown, so the flush happens — but claiming a callback the
  # behaviour does not declare is a warning that would eventually be a real
  # mismatch if the two ever diverged.
  def terminate(_reason, _state) do
    Courier.SpanCollector.flush()
    :ok
  end

  @impl true
  def init(_opts) do
    # The exception handler, attached from HERE rather than from the request plug's
    # own `init/1`: this supervisor starts once, and an endpoint plug re-runs
    # `init/1` on every code reload.
    CourierWeb.Plugs.Telemetry.attach_exception_handler()

    # The span collector, which is courier's span processor. The SDK cannot start
    # one itself, so this is the process that makes courier export anything at all;
    # see `Courier.SpanCollector` for the reproduction.
    children = [Courier.SpanCollector]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp disabled_by_sdk? do
    System.get_env("OTEL_SDK_DISABLED", "")
    |> String.downcase()
    |> String.trim()
    |> Kernel.==("true")
  end

  defp exporter_off?(name) do
    System.get_env(name, "")
    |> String.downcase()
    |> String.trim()
    |> Kernel.==("none")
  end

  defp presence(value, _fallback) when is_binary(value) and value != "", do: value
  defp presence(_value, fallback), do: fallback

  # The keys are OpenTelemetry's, and they are the dotted names core's resource
  # schema uses. `deployment.environment` is an ENUM there
  # (development/test/staging/production), so `local` is not a legal value.
  defp maybe_put(attributes, _key, nil), do: attributes
  defp maybe_put(attributes, _key, ""), do: attributes
  defp maybe_put(attributes, key, value), do: Map.put(attributes, key, value)

  # Drops the nil and the empty string, and nothing else. An attribute present
  # with an empty value is an attribute an operator filters on and gets nothing
  # back, and `service.name=""` is a second courier row in the store rather than a
  # tidier name — see the tests in `telemetry_test.exs` that assert absence.
  defp compact(map) do
    :maps.filter(fn _key, value -> value not in [nil, ""] end, map)
  end

  # An endpoint in a log line is a hostname and a port, or — for a bring-your-own
  # backend — an API KEY in the path or the query string. Redact the query and the
  # fragment and print the rest, so a self-hoster can confirm which backend their
  # service is pointed at without their key landing in a log store.
  defp redact_endpoint(target) do
    target
    |> String.split(["?", "#"], parts: 2)
    |> hd()
  end
end
