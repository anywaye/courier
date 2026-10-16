defmodule Courier.DeliverSendingDomainTest do
  @moduledoc """
  The send path chooses the sender by the message's FROM DOMAIN, and refuses
  rather than falling back.

  ## The four outcomes, and which one is the point

    1. A VERIFIED, ENABLED row for the from-domain → the TENANT's credential is
       posted. The assertion that matters is the Authorization header on the
       request the fixture received: it carries the tenant's token, not the
       deployment's.
    2. A row for the from-domain that is not usable (unverified, revoked) →
       REFUSED. No mail, no outbox row.
    3. NO row and the from-domain is not the deployment's own → REFUSED. There
       is no silent fallback to the deployment credential for a domain courier
       was never configured to send as.
    4. NO row and the from-domain IS the deployment's own (`Mailers.
       sender_domain/0`) → the deployment credential, exactly as before this
       table existed. This is the branch that keeps every existing send green.

  ## `async: false`, and why

  The tenant tests change `config :courier, :mailing`'s from-address and
  `config :courier, :tenant_sending`/`config :swoosh, :api_client` — all shared
  by the whole VM — and post to one `Courier.TestSupport.CloudflareServer`.
  """

  use Courier.DataCase, async: false

  import Swoosh.TestAssertions

  alias Courier.Deliver
  alias Courier.TenantSendingDomains
  alias Courier.TestSupport.CloudflareServer

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @other_account "2b3c4d5e-6f70-4a8b-9c0d-2e3f4a5b6c7d"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @domain "tenant.example.com"
  @tenant_token "tenant-provider-token-not-the-deployment-key"
  @provider_account_id "cf-account-abc123"

  @moduletag account: @account

  setup do
    previous_mailing = Application.get_env(:courier, :mailing)
    previous_api_client = Application.get_env(:swoosh, :api_client)
    previous_tenant = Application.get_env(:courier, :tenant_sending)

    on_exit(fn ->
      Application.put_env(:courier, :mailing, previous_mailing)
      Application.put_env(:swoosh, :api_client, previous_api_client)
      Application.put_env(:courier, :tenant_sending, previous_tenant)
    end)

    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)
    Application.ensure_all_started(:req)

    {:ok, server, port} = CloudflareServer.start_link()
    Application.put_env(:courier, :tenant_sending, base_url: "http://127.0.0.1:#{port}")

    %{server: server}
  end

  defp payload(overrides \\ %{}) do
    Map.merge(%{user_id: @user_id, email: "recipient@example.com", name: "Kaka"}, overrides)
  end

  # Point the deployment's configured sender at `domain`, which is how a
  # message's from-domain — the key the credential lookup uses — is set. In a
  # hosted deployment this is what a per-account sender would move; here the
  # from-address is configuration, and `Courier.Mailers` reads it.
  defp set_from(domain) do
    mailing = Application.get_env(:courier, :mailing, [])

    Application.put_env(
      :courier,
      :mailing,
      Keyword.put(mailing, :from, {"caFaye", "no-reply@" <> domain})
    )
  end

  # A row that is registered AND proven without going through the DNS proof and
  # the verification send, so this file is about the SEND path's selection and
  # not about the proof. `Courier.TenantSendingDomainsTest` is where the proof is.
  defp register_verified(domain, token, account \\ @account) do
    {:ok, row} =
      TenantSendingDomains.register(account, %{
        domain: domain,
        provider: :cloudflare,
        provider_account_id: @provider_account_id,
        credential: token
      })

    row
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp register_unverified(domain, token, account \\ @account) do
    {:ok, row} =
      TenantSendingDomains.register(account, %{
        domain: domain,
        provider: :cloudflare,
        provider_account_id: @provider_account_id,
        credential: token
      })

    row
  end

  describe "a verified domain is selected" do
    test "the TENANT's token is what the provider receives", %{server: server} do
      register_verified(@domain, @tenant_token)
      set_from(@domain)

      assert {:ok, %{notification_type: "welcome"}} = Deliver.welcome(payload())

      assert [request] = CloudflareServer.take(server)
      assert authorization_from(request) == "Bearer #{@tenant_token}"
      assert request.path == "/accounts/#{@provider_account_id}/email/sending/send"

      # The from-address on the wire is the tenant's domain, which is the pair
      # the credential is scoped to.
      assert decode!(request.body)["from"] == %{
               "address" => "no-reply@#{@domain}",
               "name" => "caFaye"
             }
    end

    test "an unverified row for a DIFFERENT domain does not leak into the choice", %{
      server: server
    } do
      # A verified other domain exists; the message is from @domain, which has
      # no row, and is refused rather than being sent on the other credential.
      register_verified("other.example.com", @tenant_token)
      set_from(@domain)

      assert {:error, {:no_sending_domain, @domain}} = Deliver.welcome(payload())
      assert CloudflareServer.requests(server) == []
    end
  end

  describe "a row that is not usable refuses" do
    test "an UNVERIFIED registered domain refuses the send", %{server: server} do
      register_unverified(@domain, @tenant_token)
      set_from(@domain)

      assert {:error, {:unverified_sending_domain, @domain}} = Deliver.welcome(payload())

      assert CloudflareServer.requests(server) == []
      assert no_send_recorded?()
    end

    test "a REVOKED domain refuses the send", %{server: server} do
      row = register_verified(@domain, @tenant_token)
      {:ok, _revoked} = TenantSendingDomains.revoke(row)
      set_from(@domain)

      assert {:error, {:revoked_sending_domain, @domain}} = Deliver.welcome(payload())

      assert CloudflareServer.requests(server) == []
      assert no_send_recorded?()
    end
  end

  describe "no registered domain for the from-address" do
    test "a from-domain nobody registered is refused, with no fallback", %{server: server} do
      set_from("unclaimed.example.com")

      assert {:error, {:no_sending_domain, "unclaimed.example.com"}} = Deliver.welcome(payload())

      assert CloudflareServer.requests(server) == []
      assert no_send_recorded?()
    end

    test "the DEPLOYMENT's own from-domain still uses the deployment credential" do
      # Nothing registered, and the from-address is the deployment's own
      # (`config :courier, :mailing`), so this is the deployment's mail and the
      # global adapter path is unchanged.
      assert {:ok, _result} = Deliver.welcome(payload())

      assert_email_sent(subject: "Welcome to caFaye", to: [{"Kaka", "recipient@example.com"}])
    end
  end

  describe "the account boundary" do
    test "account B cannot send from account A's verified domain", %{server: server} do
      register_verified(@domain, @tenant_token, @account)
      set_from(@domain)

      # Under account B's identity the row is invisible (row-level security),
      # so the from-domain is unregistered from B's side and the send is
      # refused. No mail and no request.
      assert {:error, {:no_sending_domain, @domain}} =
               as_account(@other_account, fn -> Deliver.welcome(payload()) end)

      assert CloudflareServer.requests(server) == []
      assert no_send_recorded?()
    end

    test "the policy protecting the credentials table exists and is forced" do
      # The refusal above is only meaningful if the boundary is a DATABASE
      # object and not just the context's predicate. Read it out of the catalog.
      %{rows: [[rls, forced]]} =
        Repo.query!(
          "select relrowsecurity, relforcerowsecurity from pg_class where relname = 'tenant_sending_domains'"
        )

      assert rls == true
      assert forced == true

      %{rows: policies} =
        Repo.query!(
          "select polname from pg_policy where polrelid = 'tenant_sending_domains'::regclass order by polname"
        )

      assert List.flatten(policies) == [
               "tenant_sending_domains_cafaye_delete",
               "tenant_sending_domains_cafaye_insert",
               "tenant_sending_domains_cafaye_select",
               "tenant_sending_domains_cafaye_update"
             ]
    end
  end

  # The rows that record a SEND. A refusal writes none of them. Scoped to this
  # test's own rows by account is not possible — `outbox_events` carries no
  # account on a user-addressed send — so this counts the delivered events this
  # file could have written, and the sandbox makes the count this test's own.
  defp no_send_recorded? do
    Repo.aggregate(
      from(e in Courier.OutboxEvent, where: e.type == ^Courier.Events.delivered_type()),
      :count
    ) == 0
  end

  defp authorization_from(request) do
    Enum.find_value(request.headers, fn {header, value} ->
      if String.downcase(header) == "authorization", do: value
    end)
  end

  defp decode!(body) do
    {:ok, decoded} = Swoosh.json_library().decode(body)
    decoded
  end
end
