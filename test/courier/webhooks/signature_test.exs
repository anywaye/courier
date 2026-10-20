defmodule Courier.Webhooks.SignatureTest do
  @moduledoc """
  The Standard Webhooks signature, exactly as `reference/standard-webhooks`
  specifies it. PLAN.md §7 adopted the spec with no custom scheme, so every
  assertion here is a claim about the spec and not about courier:

    * **Base string** — spec §Signature scheme: "the message's: ID, timestamp and
      body are concatenated (delimited by full-stops)", i.e. `msg_id.timestamp.payload`.
    * **Algorithm** — spec §Signature scheme table: symmetric is `HMAC-SHA256`,
      identifier `v1`, serialized `v1,<base64>`.
    * **Secret serialization** — same table: "base64 encoded, prefixed with
      `whsec_` for easy identification", random between 24 and 64 bytes.
    * **Header names** — spec §Webhook headers: `webhook-id`, `webhook-timestamp`,
      `webhook-signature`, and "All of the headers should be prefixed with `webhook-`".
    * **Tolerance** — spec §Verifying signatures: "verify the `webhook-timestamp`
      header has a timestamp that is within some allowable tolerance of the
      current timestamp to prevent replay attacks". The spec does not name a
      number; every reference library under `libraries/` defaults to five
      minutes, which is the number courier ships and publishes to its consumers.

  The expected HMAC is computed in this file, from the spec's base string, by
  code that is not `Courier.Webhooks.Signature` and does not call it. A test that
  asserted the signer against itself would pass even if the base string were
  wrong; these cannot.
  """

  use ExUnit.Case, async: true

  alias Courier.Webhooks.Signature
  alias Courier.Webhooks.Verifier

  # The spec's own worked example (spec §Signature scheme), so the construction
  # is checked against strings the spec published rather than ones this
  # repository made up.
  @spec_id "msg_2KWPBgLlAfxdpx2AI54pPJ85f4W"
  @spec_timestamp "1674087231"

  @spec_body ~s({"type":"contact.created","timestamp":"2022-11-03T20:26:10.344522Z","data":{"id":"1f81eb52-5198-4599-803e-771906343485"}})

  @tolerance 300

  # An independent implementation of the spec's signing scheme, written from the
  # spec's base string. Every "the signature is the spec's" assertion goes
  # through this and never through `Courier.Webhooks.Signature.sign/4`.
  defp reference_signature(secret, id, timestamp, payload) do
    secret
    |> String.replace_prefix("whsec_", "")
    |> Base.decode64!()
    |> then(&:crypto.mac(:hmac, :sha256, &1, "#{id}.#{timestamp}.#{payload}"))
    |> Base.encode64()
  end

  defp secret, do: "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  defp now, do: System.system_time(:second)

  describe "the base string" do
    test "is msg_id.timestamp.payload, the spec's construction" do
      signing_secret = secret()

      expected = reference_signature(signing_secret, @spec_id, @spec_timestamp, @spec_body)

      assert Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body) ==
               "v1," <> expected
    end

    test "signs the body byte for byte, dots and all, with no re-serialization" do
      # A body containing full-stops is the interesting case: the spec joins
      # three parts with full-stops, and a body is allowed to contain them. If
      # courier parsed and re-encoded the payload before signing, this signature
      # would not be the one a consumer computes over the bytes it received.
      signing_secret = secret()
      body = ~s({"data":{"url":"https://cafaye.com/x?a=1.2"}})

      assert Signature.sign(signing_secret, @spec_id, @spec_timestamp, body) ==
               "v1," <> reference_signature(signing_secret, @spec_id, @spec_timestamp, body)
    end

    test "a different body gives a different signature" do
      signing_secret = secret()

      refute Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body) ==
               Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body <> " ")
    end

    test "a different id gives a different signature" do
      signing_secret = secret()

      refute Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body) ==
               Signature.sign(signing_secret, "msg_other", @spec_timestamp, @spec_body)
    end

    test "a different timestamp gives a different signature" do
      signing_secret = secret()

      refute Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body) ==
               Signature.sign(signing_secret, @spec_id, "1674087232", @spec_body)
    end

    test "a different secret gives a different signature" do
      refute Signature.sign(secret(), @spec_id, @spec_timestamp, @spec_body) ==
               Signature.sign(secret(), @spec_id, @spec_timestamp, @spec_body)
    end
  end

  describe "the serialized signature" do
    test "carries the symmetric version identifier v1 the spec's table names" do
      signing_secret = secret()

      assert <<"v1,", encoded::binary>> =
               Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body)

      assert encoded ==
               reference_signature(signing_secret, @spec_id, @spec_timestamp, @spec_body)
    end

    test "the encoded part is base64 of a 32-byte HMAC-SHA256" do
      assert <<"v1,", encoded::binary>> =
               Signature.sign(secret(), @spec_id, @spec_timestamp, @spec_body)

      assert {:ok, raw} = Base.decode64(encoded)
      assert byte_size(raw) == 32
    end

    test "the base string itself is not transmitted, only the signature over it" do
      signature = Signature.sign(secret(), @spec_id, @spec_timestamp, @spec_body)

      refute signature =~ @spec_id
      refute signature =~ @spec_body
    end
  end

  describe "the headers" do
    test "are exactly the three the spec names, with no fourth" do
      headers = Signature.headers(secret(), @spec_id, @spec_timestamp, @spec_body)

      assert Enum.sort(Map.keys(headers)) == [
               "webhook-id",
               "webhook-signature",
               "webhook-timestamp"
             ]
    end

    test "carry the values the spec describes" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, @spec_timestamp, @spec_body)

      assert headers["webhook-id"] == @spec_id
      assert headers["webhook-timestamp"] == @spec_timestamp

      assert headers["webhook-signature"] ==
               Signature.sign(signing_secret, @spec_id, @spec_timestamp, @spec_body)
    end

    test "the timestamp is the integer unix seconds the spec asks for" do
      headers = Signature.headers(secret(), @spec_id, @spec_timestamp, @spec_body)

      assert {unix, ""} = Integer.parse(headers["webhook-timestamp"])
      assert unix == String.to_integer(@spec_timestamp)
    end

    test "headers_now/3 stamps the attempt time, which is not the event's own time" do
      # Spec §Webhook metadata: the attempt's timestamp "may be different to the
      # timestamp of the event that generated the attempt" and "Every time an
      # attempt is retried the timestamp of the attempt is updated".
      payload = ~s({"type":"email.delivered","time":"2020-01-01T00:00:00Z","data":{}})

      before = now()
      headers = Signature.headers_now(secret(), @spec_id, payload)
      after_now = now()

      assert {unix, ""} = Integer.parse(headers["webhook-timestamp"])
      assert unix >= before
      assert unix <= after_now
    end

    test "are not renamed, cased differently, or given a fourth name" do
      headers = Signature.headers(secret(), @spec_id, @spec_timestamp, @spec_body)

      for name <- Map.keys(headers) do
        assert name == String.downcase(name)
        assert String.starts_with?(name, "webhook-")
      end

      # The Svix-dialect names are this same scheme under different names. A
      # consumer that guesses wrong verifies nothing, which is the whole reason
      # PLAN.md §7 adopted the spec instead of a bespoke scheme.
      refute "svix-id" in headers
      refute "x-cafaye-signature" in headers
    end
  end

  describe "the signing secret" do
    test "is serialized as whsec_ plus base64, per the spec's table" do
      assert String.starts_with?(Signature.generate_secret(), "whsec_")
    end

    test "carries between 24 and 64 random bytes, the range the spec names" do
      for _attempt <- 1..20 do
        assert <<"whsec_", encoded::binary>> = Signature.generate_secret()
        assert {:ok, raw} = Base.decode64(encoded)
        assert byte_size(raw) >= 24
        assert byte_size(raw) <= 64
      end
    end

    test "is different every time it is generated" do
      secrets = for _attempt <- 1..10, do: Signature.generate_secret()

      assert length(Enum.uniq(secrets)) == 10
    end

    test "a secret with a full stop in it is refused, because the base string is dot-delimited" do
      # The spec: "it's important that both the message id and the timestamp not
      # be user controlled, or at the very least not be allowed to include any `.`
      # to prevent certain attacks." The `.` in the encoded key is the check
      # that matters — the prefix may not be smuggled in from the right.
      assert_raise ArgumentError, fn -> Signature.sign_key("whsec_abc.def", "v1") end
    end

    test "a secret that is not whsec_-prefixed is refused" do
      assert_raise ArgumentError, fn -> Signature.sign_key(Base.encode64("secret"), "v1") end
    end

    test "a secret whose body is not base64 is refused" do
      assert_raise ArgumentError, fn -> Signature.sign_key("whsec_not base64!", "v1") end
    end
  end

  describe "the message id" do
    test "is prefixed msg_, the way the spec's examples are" do
      assert String.starts_with?(Signature.new_id(), "msg_")
    end

    test "never contains a full stop, so it cannot forge a base string" do
      for _attempt <- 1..50 do
        refute Signature.new_id() =~ "."
      end
    end

    test "is unique across calls" do
      ids = for _attempt <- 1..50, do: Signature.new_id()

      assert length(Enum.uniq(ids)) == 50
    end
  end

  describe "verification, the consumer's side" do
    test "accepts courier's own headers" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)

      assert Verifier.verify(@spec_body, headers, signing_secret) == :ok
    end

    test "rejects a tampered body" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)

      assert Verifier.verify(@spec_body <> " ", headers, signing_secret) ==
               {:error, :signature_mismatch}
    end

    test "rejects a tampered timestamp" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)
      # Edited on the wire, and the base string is not re-signed: this is the
      # attack the timestamp is there to catch, half of it.
      tampered = Map.put(headers, "webhook-timestamp", (now() - 1) |> Integer.to_string())

      assert Verifier.verify(@spec_body, tampered, signing_secret) ==
               {:error, :signature_mismatch}
    end

    test "rejects a tampered id" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)
      tampered = Map.put(headers, "webhook-id", "msg_someone_else")

      assert Verifier.verify(@spec_body, tampered, signing_secret) ==
               {:error, :signature_mismatch}
    end

    test "rejects a signature made with another secret" do
      headers = Signature.headers(secret(), @spec_id, now(), @spec_body)

      assert Verifier.verify(@spec_body, headers, secret()) == {:error, :signature_mismatch}
    end

    test "rejects a timestamp older than the tolerance" do
      signing_secret = secret()
      at = now()
      stale = (at - @tolerance - 1) |> Integer.to_string()
      headers = Signature.headers(signing_secret, @spec_id, stale, @spec_body)

      assert Verifier.verify(@spec_body, headers, signing_secret, now: at) ==
               {:error, :timestamp_out_of_tolerance}
    end

    test "rejects a timestamp further ahead than the tolerance" do
      signing_secret = secret()
      at = now()
      ahead = (at + @tolerance + 1) |> Integer.to_string()
      headers = Signature.headers(signing_secret, @spec_id, ahead, @spec_body)

      assert Verifier.verify(@spec_body, headers, signing_secret, now: at) ==
               {:error, :timestamp_out_of_tolerance}
    end

    test "accepts a timestamp exactly at the tolerance, because the window is inclusive" do
      signing_secret = secret()
      # `now` is captured once and passed to the verifier. Reading the clock twice
      # would let the second reading land a second later and turn a boundary case
      # into a failure that has nothing to do with the boundary — a test that only
      # passes when the suite is fast.
      at = now()
      edge = (at - @tolerance) |> Integer.to_string()
      headers = Signature.headers(signing_secret, @spec_id, edge, @spec_body)

      assert Verifier.verify(@spec_body, headers, signing_secret, now: at) == :ok
    end

    test "rejects a timestamp one second past the tolerance" do
      signing_secret = secret()
      at = now()
      edge = (at - @tolerance - 1) |> Integer.to_string()
      headers = Signature.headers(signing_secret, @spec_id, edge, @spec_body)

      assert Verifier.verify(@spec_body, headers, signing_secret, now: at) ==
               {:error, :timestamp_out_of_tolerance}
    end

    test "the tolerance is five minutes, the window every reference library uses" do
      # The spec §Verifying signatures asks for "some allowable tolerance" and does
      # not name a number. `refs/standard-webhooks/libraries/` uses 300s in every
      # implementation, and courier publishes the same window so a customer can
      # point an official library at a courier webhook and get the same answer.
      assert Verifier.tolerance() == 300
    end

    test "rejects a timestamp that is not an integer" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)
      tampered = Map.put(headers, "webhook-timestamp", "not-a-timestamp")

      assert Verifier.verify(@spec_body, tampered, signing_secret) ==
               {:error, :malformed_timestamp}
    end

    test "rejects a request missing any of the three headers" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)

      for name <- ["webhook-id", "webhook-timestamp", "webhook-signature"] do
        assert Verifier.verify(@spec_body, Map.delete(headers, name), signing_secret) ==
                 {:error, {:missing_header, name}}
      end
    end

    test "accepts a space-delimited list of signatures, as the spec's header is" do
      # The spec calls the header "a space delimited list of signatures" so that
      # verification survives a zero-downtime secret rotation. A consumer that
      # only ever read the first entry would fail for the length of the rotation.
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)

      rotated =
        Map.put(
          headers,
          "webhook-signature",
          "v1," <>
            Base.encode64(:crypto.strong_rand_bytes(32)) <> " " <> headers["webhook-signature"]
        )

      assert Verifier.verify(@spec_body, rotated, signing_secret) == :ok
    end

    test "ignores a signature identifier it does not know" do
      # The spec's asymmetric scheme is `v1a`. A consumer must neither accept it
      # as a match nor let it stop it finding the `v1` one beside it.
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)

      with_extra =
        Map.put(
          headers,
          "webhook-signature",
          headers["webhook-signature"] <> " v1a," <> Base.encode64(:crypto.strong_rand_bytes(32))
        )

      assert Verifier.verify(@spec_body, with_extra, signing_secret) == :ok
    end

    test "rejects when no signature in the list matches" do
      signing_secret = secret()
      headers = Signature.headers(signing_secret, @spec_id, now(), @spec_body)

      foreign =
        Map.put(
          headers,
          "webhook-signature",
          "v1a," <> Base.encode64(:crypto.strong_rand_bytes(32))
        )

      assert Verifier.verify(@spec_body, foreign, signing_secret) ==
               {:error, :signature_mismatch}
    end
  end
end
