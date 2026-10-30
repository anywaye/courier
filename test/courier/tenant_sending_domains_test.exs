defmodule Courier.TenantSendingDomainsTest do
  @moduledoc """
  The sending-domain context: registration, the two-part proof, and revocation.


  Three reasons, all of them shared VM state rather than the network:

    * it replaces `config :courier, :tenant_sending` and
      `config :swoosh, :api_client`, which the whole VM shares;
    * the DNS proof's double answers from one named ETS table;
    * the credential proof posts to one `Courier.TestSupport.CloudflareServer`.


  The DNS answers are injected (`Courier.SendingDomains.Dns` is a seam on
  purpose — a verification that can pass on a broken resolver proves nothing),
  and the credential proof is a REAL HTTP request to a REAL listener that
  records what arrived. The record set is the only thing a test fabricates,
  because the thing being asserted is "does courier require THIS record set".
  """

  use Courier.DataCase, async: false

  alias Courier.SecretBox
  alias Courier.TenantSendingDomain
  alias Courier.TenantSendingDomains
  alias Courier.TestSupport.CloudflareServer
  alias Courier.TestSupport.SendingDomainDns

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @other_account "2b3c4d5e-6f70-4a8b-9c0d-2e3f4a5b6c7d"
  @domain "tenant.example.com"
  @token "tenant-provider-token-not-the-deployment-key"
  @provider_account_id "cf-account-abc123"

  @moduletag account: @account

  setup do
    table = SendingDomainDns.table()
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    :ets.new(table, [:named_table, :public])

    previous_api_client = Application.get_env(:swoosh, :api_client)
    previous_tenant = Application.get_env(:courier, :tenant_sending)

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      Application.put_env(:swoosh, :api_client, previous_api_client)
      Application.put_env(:courier, :tenant_sending, previous_tenant)
    end)

    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)
    Application.ensure_all_started(:req)

    {:ok, server, port} = CloudflareServer.start_link()
    Application.put_env(:courier, :tenant_sending, base_url: "http://127.0.0.1:#{port}")

    %{server: server, port: port}
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        domain: @domain,
        provider: :cloudflare,
        provider_account_id: @provider_account_id,
        credential: @token
      },
      overrides
    )
  end

  defp seed_cloudflare_dns(domain \\ @domain) do
    :ets.insert(
      table(),
      {{:mx, "cf-bounce." <> domain},
       [
         {1, "route1.mx.cloudflare.net"},
         {2, "route2.mx.cloudflare.net"},
         {3, "route3.mx.cloudflare.net"}
       ]}
    )

    :ets.insert(
      table(),
      {{:txt, "cf-bounce." <> domain}, ["v=spf1 include:_spf.mail.cloudflare.net ~all"]}
    )

    :ets.insert(
      table(),
      {{:txt, "cf-bounce._domainkey." <> domain},
       ["v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQ"]}
    )

    :ok
  end

  defp table, do: SendingDomainDns.table()

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


  describe "register/2" do
    test "stores the domain unverified, with the credential sealed" do
      assert {:ok, %TenantSendingDomain{} = row} =
               TenantSendingDomains.register(@account, attrs())

      assert row.domain == @domain
      assert row.provider == :cloudflare
      assert row.provider_account_id == @provider_account_id
      assert row.status == :enabled
      assert row.verified_at == nil

      [[stored]] =
        Repo.query!("select credential from tenant_sending_domains where id = $1", [
          Ecto.UUID.dump!(row.id)
        ]).rows

      refute stored == @token
      refute String.contains?(stored, @token)
      assert {:ok, @token} = SecretBox.open(stored)
    end

    test "normalises the domain and refuses a non-domain" do
      assert {:ok, row} =
               TenantSendingDomains.register(
                 @account,
                 attrs(%{domain: "  TENANT.Example.COM.  "})
               )

      assert row.domain == "tenant.example.com"

      assert {:error, changeset} =
               TenantSendingDomains.register(@account, attrs(%{domain: "not a domain"}))

      assert "is not a domain" in errors_on(changeset).domain
    end

    test "refuses a duplicate registration for the same account" do
      assert {:ok, _row} = TenantSendingDomains.register(@account, attrs())

      assert {:error, changeset} = TenantSendingDomains.register(@account, attrs())
      assert "is already registered" in errors_on(changeset).domain
    end

    test "refuses an empty credential rather than sealing it" do
      assert {:error, changeset} =
               TenantSendingDomains.register(@account, attrs(%{credential: ""}))

      assert errors_on(changeset).credential != []
    end

    test "the account is the caller's, never an attribute" do
      assert {:ok, row} =
               TenantSendingDomains.register(@account, attrs(%{account_id: @other_account}))

      assert row.account_id == @account
    end

    test "a non-uuid account is a changeset error, not a raised Ecto.ChangeError" do
      assert {:error, changeset} = TenantSendingDomains.register("not-a-uuid", attrs())
      assert errors_on(changeset).account_id != []
    end
  end

  describe "reads" do
    test "list/1 returns only the account's rows, and never the plaintext" do
      assert {:ok, _row} = TenantSendingDomains.register(@account, attrs())

      rows = TenantSendingDomains.list(@account)
      assert Enum.map(rows, & &1.domain) == [@domain]

      refute Enum.any?(rows, &(&1.credential == @token))
      refute inspect(rows) =~ @token
    end

    test "get/2 is nil for another account's row, and for a non-uuid" do
      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      assert as_account(@other_account, fn -> TenantSendingDomains.get(row.id, @other_account) end) ==
               nil

      assert TenantSendingDomains.get(row.id, @account)
      assert TenantSendingDomains.get("not-a-uuid", @account) == nil
    end

    test "for_domain/1 answers nil under another account's identity" do
      assert {:ok, _row} = TenantSendingDomains.register(@account, attrs())

      assert TenantSendingDomains.for_domain(@domain)

      assert as_account(@other_account, fn -> TenantSendingDomains.for_domain(@domain) end) == nil
    end
  end


  describe "verify/2 — the DNS half" do
    test "a domain whose name exists but publishes no MX records is refused, and no provider is called",
         %{server: server} do
      :ets.insert(table(), {{:mx, "cf-bounce." <> @domain}, []})

      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      assert {:error, {:dns_mx_mismatch, []}} = TenantSendingDomains.verify(row)

      assert CloudflareServer.requests(server) == []
      assert Repo.get(TenantSendingDomain, row.id).verified_at == nil
    end

    test "a resolver FAILURE is a lookup failure, never a pass", %{server: server} do
      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      assert {:error, {:dns_lookup_failed, :nxdomain}} = TenantSendingDomains.verify(row)

      assert CloudflareServer.requests(server) == []
      assert Repo.get(TenantSendingDomain, row.id).verified_at == nil
    end

    test "MX records that are not Cloudflare's route trio are refused", %{server: server} do
      :ets.insert(table(), {{:mx, "cf-bounce." <> @domain}, [{10, "mail.other-provider.net"}]})

      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      assert {:error, {:dns_mx_mismatch, ["mail.other-provider.net"]}} =
               TenantSendingDomains.verify(row)

      assert CloudflareServer.requests(server) == []
    end

    test "an incomplete MX trio is refused", %{server: server} do
      :ets.insert(table(), {{:mx, "cf-bounce." <> @domain}, [{1, "route1.mx.cloudflare.net"}]})

      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())
      assert {:error, {:dns_mx_mismatch, _}} = TenantSendingDomains.verify(row)
      assert CloudflareServer.requests(server) == []
    end

    test "an SPF record that does not include Cloudflare is refused", %{server: server} do
      :ets.insert(table(), {
        {:mx, "cf-bounce." <> @domain},
        [
          {1, "route1.mx.cloudflare.net"},
          {2, "route2.mx.cloudflare.net"},
          {3, "route3.mx.cloudflare.net"}
        ]
      })

      :ets.insert(
        table(),
        {{:txt, "cf-bounce." <> @domain}, ["v=spf1 include:_spf.other.net ~all"]}
      )

      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())
      assert {:error, {:dns_spf_mismatch, _}} = TenantSendingDomains.verify(row)
      assert CloudflareServer.requests(server) == []
    end

    test "a missing DKIM record is refused", %{server: server} do
      :ets.insert(table(), {
        {:mx, "cf-bounce." <> @domain},
        [
          {1, "route1.mx.cloudflare.net"},
          {2, "route2.mx.cloudflare.net"},
          {3, "route3.mx.cloudflare.net"}
        ]
      })

      :ets.insert(table(), {
        {:txt, "cf-bounce." <> @domain},
        ["v=spf1 include:_spf.mail.cloudflare.net ~all"]
      })

      :ets.insert(table(), {{:txt, "cf-bounce._domainkey." <> @domain}, ["v=DKIM1; k=rsa"]})

      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())
      assert {:error, {:dns_dkim_mismatch, _}} = TenantSendingDomains.verify(row)
      assert CloudflareServer.requests(server) == []
    end
  end

  describe "verify/2 — the credential half" do
    test "the full record set plus an accepted send marks the domain verified", %{server: server} do
      seed_cloudflare_dns()
      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      assert {:ok, %TenantSendingDomain{verified_at: verified_at}} =
               TenantSendingDomains.verify(row)

      assert %DateTime{} = verified_at

      assert request_token(server) == "Bearer #{@token}"

      assert [request] = CloudflareServer.requests(server)
      assert request.path == "/accounts/#{@provider_account_id}/email/sending/send"
      refute request.path =~ @token
    end

    test "a provider that refuses the verification send refuses the domain", %{server: server} do
      seed_cloudflare_dns()
      CloudflareServer.set_response(server, 401, ~s({"success":false,"errors":[{"code":10000}]}))

      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      assert {:error, {:credential_refused, {401, _}}} = TenantSendingDomains.verify(row)
      assert Repo.get(TenantSendingDomain, row.id).verified_at == nil
    end

    test "a credential sealed under a rotated key refuses, and never marks verified", %{
      server: server
    } do
      seed_cloudflare_dns()
      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())

      {1, _} =
        Repo.update_all(TenantSendingDomain,
          set: [credential: SecretBox.seal(@token, :crypto.strong_rand_bytes(32))]
        )

      row = Repo.get(TenantSendingDomain, row.id)
      assert {:error, :invalid_credential} = TenantSendingDomains.verify(row)
      assert CloudflareServer.requests(server) == []
    end

    test "the DNS check runs BEFORE the provider is dialled", %{server: server} do
      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())
      assert {:error, {:dns_lookup_failed, _}} = TenantSendingDomains.verify(row)
      assert CloudflareServer.requests(server) == []
    end
  end

  describe "verify/2 — the fleet-wide uniqueness rule" do
    test "a domain another account already verified is refused", %{server: server} do
      seed_cloudflare_dns()

      assert {:ok, a_row} = TenantSendingDomains.register(@account, attrs())
      assert {:ok, _} = TenantSendingDomains.verify(a_row)

      assert {:ok, b_row} =
               as_account(@other_account, fn ->
                 TenantSendingDomains.register(@other_account, attrs())
               end)

      assert {:error, changeset} =
               as_account(@other_account, fn ->
                 TenantSendingDomains.verify(b_row)
               end)

      assert "is already verified by another account" in errors_on(changeset).domain

      assert %{verified_at: nil} =
               as_account(@other_account, fn ->
                 Repo.get(TenantSendingDomain, b_row.id)
               end)

      assert CloudflareServer.requests(server) != []
    end
  end

  describe "revoke/1" do
    test "sets the status and keeps the row", %{server: _server} do
      assert {:ok, row} = TenantSendingDomains.register(@account, attrs())
      assert {:ok, revoked} = TenantSendingDomains.revoke(row)

      assert revoked.status == :revoked
      assert Repo.get(TenantSendingDomain, row.id).status == :revoked
    end
  end
end
