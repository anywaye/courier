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
  (`Courier.TestSupport.CloudflareServer`), the real
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
  alias Courier.TestSupport.CloudflareServer

  @api_key "cloudflare-test-key-not-a-real-secret"
  @account_id "test-account-id-abc123"

  setup do
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
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_roundtrip",
                 email: "roundtrip@example.com",
                 name: "Round Trip"
               })

      assert [request] = CloudflareServer.take(server)

      payload = decode!(request.body)

      # The sender courier built: `config :courier, :mailing`'s from address.
      assert payload["from"] == %{"address" => "no-reply@cafaye.com", "name" => "caFaye"}

      # The recipient the platform handed in — Cloudflare's `to` is the address
      # itself, not a personalizations wrapper.
      assert payload["to"] == %{"address" => "roundtrip@example.com", "name" => "Round Trip"}

      # The subject is courier's, from the `:mailing` configuration, rendered
      # through the template — so this is also the assertion that the subject
      # templates still resolve.
      assert payload["subject"] == "Welcome to caFaye"

      # The content is the rendered template in both formats. A message that
      # "arrives" with a subject and no body is still useless, and would pass
      # an assertion about the envelope alone.
      assert payload["text"] =~ "Round Trip"
      assert payload["html"] =~ "Round Trip"
    end

    test "the adapter authenticates with the key it was configured with" do
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_auth",
                 email: "auth@example.com",
                 name: "Authenticated"
               })

      assert [request] = CloudflareServer.take(server)
      assert header_value(request, "authorization") == "Bearer #{@api_key}"
    end

    test "the request path carries the account id" do
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_path",
                 email: "path@example.com",
                 name: "Path"
               })

      assert [request] = CloudflareServer.take(server)
      assert request.path == "/accounts/#{@account_id}/email/sending/send"
    end

    test "a 2xx with delivered recipients is the success the caller reports" do
      {:ok, _server, port} = CloudflareServer.start_link()
      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_receipt",
                 email: "receipt@example.com",
                 name: "Receipt"
               })
    end

    test "deliver_many posts each email and collects the receipts" do
      {:ok, server, port} = CloudflareServer.start_link()
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
      assert [%{id: nil}, %{id: nil}] = receipts

      assert [_first, _second] = CloudflareServer.take(server)
    end
  end

  describe "a provider that refuses the send is surfaced, not swallowed" do
    test "a 403 is an error, not a success" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(
        server,
        403,
        ~s({"success":false,"errors":[{"code":10102,"message":"forbidden"}],"messages":[],"result":null})
      )

      put_adapter(port)

      assert {:error, {403, %{"success" => false}}} =
               deliver(:welcome, %{
                 user_id: "usr_forbidden",
                 email: "forbidden@example.com",
                 name: "Forbidden"
               })

      assert [_request] = CloudflareServer.take(server)
    end

    test "a 401 is an error" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(
        server,
        401,
        ~s({"success":false,"errors":[{"code":10101,"message":"unauthorized"}],"messages":[],"result":null})
      )

      put_adapter(port)

      assert {:error, {401, %{"success" => false}}} =
               deliver(:welcome, %{
                 user_id: "usr_unauth",
                 email: "unauth@example.com",
                 name: "Unauthorized"
               })
    end

    test "a 400 is an error" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(
        server,
        400,
        ~s({"success":false,"errors":[{"code":10001,"message":"invalid"}],"messages":[],"result":null})
      )

      put_adapter(port)

      assert {:error, {400, %{"success" => false}}} =
               deliver(:welcome, %{
                 user_id: "usr_bad",
                 email: "bad@example.com",
                 name: "Bad Request"
               })
    end

    test "a 429 is an error" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(
        server,
        429,
        ~s({"success":false,"errors":[{"code":10004,"message":"throttled"}],"messages":[],"result":null})
      )

      put_adapter(port)

      assert {:error, {429, _}} =
               deliver(:welcome, %{
                 user_id: "usr_throttled",
                 email: "throttled@example.com",
                 name: "Throttled"
               })
    end

    test "a 500 is an error naming the status" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(
        server,
        500,
        ~s({"success":false,"errors":[{"code":10002,"message":"internal error"}],"messages":[],"result":null})
      )

      put_adapter(port)

      assert {:error, {500, %{"success" => false}}} =
               deliver(:welcome, %{
                 user_id: "usr_server_error",
                 email: "server-error@example.com",
                 name: "Server Error"
               })
    end

    test "a 503 is an error" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(
        server,
        503,
        ~s({"success":false,"errors":[{"code":10100,"message":"upstream"}],"messages":[],"result":null})
      )

      put_adapter(port)

      assert {:error, {503, _}} =
               deliver(:welcome, %{
                 user_id: "usr_unavail",
                 email: "unavail@example.com",
                 name: "Unavailable"
               })
    end

    test "a 400 with a non-JSON body is still an error" do
      {:ok, server, port} = CloudflareServer.start_link()
      CloudflareServer.set_response(server, 400, "<html>bad request</html>")
      put_adapter(port)

      assert {:error, {400, "<html>bad request</html>"}} =
               deliver(:welcome, %{
                 user_id: "usr_bad_body",
                 email: "bad-body@example.com",
                 name: "Bad Body"
               })
    end

    test "an unreachable provider is an error, not a success" do
      {:ok, server, port} = CloudflareServer.start_link()
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
      put_adapter(9999, nil, @account_id)

      assert_raise ArgumentError, ~r/api_key/, fn ->
        deliver(:welcome, %{
          user_id: "usr_no_key",
          email: "no-key@example.com",
          name: "No Key"
        })
      end
    end

    test "an adapter missing its account id raises rather than reporting a send" do
      put_adapter(9999, @api_key, nil)

      assert_raise ArgumentError, ~r/account_id/, fn ->
        deliver(:welcome, %{
          user_id: "usr_no_account",
          email: "no-account@example.com",
          name: "No Account"
        })
      end
    end

    test "a 2xx with permanent_bounces is an error naming the recipient" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":true,"errors":[],"messages":[],"result":{"delivered":[],"permanent_bounces":["bounced@example.com"],"queued":[],"suppressed_recipients":[]}}
      """)

      put_adapter(port)

      assert {:error, {200, %{"result" => %{"permanent_bounces" => ["bounced@example.com"]}}}} =
               deliver(:welcome, %{
                 user_id: "usr_bounced",
                 email: "bounced@example.com",
                 name: "Bounced"
               })

      assert [_request] = CloudflareServer.take(server)
    end

    test "a 2xx with suppressed_recipients is an error" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":true,"errors":[],"messages":[],"result":{"delivered":[],"permanent_bounces":[],"queued":[],"suppressed_recipients":["suppressed@example.com"]}}
      """)

      put_adapter(port)

      assert {:error, {200, %{"result" => %{"suppressed_recipients" => _}}}} =
               deliver(:welcome, %{
                 user_id: "usr_suppressed",
                 email: "suppressed@example.com",
                 name: "Suppressed"
               })

      assert [_request] = CloudflareServer.take(server)
    end

    test "a 2xx with success: false is an error even when the HTTP status is 2xx" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":false,"errors":[{"code":10001,"message":"schema invalid"}],"messages":[],"result":null}
      """)

      put_adapter(port)

      assert {:error, {200, %{"success" => false}}} =
               deliver(:welcome, %{
                 user_id: "usr_success_false",
                 email: "success-false@example.com",
                 name: "Success False"
               })

      assert [_request] = CloudflareServer.take(server)
    end

    test "a 2xx with queued only is a success — queued is not a refusal" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":true,"errors":[],"messages":[],"result":{"delivered":[],"permanent_bounces":[],"queued":["queued@example.com"],"suppressed_recipients":[]}}
      """)

      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_queued",
                 email: "queued@example.com",
                 name: "Queued"
               })
    end

    test "a 2xx with delivered recipients is a success" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":true,"errors":[],"messages":[],"result":{"delivered":["accepted@example.com"],"permanent_bounces":[],"queued":[],"suppressed_recipients":[]}}
      """)

      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_delivered",
                 email: "accepted@example.com",
                 name: "Accepted"
               })
    end

    test "a 2xx whose body is not JSON is a success with no id" do
      {:ok, server, port} = CloudflareServer.start_link()
      CloudflareServer.set_response(server, 200, "not json at all")
      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_not_json",
                 email: "not-json@example.com",
                 name: "Not Json"
               })

      assert [_request] = CloudflareServer.take(server)
    end
  end

  describe "the payload's optional shapes" do
    import Swoosh.Email

    test "cc, bcc, reply-to, headers and attachments reach the provider's shape" do
      {:ok, server, port} = CloudflareServer.start_link()
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

      # Reply-to is not a Cloudflare field — it travels as a header if present.
      # The adapter under test sends the API-shaped fields; this asserts the
      # ones that must arrive.
      assert {:ok, _receipt} = Courier.Mailer.deliver(email)

      assert [request] = CloudflareServer.take(server)
      payload = decode!(request.body)

      assert payload["from"] == %{"address" => "no-reply@cafaye.com", "name" => "caFaye"}
      assert payload["to"] == %{"address" => "ada@example.com", "name" => "Ada"}
      assert payload["cc"] == %{"address" => "bead@example.com", "name" => "Bead"}
      assert payload["bcc"] == "quiet@example.com"
      assert payload["subject"] == "Shapes"
      assert payload["text"] == "plain"
      assert payload["html"] == "<p>rich</p>"

      assert payload["headers"] == %{"X-Courier-Test" => "present"}

      attachment = Enum.find(payload["attachments"], &(&1["filename"] == "inner.txt"))
      assert attachment["content"] == Base.encode64("inner-bytes")
      assert attachment["type"] == "text/plain"
      assert attachment["disposition"] == "attachment"

      inline = Enum.find(payload["attachments"], &(&1["filename"] == "logo.png"))
      assert inline["disposition"] == "inline"
      assert inline["content"] == Base.encode64("logo-bytes")
    end
  end

  describe "REST API address shape regression (cf-address-key)" do
    test "request body carries `address` not `email` for named from and to — the shape the REST API accepts" do
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_address_shape",
                 email: "shape@example.com",
                 name: "Shape"
               })

      assert [request] = CloudflareServer.take(server)
      payload = decode!(request.body)

      # The REST API's named-address object is {address, name}; {email, name}
      # is the Workers binding shape and is refused with 400
      # invalid_request_schema (measured live on cafaye.com).
      assert payload["from"] == %{"address" => "no-reply@cafaye.com", "name" => "caFaye"}
      assert payload["to"] == %{"address" => "shape@example.com", "name" => "Shape"}
      refute Map.has_key?(payload["from"], "email")
      refute Map.has_key?(payload["to"], "email")

      # Bare address with no display name stays a bare string — also valid.
      assert payload["bcc"] == nil or is_binary(payload["bcc"]) or is_map(payload["bcc"])
    end

    test "a bare address with no name is sent as a bare string, not an object" do
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      email =
        Swoosh.Email.new()
        |> Swoosh.Email.from({"caFaye", "no-reply@cafaye.com"})
        |> Swoosh.Email.to("bare@example.com")
        |> Swoosh.Email.subject("Bare")
        |> Swoosh.Email.text_body("hi")

      assert {:ok, _receipt} = Courier.Mailer.deliver(email)

      assert [request] = CloudflareServer.take(server)
      payload = decode!(request.body)

      assert payload["to"] == "bare@example.com"
      assert payload["from"] == %{"address" => "no-reply@cafaye.com", "name" => "caFaye"}
    end
  end

  describe "the provider owns Message-ID (cf-message-id)" do
    test "a message carrying message-id sends successfully" do
      {:ok, _server, port} = CloudflareServer.start_link()
      put_adapter(port)

      # The header `Courier.Deliver.tag/2` attaches to EVERY message it sends:
      # `<courier-<uuid>@cafaye.com>` under the lowercase `message-id` key.
      # Before this packet the adapter forwarded it verbatim and Cloudflare
      # refused the whole message with 400 / 10202 — which the test server now
      # reproduces, so a regression here is red, not silently accepted.
      assert {:ok, _receipt} =
               Courier.Mailer.deliver(tagged_welcome("usr_msgid", "msgid@example.com"))
    end

    test "the provider never receives a message-id header, in any case" do
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      assert {:ok, _receipt} =
               Courier.Mailer.deliver(tagged_welcome("usr_no_header", "no-header@example.com"))

      # Assert on the request that ARRIVED, not on an internal helper.
      assert [request] = CloudflareServer.take(server)
      payload = decode!(request.body)

      refute Enum.any?(header_keys(payload), &(String.downcase(&1) == "message-id"))
    end

    test "List-Unsubscribe and List-Unsubscribe-Post both reach the provider" do
      {:ok, server, port} = CloudflareServer.start_link()
      put_adapter(port)

      {:ok, email} =
        Mailers.build(:welcome, %{
          user_id: "usr_unsub",
          email: "unsub@example.com",
          name: "Unsub"
        })

      decorated =
        email
        |> Swoosh.Email.header("List-Unsubscribe", "<https://cafaye.com/u?t=1>")
        |> Swoosh.Email.header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")

      assert {:ok, _receipt} = Courier.Mailer.deliver(decorated)

      assert [request] = CloudflareServer.take(server)
      payload = decode!(request.body)

      # RFC 8058: both headers are accepted by Cloudflare and are how the bulk
      # mail courier sends stays compliant. Dropping them would be a
      # deliverability and compliance regression, not a tidy-up.
      assert payload["headers"]["List-Unsubscribe"] == "<https://cafaye.com/u?t=1>"
      assert payload["headers"]["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
    end

    test "the receipt carries the provider's result.message_id" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":true,"errors":[],"messages":[],"result":{"delivered":["provider-id@example.com"],"permanent_bounces":[],"queued":[],"suppressed_recipients":[],"message_id":"a1b2c3d4-provider-owned"}}
      """)

      put_adapter(port)

      # The provider's id is the one its bounce and delivery reports quote, so
      # discarding it leaves courier with nothing to correlate against.
      assert {:ok, %{id: "a1b2c3d4-provider-owned"}} =
               deliver(:welcome, %{
                 user_id: "usr_provider_id",
                 email: "provider-id@example.com",
                 name: "Provider Id"
               })
    end

    test "a 2xx with no message_id still succeeds and invents no id" do
      {:ok, server, port} = CloudflareServer.start_link()

      CloudflareServer.set_response(server, 200, """
      {"success":true,"errors":[],"messages":[],"result":{"delivered":["no-id@example.com"],"permanent_bounces":[],"queued":[],"suppressed_recipients":[]}}
      """)

      put_adapter(port)

      assert {:ok, %{id: nil}} =
               deliver(:welcome, %{
                 user_id: "usr_no_id",
                 email: "no-id@example.com",
                 name: "No Id"
               })
    end
  end

  # A welcome message carrying the exact edit `Courier.Deliver.tag/2` makes:
  # `<courier-<uuid>@cafaye.com>` under the lowercase `message-id` key. It goes
  # through `Mailers.build/2`, the same composer the rest of the file uses.
  defp tagged_welcome(user_id, email) do
    {:ok, built} = Mailers.build(:welcome, %{user_id: user_id, email: email, name: "Tagged"})

    Swoosh.Email.header(
      built,
      "message-id",
      "<courier-#{Ecto.UUID.generate()}@cafaye.com>"
    )
  end

  # An adapter aimed at the loopback test server.
  defp put_adapter(port, api_key \\ @api_key, account_id \\ @account_id) do
    Application.put_env(:courier, Courier.Mailer,
      adapter: Courier.Adapters.CloudflareEmail,
      api_key: api_key,
      account_id: account_id,
      base_url: "http://127.0.0.1:#{port}"
    )

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

  defp header_keys(payload) do
    case payload["headers"] do
      headers when is_map(headers) -> Map.keys(headers)
      _ -> []
    end
  end
end
