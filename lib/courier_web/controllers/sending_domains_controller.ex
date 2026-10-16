defmodule CourierWeb.SendingDomainsController do
  @moduledoc """
  The JSON API over a tenant's sending domains: `POST`, `GET`, and the two
  state transitions, under `/v1/sending_domains`.

  This is the HTTP surface over `Courier.TenantSendingDomains` and nothing more.
  It registers a claim, proves it, lists the caller's claims and revokes one; it
  adds no behaviour the context does not already have, and the two constraints
  that matter are both enforced one layer down and are only *not opened* here.

  ## The account comes from the principal, never from the request

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

  ## A credential is never in a response

  The context has no `token/1` and no `credential/1`; this controller renders a
  fixed set of eight fields that does not include one. The credential crosses
  this boundary exactly once, on the way in, and is sealed before it is stored.
  `provider_account_id` is deliberately not rendered either — the migration says
  it is never rendered anywhere — and it is not a credential, so the point is
  only that the response is a fixed, auditable set rather than the struct.

  ## Verification is the context's two-part proof, unchanged

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

  # The domain `id` in the caller's account, or `:error`. The context answers
  # `nil` for another account's row and for a non-uuid alike, so the two collapse
  # onto one 404 and the response leaks nothing about which it was.
  defp fetch(conn, id) do
    case TenantSendingDomains.get(id, conn.assigns.current_account) do
      nil -> :error
      domain -> {:ok, domain}
    end
  end

  # The whole action runs inside one transaction carrying the caller's account,
  # so the row-level-security policies on `tenant_sending_domains` have an
  # identity to key on. A plug cannot hold such a transaction open across the
  # controller — see `Courier.Tenancy` — so each action opens its own, with the
  # account `CourierWeb.Plugs.Principal` stashed.
  #
  # `{:error, _}` — a `Repo.rollback` that escaped the action — is unreachable by
  # construction: the context rolls back only inside its own inner transactions.
  # Handled as a 503 rather than matched away, on the same rule as
  # `CourierWeb.Plugs.Idempotency`'s own scoping: a refusal the caller retries.
  defp scoped(conn, fun) do
    case Tenancy.with_account(Repo, conn.assigns.current_account, fun) do
      {:ok, conn} -> conn
      {:error, _reason} -> unavailable(conn)
    end
  end

  # The eight fields the API promises, and no others. There is no credential here
  # by construction rather than by omission, and `provider_account_id` is not
  # rendered either — see the moduledoc.
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

  # A refusal from the vocabulary rather than from the changeset: the body named
  # a field courier does not read. The field is named so a misspelling is
  # actionable, and `account_id` arrives here exactly as a typo does.
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

  # A uniqueness refusal reads as `taken` — the code core's conventions and the
  # webhook endpoints use for the same answer — rather than as a format error.
  # Both indexes on this table are uniqueness rules: a duplicate registration for
  # one account, and a domain another account already verified.
  defp code_for(:domain, opts) do
    case opts[:constraint] do
      :unique -> "taken"
      _other -> Keyword.get(opts, :code, "invalid_format")
    end
  end

  defp code_for(_field, opts), do: Keyword.get(opts, :code, "invalid_format")

  # The proof's refusals, mapped onto the two statuses a client branches on. The
  # reason a provider gave is logged and never returned: it is the provider's
  # sentence, and this repository is public.
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

  # A provider that refused the verification send is a fact about the credential
  # the caller supplied, which is the caller's to fix — the same "the request is
  # wrong" answer a declined preference gets, and `errors[]` names the field.
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

  # A resolver that could not answer is courier's dependency failing, and a
  # credential courier cannot open is courier's own key having rotated. Both are
  # 503 rather than 422: nothing about the caller's request is wrong.
  defp verification_failed(conn, {:dns_lookup_failed, reason}) do
    Logger.error("sending domain verification could not resolve DNS: #{inspect(reason)}")
    unavailable(conn)
  end

  defp verification_failed(conn, :invalid_credential) do
    Logger.error("sending domain verification could not open the stored credential")
    unavailable(conn)
  end

  # A domain another account already verified: the partial unique index refuses
  # the write, and the changeset names the field.
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
