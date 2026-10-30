defmodule Courier.TenantSendingDomains do
  @moduledoc """
  The domains a tenant proves control of and sends mail from.

  Register, prove, revoke — and the one read the send path makes.


  A tenant's mail leaves from the tenant's own domain with the tenant's own
  provider credential. That needs three things, and this module is where each
  one is enforced:

    1. **Storage** — a `tenant_sending_domains` row per account per domain,
       carrying the provider credential SEALED under `COURIER_SECRET_BOX_KEY`
       (the `Courier.SecretBox` shape, exactly like a webhook signing secret).
       The table is account-scoped and protected by kit's row-level-security
       substrate: a credentials table one account can read is a security
       incident, and the substrate is already there.
    2. **Proof** — `verify/2` requires the DNS record set Cloudflare's Email
       Sending onboarding publishes (the `cf-bounce` MX trio, the SPF TXT, the
       DKIM TXT) AND a provider-accepted verification send with the tenant's
       own token. The DNS shape proves the domain is on Cloudflare DNS with
       Email Sending on; the accepted send proves the token is scoped to send
       from it. Either half alone is not proof, and a domain is never marked
       verified on DNS alone.
    3. **Selection** — `Courier.Deliver` asks `for_domain/1` for the
       message's from-domain and uses the row's credential when the row is
       verified and enabled. A row that is not (unverified, or revoked) is a
       REFUSAL: no mail, and no fallback to the deployment credential on a
       domain somebody claimed. A domain with no row at all is the
       deployment's own mail and goes out on the deployment credential, as it
       does today — the global adapter path is untouched.


  The DNS records are Cloudflare's onboarding footprint: the MX trio points
  the domain's inbound mail at Cloudflare's route servers, the SPF record
  authorizes Cloudflare's outbound senders, and the DKIM record is the public
  half of the key Cloudflare signs with. Their presence proves the domain is
  on Cloudflare DNS with Email Sending onboarded — a domain hosted elsewhere
  has none of them, and a domain on Cloudflare DNS but not onboarded lacks
  the exact triplet. But the records are published by the onboarding flow and
  could in principle be copied by somebody who can read them; the send is the
  half that cannot be faked, because it requires the tenant's token to be
  scoped to the domain it claims. A token that can send is a token that is
  scoped correctly; a domain the provider refuses is a domain that is not
  onboarded.


  `config :courier, :sending_domain_resolver` names the
  `Courier.SendingDomains.Dns` implementation — the shipped
  `Courier.SendingDomains.Dns.System` (`:inet_res`) in every environment, and
  a table double in test. `verify/2` also takes the resolver as an optional
  second argument, so a test can hand it the answers it wants without going
  through application env at all.


  It does not send mail (`Courier.Deliver` does), does not build the messages
  (`Courier.Mailers` does), and does not choose the sender for a message —
  it answers one question about a domain, and `Courier.Deliver` asks it.
  """

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Courier.Mailer
  alias Courier.Repo
  alias Courier.SecretBox
  alias Courier.TenantSendingDomain

  @typedoc "The result of every context call: a row, or why not."
  @type result :: {:ok, TenantSendingDomain.t()} | {:error, Ecto.Changeset.t() | atom()}

  @mx_exchange ~w(route1.mx.cloudflare.net route2.mx.cloudflare.net route3.mx.cloudflare.net)
  @spf_include "include:_spf.mail.cloudflare.net"
  @dkim_marker "v=DKIM1"

  @verification_recipient "sending-domain-verification@anywaye.com"

  @doc """
  Registers a sending domain for `account_id`.

  `attrs` carries `domain`, `provider`, `provider_account_id` and the
  plaintext `credential`. The credential is sealed by `Courier.SecretBox` on
  the way in and stored as ciphertext; it is never a castable field, for the
  same reason `WebhookEndpoint` does not cast `secret` — a field the caller
  controls that names a credential is a field the caller owns.

  Returns `{:ok, domain}` or `{:error, changeset}`. A duplicate for the same
  account is refused by the `(account_id, domain)` unique index, named in the
  changeset so it reads "is already registered".

  Registering proves nothing by itself: the row starts unverified
  (`verified_at` is `nil`) and unusable, and `Courier.Deliver` refuses a send
  whose from-domain has only unverified rows. See `verify/2`.
  """
  @spec register(Ecto.UUID.t(), map()) :: result()
  def register(account_id, attrs) when is_map(attrs) do
    changeset =
      %TenantSendingDomain{}
      |> TenantSendingDomain.changeset(attrs)
      |> put_account(account_id)
      |> put_sealed_credential(attrs)

    if changeset.valid? do
      case Repo.insert(changeset, mode: :savepoint) do
        {:ok, domain} -> {:ok, domain}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Proves a domain and marks it verified.

  Two proofs, both required, in this order:

    1. **DNS** — the `cf-bounce` MX trio, the SPF TXT and the DKIM TXT must
       all be present and match. The resolver is `config :courier,
       :sending_domain_resolver` by default, or the `resolver` argument.
    2. **The credential** — one real verification mail, from the domain being
       verified, to `@verification_recipient`, posted with the tenant's own
       token through the provider. The provider must accept it.

  Returns `{:ok, domain}` with `verified_at` set, or:

    * `{:error, {:dns_mx_mismatch, exchanges}}` — the MX records are not
      Cloudflare's route trio
    * `{:error, {:dns_spf_mismatch, records}}` — no SPF record authorizes
      Cloudflare's senders
    * `{:error, {:dns_dkim_mismatch, records}}` — no DKIM record is present
    * `{:error, {:dns_lookup_failed, reason}}` — the resolver failed; a
      verification that could pass on a broken resolver proves nothing
    * `{:error, {:credential_refused, reason}}` — the provider refused the
      verification send: the token is not scoped to send from this domain
    * `{:error, changeset}` — the domain is already verified by another
      account (the partial unique index), or the row is gone

  The DNS check runs before the credential check on purpose: a domain that is
  not on Cloudflare DNS costs no provider request to refuse, and the error it
  returns names the record class that is wrong rather than a provider's
  verdict about a domain that was never onboarded.
  """
  @spec verify(TenantSendingDomain.t(), module() | nil) :: result()
  def verify(%TenantSendingDomain{} = domain, resolver \\ nil) do
    resolver =
      resolver ||
        Application.get_env(:courier, :sending_domain_resolver, Courier.SendingDomains.Dns.System)

    with :ok <- check_dns_proof(domain.domain, resolver),
         :ok <- check_credential(domain) do
      domain
      |> TenantSendingDomain.verify_changeset()
      |> Repo.update(mode: :savepoint)
    end
  end

  @doc """
  Revokes a domain: `status` becomes `:revoked` and mail through it stops.

  Revocation is a status and not a deletion. The row is the history of what
  was registered and proven — "this domain was verified on this date and
  revoked on this one" is a fact a support conversation needs — and deleting
  the row is the operator's escape hatch, not the tenant's. The send path
  reads `status`, so a revoked row is simply never selected again.
  """
  @spec revoke(TenantSendingDomain.t()) :: result()
  def revoke(%TenantSendingDomain{} = domain) do
    domain
    |> TenantSendingDomain.revoke_changeset()
    |> Repo.update(mode: :savepoint)
  end

  @doc """
  The domain `id` in `account_id`, or `nil`.

  `nil` rather than an error, because the two questions are the same question:
  "is this domain yours?" — and for a domain in another account the honest
  answer is no, without a distinction that would tell a caller the row
  exists. The `account_id` predicate is in the query as well as in the
  policy: the substrate's row-level security is defence in depth, not a
  substitute for the predicate.
  """
  @spec get(String.t() | Ecto.UUID.t(), Ecto.UUID.t()) :: TenantSendingDomain.t() | nil
  def get(id, account_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(TenantSendingDomain, id: id, account_id: account_id)
      :error -> nil
    end
  end

  @doc """
  Every domain registered by `account_id`, oldest first.

  Unverified and revoked ones included: the table is the history of claims,
  not only the usable ones, and a list that hid the unverified rows would
  hide the rows an operator is looking for when somebody asks "why is my
  domain not sending".
  """
  @spec list(Ecto.UUID.t()) :: [TenantSendingDomain.t()]
  def list(account_id) do
    TenantSendingDomain
    |> where([domain], domain.account_id == ^account_id)
    |> order_by([domain], asc: domain.inserted_at, asc: domain.id)
    |> Repo.all()
  end

  @doc """
  The row for `domain` that the current account can see, or `nil`.

  This is the send path's one question, and it is deliberately NOT filtered
  by verification or status: the caller (`Courier.Deliver`) needs to tell
  "no row at all" (the deployment's own domain — deployment credential, as
  today) from "a row exists but is not usable" (refuse the send). Filtering
  here would collapse those two into one answer and force the send path to
  guess which one it got.

  The account scoping is the table's row-level security, not a predicate in
  this query: a query for another account's domain returns `nil` because the
  policy hides the row, which is the same answer as "not registered" and the
  correct one — a tenant cannot use a domain it did not register, and it
  cannot even learn whether another tenant registered it.
  """
  @spec for_domain(String.t()) :: TenantSendingDomain.t() | nil
  def for_domain(domain) when is_binary(domain) do
    TenantSendingDomain
    |> where([d], d.domain == ^domain)
    |> Repo.one()
  end

  @doc """
  The provider adapter configuration for sending with `domain`'s credential.

  The sealed credential is opened here and nowhere else, and the plaintext
  lives only in the keyword list this returns — handed straight to
  `Swoosh.Mailer.deliver/2` as the per-call config override, which merges
  over the deployment's adapter configuration for one send and persists
  nowhere.

  Returns `{:error, :invalid_credential}` when the credential cannot be
  opened — a row sealed under a `COURIER_SECRET_BOX_KEY` that has since been
  rotated. That is a refusal, not a crash: the send path turns it into a
  send refusal, because a credential courier cannot open is a credential
  courier cannot send with, and guessing at it is the silent-default failure
  this repository exists to end.

  `base_url` is read from `config :courier, :tenant_sending` and defaults to
  the production API host. It exists so a test can point the adapter at a
  listener it controls — the same seam `Courier.Adapters.CloudflareEmail`
  documents — and is not a variable an operator sets.
  """
  @spec adapter_config(TenantSendingDomain.t()) ::
          {:ok, keyword()} | {:error, :invalid_credential}
  def adapter_config(%TenantSendingDomain{} = domain) do
    case SecretBox.open(domain.credential) do
      {:ok, token} ->
        {:ok,
         [
           adapter: Courier.Adapters.CloudflareEmail,
           api_key: token,
           account_id: domain.provider_account_id,
           base_url: base_url()
         ]}

      {:error, _reason} ->
        {:error, :invalid_credential}
    end
  end


  defp check_dns_proof(domain, resolver) do
    bounce = "cf-bounce." <> domain
    dkim = "cf-bounce._domainkey." <> domain

    with {:ok, mx} <- lookup(fn -> resolver.mx(bounce) end),
         :ok <- check_mx(mx),
         {:ok, spf} <- lookup(fn -> resolver.txt(bounce) end),
         :ok <- check_spf(spf),
         {:ok, dkim_records} <- lookup(fn -> resolver.txt(dkim) end),
         :ok <- check_dkim(dkim_records) do
      :ok
    end
  end

  defp lookup(fun) do
    case fun.() do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, {:dns_lookup_failed, reason}}
    end
  end

  defp check_mx(records) do
    exchanges = records |> Enum.map(fn {_preference, exchange} -> exchange end) |> Enum.sort()
    expected = Enum.sort(@mx_exchange)

    if exchanges == expected,
      do: :ok,
      else: {:error, {:dns_mx_mismatch, exchanges}}
  end

  defp check_spf(records) do
    if Enum.any?(records, &String.contains?(&1, @spf_include)),
      do: :ok,
      else: {:error, {:dns_spf_mismatch, records}}
  end

  defp check_dkim(records) do
    if Enum.any?(records, &(String.contains?(&1, @dkim_marker) and String.contains?(&1, "p="))),
      do: :ok,
      else: {:error, {:dns_dkim_mismatch, records}}
  end

  defp check_credential(domain) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({"Anywaye", "no-reply@" <> domain.domain})
      |> Swoosh.Email.to({"Anywaye", @verification_recipient})
      |> Swoosh.Email.subject("anywaye sending domain verification")
      |> Swoosh.Email.text_body(
        "anywaye is verifying the sending domain #{domain.domain}. " <>
          "If you received this mail, the domain's provider credential was accepted."
      )
      |> Swoosh.Email.html_body(
        "<p>anywaye is verifying the sending domain <strong>#{domain.domain}</strong>.</p>"
      )

    case adapter_config(domain) do
      {:ok, config} ->
        case Mailer.deliver(email, config) do
          {:ok, _receipt} -> :ok
          {:error, reason} -> {:error, {:credential_refused, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end


  defp put_account(changeset, account_id) do
    changeset
    |> put_change(:account_id, account_id)
    |> validate_account()
  end

  defp validate_account(changeset) do
    validate_change(changeset, :account_id, fn :account_id, account_id ->
      case Ecto.UUID.cast(account_id) do
        {:ok, _uuid} -> []
        :error -> [account_id: "is not a uuid"]
      end
    end)
  end

  defp put_sealed_credential(changeset, attrs) do
    case Map.get(attrs, :credential) || Map.get(attrs, "credential") do
      nil ->
        add_error(changeset, :credential, "can't be blank")

      token when is_binary(token) and token != "" ->
        put_change(changeset, :credential, SecretBox.seal(token))

      _other ->
        add_error(changeset, :credential, "is invalid")
    end
  end

  defp base_url do
    Application.get_env(:courier, :tenant_sending, [])[:base_url]
  end
end
