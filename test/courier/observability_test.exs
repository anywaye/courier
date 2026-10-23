defmodule Courier.ObservabilityTest do
  @moduledoc """
  The allowlist, asserted on directly.

  `Courier.TelemetryCanaryTest` proves no caller-supplied content reaches an
  exportable span. This file proves the ALLOWLIST is the thing doing the work,
  and the two are not the same claim: a canary test can be satisfied by a service
  that exports nothing, and an allowlist test can be satisfied by a service that
  never calls `record/2`. Both are needed, and each says which failure it catches.

  The pattern throughout is muse's, promoted: the realistic way courier's
  redaction boundary fails is not an attacker. It is a well-meaning engineer in
  six months adding `span.set_attribute("payload", params)` because it would help
  debug a delivery, in the one service in the fleet whose payloads are other
  customers' data. So the list itself is the assertion, and the words it may not
  contain are written down.
  """

  # NOT async, and the reason is the harness rather than the tests: the exported
  # spans live in ONE process-wide ETS table behind ONE `Courier.SpanCollector`, and
  # `spans_for/1` clears it, drives one span, flushes, and reads it back. Two async
  # tests doing that interleave and each reads the other's span — which produces
  # failures that look like redaction failures and are not one.
  use ExUnit.Case, async: false

  describe "the allowlist carries no name that could hold content" do
    test "no name contains a word that names content" do
      forbidden = ~w(
        prompt message content text body header query payload params email
        subject recipient to cc bcc body_html body_text secret token
        credential signing authorization cookie api_key detail recipient_id
        user account tenant webhook_secret
      )

      offenders =
        Enum.filter(Courier.Observability.allowed_span_attributes(), fn name ->
          lowered = String.downcase(name)
          Enum.any?(forbidden, &String.contains?(lowered, &1))
        end)

      assert offenders == [],
             """
             the span-attribute allowlist carries names that could hold content: #{inspect(offenders)}

             Every name on this list is the security control. courier renders mail on
             other services' behalf, signs webhooks with a secret, and holds a
             notification preference keyed to a user — so a name that could carry a
             recipient's address, a message body or a signing secret is a value in a
             searchable, retained, widely-readable store.
             """
    end

    test "every name is one core's own trace schema allows" do
      # Transcribed from core/schemas/telemetry/traces.schema.json,
      # `$defs.tracesAttributes.properties`. The `llm.*` half of the fleet-wide
      # redaction allowlist is deliberately absent: it is muse's, and courier calls
      # no model.
      core_allows = ~w(
        http.request.method http.response.status_code http.route db.system
        db.operation messaging.system messaging.operation otel.status_code
        error.type
      )

      unknown = Courier.Observability.allowed_span_attributes() -- core_allows

      assert unknown == [],
             """
             these attributes are not on core's trace allowlist: #{inspect(unknown)}

             An attribute core does not name is dropped by the collector, so exporting it
             buys nothing and costs a hole in the one place the boundary can be
             inspected. kit's gate compares the COLLECTOR's allowlist to the same file on
             disk and fails when the two disagree; this is courier's half of that pair.
             """
    end

    test "no name is an identifier core's metrics schema prohibits on a measurement" do
      # Byte-identical to the `not` in core/schemas/telemetry/metrics.schema.json.
      # The collector's `spanmetrics` connector derives the fleet's metrics from
      # these spans, so a name on this list is a candidate metric label, and an
      # unbounded one is a stream per value.
      prohibited = ~w(
        tenant_id user_id account_id request_id trace_id span_id session_id
        message_id notification_id email error.message error.stacktrace
        url.full url.path
      )

      offenders =
        Enum.filter(Courier.Observability.allowed_span_attributes(), &(&1 in prohibited))

      assert offenders == [],
             """
             the span-attribute allowlist carries identifiers core's metrics schema
             prohibits on a measurement: #{inspect(offenders)}
             """
    end
  end

  describe "record/2 refuses what it does not recognise" do
    test "a content-bearing name is dropped and the allowed ones survive" do
      span =
        spans_for(fn span ->
          Courier.Observability.record(span, %{
            "courier.payload" => %{"to" => "someone@example.com"},
            "courier.subject" => "your invoice",
            "http.request.method" => "POST",
            "http.response.status_code" => 201
          })
        end)

      attributes = attributes_of(span)

      assert attributes["courier.payload"] == nil
      assert attributes["courier.subject"] == nil
      assert attributes["http.request.method"] == "POST"
      assert attributes["http.response.status_code"] == 201
    end

    test "an allowed name with an impossible value is dropped" do
      # A name allowlist is a promise about NAMES. It says nothing about whether a
      # value under an allowed name is shippable, and a value is where both the
      # cardinality and the content live.
      span =
        spans_for(fn span ->
          Courier.Observability.record(span, %{
            "http.request.method" => "PROPFIND",
            "http.response.status_code" => 999,
            "http.route" => "/v1/webhook_endpoints/someone@example.com",
            "error.type" => "recipient_42_address_invalid",
            "db.system" => "postgresql?account_id=acc_01J9",
            "otel.status_code" => "MAYBE"
          })
        end)

      assert attributes_of(span) == %{}
    end

    test "a value that is not a scalar is dropped" do
      # A payload is a map. A list of recipients is a list. An object with an
      # inspect is anything at all.
      span =
        spans_for(fn span ->
          Courier.Observability.record(span, %{
            "http.route" => ["a", "b"],
            "http.response.status_code" => :not_an_integer,
            "db.system" => {:a, :b}
          })
        end)

      assert attributes_of(span) == %{}
    end

    test "an empty attribute map is not an error" do
      span = spans_for(fn span -> Courier.Observability.record(span, %{}) end)

      assert attributes_of(span) == %{}
    end
  end

  describe "the error vocabulary is core's, exactly" do
    test "the list is byte-identical to the schema's enum" do
      assert Courier.Observability.error_types() == ~w(
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
    end

    test "a class outside the vocabulary collapses to _OTHER and says so" do
      # The escape hatch that is not an escape hatch. `_OTHER` exists so
      # instrumentation is never FORCED to invent a class; this proves the forcing
      # does not happen by accident either. A collapse that happened silently is
      # how `_OTHER` becomes a permanent value nobody reads — and an alert on
      # `_OTHER` is an alert that courier has not classified its own errors.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          span =
            spans_for(fn span ->
              Courier.Observability.record_failure(span, :error, "smtp_refused", nil)
            end)

          assert attributes_of(span)["error.type"] == "_OTHER"
        end)

      assert log =~ "smtp_refused"
      assert log =~ "_OTHER"
    end
  end

  describe "record_failure/4" do
    test "sets both halves of core's biconditional and not the message" do
      # status `error` obliges an error class, and an error class obliges a failed
      # status. That pair is what makes the ABSENCE of `error.type` the load-bearing
      # "this was not an error" marker on a duration histogram.
      span =
        spans_for(fn span ->
          Courier.Observability.record_failure(
            span,
            :error,
            "timeout",
            "the provider did not answer in 30s"
          )
        end)

      attributes = attributes_of(span)

      assert attributes["error.type"] == "timeout"
      assert attributes["otel.status_code"] == "ERROR"
    end

    test "never puts the message on the span" do
      # `otel_span.record_error/3` is deliberately not called: it writes
      # `exception.message` and `exception.stacktrace`, which are unbounded, are on
      # nobody's allowlist, and in a service that renders mail are a recipient's
      # address by another route.
      span =
        spans_for(fn span ->
          Courier.Observability.record_failure(
            span,
            :error,
            "timeout",
            "smtp to someone@example.com refused"
          )
        end)

      refute Map.has_key?(attributes_of(span), :"exception.message")
      refute Map.has_key?(attributes_of(span), :"exception.stacktrace")
    end

    test "a non-error status mirrors OK" do
      # `:ok` is not a claim that the request failed, so this is the one status that
      # carries NO class. The biconditional in core's schema runs the other way too:
      # a class obliges a failed status, and a failed status obliges a class.
      span =
        spans_for(fn span ->
          Courier.Observability.record_failure(span, :ok, "dependency_unavailable", nil)
        end)

      assert attributes_of(span) == %{"otel.status_code" => "OK"}
    end
  end

  describe "span_name/3" do
    test "prefixes the service" do
      assert Courier.Observability.span_name("web", "request") == "courier.web.request"
      assert Courier.Observability.span_name("deliver") == "courier.deliver"

      assert Courier.Observability.span_name("outbox", "drain", "poll") ==
               "courier.outbox.drain.poll"
    end

    test "an identifier is not spellable in a segment" do
      # Not because this module knows about anywaye id formats — it does not — but
      # because the fleet's grammar caps every segment at fifteen characters. That
      # is why the route and the identity are ATTRIBUTES and the name carries only
      # the operation.
      name = Courier.Observability.span_name("web", "request", "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A")

      assert name == "courier.web.request.usr_01J9Z8QK5M4N7P2R3T6V8W9X0A"

      refute name =~ ~r/(\.[a-z0-9_]+){4,}/,
             "a name segment longer than fifteen characters would be a name an operator cannot group by"
    end
  end

  describe "route_template?/1" do
    test "accepts the shapes Phoenix actually produces" do
      for route <- [
            "/healthz",
            "/v1/webhook_endpoints",
            "/v1/webhook_endpoints/:id",
            # core's own schema allows `{param}` as well as `:param`, and a route
            # that legally contains braces must not be refused by a validator that
            # was written without them in mind.
            "/v1/accounts/{accountID}",
            "/v1/notification_preferences/user_01J9Z8QK5M4N7P2R3T6V8W9X0A"
          ] do
        assert Courier.Observability.route_template?(route), "refused a legal route: #{route}"
      end
    end

    test "refuses the shapes a caller most easily gets content through" do
      for value <- [
            # An email. There is no `@` in the character set.
            "/v1/accounts/someone@example.com",
            # A query string. No `?`, no `=`.
            "/v1/accounts?email=someone@example.com",
            # A space, which is what `interpolate` produces.
            "/v1/accounts/some one",
            # Not slash-led.
            "v1/accounts",
            # A percent-encoded anything.
            "/v1/accounts/%2e%2e%2f",
            # Over the length bound.
            "/" <> String.duplicate("a", 201)
          ] do
        refute Courier.Observability.route_template?(value), "accepted an illegal route: #{value}"
      end
    end

    test "refuses a non-binary" do
      refute Courier.Observability.route_template?(nil)
      refute Courier.Observability.route_template?(:"/v1/x")
      refute Courier.Observability.route_template?(["/v1/x"])
    end

    test "a concrete path still matches, and that is the documented limit" do
      # WHAT THIS FUNCTION CANNOT DO, written as a test so nobody later reads it as
      # the guarantee it is not. No pattern over a path can tell a filled-in
      # template from a literal one without the router's route table.
      #
      # The property is therefore STRUCTURAL: `CourierWeb.Plugs.Telemetry` asks
      # Phoenix for the matched route, which the router built from its own table
      # where a path parameter is the literal `:id`. A concrete path is not
      # available to that call site. `CourierWeb.Plugs.TelemetryTest` asserts it on
      # a real parameterised route, which is the only request shape on which the
      # two differ.
      assert Courier.Observability.route_template?(
               "/v1/webhook_endpoints/wh_01J9Z8QK5M4N7P2R3T6V8W9X0A"
             )
    end
  end

  # --- helpers ---------------------------------------------------------------

  # A REAL exported span: the SDK opens it, courier's own span processor collects
  # it, and the exporter writes it where this test can read it. The whole export
  # path, because a redaction claim is about what LEFT the process — and because
  # the parts of that path that are easy to get wrong fail by exporting nothing at
  # all, which makes a "no canary" assertion pass. See `Courier.TestSpanExporter`.

  defp spans_for(fun) do
    # `clear/1` is safe HERE and only here, and the reason is ExUnit's scheduling
    # rather than a convention: this module is `async: false`, and ExUnit runs every
    # `async: false` module after the `async: true` ones, one at a time, with no
    # overlap. So clearing the shared table here cannot delete another test's
    # evidence. The canary test, which is also `async: false` and DOES share the
    # table, therefore identifies its spans by name instead.
    Courier.TestSpanExporter.clear()

    ctx = CourierWeb.Plugs.Telemetry.extract_context([])

    span =
      :otel_tracer.start_span(ctx, Courier.Telemetry.tracer(), "courier.test", %{kind: :internal})

    fun.(span)
    :otel_span.end_span(span)
    Courier.SpanCollector.flush()

    # BY NAME, not by position. The rest of the suite is `async: true` and every
    # request through the endpoint exports into the same table, so "the spans
    # exported since I started" is every span the scheduler produced in between.
    # `courier.test` is opened by exactly one call site in this file.
    case Courier.TestSpans.finished_spans() |> Enum.filter(&(&1.name == "courier.test")) do
      [finished] -> finished
      other -> flunk("expected exactly one `courier.test` span, got #{length(other)}")
    end
  end

  defp attributes_of(span) do
    Enum.into(span.attributes, %{}, fn {key, value} -> {to_string(key), value} end)
  end
end
