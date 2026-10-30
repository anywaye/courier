defmodule Courier.TelemetryCanaryTest do
  @moduledoc """
  **THE PROOF.** Nothing a caller sends reaches an exportable span attribute.

  Everything else in this repository's observability work is necessary and not
  sufficient. `Courier.ObservabilityTest` asserts on the ALLOWLIST — that the names
  are names somebody already thought of, and that no name contains a word that
  names content. That proves the keys that exist are absent. It cannot prove the
  keys nobody thought of are absent, and the realistic way this leaks is not an
  attacker. It is a well-meaning engineer in six months adding
  `record(span, %{"courier.payload" => params})` because it would help debug a
  delivery, in the service whose payloads are other customers' data.

  So this file plants a canary in every field a caller controls and asserts it
  appears in NOTHING that left courier — and drives REAL requests through the REAL
  router, because the allowlist being correct says nothing about what the request
  path actually records.


  A redaction boundary that deletes everything passes a "no canary" test and is
  useless. Three separate ways that happened in this repository while it was being
  written, each of which left the suite green:

    * an exporter implementing `export/3` where the callback is `export/4`, so it
      was never called;
    * an exporter whose `init/1` returned `:ok` where `{:ok, state}` was required,
      so the SDK dropped the span processor;
    * a `record/2` guarded on `is_map(span)` when a span is a RECORD — a tuple —
      so nothing was recorded at all.

  A fourth way was found in this file while this file was being fixed, and it was
  the quietest of the four because it needed no broken SDK at all:

    * the presence assertion was never wired up. This moduledoc used to name
      `Courier.TestSpans.rendered!/0` as the guard and call it the single place the
      check was made — and this file rendered through its own private helper, which
      returns "" for an empty export. With `Courier.TestSpanExporter.export/4`
      dropping every span, all ten tests here passed.

  `Courier.TestSpans.render!/1` raises rather than returning an empty string, and
  every helper below goes through it, so a suite in which courier exported nothing
  fails loudly instead of passing quietly. That guard is the single place this is
  checked — which is the sentence this file used to make about a guard it was not
  calling.


  Each test reads only the spans its own request produced: `setup` drains
  `Courier.SpanCollector`, marks the exporter table, and the assertions read since
  the mark. That is what makes the two tests in "a request PATH never reaches a
  span" independent of each other and of the rest of the suite — see the measurement
  in `setup`, which is why the arrangement is two steps and not one. The cost of
  narrowing a read is that an empty result becomes possible where it was not before,
  so it is paired with the presence assertion above rather than trusted.


  Every request below used to be **refused before it reached a controller that
  touches a database** — an unauthenticated `PUT`, an anonymous `POST` — which is
  why a file with no sandbox could drive real requests through the real router.
  The one-click unsubscribe is the first route here whose answer depends on a row:
  `POST /unsubscribe/:token` looks the token up and answers 404 for one courier
  did not issue, so the canary has to reach that read or it is a canary on a
  request the service never really serves.

  A canary proved on a request the `:accepts` plug refuses would keep this file in
  the no-database tier, and the tier would be lying: the point of that tier is
  "these tests never touch `Courier.Repo`", and a claim about the tier that is
  true only because the request was answered early is the same kind of claim this
  file exists to disprove. So the file is a `Courier.DataCase`, it is counted in
  the database tier, and the numbers in `ci/ci.yml` were re-measured
  in the commit that moved it.


  A long canary would let a length ceiling be what makes a test pass, and a
  truncated leak is still a leak. This string is short enough that no bound in this
  repository can touch it, so what passes here passed because of the ALLOWLIST and
  nothing else.
  """

  use Courier.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint CourierWeb.Endpoint

  @canary "CANARY-4e1b-DO-NOT-EXPORT"

  @mark_key :courier_canary_mark

  setup do
    Courier.SpanCollector.flush()
    Courier.SpanCollector.clear_failure()

    Process.put(@mark_key, Courier.TestSpanExporter.mark())
    :ok
  end

  describe "a request body never reaches a span" do
    test "a notification preference, keyed to a user, exports neither the id nor the answer" do
      response =
        request(
          "PUT",
          "/v1/notification_preferences/usr_#{@canary}",
          %{"email" => %{"enabled" => false}, "sms" => "555-#{@canary}"},
          authenticated: true
        )

      assert response.status in [200, 400, 401, 403, 404]

      assert_no_canary()
    end

    test "a delivery ping carrying an id in the path exports neither" do
      response =
        request("POST", "/v1/webhook_endpoints/wh_#{@canary}/test", %{}, authenticated: true)

      assert response.status in [200, 400, 401, 403, 404, 409]

      assert_no_canary()
    end

    test "a one-click unsubscribe token exports neither, and is a 404 not a span error" do
      for verb <- ["GET", "POST"] do
        response = request(verb, "/unsubscribe/lu_#{@canary}", %{})

        assert response.status == 404,
               "#{verb} /unsubscribe answered #{response.status} for a token courier " <>
                 "never issued. A 401 here would say a credential was refused, and " <>
                 "there is no credential on this route."

        assert_no_canary()
      end
    end

    test "a webhook endpoint carrying a URL and a signing secret exports neither" do
      response =
        request("POST", "/v1/webhook_endpoints", %{
          "url" => "https://example.com/hook/#{@canary}",
          "signing_secret" => "whsec_#{@canary}",
          "events" => ["delivered"]
        })

      assert response.status in [201, 400, 401, 422]

      assert_no_canary()
    end
  end

  describe "a request PATH never reaches a span" do
    test "a parameterised route exports the TEMPLATE, so an id cannot ride in" do
      id = "01J9Z8QK5M4N7P2R3T6V8W9X0A"

      response = request("GET", "/v1/webhook_endpoints/#{id}", nil, authenticated: true)
      assert response.status in [200, 401, 404]

      for span <- request_spans() do
        route = Map.get(span.attributes, :"http.route")

        if route do
          refute route =~ id,
                 "the span carries the concrete id in its route: #{inspect(route)}.\n\n" <>
                   "A route template has one value per endpoint; a concrete path has one " <>
                   "per request, and the collector's spanmetrics connector mints a metric " <>
                   "series for every distinct value of it. Nothing downstream can tell " <>
                   "them apart: both are on core's allowlist and both pass the redaction " <>
                   "processor. This is a service-side choice, which is why it is tested " <>
                   "here and not left to the collector."
        end
      end

      assert_no_canary()
    end

    test "an id in an unmatched path reaches nothing at all" do
      response = request("GET", "/v1/accounts/#{@canary}", nil, authenticated: true)

      assert response.status == 404

      for span <- request_spans() do
        refute Map.has_key?(span.attributes, :"http.route"),
               "a 404 produced a span with a route. The path is caller-controlled text, " <>
                 "so recording it is a cardinality bomb and a content leak in one move; " <>
                 "the 404 status is the answer."
      end

      assert_no_canary()
    end
  end

  describe "a request HEADER never reaches a span" do
    test "a bearer token, an API key and a cookie are all absent" do
      request("GET", "/v1/webhook_endpoints", nil,
        authenticated: true,
        headers: [
          {"authorization", "Bearer sess_#{@canary}"},
          {"cookie", "courier_session=#{@canary}"},
          {"x-api-key", "caf_#{@canary}"},
          {"user-agent", "canary-agent/#{@canary}"}
        ]
      )

      exported = rendered_request_spans()

      for {name, value} <- [
            {"the bearer token", "Bearer sess_#{@canary}"},
            {"the cookie", "courier_session=#{@canary}"},
            {"the api key", "caf_#{@canary}"}
          ] do
        refute exported =~ value, "#{name} reached an exportable span attribute.\n\n#{exported}"
      end

      assert_no_canary()
    end
  end

  describe "a query string never reaches a span" do
    test "an email in the query string of a matched route reaches nothing" do
      request("GET", "/v1/webhook_endpoints?email=someone-#{@canary}@example.com", nil,
        authenticated: true
      )

      assert_no_canary()
    end
  end

  describe "an inbound traceparent never contributes its own characters" do
    test "a malformed header carrying content is IGNORED, not recorded" do
      response =
        request("GET", "/healthz", nil, headers: [{"traceparent", "00-#{@canary}-#{@canary}-01"}])

      assert response.status == 200

      assert_no_canary()
    end
  end

  describe "the error path never carries the message" do
    test "a 404's span carries a status and no message" do
      request("GET", "/v1/does-not-exist", nil, authenticated: true)

      for span <- request_spans() do
        assert span.status == "unset",
               "a 404 produced a #{span.status} span. A 404 is the service REFUSING a " <>
                 "request, which is the service working; an error rate that counts it " <>
                 "is a function of how much guessing the platform absorbs, and an alert " <>
                 "on it pages somebody to turn off the protection doing its job."
      end

      assert_no_canary()
    end
  end


  defp assert_no_canary do
    exported = rendered_request_spans()

    if exported =~ @canary do
      raise """
      THE REDACTION BOUNDARY LEAKED.

      The canary
      planted in a field a caller controls, so whatever route it took is a route by
      which a customer's email, a password, a webhook signing secret or a bearer token
      reaches a searchable, retained, widely-readable store — and courier sends mail on
      other services' behalf and signs webhooks with a secret, so those are the values
      this service most cannot afford to publish.

      The whole export:

      """
    else
      exported
    end
  end

  defp request_spans do
    Courier.TestSpans.finished_spans_since(Process.get(@mark_key))
    |> Enum.filter(&(&1.name == "courier.web.request"))
  end

  defp rendered_request_spans do
    Courier.TestSpans.render!(request_spans())
  end

  defp request(method, path, body, opts \\ []) do
    authenticated? = Keyword.get(opts, :authenticated, false)
    headers = Keyword.get(opts, :headers, [])

    conn =
      put_headers(build_conn(), headers)
      |> maybe_authenticate(authenticated?)
      |> put_req_header("content-type", "application/json")

    conn = Phoenix.ConnTest.dispatch(conn, @endpoint, method, path, body)

    flush()
    conn
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  defp maybe_authenticate(conn, true) do
    put_req_header(conn, "x-tenant-account", "acc_test")
  end

  defp maybe_authenticate(conn, false), do: conn

  defp flush do
    Courier.SpanCollector.flush()
    Process.sleep(0)
    :ok
  end
end
