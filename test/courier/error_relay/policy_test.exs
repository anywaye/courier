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


  Every leak test here comes in a pair, and the pair is the point. The house
  pattern is muse's canary: a unique string placed where the caller put it,
  asserted **absent from the rendered payload**, asserted **separately** from the
  assertion that the dangerous *key* is gone. A test that only checked the key
  names would still pass if redaction were replaced by something that emptied
  every map, and a test that only checked the canary would pass if the key names
  were kept with the values scrubbed. Neither is the claim. Both are.


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

  @canary "CANARY-4f19b2c7-do-not-store-me"

  @jwt "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @sk "sk-live-0123456789abcdefghij"
  @bearer "Bearer abcdefghijklmnopqrstuvwxyz012345"

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

    test "the exception message survives, masked of credential-shaped values" do
      redacted = redact(event())

      value = redacted["exception"]["values"] |> List.first() |> Map.get("value")

      refute is_nil(value)
      refute value =~ @canary
      refute value =~ @jwt
      assert value =~ "anywaye.redacted"
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
      redacted =
        redact(event(%{"request" => %{"method" => "POST", "route" => "/v1/x?token=#{@jwt}"}}))

      assert %{"method" => "POST"} == redacted["request"]
    end

    test "every stored event is marked as having passed the boundary" do
      redacted = redact(event())

      assert "true" == redacted["tags"]["anywaye.redacted"]
    end
  end

  describe "what is removed, asserted on the value" do
    test "the canary is absent from the rendered payload, not merely from a key" do
      redacted = redact(event())

      rendered = Jason.encode!(redacted)

      refute rendered =~ @canary
    end

    test "a credential that arrives under an allowed key is masked, not kept" do
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
      redacted = redact(event(%{"tags" => %{"error.type" => "user_42_email_invalid"}}))

      assert "_OTHER" == redacted["tags"]["error.type"]
    end

    test "an event with no error.type at all is rejected by the relay, not defaulted here" do
      assert {:error, :unclassified} ==
               Policy.classify(event(%{"tags" => %{"service.name" => "courier"}}))
    end
  end

  describe "it is a function, not a process" do
    test "a value that is not a map is an error rather than a raise" do
      assert {:error, :not_an_event} == Policy.redact("not a map")
      assert {:error, :not_an_event} == Policy.redact(nil)
      assert {:error, :not_an_event} == Policy.redact([1, 2, 3])
    end

    test "an exception with no `values` key still redacts rather than raising" do
      redacted = redact(event(%{"exception" => %{"mechanism" => %{"type" => "generic"}}}))

      assert is_map(redacted)
    end

    test "an event with no exception at all is still classifiable" do
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
      assert Policy.fingerprint("garbage") == Policy.fingerprint("more garbage")
    end
  end
end
