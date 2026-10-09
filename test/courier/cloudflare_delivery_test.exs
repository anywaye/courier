defmodule Courier.CloudflareDeliveryTest do
  @moduledoc """
  The Cloudflare adapter is really wired: a message crosses a real HTTP
  request, and a provider that refuses the send is surfaced, not swallowed.

  Every other test in this repository asserts about courier. This one asserts
  about courier *and a provider*, because the failure it exists to prevent is
  invisible to a test that stops one layer short. The brief's first failure
  mode is a provider path that leaves delivery failures at their silent
  default — jumpstart's Cloudflare-ish route set `raise_delivery_errors` to
  `false` and mail vanished with no error. So the refusals are the point, and
  they are driven against a REAL HTTP server that refuses the send, not a
  stub that raises.

  A real Bandit listener on a real ephemeral loopback port
  (`Courier.TestSupport.MailChannelsServer`), the real
  `Courier.Adapters.CloudflareEmail`, the real `Swoosh.ApiClient.Req` client
  underneath it, and assertions about the request that arrived. Nothing here
  is mocked, and nothing here would pass against an adapter that returned
  `{:ok, _}` for a refused send.

  ## Why the whole conversation is driven rather than stubbed

  Each test configures the adapter and calls `Courier.Mailers.deliver/2` —
  the same two lines production runs. A test that built a `%Swoosh.Email{}` by
  hand and handed it to `Mailer.deliver/1` would prove the adapter works while
  saying nothing about whether courier composes a message it can actually
  send, and the two have been broken independently in this repository.
  """

  # `async: false`, and the reason is the application environment rather than
  # the network: these tests replace `config :courier, Courier.Mailer` and
  # `config :swoosh, :api_client`, which the whole VM shares, so two of them
  # running at once would deliver through each other's adapter. Same rule as
  # the other `*ConfigTest` files in this suite.
  use ExUnit.Case, async: false

  alias Courier.Mailers
  alias Courier.TestSupport.MailChannelsServer

  @api_key "cloudflare-test-key-not-a-real-secret"

  setup do
    # The suite's defaults are `Swoosh.Adapters.Test` and `api_client: false`,
    # and both have to be restored. `on_exit` runs after the test even when it
    # fails, so a test that dies mid-way cannot leave the Cloudflare adapter
    # configured for the files that run next.
    previous_mailer = Application.get_env(:courier, Courier.Mailer)
    previous_api_client = Application.get_env(:swoosh, :api_client)

    on_exit(fn ->
      Application.put_env(:courier, Courier.Mailer, previous_mailer)
      Application.put_env(:swoosh, :api_client, previous_api_client)
    end)

    :ok
  end

  describe "a send crosses a real HTTP request" do
    test "the message the provider received is the message courier composed" do
      {:ok, server, port} = MailChannelsServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_roundtrip",
                 email: "roundtrip@example.com",
                 name: "Round Trip"
               })

      # The request is recorded inside the Plug, which has already returned by
      # the time `deliver/2` answers, because the response is sent after the
      # insert. So reading the table is a barrier, not a wait.
      assert [request] = MailChannelsServer.take(server)

      payload = decode!(request.body)

      # The envelope courier built: `config :courier, :mailing`'s from address
      # and the address the platform handed in.
      assert payload["from"] == %{"email" => "no-reply@cafaye.com", "name" => "caFaye"}

      assert payload["personalizations"] == [
               %{"to" => [%{"email" => "roundtrip@example.com", "name" => "Round Trip"}]}
             ]

      # The subject is courier's, from the `:mailing` configuration, rendered
      # through the template — so this is also the assertion that the subject
      # templates still resolve.
      assert payload["subject"] == "Welcome to caFaye"

      # The content is the rendered template in both formats, not an empty
      # array. A message that "arrives" with a subject and no body is still
      # useless, and would pass an assertion about the envelope alone.
      assert [
               %{"type" => "text/plain", "value" => text},
               %{"type" => "text/html", "value" => html}
             ] =
               payload["content"]

      assert text =~ "Round Trip"
      assert html =~ "Round Trip"
    end

    test "the adapter authenticates with the key it was configured with" do
      # The server does NOT check the key — the assertion is that the key
      # travelled out of courier's configuration, through the adapter and
      # through `Swoosh.ApiClient.Req`, into a real request header. A server
      # that required the key would prove the server works, not that courier
      # sent it.
      {:ok, server, port} = MailChannelsServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_auth",
                 email: "auth@example.com",
                 name: "Authenticated"
               })

      assert [request] = MailChannelsServer.take(server)
      assert header_value(request, "x-api-key") == @api_key
    end

    test "a 202 is the provider-shaped id courier reports" do
      {:ok, _server, port} = MailChannelsServer.start_link()
      put_adapter(port)

      assert {:ok, %{id: "test-request"}} =
               deliver(:welcome, %{
                 user_id: "usr_receipt",
                 email: "receipt@example.com",
                 name: "Receipt"
               })
    end

    test "deliver_many posts each email and collects the receipts" do
      {:ok, server, port} = MailChannelsServer.start_link()
      put_adapter(port)

      emails =
        Enum.map(1..2, fn n ->
          {:ok, email} =
            Mailers.build(:welcome, %{
              user_id: "usr_many_#{n}",
              email: "many-#{n}@example.com",
              name: "Many #{n}"
            })

          email
        end)

      assert {:ok, receipts} = Courier.Mailer.deliver_many(emails)
      assert [%{id: "test-request"}, %{id: "test-request"}] = receipts

      # Both emails crossed, so the batch is real rather than one post
      # reported twice.
      assert [_first, _second] = MailChannelsServer.take(server)
    end
  end

  describe "a provider that refuses the send is surfaced, not swallowed" do
    test "a 403 is an error, not a provider-shaped id" do
      # THE case. The brief's first failure mode: a provider path that leaves
      # delivery failures at their silent default, so mail vanishes with no
      # error. A 403 is MailChannels' answer to a missing/invalid key or an
      # unauthorized sending domain — the two most common real refusals — and
      # it must NOT come back `{:ok, _}`.
      {:ok, server, port} = MailChannelsServer.start_link()
      MailChannelsServer.set_response(server, 403, ~s({"errors":["forbidden"]}))
      put_adapter(port)

      assert {:error, {403, %{"errors" => ["forbidden"]}}} =
               deliver(:welcome, %{
                 user_id: "usr_forbidden",
                 email: "forbidden@example.com",
                 name: "Forbidden"
               })

      # The refusal really is at the provider: the request crossed, so this is
      # not a send that reported failure before it was attempted.
      assert [_request] = MailChannelsServer.take(server)
    end

    test "a 500 is an error naming the status" do
      # The transient shape. MailChannels answers 500 for its own service
      # failures and 502 for infrastructure ones; both are delivery failures
      # the caller must be told about, because the mail did not go out.
      {:ok, server, port} = MailChannelsServer.start_link()
      MailChannelsServer.set_response(server, 500, ~s({"errors":["internal error"]}))
      put_adapter(port)

      assert {:error, {500, %{"errors" => ["internal error"]}}} =
               deliver(:welcome, %{
                 user_id: "usr_server_error",
                 email: "server-error@example.com",
                 name: "Server Error"
               })
    end

    test "a 400 with a non-JSON body is still an error" do
      # Not every provider answers JSON on every failure. A refusal whose body
      # is not decodable must still be `{:error, {code, body}}` — the raw
      # bytes are the most an adapter can honestly report.
      {:ok, server, port} = MailChannelsServer.start_link()
      MailChannelsServer.set_response(server, 400, "<html>bad request</html>")
      put_adapter(port)

      assert {:error, {400, "<html>bad request</html>"}} =
               deliver(:welcome, %{
                 user_id: "usr_bad_request",
                 email: "bad-request@example.com",
                 name: "Bad Request"
               })
    end

    test "an unreachable provider is an error, not a provider-shaped id" do
      # The other shape of failure, and the more likely one in practice: the
      # endpoint is not listening at all. Stop the server, keep its port, and
      # the send must fail loudly.
      {:ok, server, port} = MailChannelsServer.start_link()
      :ok = GenServer.stop(server)
      put_adapter(port)

      assert {:error, _reason} =
               deliver(:welcome, %{
                 user_id: "usr_unreachable",
                 email: "unreachable@example.com",
                 name: "Unreachable"
               })
    end

    test "an adapter missing its key raises rather than reporting a send" do
      # `Courier.Adapters.CloudflareEmail` declares `required_config:
      # [:api_key]` and Swoosh validates it by RAISING an `ArgumentError` — it
      # does not return `{:error, _}`. Asserted as written rather than as one
      # might expect, because it is the honest contract: a half-configured
      # adapter is a deployment fault, and courier's own refusal (see
      # `Courier.MailerAdapter`) is what stops it reaching this point at all.
      put_adapter(9999, nil)

      assert_raise ArgumentError, ~r/api_key/, fn ->
        deliver(:welcome, %{
          user_id: "usr_no_key",
          email: "no-key@example.com",
          name: "No Key"
        })
      end
    end

    test "a 202 whose results carry a failed message is an error" do
      # THE second silent-default shape, and the one a non-2xx check cannot
      # see. MailChannels' `SendResult` is `{index, message_id, reason,
      # status}` with `status` in `sent | failed`, so a well-formed request
      # whose one message was refused still answers 202. Reporting that as
      # `{:ok, _}` would write an outbox row and publish
      # `courier.email.delivered` for a mail that was not sent — the exact
      # defect this packet exists to end, wearing a success status.
      {:ok, server, port} = MailChannelsServer.start_link()

      MailChannelsServer.set_response(server, 202, """
      {"request_id":"req-202-failed","results":[{"index":0,"message_id":"msg-1","status":"failed","reason":"recipient domain not found"}]}
      """)

      put_adapter(port)

      assert {:error,
              {202,
               [
                 %{
                   "index" => 0,
                   "message_id" => "msg-1",
                   "status" => "failed",
                   "reason" => "recipient domain not found"
                 }
               ]}} =
               deliver(:welcome, %{
                 user_id: "usr_202_failed",
                 email: "failed@example.com",
                 name: "Two Oh Two"
               })

      # The refusal really is at the provider, and after the request crossed.
      assert [_request] = MailChannelsServer.take(server)
    end

    test "a 202 whose results are all sent is a success naming the request" do
      {:ok, server, port} = MailChannelsServer.start_link()

      MailChannelsServer.set_response(server, 202, """
      {"request_id":"req-202-ok","results":[{"index":0,"message_id":"msg-9","status":"sent"}]}
      """)

      put_adapter(port)

      assert {:ok, %{id: "req-202-ok"}} =
               deliver(:welcome, %{
                 user_id: "usr_202_ok",
                 email: "accepted@example.com",
                 name: "Accepted"
               })
    end

    test "a 200 dry-run body is a success with no id to report" do
      # The provider's other 2xx: `?dry-run=true` answers `200` with a
      # `Message` body — the rendered message, no `results`, no `request_id`.
      # It is a success, and the honest receipt is no id rather than an
      # invented one.
      {:ok, server, port} = MailChannelsServer.start_link()
      MailChannelsServer.set_response(server, 200, ~s({"data":["rendered message"]}))
      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_dry_run",
                 email: "dry-run@example.com",
                 name: "Dry Run"
               })
    end

    test "a 2xx whose body is not JSON is a success with no id" do
      # The adapter must not invent a refusal the provider did not make. A
      # body that will not decode cannot be inspected for a failed result,
      # and the provider answered 2xx — so `{:ok, %{id: nil}}` is the honest
      # answer.
      {:ok, server, port} = MailChannelsServer.start_link()
      MailChannelsServer.set_response(server, 202, "not json at all")
      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_not_json",
                 email: "not-json@example.com",
                 name: "Not Json"
               })

      assert [_request] = MailChannelsServer.take(server)
    end
  end

  describe "the payload's optional shapes" do
    # `Courier.Mailers` sends one recipient, no cc, no bcc, no reply-to and no
    # attachments, so the happy path above never exercises them. A payload
    # builder that is only ever asserted on the inputs it is guaranteed to
    # produce is one nothing has checked — the same rule `Mailers.body?/1` is
    # tested under. So each optional field is driven with a message that
    # carries it, through the same real adapter over the same real socket.
    import Swoosh.Email

    test "cc, bcc, reply-to, headers and attachments reach the provider's shape" do
      {:ok, server, port} = MailChannelsServer.start_link()
      put_adapter(port)

      email =
        new()
        |> from({"caFaye", "no-reply@cafaye.com"})
        |> to({"Ada", "ada@example.com"})
        |> cc({"Bead", "bead@example.com"})
        |> bcc("quiet@example.com")
        |> reply_to({"Support", "support@cafaye.com"})
        |> subject("Shapes")
        |> text_body("plain")
        |> html_body("<p>rich</p>")
        |> header("X-Courier-Test", "present")
        |> attachment(
          Swoosh.Attachment.new({:data, "inner-bytes"},
            filename: "inner.txt",
            content_type: "text/plain"
          )
        )
        |> attachment(
          Swoosh.Attachment.new({:data, "logo-bytes"},
            filename: "logo.png",
            content_type: "image/png",
            type: :inline,
            cid: "logo123"
          )
        )

      assert {:ok, _receipt} = Courier.Mailer.deliver(email)

      assert [request] = MailChannelsServer.take(server)
      payload = decode!(request.body)

      # ONE personalization, with cc and bcc inside it — MailChannels' shape,
      # and not three personalizations each carrying its own `to`. A sender
      # that appended bcc as a second entry would send the same message twice
      # to the visible recipient.
      assert [personalization] = payload["personalizations"]
      assert [_to] = personalization["to"]
      assert [%{"email" => "bead@example.com", "name" => "Bead"}] = personalization["cc"]
      assert [%{"email" => "quiet@example.com"}] = personalization["bcc"]

      assert payload["reply_to"] == %{"email" => "support@cafaye.com", "name" => "Support"}

      # A JSON OBJECT of name to value, per the schema's
      # `additionalProperties: string` — NOT the `[{Name, Value}]` array a
      # Postmark-shaped adapter would produce.
      assert payload["headers"] == %{"X-Courier-Test" => "present"}

      attachment = Enum.find(payload["attachments"], &(&1["filename"] == "inner.txt"))
      assert attachment["content"] == Base.encode64("inner-bytes")
      assert attachment["type"] == "text/plain"
      refute Map.has_key?(attachment, "content_id")

      # The inline one, and `content_id` is the BARE cid — MailChannels
      # documents `<img src="cid:logo123">` referring to an attachment whose
      # `content_id` is `logo123`, so the `cid:` prefix a Postmark-shaped
      # adapter adds would be a broken image in every HTML mail.
      inline = Enum.find(payload["attachments"], &(&1["filename"] == "logo.png"))
      assert inline["content_id"] == "logo123"
      assert inline["content"] == Base.encode64("logo-bytes")
    end
  end

  # An adapter aimed at the loopback test server.
  #
  # `base_url` points at the local listener; the endpoint `/send` is appended
  # by the adapter. The key is a canary — it must never appear in a log, and
  # `Courier.MailerAdapterCredentialsTest` asserts that separately.
  defp put_adapter(port, api_key \\ @api_key) do
    Application.put_env(:courier, Courier.Mailer,
      adapter: Courier.Adapters.CloudflareEmail,
      api_key: api_key,
      base_url: "http://127.0.0.1:#{port}/tx/v1"
    )

    # Swoosh's HTTP client is `false` in test (the suite uses the Test adapter,
    # which never calls it). Cloudflare posts through it, so the test turns it
    # on and starts Req — the same two things `config/runtime.exs` does in prod
    # when the provider table names `Swoosh.ApiClient.Req`.
    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)
    Application.ensure_all_started(:req)
  end

  defp deliver(type, payload), do: Mailers.deliver(type, payload)

  defp decode!(body) do
    case Swoosh.json_library().decode(body) do
      {:ok, decoded} ->
        decoded

      {:error, reason} ->
        raise "the test server received a body that is not JSON: #{inspect(reason)}"
    end
  end

  defp header_value(request, name) do
    Enum.find_value(request.headers, fn {header, value} ->
      if String.downcase(header) == name, do: value
    end)
  end
end
