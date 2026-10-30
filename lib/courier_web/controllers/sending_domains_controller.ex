defmodule CourierWeb.SendingDomainsController do
  @moduledoc """
  The JSON API over a tenant's sending domains: `POST`, `GET`, and the two
  state transitions, under `/v1/sending_domains`.

  This is the HTTP surface over `Courier.TenantSendingDomains` and nothing more.
  It registers a claim, proves it, lists the caller's claims and revokes one; it
  adds no behaviour the context does not already have, and the two constraints
  that matter are both enforced one layer down and are only *not opened* here.


  Every action reads `conn.assigns.current_account`, which
  `CourierWeb.Plugs.Principal` put there from the caller's token, and never from
  the body. `CourierWeb.SendingDomains` refuses an `account_id` in a body as the
  unknown field it is, and `Courier.TenantSendingDomain` sets `account_id` from
  the principal and never casts it — so there is no code path here that takes an
  account from a request, and there is no test that could pass by showing the
  body was honoured because the account happened to match.

  A domain in another account is a **404, not a 403**, on the same rule the
  webhook endpoints follow: core's conventions forbid a 403 that leaks the
  existence of a resource the caller cannot see. `Courier.TenantSendingDomains.
  get/2` answers `nil` for another account's row and for a non-uuid alike, so the
  controller cannot tell those two apart and does not try.


  The context has no `token/1` and no `credential/1`; this controller renders a
  fixed set of eight fields that does not include one. The credential crosses
  this boundary exactly once, on the way in, and is sealed before it is stored.
  `provider_account_id` is deliberately not rendered either — the migration says
  it is never rendered anywhere — and it is not a credential, so the point is
  only that the response is a fixed, auditable set rather than the struct.


  `POST /:id/verify` calls `Courier.TenantSendingDomains.verify/2` and maps its
  refusals onto statuses a client branches on:

    * a DNS record that is not Cloudflare's onboarding footprint, or a provider
      that refused the verification send, is a **422** naming the field at fault
      — `domain` or `credential`;
    * a resolver that could not answer, or a credential courier cannot open, is
      a **503**: courier is fine and its dependency (or its own key) is not, and
      the retry is the caller's.

  The route is behind `Idempotency-Key`, because a retried verification re-runs
  the two-part proof and re-sends nothing the first attempt did not — the same
  reason every mutating `POST` here carries the header.
  """

  use CourierWeb, :controller

  require Logger

  alias Courier.Repo
  alias Courier.Tenancy
  alias Courier.TenantSendingDomain
  alias Courier.TenantSendingDomains
  alias CourierWeb.Problem
  alias CourierWeb.SendingDomains

  @doc """
  Registers a sending domain for the caller's account, unverified, and answers
  201 with the row.
  """
  def create(conn, params) do
    scoped(conn, fn ->
      with {:ok, attrs} <- SendingDomains.validate(params) do
        case TenantSendingDomains.register(conn.assigns.current_account, attrs) do
          {:ok, domain} ->
            conn
            |> put_status(:created)
            |> json(%{data: domain_json(domain)})

          {:error, %Ecto.Changeset{} = changeset} ->
            validation_failed(conn, changeset)
        end
      else
        {:error, fields} -> validation_failed_fields(conn, fields)
      end
    end)
  end

  @doc """
  Every domain the caller's account has registered, oldest first.
  """
  def index(conn, _params) do
    scoped(conn, fn ->
      domains = TenantSendingDomains.list(conn.assigns.current_account)

      json(conn, %{data: Enum.map(domains, &domain_json/1)})
    end)
  end

  @doc """
  One of the caller's domains, or 404.
  """
  def show(conn, %{"id" => id}) do
    scoped(conn, fn ->
      case fetch(conn, id) do
        {:ok, domain} -> json(conn, %{data: domain_json(domain)})
        :error -> not_found(conn)
      end
    end)
  end

  @doc """
  Runs the two-part proof for one of the caller's domains, or says which half
  failed.
  """
  def verify(conn, %{"id" => id}) do
    scoped(conn, fn ->
      case fetch(conn, id) do
        {:ok, domain} ->
          case TenantSendingDomains.verify(domain) do
            {:ok, verified} -> json(conn, %{data: domain_json(verified)})
            {:error, reason} -> verification_failed(conn, reason)
          end

        :error ->
          not_found(conn)
      end
    end)
  end

  @doc """
  Revokes one of the caller's domains: `status` becomes `revoked` and mail through
  it stops. The row stays — revocation is a status, not a deletion.
  """
  def revoke(conn, %{"id" => id}) do
    scoped(conn, fn ->
      case fetch(conn, id) do
        {:ok, domain} ->
          case TenantSendingDomains.revoke(domain) do
            {:ok, revoked} -> json(conn, %{data: domain_json(revoked)})
            {:error, %Ecto.Changeset{} = changeset} -> validation_failed(conn, changeset)
          end

        :error ->
          not_found(conn)
      end
    end)
  end

  defp fetch(conn, id) do
    case TenantSendingDomains.get(id, conn.assigns.current_account) do
      nil -> :error
      domain -> {:ok, domain}
    end
  end

  defp scoped(conn, fun) do
    case Tenancy.with_account(Repo, conn.assigns.current_account, fun) do
      {:ok, conn} -> conn
      {:error, _reason} -> unavailable(conn)
    end
  end

  defp domain_json(%TenantSendingDomain{} = domain) do
    %{
      id: domain.id,
      account_id: domain.account_id,
      domain: domain.domain,
      provider: domain.provider,
      status: domain.status,
      verified_at: domain.verified_at,
      inserted_at: domain.inserted_at,
      updated_at: domain.updated_at
    }
  end

  defp not_found(conn) do
    Problem.send(conn, 404, :not_found, "No sending domain with that id.")
  end

  defp validation_failed_fields(conn, fields) do
    Problem.send(conn, 422, :validation_failed, "The sending domain was not valid.", fields)
  end

  defp validation_failed(conn, changeset) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "The sending domain was not valid: " <>
        Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
          "#{field} #{message}"
        end),
      Enum.map(changeset.errors, fn {field, {_message, opts}} ->
        %{"field" => to_string(field), "code" => code_for(field, opts)}
      end)
    )
  end

  defp code_for(:domain, opts) do
    case opts[:constraint] do
      :unique -> "taken"
      _other -> Keyword.get(opts, :code, "invalid_format")
    end
  end

  defp code_for(_field, opts), do: Keyword.get(opts, :code, "invalid_format")

  defp verification_failed(conn, {:dns_mx_mismatch, _records}) do
    domain_not_proven(
      conn,
      "dns_mx_mismatch",
      "The domain does not publish Cloudflare's MX route record set."
    )
  end

  defp verification_failed(conn, {:dns_spf_mismatch, _records}) do
    domain_not_proven(
      conn,
      "dns_spf_mismatch",
      "The domain does not publish the SPF record that authorizes Cloudflare's senders."
    )
  end

  defp verification_failed(conn, {:dns_dkim_mismatch, _records}) do
    domain_not_proven(
      conn,
      "dns_dkim_mismatch",
      "The domain does not publish a Cloudflare DKIM record."
    )
  end

  defp verification_failed(conn, {:credential_refused, reason}) do
    Logger.error("sending domain verification refused by the provider: #{inspect(reason)}")

    Problem.send(
      conn,
      422,
      :validation_failed,
      "The provider did not accept a verification message sent with this credential, so " <>
        "the credential is not scoped to send from this domain.",
      [%{"field" => "credential", "code" => "credential_refused"}]
    )
  end

  defp verification_failed(conn, {:dns_lookup_failed, reason}) do
    Logger.error("sending domain verification could not resolve DNS: #{inspect(reason)}")
    unavailable(conn)
  end

  defp verification_failed(conn, :invalid_credential) do
    Logger.error("sending domain verification could not open the stored credential")
    unavailable(conn)
  end

  defp verification_failed(conn, %Ecto.Changeset{} = changeset),
    do: validation_failed(conn, changeset)

  defp domain_not_proven(conn, code, detail) do
    Problem.send(conn, 422, :validation_failed, detail, [
      %{"field" => "domain", "code" => code}
    ])
  end

  defp unavailable(conn) do
    Problem.send(
      conn,
      503,
      :unavailable,
      "courier could not complete this verification, so the domain is not verified and " <>
        "this request is safe to retry."
    )
  end
end
