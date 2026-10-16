defmodule CourierWeb.SendingDomainsControllerTest do
  @moduledoc """
  The sending-domain API, over real requests through the real router.

  ## What this file proves that `Courier.TenantSendingDomainsTest` cannot

  The context's tests are about the rows. These are about the **seam**: that the
  account comes from the caller's token and never from a body, that a domain in
  another account is the same 404 wherever it is addressed, that a successful
  verification really posts the tenant's own provider token to the provider, and
  — the property this surface is most likely to break — that **no response ever
  contains a credential**. The last one is asserted on the keys of the rendered
  body and on the token's absence from the bytes, not merely on a 2xx, because a
  response that echoed a token would still be a 2xx.

  ## `async: false`, and why

  The verification proof changes `config :courier, :tenant_sending`,
  `config :swoosh, :api_client` and `config :courier, :mailing`, all shared by
  the whole VM, answers DNS from one named ETS table, and posts to one
  `Courier.TestSupport.CloudflareServer`. That is `Courier.TenantSendingDomainsTest`'s
  reason and `Courier.DeliverSendingDomainTest`'s, and it is the same fixture:
  the DNS record set is the only thing a test fabricates, because the thing under
  assertion is "does courier require THIS record set" and "does it post THIS
  token".
  """

  use CourierWeb.ConnCase, async: false

  alias Courier.Deliver
  alias Courier.TestSupport.CloudflareServer
  alias Courier.TestSupport.SendingDomainDns

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @other_account "2b3c4d5e-6f70-4a8b-9c0d-2e3f4a5b6c7d"
  @domain "tenant.example.com"
  @token "tenant-provider-token-not-the-deployment-key"
  @provider_account_id "cf-account-abc123"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The eight fields the API promises, sorted. The credential and
  # `provider_account_id` are deliberately absent; a ninth key is a defect.
  @response_fields ~w(account_id domain id inserted_at provider status updated_at verified_at)

  @moduletag account: @account

  setup do
    table = SendingDomainDns.table()
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    :ets.new(table, [:named_table, :public])

    previous_api_client = Application.get_env(:swoosh, :api_client)
    previous_tenant = Application.get_env(:courier, :tenant_sending)
    previous_mailing = Application.get_env(:courier, :mailing)

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      Application.put_env(:swoosh, :api_client, previous_api_client)
      Application.put_env(:courier, :tenant_sending, previous_tenant)
      Application.put_env(:courier, :mailing, previous_mailing)
    end)

    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)
    Application.ensure_all_started(:req)

    {:ok, server, port} = CloudflareServer.start_link()
    Application.put_env(:courier, :tenant_sending, base_url: "http://127.0.0.1:#{port}")

    %{server: server}
  end

  # --- helpers ---------------------------------------------------------------

  defp authed(account), do: put_req_header(build_conn(), "x-courier-account", account)

  defp body(overrides \\ %{}) do
    Map.merge(
      %{
        "domain" => @domain,
        "provider" => "cloudflare",
        "provider_account_id" => @provider_account_id,
        "credential" => @token
      },
      overrides
    )
  end

  defp register(account, overrides \\ %{}) do
    authed(account) |> post("/v1/sending_domains", body(overrides))
  end

  defp data(conn), do: Jason.decode!(conn.resp_body)["data"]
  defp errors(conn), do: Jason.decode!(conn.resp_body)["errors"]

  # The exact record set Cloudflare Email Sending publishes for an onboarded
  # domain: the `cf-bounce` MX trio, the SPF TXT and the DKIM TXT.
  defp seed_cloudflare_dns(domain \\ @domain) do
    :ets.insert(
      SendingDomainDns.table(),
      {{:mx, "cf-bounce." <> domain},
       [
         {1, "route1.mx.cloudflare.net"},
         {2, "route2.mx.cloudflare.net"},
         {3, "route3.mx.cloudflare.net"}
       ]}
    )

    :ets.insert(
      SendingDomainDns.table(),
      {{:txt, "cf-bounce." <> domain}, ["v=spf1 include:_spf.mail.cloudflare.net ~all"]}
    )

    :ets.insert(
      SendingDomainDns.table(),
      {{:txt, "cf-bounce._domainkey." <> domain},
       ["v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ"]}
    )
  end

  # Point the deployment's configured sender at `domain` — the key the credential
  # lookup uses — so `Courier.Deliver` asks the send path's question about the row
  # this file registered through the API.
  defp set_from(domain) do
    mailing = Application.get_env(:courier, :mailing, [])

    Application.put_env(
      :courier,
      :mailing,
      Keyword.put(mailing, :from, {"caFaye", "no-reply@" <> domain})
    )
  end

  defp request_token(server) do
    server
    |> CloudflareServer.requests()
    |> List.last()
    |> then(fn request ->
      Enum.find_value(request.headers, fn {header, value} ->
        if String.downcase(header) == "authorization", do: value
      end)
    end)
  end

  # --- registration ----------------------------------------------------------

  describe "POST /v1/sending_domains" do
    test "answers 201 with the row under the caller's account, unverified" do
      conn = register(@account)

      assert conn.status == 201
      row = data(conn)

      assert row["account_id"] == @account
      assert row["domain"] == @domain
      assert row["provider"] == "cloudflare"
      assert row["status"] == "enabled"
      # Registration alone proves nothing: the row starts unusable.
      assert row["verified_at"] == nil
      assert is_binary(row["id"])
    end

    test "a body carrying account_id is refused, and registers nothing" do
      conn = register(@account, %{"account_id" => @other_account})

      assert conn.status == 422
      assert %{"field" => "account_id", "code" => "unknown_field"} in errors(conn)

      # And the refusal is real: the account named in the body has nothing.
      assert data(authed(@other_account) |> get("/v1/sending_domains")) == []
    end

    test "an unknown field is refused by name rather than silently dropped" do
      conn = register(@account, %{"provider_acount_id" => "cf-typo"})

      assert conn.status == 422
      assert %{"field" => "provider_acount_id", "code" => "unknown_field"} in errors(conn)
    end

    test "a duplicate for the same account is refused" do
      assert register(@account).status == 201

      conn = register(@account)

      assert conn.status == 422
      assert %{"field" => "domain", "code" => "taken"} in errors(conn)
    end

    test "an empty credential is refused rather than sealed" do
      conn = register(@account, %{"credential" => ""})

      assert conn.status == 422
      assert %{"field" => "credential"} = hd(errors(conn))
    end

    test "a provider courier does not speak is refused" do
      conn = register(@account, %{"provider" => "sendgrid"})

      assert conn.status == 422
      assert %{"field" => "provider"} = hd(errors(conn))
    end

    test "an unauthenticated request is refused" do
      conn = post(build_conn(), "/v1/sending_domains", body())

      assert conn.status == 401
    end
  end

  # --- listing and reading ---------------------------------------------------

  describe "GET /v1/sending_domains" do
    test "lists only the caller's own domains" do
      assert register(@account).status == 201

      assert [%{"domain" => @domain}] = data(authed(@account) |> get("/v1/sending_domains"))
      assert data(authed(@other_account) |> get("/v1/sending_domains")) == []
    end

    test "an unauthenticated request is refused" do
      assert get(build_conn(), "/v1/sending_domains").status == 401
    end
  end

  describe "GET /v1/sending_domains/:id" do
    test "returns the caller's row, and 404 for another account's" do
      id = data(register(@account))["id"]

      assert data(authed(@account) |> get("/v1/sending_domains/#{id}"))["domain"] == @domain

      assert authed(@other_account) |> get("/v1/sending_domains/#{id}") |> Map.fetch!(:status) ==
               404
    end

    test "404s an id that is not a uuid, so the two questions are one answer" do
      conn = authed(@account) |> get("/v1/sending_domains/not-a-uuid")
      assert conn.status == 404
    end
  end

  # --- verification ----------------------------------------------------------

  describe "POST /v1/sending_domains/:id/verify" do
    test "the full proof marks the domain verified and posts the TENANT's token", %{
      server: server
    } do
      seed_cloudflare_dns()
      id = data(register(@account))["id"]

      conn = authed(@account) |> post("/v1/sending_domains/#{id}/verify")

      assert conn.status == 200
      assert is_binary(data(conn)["verified_at"])

      assert request_token(server) == "Bearer #{@token}"
      assert [request] = CloudflareServer.requests(server)
      assert request.path == "/accounts/#{@provider_account_id}/email/sending/send"
    end

    test "without Cloudflare's MX records it is refused, and the domain stays unverified" do
      # Seeded but empty, so the DNS check answers a MISMATCH rather than a
      # lookup failure: a domain whose onboarding is incomplete is a 422 about
      # the domain, while a resolver that could not answer is a 503.
      :ets.insert(SendingDomainDns.table(), {{:mx, "cf-bounce." <> @domain}, []})
      id = data(register(@account))["id"]

      conn = authed(@account) |> post("/v1/sending_domains/#{id}/verify")

      assert conn.status == 422
      assert %{"field" => "domain", "code" => "dns_mx_mismatch"} in errors(conn)

      # And the API still reports it unverified, which is the seam's claim: the
      # API cannot produce a sendable domain without the proof.
      assert data(authed(@account) |> get("/v1/sending_domains/#{id}"))["verified_at"] == nil
    end

    test "a provider that refuses the verification send is refused on the credential", %{
      server: server
    } do
      seed_cloudflare_dns()
      CloudflareServer.set_response(server, 401, ~s({"success":false,"errors":[{"code":10000}]}))
      id = data(register(@account))["id"]

      conn = authed(@account) |> post("/v1/sending_domains/#{id}/verify")

      assert conn.status == 422
      assert %{"field" => "credential", "code" => "credential_refused"} in errors(conn)
    end

    test "account B cannot verify account A's domain" do
      seed_cloudflare_dns()
      id = data(register(@account))["id"]

      assert authed(@other_account)
             |> post("/v1/sending_domains/#{id}/verify")
             |> Map.fetch!(:status) ==
               404
    end

    test "an unauthenticated request is refused" do
      id = data(register(@account))["id"]

      assert post(build_conn(), "/v1/sending_domains/#{id}/verify").status == 401
    end
  end

  # --- revocation ------------------------------------------------------------

  describe "POST /v1/sending_domains/:id/revoke" do
    test "revokes the caller's domain, keeping the row" do
      id = data(register(@account))["id"]

      conn = authed(@account) |> post("/v1/sending_domains/#{id}/revoke")

      assert conn.status == 200
      assert data(conn)["status"] == "revoked"
      assert data(authed(@account) |> get("/v1/sending_domains/#{id}"))["status"] == "revoked"
    end

    test "account B cannot revoke account A's domain" do
      id = data(register(@account))["id"]

      assert authed(@other_account)
             |> post("/v1/sending_domains/#{id}/revoke")
             |> Map.fetch!(:status) ==
               404

      # And it is still enabled for its owner — the 404 was a refusal, not a
      # silent success.
      assert data(authed(@account) |> get("/v1/sending_domains/#{id}"))["status"] == "enabled"
    end
  end

  # --- the two properties this packet exists for -----------------------------

  describe "a response never contains a provider credential" do
    test "the register response's keys are the eight the document declares" do
      conn = register(@account)

      assert Map.keys(data(conn)) |> Enum.sort() == @response_fields
      refute conn.resp_body =~ @token
      refute conn.resp_body =~ @provider_account_id
    end

    test "a VERIFIED row's response carries no credential either", %{server: _server} do
      seed_cloudflare_dns()
      id = data(register(@account))["id"]

      # The row now holds a sealed credential that has been opened to send with.
      conn = authed(@account) |> post("/v1/sending_domains/#{id}/verify")

      assert conn.status == 200
      assert Map.keys(data(conn)) |> Enum.sort() == @response_fields
      refute conn.resp_body =~ @token
    end

    test "the read surfaces carry none either" do
      id = data(register(@account))["id"]

      list = authed(@account) |> get("/v1/sending_domains")
      show = authed(@account) |> get("/v1/sending_domains/#{id}")

      for conn <- [list, show] do
        refute conn.resp_body =~ @token
        refute conn.resp_body =~ @provider_account_id
      end

      assert Map.keys(hd(data(list))) |> Enum.sort() == @response_fields
    end
  end

  describe "the registered row is not usable until it is proven" do
    test "an unverified row registered through the API cannot send", %{server: server} do
      # Registered THROUGH THE DOOR, then the send path asked its own question
      # about it. The API's answer said `verified_at: null`, and the send path
      # agrees: no mail, no provider request.
      assert data(register(@account))["verified_at"] == nil
      set_from(@domain)

      assert {:error, {:unverified_sending_domain, @domain}} =
               as_account(@account, fn -> Deliver.welcome(payload()) end)

      assert CloudflareServer.requests(server) == []
    end

    test "a revoked domain cannot send", %{server: server} do
      seed_cloudflare_dns()
      id = data(register(@account))["id"]

      assert authed(@account) |> post("/v1/sending_domains/#{id}/verify") |> Map.fetch!(:status) ==
               200

      assert authed(@account) |> post("/v1/sending_domains/#{id}/revoke") |> Map.fetch!(:status) ==
               200

      # Clear the verification send, so a request after revocation is the thing
      # the assertion below is about rather than the proof's own dial.
      CloudflareServer.take(server)
      set_from(@domain)

      assert {:error, {:revoked_sending_domain, @domain}} =
               as_account(@account, fn -> Deliver.welcome(payload()) end)

      assert CloudflareServer.requests(server) == []
    end
  end

  defp payload do
    %{user_id: @user_id, email: "recipient@example.com", name: "Kaka"}
  end
end
