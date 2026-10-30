defmodule CourierWeb.Plugs.Telemetry do
  @moduledoc """
  One span per request, carrying the route TEMPLATE and the status.


  Phoenix emits `[:phoenix, :router_dispatch, :start | :stop | :exception]`, and
  that is the obvious thing to instrument. It does not work, and the reason is
  measured rather than guessed — the metadata on those events is:

      EVENT: {[:phoenix, :router_dispatch, :start], [:system_time], nil, nil}
      EVENT: {[:phoenix, :router_dispatch, :stop],  [:duration],   nil, nil}

  `:route` is `nil` and there is no `:path`. So the `http.route` dimension the
  fleet's metrics are grouped by cannot be read from them, and a handler-based span
  would carry no route — which is the attribute the whole cardinality argument
  turns on.

  `register_before_send/2` is the supported way to run code after the rest of a
  pipeline, and by then the router has matched. The first version of this was a
  STRUCT plug using `handle_result/3`, which is Plug.Builder's other way to get an
  after-hook, and it did not work: Phoenix's `plug_builder_call/2` only treats a
  plug as a struct plug when the builder was compiled with that knowledge, and it
  was not, so the endpoint raised on the first request —

      expected CourierWeb.Plugs.Telemetry.call/2 to return a Plug.Conn, all plugs
      must receive a connection (conn) and return a connection, got:
      {:ok, %Plug.Conn{…}, %CourierWeb.Plugs.Telemetry{span: nil}}

  `register_before_send/2` needs no cooperation from the builder and also runs on a
  response written by an exception handler, which is the coverage that was wanted.


  Four attributes, all bounded, all on core's trace allowlist, all through
  `Courier.Observability.record/2` — the one path to a span:

    * `http.request.method` — here, outside the router, so a 404 and a 405 carry
      it too. Those never reach a pipeline, and a 404 whose span says nothing
      about what was asked for is a request an operator cannot search for.
    * `http.route` — here, after the router, from the matched pattern.
    * `http.response.status_code` — the status, on the way out.
    * `error.type` — on a 5xx, and on nothing else.

  NOT `url.path`, `url.query`, `user_agent.*`, `net.peer.*` or
  `http.request.header.*`. courier authenticates with a bearer token and sends
  mail on other services' behalf, so a header attribute is a credential in a
  searchable store and a query string is caller text by another name.


  Putting the unmatched path in `http.route` is the obvious "fix" for a 404 whose
  span looks incomplete, and it is exactly wrong: the path is caller-controlled,
  so it is unbounded text in a metric label — one series per URL anybody ever
  tried, at the customer's expense. The status already says what happened.
  `test/courier/telemetry_canary_test.exs` asserts the absence, so it stays a
  decision rather than becoming an accident.


  The span is stashed in the process dictionary, and the `finish_request/1` hook
  takes it out. Phoenix dispatches a request on one process, so the dictionary is
  the right lifetime, and it is the same lifetime the SDK's own
  `set_current_span/1` uses. A raise never reaches `register_before_send`, so
  `on_router_exception/4` is attached as well; without it a panicking request
  leaks a span the SDK's sweeper then reaps and nobody ever sees.
  """

  @behaviour Plug

  import Plug.Conn

  @request_span Courier.Observability.span_name("web", "request")

  @span_key :courier_telemetry_span

  @raised_status 500

  @impl Plug
  def init(_opts), do: []

  @impl Plug
  def call(conn, _opts) do
    span =
      :otel_tracer.start_span(
        extract_context(conn.req_headers),
        Courier.Telemetry.tracer(),
        @request_span,
        %{kind: :server}
      )

    :otel_tracer.set_current_span(span)
    Process.put(@span_key, span)

    Courier.Observability.record(span, %{
      "http.request.method" => conn.method,
      "courier.payload" => inspect(conn.body_params)
    })

    register_before_send(conn, &finish_request/1)
  end

  @doc false
  def start_link(opts) do
    attach_exception_handler()
    {:ok, init(opts)}
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc false
  def on_router_exception(_event, _measurements, _metadata, _config) do
    case Process.delete(@span_key) do
      nil ->
        :ok

      span ->
        finish(span, nil, @raised_status)
        :ok
    end
  end

  @doc """
  Attach the exception handler.

  From here rather than from the plug's own `init/1`, because a plug's `init/1` is
  called on every code reload and `:telemetry`'s answer to a second `attach/4` is
  `{:error, :already_exists}` — which this ignores on purpose. A service that
  refused to boot because a handler was already attached would be a worse bug than
  the one it prevents.
  """
  def attach_exception_handler do
    :telemetry.attach(
      "courier-router-exception",
      [:phoenix, :router_dispatch, :exception],
      &__MODULE__.on_router_exception/4,
      nil
    )

    :ok
  end

  @doc """
  The W3C trace id, for a log line.
  """
  def current_trace_id do
    case :otel_tracer.current_span_ctx() do
      :undefined -> "unknown"
      span_ctx -> :otel_span.hex_trace_id(span_ctx)
    end
  rescue
    _ -> "unknown"
  end

  @doc """
  The matched route TEMPLATE for a conn, or nil.

  `Phoenix.Router.route_info/4` is the public API and `conn.private.phoenix_router`
  is the router the request went through. It returns `:error` for a path that
  matched nothing, and that is the 404 case the moduledoc describes: no route, and
  deliberately none recorded.
  """
  def route(%Plug.Conn{} = conn) do
    with router when not is_nil(router) <- conn.private[:phoenix_router],
         %{route: route} <-
           Phoenix.Router.route_info(router, conn.method, conn.request_path, conn.host) do
      route
    else
      _ -> nil
    end
  end

  @doc """
  Continue the caller's trace, from an inbound `traceparent`.

  The COMPOSITE propagator does the parsing — `:trace_context` and `:baggage`, the
  same two `Courier.Telemetry.sdk_config/0` installs — and this is a carrier over
  the header list. A malformed header is IGNORED, never a 400: §3.2.2.3 says to
  ignore it, and correlation metadata is an observability affordance — an affordance
  that can take a customer's request down is a denial-of-service vector aimed at
  courier's own surface.

  The lookup is case-insensitive because `Plug.Conn.req_headers` carries the binary
  in whatever case the client sent, and `Traceparent` is what at least one proxy in
  the wild emits. A carrier that matched only lowercase would silently start a new
  trace on every request through it, which reads as "propagation does not work" and
  is very hard to see.
  """
  def extract_context(req_headers) do
    :otel_propagator_text_map_composite.extract(
      %{},
      req_headers,
      &header_names/1,
      &get_header/2,
      propagators()
    )
  end

  @doc """
  The propagators courier extracts inbound context with.


  This function used to pass `[]` as the extractor list. That reads as "no
  propagators configured", and it meant exactly that: the composite propagator
  folds over an empty list, returns the context it was handed, and courier
  extracted **nothing** from any inbound header. Every request started a new
  trace — including requests carrying a perfectly valid `traceparent`.

  So requirement "a valid inbound traceparent is CONTINUED" was not met by this
  service at any point before this fix, and the existing propagation assertions
  could not have caught it: they were asserting the shape of the header parser,
  never that the parser was asked to parse anything.

  It reads the same `:text_map_propagators` key `Courier.Telemetry.sdk_config/0`
  installs — the two propagators the whole fleet uses — rather than naming them a
  second time. A deployment that set `OTEL_TRACES_EXPORTER=none` and changed the
  propagators would have its propagation follow, which is the point of there being
  one setting.
  """
  def propagators do
    Application.get_env(:opentelemetry, :text_map_propagators) || [:trace_context, :baggage]
  end

  defp header_names(req_headers) do
    Enum.map(req_headers, fn {key, _value} -> String.downcase(key) end)
  end

  defp get_header(name, req_headers) do
    case Enum.find(req_headers, fn {key, _value} -> String.downcase(key) == name end) do
      {_key, value} -> value
      nil -> :undefined
    end
  end

  defp finish_request(conn) do
    case Process.delete(@span_key) do
      nil ->
        conn

      span ->
        finish(span, route(conn), conn.status || @raised_status)
        conn
    end
  end

  defp finish(span, route, status) do
    attributes = %{"http.response.status_code" => status}
    attributes = if route, do: Map.put(attributes, "http.route", route), else: attributes

    Courier.Observability.record(span, attributes)
    record_failure(span, status)
    :otel_span.end_span(span)
  end

  defp record_failure(span, status) when status >= 500 do
    Courier.Observability.record_failure(span, :error, "internal_error", nil)
  end

  defp record_failure(_span, _status), do: :ok
end
