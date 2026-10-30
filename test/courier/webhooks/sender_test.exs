defmodule Courier.Webhooks.SenderTest do
  @moduledoc """
  What courier puts on the wire, asserted the way a consumer sees it.

  The `Courier.Webhooks.Signature` tests prove the signature is the spec's. This
  file proves the *request* is well-formed: a consumer running an official
  Standard Webhooks library — Svix's, Twilio's, the reference
  `standardwebhooks` package — reads these three headers, takes the raw body, and
  gets a verdict. If the headers were misnamed, the body were re-encoded, or the
  `Host` were wrong, this is where it shows.

  The classification half — what counts as a success, what is worth retrying,
  what a `410` means — is the spec's §Delivery success and failure table, and it
  is courier's policy rather than the sender's, so it is asserted against
  `Courier.Webhooks.Sender` directly.

  Nothing here touches a socket. The sender is a behaviour with a recording
  implementation in `test/support`, which is what lets the assertions be about
  courier's behaviour and not about a local HTTP server's timing.
  """

  use ExUnit.Case, async: true

  alias Courier.TestSupport.RecordingSender
  alias Courier.Webhooks.Sender
  alias Courier.Webhooks.Signature
  alias Courier.Webhooks.Verifier

  @secret "whsec_" <> Base.encode64("k" <> :binary.copy(<<0>>, 31))
  @timestamp 1_774_000_000

  defp send_request(attrs \\ %{}) do
    request =
      Map.merge(
        %{
          url: "https://hooks.example.com/events",
          secret: @secret,
          msg_id: "msg_test_123",
          payload: ~s({"type":"email.delivered","data":{}}),
          timestamp: @timestamp
        },
        attrs
      )

    RecordingSender.reset()
    assert {:ok, result} = Sender.impl().send(request)
    {result, RecordingSender.last()}
  end

  defp send_with(overrides) do
    RecordingSender.reset()

    {:ok, result} =
      Sender.impl().send(
        Map.merge(
          %{
            url: "https://x.example.com",
            secret: @secret,
            msg_id: "m",
            payload: "{}",
            timestamp: 1
          },
          overrides
        )
      )

    result
  end

  defp result(status) do
    %Sender.Result{success?: status in 200..299, status_code: status, duration_ms: 1}
  end

  describe "the request" do
    test "is a POST" do
      {_result, request} = send_request()

      assert request.method == "POST"
    end

    test "goes to the url it was given" do
      {_result, request} = send_request(%{url: "https://other.example.com/hooks"})

      assert request.url == "https://other.example.com/hooks"
    end

    test "sends the exact payload it signed, byte for byte" do
      payload = ~s({"type":"ping","data":{"url":"https://anywaye.com/x?a=1.2"}})

      {_result, request} = send_request(%{payload: payload})

      assert request.body == payload
    end

    test "sends a binary body, so the bytes on the wire are the bytes signed" do
      {_result, request} = send_request()

      assert is_binary(request.body)
      assert request.body == ~s({"type":"email.delivered","data":{}})
    end

    test "declares the content type, so a consumer's framework parses it" do
      {_result, request} = send_request()

      assert request.headers["content-type"] == "application/json"
    end
  end

  describe "the signature headers" do
    test "are the spec's three, on the request" do
      {_result, request} = send_request()

      assert request.headers["webhook-id"] == "msg_test_123"
      assert request.headers["webhook-timestamp"] == to_string(@timestamp)
      assert request.headers["webhook-signature"]
    end

    test "carry a signature a verifier accepts" do
      {_result, request} = send_request()

      assert Verifier.verify(request.body, request.headers, @secret, now: @timestamp) == :ok
    end

    test "carry a signature computed over the body actually sent" do
      {_result, request} = send_request()

      base_string = "msg_test_123.#{@timestamp}." <> request.body

      expected =
        :hmac
        |> :crypto.mac(:sha256, Signature.sign_key(@secret, "v1"), base_string)
        |> Base.encode64()

      assert request.headers["webhook-signature"] == "v1," <> expected
    end

    test "are the only webhook- headers, with no svix-dialect names" do
      {_result, request} = send_request()

      webhook_headers =
        for {name, _value} <- request.headers, String.starts_with?(name, "webhook-"), do: name

      assert Enum.sort(webhook_headers) == [
               "webhook-id",
               "webhook-signature",
               "webhook-timestamp"
             ]
    end
  end

  describe "what counts as success" do
    test "reports the status code" do
      {result, _request} = send_request()

      assert result.status_code == 200
    end

    test "reports how long the attempt took" do
      {result, _request} = send_request()

      assert result.duration_ms >= 0
    end

    test "treats any 2xx as success, as the spec defines" do
      for status <- [200, 201, 202, 204, 299] do
        assert send_with(%{response_status: status}).success?,
               "status #{status} must count as success"
      end
    end

    test "treats 3xx as a failure, because following a redirect is what the spec warns against" do
      for status <- [301, 302, 307, 308] do
        refute send_with(%{response_status: status}).success?,
               "status #{status} must not count as success"
      end
    end

    test "treats a 4xx as a failure" do
      for status <- [400, 401, 404, 410, 422, 429, 500] do
        refute send_with(%{response_status: status}).success?
      end
    end
  end

  describe "the Retry-After header" do
    test "is read when the consumer sent one" do
      result = send_with(%{response_status: 429, response_headers: %{"retry-after" => "120"}})

      assert result.retry_after_seconds == 120
    end

    test "is absent when the consumer sent none" do
      assert send_with(%{response_status: 429}).retry_after_seconds == nil
    end

    test "a date form is read as absent, not as a number of seconds" do
      result =
        send_with(%{
          response_status: 503,
          response_headers: %{"retry-after" => "Wed, 21 Oct 2026 07:28:00 GMT"}
        })

      assert result.retry_after_seconds == nil
    end
  end

  describe "a transport failure" do
    test "is reported, not raised" do
      result = send_with(%{url: "https://down.example.com", error: :econnrefused})

      refute result.success?
      assert result.status_code == nil
      assert result.error == :econnrefused
    end
  end

  describe "retryable?/1" do
    test "does not retry a 2xx" do
      refute Sender.retryable?(result(204))
    end

    test "does not retry a 3xx, because following the redirect is what the spec warns against" do
      for status <- [301, 302, 307, 308] do
        refute Sender.retryable?(result(status)), "status #{status} must not be retried"
      end
    end

    test "retries 408 and 429, which mean 'not now' rather than 'no'" do
      assert Sender.retryable?(result(408))
      assert Sender.retryable?(result(429))
    end

    test "does not retry any other 4xx, because the request is wrong and will stay wrong" do
      for status <- [400, 401, 403, 404, 410, 413, 422] do
        refute Sender.retryable?(result(status)), "status #{status} must not be retried"
      end
    end

    test "retries a 5xx" do
      for status <- [500, 502, 503, 504] do
        assert Sender.retryable?(result(status)), "status #{status} must be retried"
      end
    end

    test "retries a transport failure, because nothing answering is not the url being wrong" do
      assert Sender.retryable?(%Sender.Result{
               success?: false,
               status_code: nil,
               error: :econnrefused
             })

      assert Sender.retryable?(%Sender.Result{success?: false, status_code: nil, error: :timeout})
    end
  end

  describe "gone?/1" do
    test "is true only for 410 Gone" do
      assert Sender.gone?(result(410))
    end

    test "is false for everything else, including the 4xx that look terminal" do
      for status <- [200, 301, 400, 404, 422, 500] do
        refute Sender.gone?(result(status)), "status #{status} must not end an endpoint"
      end
    end
  end

  describe "describe/1" do
    test "says what came back" do
      assert Sender.describe(result(500)) == "HTTP 500"
    end

    test "distinguishes no response from a response" do
      no_response = %Sender.Result{success?: false, status_code: nil, error: :econnrefused}

      assert Sender.describe(no_response) =~ "no response"
      assert Sender.describe(result(500)) =~ "HTTP"
    end
  end
end
