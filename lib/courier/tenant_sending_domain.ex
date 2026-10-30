defmodule Courier.TenantSendingDomain do
  @moduledoc """
  One account's claim on a domain it sends mail from, and the provider
  credential that is allowed to send from it.


  `credential` holds `Courier.SecretBox` ciphertext, never the token — the same
  shape `webhook_endpoints.secret` uses, for the same reason: a database dump
  is not a list of provider tokens anybody can send mail with. The plaintext
  exists in exactly one place: the adapter configuration
  `Courier.TenantSendingDomains.adapter_config/1` builds, per send, and hands
  straight to the provider client. There is deliberately no `token/1`,
  `credential/1` or `plaintext/1` function on this module: a read path that
  could return the token is a read path a later packet will add a caller to,
  and the way to make that impossible is to not write it.


  A row is usable — selectable by `Courier.Deliver` — only when `verified_at`
  is set AND `status` is `:enabled`. Registration alone proves nothing: the
  proof is DNS plus a provider-accepted verification send, and it happens in
  `Courier.TenantSendingDomains.verify/2`. An unverified row is a claim, not a
  capability, and the send path refuses rather than falls back to the
  deployment credential on a domain somebody claimed.


  It comes from the authenticated principal (`Courier.TenantSendingDomains.
  register/2` takes it as an argument), and the table is protected by the
  substrate's row-level security besides — see the migration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @providers [:cloudflare]

  @statuses [:enabled, :revoked]

  @type t :: %__MODULE__{}

  @doc false
  def providers, do: @providers

  @doc false
  def statuses, do: @statuses

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "tenant_sending_domains" do
    field :account_id, Ecto.UUID
    field :domain, :string
    field :provider, Ecto.Enum, values: @providers
    field :provider_account_id, :string
    field :credential, :string
    field :verified_at, :utc_datetime_usec
    field :status, Ecto.Enum, values: @statuses, default: :enabled

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for registering a domain.

  Casts the three caller-supplied fields and never the credential or the
  account: the credential is sealed onto the changeset by the context (the
  plaintext is never a castable field, for the same reason
  `WebhookEndpoint` does not cast `secret`), and the account comes from the
  principal. `unique_constraint/3` names the `(account_id, domain)` index so a
  duplicate reads "is already registered".
  """
  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:domain, :provider, :provider_account_id])
    |> normalize_domain()
    |> validate_required([:domain, :provider, :provider_account_id])
    |> validate_domain()
    |> unique_constraint(:domain,
      name: :tenant_sending_domains_account_id_domain_index,
      message: "is already registered"
    )
  end

  @doc """
  The changeset that verifies a domain: it sets `verified_at`, and nothing
  else.

  `unique_constraint/3` names the partial verified-domain index, so a domain
  another account already verified is refused with "is already verified by
  another account" — the database enforcing the fleet-wide rule a
  cross-account read cannot. See the migration for why the index is the
  mechanism.
  """
  def verify_changeset(domain) do
    domain
    |> change(verified_at: DateTime.utc_now())
    |> unique_constraint(:domain,
      name: :tenant_sending_domains_verified_domain_index,
      message: "is already verified by another account"
    )
  end

  @doc """
  The changeset that revokes a domain.

  Revocation is a status, not a deletion: the row is the history of what was
  registered and proven, and "mail through it stops" is enforced by the send
  path reading `status`. Deleting the row is the operator's escape hatch.
  """
  def revoke_changeset(domain) do
    change(domain, status: :revoked)
  end

  defp validate_domain(changeset) do
    validate_change(changeset, :domain, fn :domain, domain ->
      if domain?(domain), do: [], else: [domain: "is not a domain"]
    end)
  end

  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      nil ->
        changeset

      domain when is_binary(domain) ->
        put_change(
          changeset,
          :domain,
          domain |> String.trim() |> String.downcase() |> String.trim_trailing(".")
        )

      _other ->
        changeset
    end
  end

  defp domain?(domain) do
    Regex.match?(~r/^(?!-)[a-z0-9-]{1,63}(?<!-)(\.[a-z0-9-]{1,63}(?<!-))+$/i, domain) and
      !Regex.match?(~r/\.[0-9]+$/, domain)
  end
end
