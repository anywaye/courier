defmodule Courier.Observability do
  @moduledoc """
  The three things a span must get right, in one place.

  `record/2` is the one to read, and it exists for a reason that is worth stating
  plainly before the code.


  Telemetry is the one place sensitive content leaks by accident. courier sends
  email on behalf of other services, signs webhooks with a secret, and holds a
  notification preference keyed to a user. A tracing backend is a searchable,
  retained, widely-readable store, and adding spans to courier adds a new
  destination for exactly the text courier's whole job is not to publish.

  The realistic way this leaks is not an attacker. It is a well-meaning engineer
  in six months adding `span.set_attribute("payload", params)` because it would
  help debug a delivery, in a service whose payloads are other customers' data.

  So the control is an **allowlist at one choke point**, not discipline at each
  call site. `record/2` is the only way an attribute reaches a span, and anything
  it does not recognise does not land. `test/courier/observability_test.exs`
  asserts on the list itself — including that no name in it contains a word that
  names content — and `test/courier/telemetry_canary_test.exs` drives a real
  request with a canary in every field a caller controls and asserts it appears
  nowhere in the rendered export.

  The collector's redaction processor is the SECOND control, not the first. An
  attribute that never leaves this node cannot leak even if the collector is
  misconfigured, and a service that exports a span carrying a caller's body and
  relies on the collector to take it back out is one control, not two.


    * `error.message`. A message is unbounded, it is a cardinality bomb on any
      metric derived from it, and on a service that renders mail it is a
      recipient's name by another route. `record_failure/4` sets the span's
      STATUS and the bounded error CLASS and never the message.
    * `url.path`, `url.full`, `url.query`. A query string is caller text by
      another name. The route TEMPLATE is the bounded stand-in.
    * `user_agent.*`, `net.peer.*`, `http.request.header.*`. Courier authenticates
      with a bearer token; a header attribute is a credential in a searchable
      store.
  """

  require Logger

  @service_name "courier"

  @doc """
  The emitting service's own name.

  It is the mandatory prefix on every span name and the label every fleet query
  partitions by. One function rather than a literal in each caller, so a rename
  is one edit and not a search.
  """
  def service_name, do: @service_name

  @allowed_span_attributes ~w(
    http.request.method
    http.response.status_code
    http.route
    db.system
    error.type
    otel.status_code
  )

  @doc """
  The allowlist itself, for a test to assert on.
  """
  def allowed_span_attributes, do: @allowed_span_attributes

  @doc """
  core's CLOSED error-class vocabulary, byte-identical to the `enum` in
  `traces.schema.json`.

  A class is a grouping key, and the set is closed rather than a pattern for a
  mechanical reason: a pattern bounds the SHAPE of a value and not the set of
  values, so `recipient_42_address_invalid` would validate — snake_case,
  twenty-seven characters, and one series per value, which on the metric side is a
  user id on a measurement wearing a different name.

  `_OTHER` is the only member outside the snake_case shape and it is the OTel
  well-known fallback. It exists so instrumentation is never FORCED to invent a
  class: a closed vocabulary with no escape hatch gets widened under pressure the
  first time a real failure does not fit. An alert on `_OTHER` is an alert that
  this service has not classified its own errors.
  """
  @error_types ~w(
    _OTHER
    cancelled
    circuit_open
    conflict
    connection_failed
    dependency_unavailable
    internal_error
    invalid_request
    policy_denied
    provider_auth
    provider_rejected
    rate_limited
    timeout
  )

  def error_types, do: @error_types

  @http_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS TRACE)
  @databases ~w(postgresql redis sqlite other)

  @max_route_length 200

  @doc """
  The fleet's span name: `<service>.<operation>[.<target>[.<qualifier>]]`.

  NOT the OTel HTTP convention's `GET /v1/deliveries/{id}`. A name is the
  grouping key in every trace UI, so an attribute in the name is an attribute
  that cannot be filtered out of the grouping, and a route with an id in it is a
  cardinality explosion with a GET attached.

  The grammar caps every segment at fifteen characters, which is what makes an
  interpolated id impossible to spell even by accident: it says nothing about
  anywaye id formats, it just says no segment is longer than fifteen characters.
  """
  def span_name(operation, target \\ nil, qualifier \\ nil) do
    [operation, target, qualifier]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
    |> then(&"#{@service_name}.#{&1}")
  end

  @doc """
  Put attributes on a span, if they are allowed to be there.

  THE ONLY PATH from a value to a span in this service. Four filters, in order of
  how much they protect against:

    1. **Unknown name** — dropped. This is the one that catches a future
       `courier.payload`.
    2. **Impossible value for a known name** — dropped. A method outside
       core's eight, a status outside 100..599, a route that is not a template,
       an error class outside the closed vocabulary. A name being allowlisted is
       not a promise that any value under it is shippable, and a value is where
       both the cardinality and the content live.
    3. **Over-long string** — dropped, not truncated. A shortened route template
       matches no real endpoint, so it is a metric label that reads as "no
       traffic" on a route that is busy.
    4. **Non-scalar** — dropped. A list or a map can be a payload.
  """
  def record(span, attributes) when is_map(attributes) do
    if :otel_span.is_recording(span) do
      accepted =
        attributes
        |> Enum.flat_map(fn {name, value} -> attribute(name, value) end)

      :otel_span.set_attributes(span, accepted)
    end

    span
  end

  def record(span, _attributes), do: span

  defp attribute(name, value) when name in @allowed_span_attributes do
    with {:ok, v} <- coerce(name, value) do
      [{String.to_atom(name), v}]
    else
      :error -> []
    end
  end

  defp attribute(_name, _value), do: []

  defp coerce("http.request.method", v) when is_binary(v) do
    if v in @http_methods, do: {:ok, v}, else: :error
  end

  defp coerce("http.response.status_code", v) when is_integer(v) do
    if v >= 100 and v <= 599, do: {:ok, v}, else: :error
  end

  defp coerce("http.route", v) when is_binary(v) do
    if route_template?(v), do: {:ok, v}, else: :error
  end

  defp coerce("db.system", v) when is_binary(v) do
    if v in @databases, do: {:ok, v}, else: :error
  end

  defp coerce("error.type", v) when is_binary(v) do
    if v in @error_types, do: {:ok, v}, else: :error
  end

  defp coerce("otel.status_code", v) when is_binary(v) do
    if v in ~w(OK ERROR), do: {:ok, v}, else: :error
  end

  defp coerce(_name, _value), do: :error

  @doc """
  Whether a string is a legal `http.route` value.

  A slash-led path of bounded length drawn from a small character set, and the
  character set is the load-bearing half: there is no `@`, no `?`, no `=` and no
  space in it, so a template cannot hold an email, a query string or a
  percent-encoded anything — the three shapes a caller most easily gets into a
  path.

  A character check rather than a regex, and the reason is worth the extra line: a
  `~r{...}` sigil cannot hold a character class containing `{` and `}` without the
  sigil's own brace counting getting confused, and the first version of this
  function did exactly that and would not compile. A route pattern legitimately
  contains both — Phoenix's own is `"/v1/webhook_endpoints/:id"` and core's schema
  allows `{param}` — so the class is not optional and the regex was the wrong tool
  for it.

  WHAT THIS DOES NOT DO: it cannot tell a route TEMPLATE from a concrete path.
  `/v1/webhook_endpoints/wh_01J9Z8QK…` matches exactly as
  `/v1/webhook_endpoints/:id` does, and no pattern over a path can separate them
  without the router's route table. That property is structural —
  `CourierWeb.Plugs.Telemetry` asks Phoenix for the matched route, which the
  router built from its own table — and
  `test/courier_web/plugs/telemetry_test.exs` asserts it on a real parameterised
  route.
  """
  @route_chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.-:{}"

  def route_template?(value) when is_binary(value) do
    byte_size(value) <= @max_route_length and
      String.starts_with?(value, "/") and
      value
      |> String.to_charlist()
      |> Enum.all?(&(&1 in @route_chars))
  end

  def route_template?(_value), do: false

  @doc """
  Mark a span ERRORED and attach the bounded error CLASS.

  Two decisions, and the second is the one people get wrong.

    1. The PREDICATE for "this is an error" is the span's status, not
       `error.type`. The fleet dashboard partitions by service, filters on
       `status = error`, and drills down by class — because a fleet-wide
       breakdown grouped by `error.type` is invalid however good it looks. A span
       whose status is unset is invisible to that filter however many error
       attributes it carries.

    2. `error.type` is the CLASS, never the message, and `otel_span.record_error/3`
       is deliberately NOT called: the Erlang SDK records
       `exception.message` and `exception.stacktrace`, which are unbounded, are on
       nobody's allowlist, and in a service that renders mail are a recipient's
       name by another route.

  A class outside the closed vocabulary collapses to `_OTHER` and the caller is
  told, so instrumentation is never silently wrong. A handled-and-retried failure
  is not recorded at all: a retry that succeeded is not an error, and recording
  it makes the error rate a lie.
  """
  def record_failure(span, status, error_type, _description) do
    :otel_span.set_status(span, status)

    if status == :error do
      resolved = if error_type in @error_types, do: error_type, else: "_OTHER"

      record(span, %{"error.type" => resolved, "otel.status_code" => "ERROR"})

      if resolved != error_type do
        Logger.warning(
          "courier: #{inspect(error_type)} is not in core's error vocabulary; " <>
            "recorded as _OTHER. Add it to core's schema, not here."
        )
      end
    else
      record(span, %{"otel.status_code" => "OK"})
    end

    span
  end

  @doc """
  An EXCEPTION LOG RECORD, which is the current convention.

  The `exception` SPAN EVENT is Deprecated in favour of exactly this: a log record
  with an event name ending `.exception` and a severity chosen by EXPECTED
  IMPACT. The span-event form is a compatibility shim.

  The class goes on the record and the detail does not: the collector drops
  `exception.message` and `exception.stacktrace` because they are on nobody's
  allowlist, and a stack trace is unbounded text. `detail` is for courier's own
  application log, which is not a searchable retained store the collector ships
  to a backend — it is the line an operator reads at 3am.

  All `=>` string keys, and that is not a style choice: a dotted attribute name
  is not a valid Elixir atom key without `:"..."`, and a keyword list cannot mix
  `key:` and `"key" =>` — it is a hard SyntaxError.
  """
  def log_exception(error_type, detail, impact \\ :error) do
    level =
      case impact do
        :warning -> :warning
        :fatal -> :error
        _ -> :error
      end

    resolved = if error_type in @error_types, do: error_type, else: "_OTHER"

    Logger.log(
      level,
      detail,
      event: "exception",
      error_type: resolved,
      log_severity: Atom.to_string(level)
    )
  end
end
