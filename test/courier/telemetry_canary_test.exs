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

  ## Why every absence assertion here is paired with a presence one

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

  ## What "this test's spans" means, since a narrower read is a vacuous one

  Each test reads only the spans its own request produced: `setup` drains
  `Courier.SpanCollector`, marks the exporter table, and the assertions read since
  the mark. That is what makes the two tests in "a request PATH never reaches a
  span" independent of each other and of the rest of the suite — see the measurement
  in `setup`, which is why the arrangement is two steps and not one. The cost of
  narrowing a read is that an empty result becomes possible where it was not before,
  so it is paired with the presence assertion above rather than trusted.

  ## This file is a `Courier.DataCase`, and that arrived with the unsubscribe route

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
  the database tier, and the numbers in `.github/workflows/ci.yml` were re-measured
  in the commit that moved it.

  ## The canary is SHORT, and that is deliberate

  A long canary would let a length ceiling be what makes a test pass, and a
  truncated leak is still a leak. This string is short enough that no bound in this
  repository can touch it, so what passes here passed because of the ALLOWLIST and
  nothing else.
  """

  use Courier.DataCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint CourierWeb.Endpoint

  # Short, and in no allowlist and in no expected output.
  @canary "CANARY-4e1b-DO-NOT-EXPORT"

  # Where the per-test watermark lives. The PROCESS DICTIONARY, not an ExUnit
  # context key, and that is a deliberate choice rather than a shortcut: `setup`
  # runs in the same process as the test, the watermark is per-test state, and a
  # context key would mean threading `context` through all ten test signatures to
  # carry a value that only the two helpers below ever read.
  @mark_key :courier_canary_mark

  setup do
    # THIS MODULE'S OWN SPANS, and it takes two steps IN THIS ORDER because either
    # one alone still reads somebody else's evidence.
    #
    # `Courier.SpanCollector` is a BATCHER, not a per-request sink. A span ends
    # into its queue and leaves the queue when something flushes it — and the only
    # two things that flush it are this file's own `flush/0` and the collector's
    # five-second timer. So a test in another module that drives a request and
    # never flushes leaves its span SITTING IN THE QUEUE, and the next flush — the
    # one this test's own `request/4` makes — exports it into the shared table.
    #
    # MEASURED, on `mix test --seed 885732`, red on the commit this file is on.
    # At the setup of "an id in an unmatched path reaches nothing at all" the queue
    # held SIXTEEN spans belonging to three earlier modules (`/inbound/resend`,
    # `/readyz`, `/healthz`), the exporter table was empty before `clear/0` and
    # empty after it, and the test's own flush exported all SEVENTEEN at once. So
    # the assertion "a 404 produced a span with a route" was reading sixteen spans
    # with routes that this test never made, and it failed on sixteen spans of
    # evidence about requests made in other files. At the other nine setups the
    # queue held zero, which is the whole of why the rate is about one run in ten
    # rather than one in one hundred: it depends on whether the modules scheduled
    # just before this one happened to leave a backlog.
    #
    # The `clear/0` that used to be here was reading the wrong table. Nothing ever
    # landed after it — the measured row count was zero both before and after — so
    # it was clearing faithfully and the leak was upstream of it, in a queue it
    # cannot see.
    #
    # So: DRAIN FIRST, so the next thing to be exported is this test's own span,
    # and only then MARK. The mark alone is not enough, and the same measurement
    # says why: those sixteen foreign spans are inserted into the table AFTER any
    # mark taken now, because being exported late is exactly what being stuck in a
    # queue means. `mark/0` filters by when a span ARRIVED, not by which test made
    # it, and the two only agree once the queue is empty.
    Courier.SpanCollector.flush()
    Courier.SpanCollector.clear_failure()

    Process.put(@mark_key, Courier.TestSpanExporter.mark())
    :ok
  end

  describe "a request body never reaches a span" do
    test "a notification preference, keyed to a user, exports neither the id nor the answer" do
      # `PUT /v1/notification_preferences/:user_id` — a user id in the PATH and a
      # per-notification-type answer in the BODY. The path is the interesting half:
      # the span records the route TEMPLATE, so the id must be nowhere on it. The
      # body is the other half: a map of a user's answers is exactly the shape that
      # ends up in a `params` attribute in somebody's debugging change.
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
      # `POST /v1/webhook_endpoints/:id/test` — a path parameter on the one resource
      # whose whole nature is a secret.
      response =
        request("POST", "/v1/webhook_endpoints/wh_#{@canary}/test", %{}, authenticated: true)

      assert response.status in [200, 400, 401, 403, 404, 409]

      assert_no_canary()
    end

    test "a one-click unsubscribe token exports neither, and is a 404 not a span error" do
      # The sharpest value in this service after a signing secret. The token in
      # `/unsubscribe/:token` IS the whole authorization for an unauthenticated
      # `POST` that changes what a person receives, and it travels in a URL — which
      # is the shape that ends up in a `Location`, a `url.full` attribute or a
      # server access log. RFC 8058 §3.1 wants it opaque for exactly the reason
      # that matters here: a leaked one is a live credential.
      #
      # The route is parameterised, so the span records the TEMPLATE and the token
      # cannot ride in — which is the same property the webhook test above asserts,
      # on the one surface where a concrete path would be worst.
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
      # The signing secret is the sharpest case: courier stores it SEALED, and a
      # span attribute is the one place it would be stored in the clear on its way
      # to being exported.
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
      # This is the cardinality guarantee and the content guarantee in one
      # assertion, and it is the one that is only observable on a parameterised
      # route: for `/healthz` the path and the template are the same string, so a
      # service recording `conn.request_path` instead of the matched route passes
      # every test that drives a fixed path.
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
      # courier authenticates with a bearer token and mints one of its own, so a
      # header attribute here is a credential in a searchable, retained store. There
      # is no `http.request.header.*` on the allowlist at all.
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
      # A malformed `traceparent` starts a new trace and is never a 4xx — §3.2.2.3
      # says ignore it, and an affordance that can take a customer's request down is
      # a denial-of-service vector aimed at courier's own surface. The other half is
      # that "ignore" must not mean "truncate and keep the usable part".
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

  # --- helpers ---------------------------------------------------------------

  # The presence assertion, in every test above.
  #
  # `rendered!/0` raises when the export is empty, so this is simultaneously "the
  # canary is absent" and "something was exported". A test that only ever asserted
  # absence would be satisfied by a courier that records nothing, which is the
  # failure three separate bugs in this repository produced while it was written.
  defp assert_no_canary do
    exported = rendered_request_spans()

    if exported =~ @canary do
      raise """
      THE REDACTION BOUNDARY LEAKED.

      The canary #{inspect(@canary)} reached an exportable span attribute. It was
      planted in a field a caller controls, so whatever route it took is a route by
      which a customer's email, a password, a webhook signing secret or a bearer token
      reaches a searchable, retained, widely-readable store — and courier sends mail on
      other services' behalf and signs webhooks with a secret, so those are the values
      this service most cannot afford to publish.

      The whole export:

      #{exported}
      """
    else
      exported
    end
  end

  # THIS file's spans, and by NOTHING ELSE: neither by name alone, nor by whatever
  # the table happened to hold, nor by what the name filter is left holding after
  # the next test's flush.
  #
  # The name filter is kept because a span opened by something other than this
  # file's requests can also be called `courier.web.request`, and a test that only
  # works when it happens to run alone is a test that will not. It is not what makes
  # the two path tests independent, though. Name alone could not: BOTH of them
  # assert about `courier.web.request`, so "the parameterised route" test's span and
  # the "an id in an unmatched path" test's span are indistinguishable to it. That
  # is why the earlier version of this comment claimed the name filter had solved a
  # failure it had not solved: the comment said the cross-test bleed "cannot [be
  # told apart]", and then the filter was the only defence against it.
  #
  # What is left of that failure, and what it is now: `setup` drains the collector's
  # queue and marks the table, so "since the mark" and "made by this test" are the
  # same set. See the measurement in `setup`.
  defp request_spans do
    Courier.TestSpans.finished_spans_since(Process.get(@mark_key))
    |> Enum.filter(&(&1.name == "courier.web.request"))
  end

  # THIS file's spans as a string, GUARDED.
  #
  # The guard used to be missing, which is the defect this helper is here to close.
  # The moduledoc above says `Courier.TestSpans.rendered!/0` "raises rather than
  # returning an empty string" and calls that the single place it is checked — and
  # this file never called it. It rendered through the private helper below, which
  # returns "" for an empty export, so `assert_no_canary/0` below was satisfied by
  # an empty string on every test in the file.
  #
  # Measured, not argued: with `Courier.TestSpanExporter.export/4` mutated to drop
  # every span, all TEN tests in this file passed and the suite reported
  # `Result: 10 passed` — a complete redaction suite that had exported nothing and
  # proved nothing. `Courier.ObservabilityTest` caught the same mutation with eight
  # failures, so the guard was alive in this repository; it was this file's copy of
  # it that was not wired up.
  #
  # Which matters more here than anywhere else in the suite, because the previous
  # commit made this file's read NARROWER (own spans only, via a watermark). A
  # narrower read is a vacuous read unless something asserts that it read
  # something, and at that point the only thing standing between "one span" and "no
  # spans" was the absence of a crash.
  defp rendered_request_spans do
    Courier.TestSpans.render!(request_spans())
  end

  # `Phoenix.ConnTest.dispatch/5` rather than `@endpoint.call/3`, because
  # `Endpoint.call/3` does not split a query string out of the path: it hands
  # `request_path: "/"` and a `query_string: ""` to the router, so every request
  # 404s on the wrong path and the query-string test would be asserting about a
  # route that was never matched. `dispatch/5` builds a conn the way a real server
  # does.
  defp request(method, path, body, opts \\ []) do
    authenticated? = Keyword.get(opts, :authenticated, false)
    headers = Keyword.get(opts, :headers, [])

    conn =
      put_headers(build_conn(), headers)
      |> maybe_authenticate(authenticated?)
      |> put_req_header("content-type", "application/json")

    # The body goes in as `dispatch/5`'s params argument, which JSON-encodes a map
    # itself. There is no `put_req_body/2` in this Plug version — it was removed in
    # Plug 1.16 — and building the body by hand would be one more place for a test
    # to differ from what a client actually sends.
    # `dispatch/5` returns the CONN, not a `{conn, opts}` pair — the pair is
    # `recycle/2`'s shape and matching on it fails with a MatchError that prints
    # the whole conn, which buries the actual mistake.
    conn = Phoenix.ConnTest.dispatch(conn, @endpoint, method, path, body)

    # No explicit send. `dispatch/5` already sent the response — it calls
    # `Plug.Conn.send_resp/1` on the way out, which is what fires
    # `register_before_send` — and sending again raises `AlreadySentError`.
    #
    # Both of those were tried and both are written down because each looks right:
    # `Phoenix.ConnTest.recycle/2` BUILDS a fresh conn for the next request rather
    # than sending this one, and `Plug.Conn.send_resp/2` is the ADAPTER's
    # `(state, status, headers, body)`, four arguments, not the conn's.
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

  # The export is on a 5s timer in production; in test it is on demand, and this is
  # the on-demand call. A sleep would be a guess about the timer, and it would be
  # wrong on the machine where it matters.
  defp flush do
    Courier.SpanCollector.flush()
    Process.sleep(0)
    :ok
  end
end
