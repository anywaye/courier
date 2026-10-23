defmodule CourierWeb.MessagesControllerSendingDomainConfigTest do
  @moduledoc """
  The three sending-domain refusals the send path can return, told to the caller
  through `POST /v1/messages` as the statuses their meaning calls for.

  `Courier.Deliver` refuses a send when the message's FROM domain is one it
  cannot prove — an unverified row, a revoked row, or no row at all and not the
  deployment's own domain (`lib/courier/deliver.ex`'s `fetch_sender/1`). Those
  three tuples had no clause in the controller, so a tenant who registered a
  domain and did not finish verifying it got a **500**: the server blaming
  itself for the caller's state, with no diagnosis. This file is the HTTP door's
  half of that vocabulary and nothing else — the send path's own refusals are
  unchanged (`Courier.DeliverSendingDomainTest`).

  ## `async: false`, and why

  The from-domain a message sends as is `config :courier, :mailing`'s `:from`,
  and application env is VM-global: for the length of this module any other test
  that builds a message would build it from the domain this file points the
  sender at. `on_exit` restores it before the next test starts. That is why the
  file is separate from `messages_controller_test.exs`, which is `async: true`
  and must not change shared env — the same split `messages_controller_config_test.exs`
  makes for the adapter, and the same reason `deliver_sending_domain_test.exs`
  gives for `set_from/1`.

  ## Every count here is over courier's own rows

  "No mail was sent" is asserted on the test adapter's own mailbox, and "no
  outbox row" on an address this file mints fresh per call — never on the
  table's count, which would be a claim about every other test in the suite.
  """

  use CourierWeb.ConnCase, async: false

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.TenantSendingDomains

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @domain "tenant.example.com"
  @provider_account_id "cf-account-abc123"
  @token "tenant-provider-token-not-the-deployment-key"

  # The file seeds `tenant_sending_domains`, a protected table, so the sandbox
  # connection needs an identity for the writes. See `Courier.DataCase`.
  @moduletag account: @account

  setup do
    previous_mailing = Application.get_env(:courier, :mailing)
    on_exit(fn -> Application.put_env(:courier, :mailing, previous_mailing) end)
    :ok
  end

  defp address, do: "recipient-#{System.unique_integer([:positive])}@example.com"

  defp body(overrides \\ %{}) do
    Map.merge(
      %{"type" => "welcome", "user_id" => @user_id, "to" => address(), "name" => "Kaka"},
      overrides
    )
  end

  defp post_authed(payload) do
    build_conn()
    |> put_req_header("x-courier-account", @account)
    |> post(~p"/v1/messages", payload)
  end

  defp problem(conn), do: Jason.decode!(conn.resp_body)

  # Point courier's configured sender at `domain`. The from-address is
  # configuration in this single-sender deployment, and `Courier.Mailers` reads
  # it when it builds the message; the domain part is the key the credential
  # lookup uses. `DeliverSendingDomainTest` sets it the same way.
  defp set_from(domain) do
    mailing = Application.get_env(:courier, :mailing, [])

    Application.put_env(
      :courier,
      :mailing,
      Keyword.put(mailing, :from, {"Anywaye", "no-reply@" <> domain})
    )
  end

  defp register(domain, account \\ @account) do
    {:ok, row} =
      TenantSendingDomains.register(account, %{
        domain: domain,
        provider: :cloudflare,
        provider_account_id: @provider_account_id,
        credential: @token
      })

    row
  end

  # Proven without the DNS proof and the verification send, so this file is
  # about the SEND path's refusal and not about the proof. The proof is
  # `Courier.TenantSendingDomainsTest`'s subject.
  defp register_verified(domain, account \\ @account) do
    domain
    |> register(account)
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now())
    |> Repo.update!()
  end

  # Every message the test adapter handed to this process. The send happens
  # inside the request, so the mailbox already holds it; `after 0` and not a
  # sleep.
  defp sent do
    do_sent([])
  end

  defp do_sent(acc) do
    receive do
      {:email, email} -> do_sent([email | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp outbox_for(email) do
    Enum.filter(Repo.all(OutboxEvent), &(&1.data["email"] == email))
  end

  describe "an unverified sending domain" do
    test "is a 409, not a 500, and names the domain" do
      _row = register(@domain)
      set_from(@domain)

      conn = post_authed(body())

      assert conn.status == 409
      refute conn.status == 500
      assert problem(conn)["code"] == "conflict"
      assert problem(conn)["status"] == 409
      assert problem(conn)["detail"] =~ @domain
    end

    test "sends no mail and writes no outbox row" do
      recipient = address()
      _row = register(@domain)
      set_from(@domain)

      conn = post_authed(body(%{"to" => recipient}))

      assert conn.status == 409
      assert sent() == []
      assert outbox_for(recipient) == []
    end

    test "never echoes the sealed credential" do
      _row = register(@domain)
      set_from(@domain)

      conn = post_authed(body())

      assert conn.status == 409
      refute conn.resp_body =~ @token
    end
  end

  describe "a revoked sending domain" do
    test "is a 409, not a 500, and names the domain" do
      row = register_verified(@domain)
      {:ok, _revoked} = TenantSendingDomains.revoke(row)
      set_from(@domain)

      conn = post_authed(body())

      assert conn.status == 409
      refute conn.status == 500
      assert problem(conn)["code"] == "conflict"
      assert problem(conn)["status"] == 409
      assert problem(conn)["detail"] =~ @domain
    end

    test "sends no mail and writes no outbox row" do
      recipient = address()
      row = register_verified(@domain)
      {:ok, _revoked} = TenantSendingDomains.revoke(row)
      set_from(@domain)

      conn = post_authed(body(%{"to" => recipient}))

      assert conn.status == 409
      assert sent() == []
      assert outbox_for(recipient) == []
    end
  end

  describe "a from-domain nobody registered" do
    @unclaimed "unclaimed.example.com"

    test "is a 422, not a 500, and names the domain" do
      set_from(@unclaimed)

      conn = post_authed(body())

      assert conn.status == 422
      refute conn.status == 500
      assert problem(conn)["code"] == "validation_failed"
      assert problem(conn)["status"] == 422
      assert problem(conn)["detail"] =~ @unclaimed
    end

    test "sends no mail and writes no outbox row" do
      recipient = address()
      set_from(@unclaimed)

      conn = post_authed(body(%{"to" => recipient}))

      assert conn.status == 422
      assert sent() == []
      assert outbox_for(recipient) == []
    end
  end
end
