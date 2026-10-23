defmodule Courier.ErrorRelay.PolicyTest do
  @moduledoc """
  The redaction boundary, applied to a Sentry event.

  This is the file that says what may reach the error store, and it is the
  reason this repository may point an Sentry SDK at anything at all. The
  reasoning it implements is not new and it is not ours: core's
  `schemas/telemetry/redaction.schema.json` says the boundary is enforced at
  **one** chokepoint, default-deny, and the collector is that chokepoint for
  traces, metrics and logs. A Sentry envelope is a fourth signal and the
  collector cannot reach it — GlitchTip speaks the Sentry protocol, not OTLP —
  so this module is the same chokepoint, written in the language the error path
  is written in, and it is the **only** implementation of it in the fleet.

  ## The two properties this asserts, separately

  Every leak test here comes in a pair, and the pair is the point. The house
  pattern is muse's canary: a unique string placed where the caller put it,
  asserted **absent from the rendered payload**, asserted **separately** from the
  assertion that the dangerous *key* is gone. A test that only checked the key
  names would still pass if redaction were replaced by something that emptied
  every map, and a test that only checked the canary would pass if the key names
  were kept with the values scrubbed. Neither is the claim. Both are.

  ## The consequence nobody should have to discover in an incident

  An error store is a **retained, indexed, widely-readable** store, and it is
  read by a human on purpose. That is exactly the threat model core's redaction
  policy was written for, which is why the collector already deletes
  `exception.message` and `exception.stacktrace` off span events — see
  `transform/anywaye_span_events` in kit's collector config, whose comment calls
  `exception.message` "a path straight to a prompt". So **this policy removes
  the exception message and the frame variables.** What survives is the class,
  the file, the line, the function, the release, the environment, and the
  `error.type` class — which is enough to act on a crash and is nothing a
  customer typed. That is a deliberate product decision, it is the reason a
  Sentry SDK may be allowed into this fleet at all, and it is asserted below
  rather than left to a reader to infer.
  """

  use ExUnit.Case, async: true

  alias Courier.ErrorRelay.Policy

  # A string that exists nowhere else in the suite, so "the canary is absent"
  # cannot be satisfied by a truncation that also happened to remove the value
  # the test was checking a different assertion about.
  @canary "CANARY-4f19b2c7-do-not-store-me"

  # Every one of these is a credential shape the collector already masks, kept
  # byte-identical to `blocked_values` in kit's `redaction/anywaye_traces`
  # processor. Two implementations of the same vocabulary is one too many, so
  # this list is the collector's list and a change to one is a change to both.
  @jwt "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @sk "sk-live-0123456789abcdefghij"
  @bearer "Bearer abcdefghijklmnopqrstuvwxyz012345"

  # `Policy.redact/1` answers `{:ok, event} | {:error, :not_an_event}` because
  # the relay parses bytes off a socket and a malformed envelope is an expected
  # input rather than a programming error. Every test below is about the happy
  # shape, so it unwraps here once rather than in thirty places — and the three
  # that are about the sad shape call `Policy.redact/1` directly.
  defp redact(event) do
    assert {:ok, redacted} = Policy.redact(event)
    redacted
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
        "timestamp" => "2026-10-01T12:00:00Z",
        "platform" => "elixir",
        "level" => "error",
        "release" => "9f2c1ab",
        "environment" => "production",
        "transaction" => "courier.email.deliver",
        "tags" => %{"error.type" => "internal_error", "service.name" => "courier"},
        "contexts" => %{"runtime" => %{"name" => "BEAM", "version" => "OTP 29"}},
        "exception" => %{
          "values" => [
            %{
              "type" => "RuntimeError",
              "module" => "Elixir.Courier.Deliver",
              "value" => "boom: #{@canary} #{@jwt} #{@sk} #{@bearer}",
              "stacktrace" => %{
                "frames" => [
                  %{
                    "filename" => "lib/courier/deliver.ex",
                    "function" => "deliver/3",
                    "lineno" => 42,
                    "in_app" => true,
                    "module" => "Elixir.Courier.Deliver",
                    "vars" => %{"api_key" => @canary, "token" => @jwt},
                    "context_line" => "def deliver(secret) do",
                    "pre_context" => ["# the caller typed this"],
                    "post_context" => ["  send_it(secret)"]
                  }
                ]
              }
            }
          ]
        }
      },
      overrides
    )
  end

  describe "what survives" do
    test "the crash itself is still there: class, file, line, function" do
      redacted = redact(event())

      frame =
        redacted["exception"]["values"]
        |> List.first()
        |> get_in(["stacktrace", "frames"])
        |> List.first()

      assert "RuntimeError" == redacted["exception"]["values"] |> List.first() |> Map.get("type")
      assert "lib/courier/deliver.ex" == frame["filename"]
      assert 42 == frame["lineno"]
      assert "deliver/3" == frame["function"]
      assert true == frame["in_app"]
    end

    test "the release and environment, because a bug that only happens in prod" do
      redacted = redact(event())

      assert "9f2c1ab" == redacted["release"]
      assert "production" == redacted["environment"]
    end

    test "the runtime context, which is bounded and is how you read a BEAM stack" do
      redacted = redact(event())

      assert %{"name" => "BEAM", "version" => "OTP 29"} == redacted["contexts"]["runtime"]
    end
  end

  describe "what is removed, asserted on the key" do
    test "`extra` is gone entirely — it is where prompts, completions and credentials go" do
      redacted =
        redact(
          event(%{
            "extra" => %{
              "DATABASE_URL" => "postgres://u:p@h/db",
              "prompt" => @canary,
              "llm_request" => %{"messages" => [%{"content" => @canary}]}
            }
          })
        )

      refute Map.has_key?(redacted, "extra")
    end

    test "`breadcrumbs` is gone — a breadcrumb is a URL with a query string in it" do
      redacted =
        redact(
          event(%{
            "breadcrumbs" => [
              %{
                "category" => "http",
                "message" => "POST /v1/x",
                "data" => %{"url" => "https://a/?t=#{@jwt}"}
              }
            ]
          })
        )

      refute Map.has_key?(redacted, "breadcrumbs")
    end

    test "the `request` keeps the method and the route template and nothing else" do
      redacted =
        redact(
          event(%{
            "request" => %{
              "method" => "POST",
              "url" => "https://api.example.com/v1/webhook_endpoints?token=#{@jwt}",
              "route" => "/v1/webhook_endpoints",
              "headers" => %{"Authorization" => @bearer, "Cookie" => "session=#{@canary}"},
              "data" => %{"api_key" => @sk},
              "query_string" => "token=#{@jwt}",
              "cookies" => %{"session" => @canary}
            }
          })
        )

      assert %{"method" => "POST", "route" => "/v1/webhook_endpoints"} == redacted["request"]
    end

    test "the `user` is gone entirely — a user id is a tenant identifier" do
      redacted =
        redact(
          event(%{
            "user" => %{
              "id" => "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
              "email" => "person@example.com",
              "ip_address" => "203.0.113.4"
            }
          })
        )

      refute Map.has_key?(redacted, "user")
    end

    test "the exception message is gone, and the reason is in the moduledoc" do
      redacted = redact(event())

      value = redacted["exception"]["values"] |> List.first() |> Map.get("value")

      assert is_nil(value)
    end

    test "frame variables are gone — in Go and Ruby these are the arguments" do
      redacted = redact(event())

      frame =
        redacted["exception"]["values"]
        |> List.first()
        |> get_in(["stacktrace", "frames"])
        |> List.first()

      refute Map.has_key?(frame, "vars")
      refute Map.has_key?(frame, "context_line")
      refute Map.has_key?(frame, "pre_context")
      refute Map.has_key?(frame, "post_context")
    end

    test "`server_name` is gone: an unbounded per-container identifier" do
      redacted = redact(event(%{"server_name" => "courier-7d9f-x1q2"}))

      refute Map.has_key?(redacted, "server_name")
    end

    test "a key that is not on the allowlist is removed from `tags`" do
      redacted =
        redact(event(%{"tags" => %{"error.type" => "timeout", "db.statement" => @canary}}))

      assert "timeout" == redacted["tags"]["error.type"]
      refute Map.has_key?(redacted["tags"], "db.statement")
    end

    test "a route carrying a query string is rejected, because a route is a template" do
      # core: "`http.route` is the **template**. `/v1/users/{id}` has one value
      # per endpoint. `/v1/users/usr_01J9Z8QK5M4N7P2R3T6V8W9X0A` has one per
      # request". A `route` with a `?` in it is not a template at all — it is a
      # URL somebody was called on, and the query string is where a token is.
      redacted =
        redact(event(%{"request" => %{"method" => "POST", "route" => "/v1/x?token=#{@jwt}"}}))

      assert %{"method" => "POST"} == redacted["request"]
    end

    test "every stored event is marked as having passed the boundary" do
      # One constant, and it is a constant on purpose. A *count* of what was
      # removed would be a tag whose value changes with every allowlist edit,
      # which is a cardinality axis nobody queries and a history that breaks on
      # a config change — the same argument the collector's
      # `transform/anywaye_metrics_labels` makes about
      # `redaction.redacted.count`. So the counts go to a log line and the event
      # carries one fixed token, which is what lets a reader of a GlitchTip issue
      # know the event is not something a service wrote straight to the store.
      redacted = redact(event())

      assert "true" == redacted["tags"]["anywaye.redacted"]
    end
  end

  describe "what is removed, asserted on the value" do
    test "the canary is absent from the rendered payload, not merely from a key" do
      # The half that a key-name check cannot make. Asserted on the ENCODED
      # bytes, because a policy that returned a structure Jason encodes
      # differently would pass a `Map` walk and fail here.
      redacted = redact(event())

      rendered = Jason.encode!(redacted)

      refute rendered =~ @canary
    end

    test "a credential that arrives under an allowed key is masked, not kept" do
      # The second barrier, and a different KIND of barrier: the allowlist keeps
      # a key out, and this masks a credential-shaped VALUE that arrived under a
      # key the allowlist does keep. `transaction` is the realistic case — it is
      # allowlisted, and a careless caller interpolates a tenant id into it.
      redacted = redact(event(%{"transaction" => "courier.send/#{@jwt}"}))

      rendered = Jason.encode!(redacted)

      assert rendered =~ "courier.send/"
      refute rendered =~ @jwt
    end

    test "each of the collector's three blocked shapes is masked where it appears" do
      for secret <- [@jwt, @sk, @bearer] do
        redacted =
          redact(
            event(%{
              "tags" => %{"error.type" => "timeout"},
              "transaction" => "courier.send/#{secret}"
            })
          )

        rendered = Jason.encode!(redacted)

        refute rendered =~ secret, "#{secret} survived the blocked_values pass"
        assert rendered =~ "anywaye.redacted"
      end
    end

    test "a secret in the exception TYPE is masked rather than trusted" do
      # `type` is allowlisted because it is the class and the class is what
      # makes the error actionable. It is also a free string that a language
      # runtime builds from the exception's own `to_string`, and an Elixir
      # `RuntimeError` raised with a token in the message can carry one here.
      # So the value is masked even though the key is allowed. This is the
      # reason `blocked_values` is not redundant with the allowlist.
      redacted = redact(event(%{"exception" => %{"values" => [%{"type" => "Err:#{@jwt}"}]}}))

      rendered = Jason.encode!(redacted)

      refute rendered =~ @jwt
    end
  end

  describe "error.type — the closed vocabulary, so the decision stays reversible" do
    test "a class from core's enum is kept as-is" do
      for class <- ~w(invalid_request policy_denied provider_auth provider_rejected
                      rate_limited timeout connection_failed circuit_open
                      dependency_unavailable conflict cancelled internal_error) do
        redacted = redact(event(%{"tags" => %{"error.type" => class}}))

        assert class == redacted["tags"]["error.type"]
      end
    end

    test "the OTel fallback `_OTHER` is kept — it is the one member that is not snake_case" do
      redacted = redact(event(%{"tags" => %{"error.type" => "_OTHER"}}))

      assert "_OTHER" == redacted["tags"]["error.type"]
    end

    test "a value outside the vocabulary is replaced, never passed through" do
      # `user_42_email_invalid` is snake_case, 22 characters, and validates
      # against a `pattern` — which is exactly how core-04's first version of
      # this rule came to permit a value per user on a dimension a dashboard
      # groups by. The enum is the fix, so an undeclared class is replaced
      # rather than trusted.
      redacted = redact(event(%{"tags" => %{"error.type" => "user_42_email_invalid"}}))

      assert "_OTHER" == redacted["tags"]["error.type"]
    end

    test "an event with no error.type at all is rejected by the relay, not defaulted here" do
      # Redaction does not invent a class: an event that arrives unclassified is
      # `{:error, :unclassified}` from `Policy.classify/1` and the relay drops it
      # with a counted reason. Defaulting it here would put `_OTHER` in the store
      # and make an alert on `_OTHER` — which is an alert that this service has
      # not classified its own errors — silently unreachable.
      assert {:error, :unclassified} ==
               Policy.classify(event(%{"tags" => %{"service.name" => "courier"}}))
    end
  end

  describe "it is a function, not a process" do
    test "a value that is not a map is an error rather than a raise" do
      # The relay parses bytes off a socket. Whatever is in them is not
      # courier's to trust, and a parse failure that raises inside the relay is a
      # crash in the process every other service's error reporting depends on.
      assert {:error, :not_an_event} == Policy.redact("not a map")
      assert {:error, :not_an_event} == Policy.redact(nil)
      assert {:error, :not_an_event} == Policy.redact([1, 2, 3])
    end

    test "an exception with no `values` key still redacts rather than raising" do
      redacted = redact(event(%{"exception" => %{"mechanism" => %{"type" => "generic"}}}))

      assert is_map(redacted)
    end

    test "an event with no exception at all is still classifiable" do
      # A Sentry *message* event has no `exception`; it has a log entry. The
      # relay accepts it (a background failure logged at error level is exactly
      # the signal this packet is for) and it still needs a class.
      assert {:ok, "internal_error"} == Policy.classify(event(%{"exception" => nil}))
    end
  end

  describe "fingerprint" do
    test "two occurrences of one bug share a fingerprint" do
      a = Policy.fingerprint(event(%{"timestamp" => "2026-10-01T12:00:00Z", "event_id" => "a"}))
      b = Policy.fingerprint(event(%{"timestamp" => "2026-10-01T12:34:56Z", "event_id" => "b"}))

      assert a == b
    end

    test "a different class is a different bug" do
      a =
        Policy.fingerprint(
          event(%{"tags" => %{"error.type" => "timeout"}, "transaction" => "a.b"})
        )

      b =
        Policy.fingerprint(
          event(%{"tags" => %{"error.type" => "internal_error"}, "transaction" => "a.b"})
        )

      refute a == b
    end

    test "a different operation is a different bug" do
      a = Policy.fingerprint(event(%{"transaction" => "courier.email.deliver"}))
      b = Policy.fingerprint(event(%{"transaction" => "courier.webhook.send"}))

      refute a == b
    end

    test "a different top frame is a different bug" do
      a = Policy.fingerprint(event())

      b =
        redact(
          event(%{
            "exception" => %{
              "values" => [
                %{
                  "type" => "RuntimeError",
                  "module" => "Elixir.Courier.Deliver",
                  "stacktrace" => %{
                    "frames" => [
                      %{
                        "filename" => "lib/courier/deliver.ex",
                        "function" => "deliver/3",
                        "lineno" => 99,
                        "in_app" => true
                      }
                    ]
                  }
                }
              ]
            }
          })
        )

      refute a == Policy.fingerprint(b)
    end

    test "the fingerprint is a stable hex digest, so it is safe as a table key" do
      fp = Policy.fingerprint(event())

      assert is_binary(fp)
      assert 64 == byte_size(fp)
      assert fp == String.downcase(fp)
      assert fp =~ ~r/\A[0-9a-f]+\z/
    end

    test "an unredactable event fingerprints to a constant rather than raising" do
      # The relay computes the fingerprint from the REDACTED event, so this
      # cannot normally happen — but a constant keeps a malformed event in the
      # throttle table under one key instead of removing it, which is the
      # difference between "throttled" and "not in the table at all".
      assert Policy.fingerprint("garbage") == Policy.fingerprint("more garbage")
    end
  end
end
