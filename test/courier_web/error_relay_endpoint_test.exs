defmodule CourierWeb.ErrorRelayEndpointTest do
  @moduledoc """
  The error-ingestion surface, over real requests, through `CourierWeb.ErrorRouter`.

  ## Why it is not on `CourierWeb.Router`

  Because it is not a customer API operation and putting it there would have cost
  something this repository will not pay. Everything on `/v1` takes a anywaye
  principal resolved from a bearer token; this surface takes a **shared ingest
  secret**, because a Sentry SDK holds a DSN and there is no identity service in
  that path to mint a JWT. A generated client from `openapi.yaml` must not have
  it, and a route on the public router would have needed a third entry in
  `CourierWeb.OpenAPIDocumentTest`'s exclusion list — which is weakening an
  existing check to accommodate new code, and the brief rules that out.

  So the surface is a **second listener** (`CourierWeb.ErrorEndpoint`, its own
  port) and the bidirectional router↔document test is untouched. That is the
  deciding reason and it is worth stating, because "put it on the other endpoint"
  is otherwise a detail.

  ## What these tests hold

    * the shared secret is **required** and its default is *refuse*, not allow;
    * a wrong, absent, or repeated header is `401` with core's `problem+json` and
      a body that does not distinguish "no token configured" from "wrong token";
    * the relay's own health check is **not** behind the secret, and does not
      consult a dependency — a probe behind auth reads as a dead component;
    * a body the relay cannot read is a counted discard and a `200`, never a
      non-2xx, because the Sentry SDK retries every non-2xx and a `400` for a
      malformed envelope is a retry storm in the service that sent it;
    * an oversized body is refused **before** it is read.

  `async: true`: it changes no application env and starts no shared process. The
  relay it posts to is started per test with `start_supervised!/1`, so no state
  outlives a test.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.ErrorRelay
  alias Courier.ErrorRelay.Sink
  alias Courier.TestSupport.RecordingSink

  @token "test-error-relay-token-not-a-secret"
  @canary "CANARY-4f19b2c7-endpoint"

  setup do
    relay =
      start_supervised!(
        {ErrorRelay,
         name: :"endpoint_relay_#{System.unique_integer([:positive])}",
         sink: RecordingSink,
         sink_target: self(),
         burst: 50,
         per_minute: 60,
         capacity: 64,
         queue_size: 16}
      )

    {:ok, relay: relay}
  end

  # --- the happy path --------------------------------------------------------

  describe "an envelope with the right secret" do
    test "is accepted, and the caller gets 200 before anything is forwarded", %{relay: relay} do
      # `sync/1` first: the assertion that matters is the **200**, and a `200`
      # that arrives before the store has been written is the property — the
      # request path does not wait on the error path. Asserting only "it arrived"
      # would pass for a synchronous implementation and prove nothing.
      conn = post_envelope(valid_envelope(), relay: relay)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}

      assert_receive {:relayed, body}, 2_000
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(body)
    end

    test "and the event arrives with its class and its tags", %{relay: relay} do
      assert post_envelope(valid_envelope(), relay: relay).status == 200
      assert_receive {:relayed, body}, 2_000

      assert {:ok, [%{"payload" => payload}]} = Sink.parse_envelope(body)
      assert {:ok, event} = Jason.decode(payload)
      assert "internal_error" == event["tags"]["error.type"]
      assert "courier" == event["tags"]["service.name"]
    end

    test "and the secret the SDK put in `extra` is not in the stored bytes", %{relay: relay} do
      # The end-to-end version of the boundary, over a real HTTP request rather
      # than a direct call. The canary is in the two places a courier event would
      # carry a caller's data — `extra` and the exception message — and the
      # assertion is on the bytes the sink was handed.
      #
      # The negative half of `CourierWeb.ErrorReportingTest`: that file proves the
      # SDK-side filter, this one proves the relay, and neither can substitute for
      # the other because they are two different processes reached by two different
      # paths.
      assert post_envelope(valid_envelope(), relay: relay).status == 200
      assert_receive {:relayed, body}, 2_000

      refute body =~ @canary
      assert body =~ "RuntimeError"
    end
  end

  # --- the secret ------------------------------------------------------------

  describe "the shared secret" do
    test "no header is 401, in problem+json, with core's code", %{relay: relay} do
      conn = post_envelope(valid_envelope(), token: nil, relay: relay)

      assert conn.status == 401
      assert %{"code" => "unauthorized", "title" => "Unauthorized"} = body(conn)
    end

    test "a wrong token is 401", %{relay: relay} do
      conn = post_envelope(valid_envelope(), token: "not-the-token", relay: relay)

      assert conn.status == 401
    end

    test "a repeated header is 401, rather than first-one-wins", %{relay: relay} do
      # `get_req_header/2` returns a list, and a plug that pattern-matches
      # `[token]` on it is right. A plug that took `List.first/1` would accept
      # `token: wrong, token: right` — and "the last header wins" is a header
      # injection surface on a shared secret.
      # `Plug.Conn.prepend_req_headers/2` rather than a second `put_req_header/3`,
      # because the latter **replaces** rather than adds — so the first version of
      # this test sent one header and the assertion passed for the wrong reason.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.prepend_req_headers([
          {"x-anywaye-error-token", "not-the-token"},
          {"x-anywaye-error-token", @token}
        ])
        |> assign(:error_relay, relay)
        |> dispatch_post()

      # And the point of the test: the *correct* token is present, and the request
      # is still refused, because `get_req_header/2` returned two values.
      assert conn.status == 401
    end

    test "a repeated `sentry_key` in one auth header is 401", %{relay: relay} do
      # The same injection shape one level down, and the one a "parse the params"
      # implementation gets wrong by accident: `sentry_key=wrong, sentry_key=right`
      # has the right token in it. Refused rather than resolved.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_key=not-the-token, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "an auth header without the `Sentry ` scheme prefix is 401", %{relay: relay} do
      # A header that merely *contains* `sentry_key=` is not a Sentry auth header.
      # Accepting one would widen the set of things that authenticate without
      # widening the set of things that are authenticated.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("x-sentry-auth", "sentry_key=#{@token}")
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "both headers present with the same token is accepted", %{relay: relay} do
      # The two accepted presentations of one secret, agreeing. Otherwise this is a
      # 401 for a request that is authenticated twice over, which is the kind of
      # refusal that reads as "the relay is broken".
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("x-anywaye-error-token", @token)
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 200
    end

    test "both headers present with different tokens is 401", %{relay: relay} do
      # The disagreement case, and the reason "they must agree" is a rule rather
      # than a nicety: one of the two headers is right and the other is wrong, and
      # a relay that picked either would be accepting a request that is only
      # half-authenticated.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("x-anywaye-error-token", "not-the-token")
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "an SDK-shaped request with the token is accepted, and reaches the relay", %{
      relay: relay
    } do
      # The end-to-end shape of what `Sentry.DSN.parse/1` actually sends: the path
      # an SDK computes, `application/x-sentry-envelope`, and `X-Sentry-Auth`
      # carrying the shared secret as the `sentry_key` — because a DSN's userinfo
      # **is** the token on this surface. Everything else in this file builds the
      # request by hand from a helper, so this one builds it from the SDK's own
      # three conventions and proves the relay accepts what a real SDK emits
      # rather than what the test file imagined a real SDK emits.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header(
          "x-sentry-auth",
          "Sentry sentry_version=7, sentry_client=anywaye-error-relay/1, sentry_key=#{@token}"
        )
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}

      # Asserted on the bytes the sink was handed rather than on `stats/1`,
      # because the point is that the event arrived — and `forwarded` is counted
      # by the *sender*, one process deeper, so it is a claim about a drain that
      # happens after the 200. `assert_receive` is the synchronisation the rest of
      # this file uses for the same reason.
      assert_receive {:relayed, body}, 2_000
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(body)
    end

    test "a correct token in an unexpected header is 401", %{relay: relay} do
      # The token is in the userinfo of a DSN, so an SDK sends it as `sentry_key`
      # inside `X-Sentry-Auth`. Accepting the token from *any* header would be a
      # wider surface than the one the SDKs use, and the header name is courier's
      # to fix — so only the two named headers are read and a third is ignored.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", valid_envelope())
        |> Plug.Conn.put_req_header("content-type", "application/x-sentry-envelope")
        |> Plug.Conn.put_req_header("authorization", @token)
        |> assign(:error_relay, relay)
        |> dispatch_post()

      assert conn.status == 401
    end

    test "a hand-written envelope, the way an SDK frames one, is accepted", %{relay: relay} do
      # Every other request in this file is built by `Sink.build_envelope/2` or
      # `valid_envelope/0`, so the fixture and the parser are the same author and
      # they agree by construction. A real SDK's framing is written by Sentry, not
      # by courier, so this test builds one **by hand** — the two JSON header lines
      # and the length-prefixed payload — and asserts it arrives.
      #
      # This is not belt and braces. A hand-written envelope whose item header
      # declared the wrong `length` took the relay down with a `MatchError` from
      # `Sink.take_payload/2` and answered `500`, which is the one thing
      # `CourierWeb.ErrorEnvelopeController`'s moduledoc says it must never do: an
      # error in the error path becomes a retry storm in the service that hit it.
      # Found by POSTing this envelope at the running compose stack, which is the
      # first place the parser met a framing it did not write itself.
      #
      # The payload is built with `Jason.encode!/1` and the length measured with
      # `byte_size/1` rather than written by hand, because a length that is wrong
      # by one character is the defect being guarded against and a hand-counted
      # one would be wrong in the test rather than in the parser.
      event =
        Jason.encode!(%{
          "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
          "timestamp" => "2026-10-01T12:00:00Z",
          "platform" => "elixir",
          "level" => "error",
          "tags" => %{"error.type" => "internal_error", "service.name" => "courier"}
        })

      envelope =
        Enum.join(
          [
            ~s({"event_id":"6f5d4c3b2a184e8f9c071b2d3e4f5061","timestamp":1757330000,"platform":"elixir","level":"error"}),
            ~s({"type":"event","length":#{byte_size(event)}}),
            event
          ],
          "\n"
        ) <> "\n"

      conn = post_envelope(envelope, relay: relay)

      assert conn.status == 200
      assert_receive {:relayed, forwarded}, 2_000
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(forwarded)
    end

    test "an envelope whose declared length disagrees with its bytes is a counted discard", %{
      relay: relay
    } do
      # The same framing, deliberately miscounted — the header claims fewer bytes
      # than the payload really has, so the parser must treat what follows as a new
      # item header and fail to decode it.
      #
      # The assertion is `200 {}` and a counter, never a non-2xx and never a raise.
      # Both halves matter: a `400` would make every Sentry SDK retry a body this
      # relay will never accept, and a `500` turns a bad length into a retry storm.
      # This is the case the running compose stack found and `take_payload/2` did
      # not survive.
      envelope =
        ~s({"event_id":"6f5d4c3b2a184e8f9c071b2d3e4f5061","timestamp":1757330000,"platform":"elixir","level":"error"}\n) <>
          ~s({"type":"event","length":2}\n) <> ~s({"not":"what you said"}) <> "\n"

      conn = post_envelope(envelope, relay: relay)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
      refute_receive {:relayed, _forwarded}, 300
    end

    test "a DSN with an explicit port keeps the port, so a non-default store is reachable" do
      # Found at the running compose stack, where it is not a subtle failure: the
      # relay dialled `http://glitchtip/api/1/envelope/` — port 80 — against a store
      # on 8000, and every forwarded envelope came back `store_unreachable`. The
      # relay counted it correctly and logged a symbol, which is the whole design
      # working; the bug was that `parse_dsn/1` read `URI`'s `host` field, and
      # `host` **excludes the port**.
      #
      # This is the class of defect an end-to-end run finds and a unit test over
      # the parser nearly does not, because the obvious DSN in a test fixture has no
      # port in it. So the assertion is on the URL the sink would dial, and the
      # fixture carries a port on purpose.
      assert {:ok, url, headers} =
               Sink.Req.parse_dsn("http://publickey@glitchtip:8000/1")

      assert url == "http://glitchtip:8000/api/1/envelope/"

      assert {"X-Sentry-Auth",
              "Sentry sentry_version=7, sentry_client=anywaye-error-relay/1, sentry_key=publickey"} in headers

      # And the port is the scheme's default when the DSN does not name one, which
      # is `URI.port/1`'s behaviour rather than `nil` — so the two cases are
      # genuinely different URLs and the first assertion is not vacuously true for
      # a parser that ignored the port entirely.
      assert {:ok, "http://glitchtip:80/api/1/envelope/", _headers} =
               Sink.Req.parse_dsn("http://publickey@glitchtip/1")
    end

    test "the relay's envelope header carries a distinct id per envelope, never a fixed one" do
      # THE event-loss defect, found by running the chain rather than by reading it.
      #
      # The envelope header's `event_id` used to be the literal
      # `"00000000000000000000000000000000"`. GlitchTip's ingest path falls back to
      # the **header's** id when an event payload carries none of its own
      # (`apps/event_ingest/views.py`: `if item.event_id is None: item.event_id =
      # envelope_header_event_id or uuid.uuid4()`), then dedupes on
      # `cache.aadd("uuid" + item.event_id.hex)`. So every envelope the relay ever
      # forwarded for an event without its own id shared one key, and the **first
      # was the only one**: the rest were counted by the relay as `forwarded`,
      # answered `200`, and discarded by the store as duplicates.
      #
      # Nothing in courier could see it. The relay's counters said forwarded, the
      # store said `200`, the sender saw no error — and the store held one event.
      # The only observation that showed it was counting rows in GlitchTip's
      # database, which is why the assertion here is about the header's bytes.
      #
      # So: two envelopes built from one event, and their header ids must differ.
      {:ok, first} = Sink.build_envelope([as_item(event())], "http://glitchtip:8000/1")
      {:ok, second} = Sink.build_envelope([as_item(event())], "http://glitchtip:8000/1")

      assert {:ok, %{"event_id" => first_id}} = take_envelope_header(first)
      assert {:ok, %{"event_id" => second_id}} = take_envelope_header(second)

      assert first_id != second_id
      refute first_id == "00000000000000000000000000000000"

      # 32 lowercase hex characters, which is what the Sentry envelope spec calls
      # for and what GlitchTip's `UUID` parser will accept. Asserted as a shape
      # rather than by eye, because a truncated id parses as a *different* valid
      # uuid and the bug would come back wearing a different shape.
      assert first_id =~ ~r/^[0-9a-f]{32}$/
    end

    test "an event that carries its own id keeps it, so the store's dedupe sees distinct events" do
      # The other half of the same fix, and the reason the header is not simply
      # always fresh: an SDK's own `event_id` is the id the reporter knows by, and
      # the relay must not overwrite it. `Courier.ErrorRelay.Policy` keeps
      # `event_id` in its event allowlist precisely so this survives redaction.
      {:ok, envelope} =
        Sink.build_envelope(
          [as_item(event(%{"event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061"}))],
          "http://glitchtip:8000/1"
        )

      assert {:ok, items} = Sink.parse_envelope(envelope)
      assert [item] = items
      assert {:ok, decoded} = Jason.decode(item["payload"])
      assert decoded["event_id"] == "6f5d4c3b2a184e8f9c071b2d3e4f5061"
    end

    test "the two refusals are indistinguishable to the caller", %{relay: relay} do
      # "no token configured" is a fact about the *deployment* and "wrong token"
      # is a fact about the *caller*. Only the second is any use to an attacker,
      # and a self-hoster diagnosing a misconfiguration reads the log line, which
      # names the reason.
      wrong = post_envelope(valid_envelope(), token: "nope", relay: relay)
      absent = post_envelope(valid_envelope(), token: nil, relay: relay)

      # `trace_id` is per-request by design (`CourierWeb.Plugs.Trace`), so it is
      # removed before the comparison rather than the comparison being weakened
      # to "the status is the same": the claim is that a caller cannot *tell* the
      # two refusals apart, and the trace id is the one field that legitimately
      # differs between any two responses in courier.
      assert strip_trace(wrong) == strip_trace(absent)
    end
  end

  # --- the probes -----------------------------------------------------------

  describe "the relay's health check" do
    test "answers 200 with no token" do
      # Outside the `:ingest` pipeline, and that is the whole point. A probe
      # behind the auth middleware answers `401` whatever calls it concludes the
      # component is down, and a deployment rolls back with nothing in the message
      # saying why. darkroom's README records the test that caught the equivalent
      # bug in axum: `Router.layer` applies to every route the router holds, so
      # registering the probes "before" the auth layer does not exempt them.
      conn =
        Phoenix.ConnTest.dispatch(
          build_conn(),
          CourierWeb.ErrorEndpoint,
          :get,
          "/internal/v1/errors/healthz",
          %{}
        )

      assert conn.status == 200
      assert %{"status" => "ok"} = body(conn)
    end

    test "does not consult the store, and does not consult the database" do
      # A relay that cannot reach GlitchTip has **lost errors**; it is not
      # unhealthy, and restarting courier because the error store is down
      # converts an observability outage into a notification outage. core's
      # `probes.schema.json` makes the same argument about `/healthz` and
      # constrains `checks` to `maxItems: 0` so a declaration cannot quietly give
      # liveness a dependency.
      conn =
        Phoenix.ConnTest.dispatch(
          build_conn(),
          CourierWeb.ErrorEndpoint,
          :get,
          "/internal/v1/errors/healthz",
          %{}
        )

      assert conn.status == 200
      refute Map.has_key?(body(conn), "deps")
    end

    test "answers on GET and not on the write verb, so a probe cannot post a crash" do
      assert :error ==
               Phoenix.Router.route_info(
                 CourierWeb.ErrorRouter,
                 "POST",
                 "/internal/v1/errors/healthz",
                 ""
               )
    end
  end

  # --- bodies the relay will not store ---------------------------------------

  describe "a body the relay will not store" do
    test "is a 200 and a counted discard, never a non-2xx", %{relay: relay} do
      # The Sentry SDK retries every non-2xx, so a `400` for a malformed envelope
      # means the sender retries a body this relay will never accept, and a `500`
      # for a redaction failure means a bug in the redaction boundary becomes a
      # retry storm in the service that hit it. `200 {}` and a counter is the only
      # correct answer, and the counters in `ErrorRelay.stats/1` are how an
      # operator finds out.
      for body <- ["", "not an envelope at all", ~s({"nonsense":true}), "\n\n\n"] do
        conn = post_envelope(body, relay: relay)

        assert conn.status == 200
        assert Jason.decode!(conn.resp_body) == %{}
      end
    end

    test "an oversized body is refused on its declared length, before it is read", %{relay: relay} do
      # A megabyte, which is over the controller's bound. `Plug.Test.conn/3` is
      # used because Phoenix's `post/3` has its own, smaller, opinion about how
      # much a test connection will carry — and a test that hit *that* limit would
      # be asserting the test framework's bound and calling it the controller's.
      oversized = String.duplicate("x", 1_100_000)

      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", oversized)
        |> then(&Plug.Conn.put_req_header(&1, "x-anywaye-error-token", @token))
        |> then(&Plug.Conn.put_req_header(&1, "content-type", "application/x-sentry-envelope"))
        |> assign(:error_relay, relay)
        |> then(&CourierWeb.ErrorEndpoint.call(&1, []))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}

      # ... and it was a *discard*, not a forward: a megabyte of junk is not
      # something to put in an error store.
      refute_received {:relayed, _body}
    end

    test "a body with no content-length is still bounded", %{relay: relay} do
      # A caller that streams a body has sent no `content-length`, so the declared
      # check cannot be the only one. `read_body/2`'s `:length` is the real bound
      # and the refusal happens on it. `Plug.Test.conn/3` is used rather than
      # `Phoenix.ConnTest`'s builders because this is the one test that needs the
      # absence of a header to be real, and those builders set one.
      conn =
        :post
        |> Plug.Test.conn("/api/1/envelope/", String.duplicate("y", 5_000))
        |> then(&Plug.Conn.put_req_header(&1, "x-anywaye-error-token", @token))
        |> then(&Plug.Conn.put_req_header(&1, "content-type", "application/x-sentry-envelope"))
        |> then(&Plug.Conn.delete_req_header(&1, "content-length"))
        |> assign(:error_relay, relay)
        |> then(&CourierWeb.ErrorEndpoint.call(&1, []))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
    end
  end

  # --- the router, as a contract --------------------------------------------

  describe "the surface's shape" do
    test "the two routes resolve to the controllers they claim" do
      assert %{plug: CourierWeb.ErrorEnvelopeController, plug_opts: :create} =
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", "/api/1/envelope/", "")

      assert %{plug: CourierWeb.ErrorEnvelopeHealthController, plug_opts: :healthz} =
               Phoenix.Router.route_info(
                 CourierWeb.ErrorRouter,
                 "GET",
                 "/internal/v1/errors/healthz",
                 ""
               )
    end

    test "the write route is behind the ingest pipeline and the probe is not" do
      # Proved on the router rather than inferred from the two tests above: a
      # future edit that moved the probe into the pipeline would still pass both
      # of them, because a caller with the token in hand would get a 200.
      assert %{pipe_through: [:ingest]} =
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", "/api/1/envelope/", "")

      assert %{pipe_through: []} =
               Phoenix.Router.route_info(
                 CourierWeb.ErrorRouter,
                 "GET",
                 "/internal/v1/errors/healthz",
                 ""
               )
    end

    test "the public router has no route to it, and the public document has no path" do
      # The claim that `openapi.yaml` and the customer API are untouched. Both
      # halves: no route on `CourierWeb.Router` for the ingest path, and no path
      # in the document for it either — so a generated client has no method for it.
      #
      # Checked on **both** route shapes, and `*_` on the public router is
      # deliberate rather than redundant: the customer router serves `/v1/...`, so
      # asserting only `/api/1/envelope/` would keep passing if a future edit ever
      # added a `/*_glob` catch-all. One assertion is the route's business; the
      # other is this test's.
      assert :error ==
               Phoenix.Router.route_info(CourierWeb.Router, "POST", "/api/1/envelope/", "")

      assert :error ==
               Phoenix.Router.route_info(CourierWeb.Router, "POST", "*_glob", "")

      # `"/api/1/envelope/"` and not the bare word: `openapi.yaml` is full of
      # prose, and `problem+json` responses are legitimately described as carrying
      # "the envelope". A path substring is the claim; a word is not.
      refute File.read!("openapi.yaml") =~ "/api/1/envelope/"
    end

    test "the URL courier's own SDK derives from a relay DSN is a path this router serves" do
      # THE test this whole file's route naming turns on, and the one that was
      # missing while it mattered.
      #
      # Every client of this relay is a Sentry SDK — courier's own, identity's Go
      # SDK, billing's sentry-ruby — and an SDK does not let you choose an ingest
      # path. `Sentry.DSN.parse/1` pops the **last** path segment off the DSN as
      # the project id and rebuilds the envelope URL as `<base>/api/<project>/envelope/`
      # (see `deps/sentry/lib/sentry/dsn.ex`, `pop_project_id/1`). So the DSN an
      # operator writes as `http://<token>@courier:4003/1` becomes
      # `http://<token>@courier:4003/api/1/envelope/`, and if the router does not
      # serve *that* path, courier's own errors are 404'd at its own relay.
      #
      # Every other test in this file posts to the ingest path by hand, so they
      # agreed with whatever the route was and could not tell that the SDK agreed
      # with nothing. The seam that made it invisible is `Courier.ErrorRelay.Sink`:
      # `error_reporting_test.exs` points the SDK at a **test sink** that captures
      # envelopes in-process, so the SDK→relay HTTP hop had never been taken.
      # Hence this test derives the URL the way the SDK does instead of naming it.
      {:ok, %Sentry.DSN{endpoint_uri: endpoint_uri}} =
        Sentry.DSN.parse("http://relay-token@relay.test/1")

      %URI{path: derived_path} = URI.parse(endpoint_uri)

      assert derived_path == "/api/1/envelope/"

      assert %{plug: CourierWeb.ErrorEnvelopeController, plug_opts: :create} =
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", derived_path, "")
    end

    test "a DSN carrying a base path is not routed, and that is the documented contract" do
      # `pop_project_id/1` **splits** the DSN path rather than discarding the front
      # of it, so a prefixed DSN is derivable and comes out prefixed. Asserted here
      # because the relay deliberately does not follow:
      #
      #   * the surface is on its own port, published nowhere, and its shape should
      #     not be settable by whoever holds the ingest token;
      #   * a configurable prefix is a router built from config, and a
      #     config-built path on an ingestion surface is a shape whose escaping is
      #     somebody's bug to write — for a feature no deployment in this packet
      #     uses.
      #
      # So a prefixed DSN gets a `404`, and the fix is a one-character change to
      # the operator's DSN rather than a code change nobody would know to make.
      # The relay's own documentation states the required shape, and this test is
      # what stops the two from drifting apart.
      {:ok, %Sentry.DSN{endpoint_uri: endpoint_uri}} =
        Sentry.DSN.parse("http://relay-token@relay.test/errors/7")

      %URI{path: derived_path} = URI.parse(endpoint_uri)

      assert derived_path == "/errors/api/7/envelope/"

      assert :error ==
               Phoenix.Router.route_info(CourierWeb.ErrorRouter, "POST", derived_path, "")
    end

    test "the relay is in the supervision tree, and the SDK is not" do
      # The shape of `Courier.Application`'s children, asserted rather than
      # described, because the mistake it guards against is invisible to every
      # other test in this repository.
      #
      # `{Courier.ErrorRelay, _}` must be there: the ingest surface is a listener
      # with nothing behind it if the relay is missing, and every request to it
      # would be answered by a relay that does not exist.
      #
      # `Sentry` must **not** be there, and this is the load-bearing half. `:sentry`
      # is an OTP application of its own — its `mix.exs` declares
      # `mod: {Sentry.Application, []}` — so the release starts it. Putting
      # `{Sentry, opts}` in this tree looks correct and dies at boot with "The
      # module Sentry was given as a child to a supervisor but it does not
      # implement child_spec/1".
      #
      # And the honest statement about what this assertion is worth: putting
      # `{Sentry, []}` back into `children/2` does not make this test fail, it
      # makes `Courier.Application.start/2` raise before the first test runs, so
      # the whole suite dies at startup with the supervisor's error rather than
      # with a readable failure line. Verified by doing exactly that and putting it
      # back.
      #
      # So the defect was caught by **running** the tree — the release image, the
      # first time this stack was brought up — not by a test, and the test is
      # here to name the invariant and fail readably if the tree is rebuilt with a
      # different shape, not because it would have caught that.
      children = supervision_children()

      assert Courier.ErrorRelay in children
      refute Sentry in children
    end

    test "the relay surface is bound when the server is, and unbound when it is not" do
      # The listener that makes every other test in this file meaningful against a
      # running courier rather than only against `Endpoint.call/2`.
      #
      # `config/config.exs` sets `server: false` on this endpoint and
      # `config/runtime.exs` sets it back to `true` inside the `PHX_SERVER` block —
      # **the same block** that enables the customer endpoint, and that adjacency is
      # the point. The failure from enabling only the first is invisible from
      # outside: port 4003 is not published by compose, so there is no refused
      # connection on localhost to notice, and the single symptom is a log line
      # reading "Configuration :server was not enabled for CourierWeb.ErrorEndpoint,
      # http/https services won't start" — which looks like a notice and leaves the
      # relay silently unreachable by all three services.
      #
      # So the invariant is asserted by **evaluating `config/runtime.exs`** with the
      # variable actually set, rather than by reading this process's merged
      # application env — which is this suite's config, where `PHX_SERVER` is
      # deliberately absent.
      #
      # `System.put_env/2` rather than `Config.Reader`'s `:env` option, and the
      # reason is worth recording because the `:env` option looks like it does
      # this and does not: it supplies variables for `env`-style config reading,
      # and `runtime.exs` asks `System.get_env("PHX_SERVER")`. Measured, not
      # assumed — with `:env` given and the variable unset, the reader returned a
      # config with **no `:server` key at all**, which is a green-looking result
      # for the wrong reason. Restored in `on_exit` because application env is the
      # whole VM and this file is `async: true`.
      #
      # Both endpoints asserted together, for the reason in the comment above: a
      # check on the error endpoint alone stays green if the customer API's own
      # `server` key is dropped, and "the customer API answers but the relay is
      # unreachable" is exactly the state being ruled out.
      assert %{endpoint: true, error_endpoint: true} =
               release_server_flags([{"PHX_SERVER", "true"}])

      # And the default, so this is a pair rather than one assertion with a
      # comment: without `PHX_SERVER` the listener stays off, or `mix test` binds a
      # second port and fights the customer endpoint for the machine's.
      assert %{endpoint: false, error_endpoint: false} = release_server_flags([])

      # And the compile-time half, in this environment, which is where the suite
      # runs: off, from `config/config.exs`. `%{server: false} = _` rather than
      # `Map.fetch!` so the whole config is in the failure message — this endpoint's
      # settings are also where the port, the adapter and the error renderer live,
      # and a failure here should show all of it.
      assert Application.get_env(:courier, CourierWeb.ErrorEndpoint)[:server] == false

      # And the listener binds loopback in test even though `config/config.exs`
      # asks for `{0, 0, 0, 0}`. `config/test.exs` narrows it, which is what keeps
      # `mix test` from binding a routable interface; asserted because a release
      # config change that dropped the override would otherwise expose the relay's
      # ingest port on every interface a developer runs their suite from.
      assert Application.get_env(:courier, CourierWeb.ErrorEndpoint)[:http] ==
               [ip: {127, 0, 0, 1}, port: 4003]
    end

    test "the customer API's own probes are unaffected" do
      # Two endpoints, two probe contracts, and the new one must not have moved
      # the old one. `CourierWeb.RouterTest` holds the customer API's; this holds
      # the fact that adding an endpoint did not disturb it.
      assert %{plug: CourierWeb.HealthController} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/healthz", "")

      assert %{plug: CourierWeb.HealthController} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/readyz", "")
    end
  end

  # --- helpers ---------------------------------------------------------------

  # `Phoenix.ConnTest.dispatch/5` rather than the `post/3` helper, and the reason
  # is worth recording because it produced nine failures that all looked like a
  # broken plug.
  #
  # `post/3` on a connection built by `build_conn/0` dispatches to **`@endpoint`**,
  # which `CourierWeb.ConnCase` sets to `CourierWeb.Endpoint` — the customer API,
  # not the error endpoint. Re-declaring `@endpoint CourierWeb.ErrorEndpoint` below
  # the `use` does not help, because the `using` block has already injected its own
  # `@endpoint` and the *helper* is what reads it. So every request in this file
  # was being sent to a router with no route for it, and the router's 404 rendered
  # as a `200` with an empty body on the error endpoint's error renderer — which
  # looks exactly like "the plug let it through".
  #
  # `Plug.Test.conn/3` and `CourierWeb.ErrorEndpoint.call/2`, for two reasons
  # neither of which is style.
  #
  #   * The **endpoint is named per request.** `Phoenix.ConnTest`'s `post/3`
  #     dispatches to `@endpoint`, which `CourierWeb.ConnCase` sets to
  #     `CourierWeb.Endpoint` — the *customer API*, which has no route for this
  #     path. Re-declaring `@endpoint` below the `use` does not help, because the
  #     `using` block has already injected one and the helper is what reads it. So
  #     every request went to a router with no matching route and the 404 rendered
  #     as `200 {}` on the error endpoint's error renderer — indistinguishable,
  #     from the assertion, from "the token plug let it through".
  #   * **The body has to be on the connection.** `dispatch/5`'s fifth argument is
  #     *params*, and an envelope is a binary body, not a map. Passing the envelope
  #     as params produced an empty request body, `parse_envelope/1` refused it,
  #     and the relay correctly forwarded nothing — so a test asserting on the
  #     forwarded bytes failed while every status assertion passed.
  # `\\ []` is never used — every call site passes `relay:`, and the two that
  # do not are the hand-built connections below. Removed rather than left as a
  # default the compiler warns about, because a default nobody uses is a second
  # way for this file to build a request that goes nowhere.
  defp post_envelope(body, opts) do
    :post
    |> Plug.Test.conn("/api/1/envelope/", body)
    # `x-anywaye-error-token` rather than the SDK's `X-Sentry-Auth`, so this helper
    # is the explicit-header presentation. The SDK presentation is exercised
    # separately, built from the header format in `deps/sentry/lib/sentry/transport.ex`,
    # because a helper that used the SDK header would have let the plug read a
    # header no SDK sends without a single test noticing.
    |> then(fn conn ->
      case Keyword.get(opts, :token, @token) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "x-anywaye-error-token", token)
      end
    end)
    |> then(&Plug.Conn.put_req_header(&1, "content-type", "application/x-sentry-envelope"))
    |> then(&maybe_assign_relay(&1, opts))
    |> then(&CourierWeb.ErrorEndpoint.call(&1, []))
  end

  # Point the surface at this test's own relay, through the assign the router's
  # `put_error_relay` plug reads. See that plug's comment for why this is an
  # assign and not application env: application env is the whole VM, and a test
  # that set it would be `async: false`.
  defp maybe_assign_relay(conn, opts) do
    case Keyword.get(opts, :relay) do
      nil -> conn
      relay -> assign(conn, :error_relay, relay)
    end
  end

  # For a connection that already carries its body and headers — used by the two
  # hand-built cases. `post/3` on a `build_conn/0` would go to the wrong endpoint
  # for the reason in `post_envelope/2`.
  defp dispatch_post(conn) do
    CourierWeb.ErrorEndpoint.call(conn, [])
  end

  # An envelope's first line, decoded. Its own helper rather than reusing
  # `Sink.parse_envelope/1`, which by design discards the header — and the header's
  # `event_id` is the thing under test here.
  defp take_envelope_header(envelope) when is_binary(envelope) do
    [header | _rest] = :binary.split(envelope, "\n")

    case Jason.decode(header) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, :undecodable_header}
    end
  end

  defp as_item(payload), do: %{"type" => "event", "payload" => payload}

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => nil,
        "timestamp" => "2026-10-01T12:00:00Z",
        "platform" => "elixir",
        "level" => "error",
        "tags" => %{"error.type" => "internal_error", "service.name" => "courier"}
      },
      overrides
    )
  end

  # `Courier.Application.start/2` returns a `{:ok, pid}` and the children are
  # `Supervisor.which_children/1`'s view, which reports each child's **module** as
  # its `id` for the `{Module, opts}` form. Reading it back through the running
  # supervisor rather than through a copy of the source is deliberate: the claim is
  # about what the application starts, not about what the file appears to say.
  # Read `config/runtime.exs` the way a release does: `Config.Reader` evaluates it
  # with the environment it is given, so the `PHX_SERVER` branch is actually taken
  defp endpoint_config(settings, endpoint) do
    case Map.fetch(settings, endpoint) do
      {:ok, config} -> Map.new(config)
      :error -> %{}
    end
  end

  # `File.cwd!/1` rather than a relative "config", because `mix test` runs from the
  # project root but this file's other helpers do not assume it, and a helper that
  # only works from one directory is a helper somebody will call from another.
  defp runtime_path, do: Path.join([File.cwd!(), "config", "runtime.exs"])

  # The minimum set of variables a release needs to get past `runtime.exs`'s own
  # `raise`s: `DATABASE_URL`, `SECRET_KEY_BASE`, `COURIER_SECRET_BOX_KEY` (32
  # bytes, base64 — `Courier.SecretBox` refuses anything else and the raise would be
  # indistinguishable from a broken assertion) and `COURIER_ERROR_RELAY_TOKEN`.
  @release_env [
    {"DATABASE_URL", "ecto://postgres:postgres@localhost/courier_probe"},
    {"SECRET_KEY_BASE", String.duplicate("s", 64)},
    {"COURIER_SECRET_BOX_KEY", Base.encode64(String.duplicate("k", 32))},
    {"COURIER_ERROR_RELAY_TOKEN", "probe-token"}
  ]

  # What `config/runtime.exs` sets `server:` to on each endpoint when evaluated
  # **as a release evaluates it**.
  #
  # Two things make this more than `Config.Reader.read!("config/runtime.exs")`, and
  # both were found by doing it the obvious way first:
  #
  #   * `env: [target: :prod]`. `runtime.exs` guards its prod blocks with
  #     `config_env() == :prod`, and `config_env()` reads the reader's `:target`.
  #     Without it the reader is evaluating this test environment's file and the
  #     prod blocks never run — which is a config that looks fine and answers
  #     `server: false` for a reason that has nothing to do with the assertion.
  #   * The `PHX_SERVER` variable in the **real** environment, not in `env:`.
  #     `runtime.exs` calls `System.get_env("PHX_SERVER")`, and `Config.Reader`'s
  #     `:env` option does not satisfy `System.get_env/1` — it supplies variables
  #     for `env`-style config reading. Measured: with `:env` given and the
  #     variable unset, the reader returned no `:server` key at all, which is a
  #     green-looking result for the wrong reason.
  #
  # `System.put_env/2` is restored in `on_exit`. This file is `async: true` and the
  # environment is the whole VM, so the window is real — which is the honest cost of
  # reading a `System.get_env/1` branch without a subprocess, and why the restore is
  # in `on_exit` rather than after the call (an assertion failure must still restore).
  defp release_server_flags(env) do
    previous = System.get_env("PHX_SERVER")
    apply_phx_server(env)

    on_exit(fn -> restore_phx_server(previous) end)

    settings =
      runtime_path()
      |> Config.Reader.read!(env: [target: :prod])
      |> Keyword.get(:courier, [])
      |> Map.new()

    %{
      endpoint: settings |> endpoint_config(CourierWeb.Endpoint) |> server_flag(),
      error_endpoint: settings |> endpoint_config(CourierWeb.ErrorEndpoint) |> server_flag()
    }
  end

  defp apply_phx_server([]), do: System.delete_env("PHX_SERVER")
  defp apply_phx_server(_env), do: System.put_env("PHX_SERVER", "true")

  defp restore_phx_server(nil), do: System.delete_env("PHX_SERVER")
  defp restore_phx_server(value), do: System.put_env("PHX_SERVER", value)

  # `false` when the key is **absent**, which is the case `runtime.exs` leaves in
  # the no-`PHX_SERVER` branch. Collapsing absent to false is what lets one
  # assertion cover both "explicitly off" and "not mentioned", and it is why the
  # test above also asserts the compile-time half from `config/config.exs`, where
  # the value really is `false`.
  defp server_flag(%{server: server}) when is_boolean(server), do: server
  defp server_flag(_settings), do: false

  defp supervision_children do
    Courier.Supervisor
    |> Supervisor.which_children()
    # `Supervisor.which_children/1` reports each child's id, and for the
    # `{Module, opts}` form the id **is** the module. That is the whole trick here:
    # it means the assertion is about the running tree rather than about a
    # re-reading of the source, and it does not care whether the child is up,
    # temporarily restarting, or still `:undefined` — a child that failed to start
    # is `undefined` here, and a tree that would crash a release is exactly the
    # thing worth seeing in that state.
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
  end

  defp strip_trace(conn) do
    conn.resp_body
    |> Jason.decode!()
    |> Map.delete("trace_id")
  end

  defp body(conn) do
    {:ok, decoded} = Jason.decode(conn.resp_body)
    decoded
  end

  # A real envelope, framed the way the Sentry SDK frames one: a header line, then
  # an item-header line carrying the payload `length`, then the payload. Built
  # with the relay's own `build_envelope/2` so the test cannot pass against a
  # framing the store would reject.
  defp valid_envelope do
    event = %{
      "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
      "timestamp" => "2026-10-01T12:00:00Z",
      "platform" => "elixir",
      "level" => "error",
      "transaction" => "courier.email.deliver",
      "tags" => %{"error.type" => "internal_error", "service.name" => "courier"},
      "extra" => %{"prompt" => @canary},
      "exception" => %{"values" => [%{"type" => "RuntimeError", "value" => @canary}]}
    }

    {:ok, envelope} =
      Sink.build_envelope([%{"type" => "event", "payload" => event}], "http://relay.test/1")

    envelope
  end
end
