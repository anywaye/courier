defmodule CourierWeb.SendingDomains do
  @moduledoc """
  The HTTP sending-domain surface's own rules: what a
  `POST /v1/sending_domains` body must carry, and what it must not.

  This is the same shape `CourierWeb.Messages` establishes for the send surface,
  for the same reason. `Courier.TenantSendingDomains.register/2` casts the body
  with `Ecto.Changeset.cast/3` against a fixed field list and **discards
  everything else without a word** — right for a library a trusted caller holds,
  and wrong for a request body, where a misspelled `provider_acount_id` or an
  `account_id` that courier reads nowhere would otherwise be accepted with no
  sign anything was ignored. So every key is checked against the list below and
  an unknown one is a 422.


  The account is `conn.assigns.current_account` — the account
  `CourierWeb.Plugs.Principal` resolved from the caller's token — and never the
  body's. An account a caller can name in a body is an account they can write
  to, and `TenantSendingDomain`'s own moduledoc says the same: `account_id` is
  set from the principal and is never a castable field. A body that carries one
  is therefore an unknown field and a 422 naming it — the answer
  `CourierWeb.Messages` gives `account_id` and `from`, and a stronger one than
  it gives a genuinely-ignored extra, because this one is asking courier to
  attribute a credential to somebody else.


  The credential is required on the way IN — the context seals it and stores
  ciphertext — and there is deliberately no read path that returns it:
  `Courier.TenantSendingDomain` has no `token/1`, and the controller renders a
  fixed set of fields that does not include it. The credential exists in exactly
  two places, the request that registers it and the provider client that sends
  with it, and this module is where the first of those is spelled.
  """

  @wire_fields ~w(domain provider provider_account_id credential)

  @doc """
  The fields a body may carry, in the order the document lists them.
  """
  @spec fields() :: [String.t()]
  def fields, do: @wire_fields

  @doc """
  Checks `params` against the vocabulary and returns the attributes for
  `Courier.TenantSendingDomains.register/2` when it passes.

  `{:ok, attrs}`, or `{:error, fields}` where `fields` is the list of
  `%{"field" => name, "code" => code}` entries a 422 renders as `errors[]`.

  Only unknown keys are checked here. The required fields, the domain's shape,
  the provider's membership in the closed set and the credential's non-blankness
  are `Courier.TenantSendingDomains.register/2`'s own changeset, and they arrive
  as `{:error, changeset}` for the controller to render from the changeset's own
  errors — the same "one list of required fields" rule `CourierWeb.Messages`
  follows.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [map()]}
  def validate(params) when is_map(params) do
    case unknown(params) do
      [] -> {:ok, attrs(params)}
      fields -> {:error, fields}
    end
  end

  defp unknown(params) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in @wire_fields))
    |> Enum.sort()
    |> Enum.map(&%{"field" => &1, "code" => "unknown_field"})
  end

  defp attrs(params) do
    %{
      domain: params["domain"],
      provider: params["provider"],
      provider_account_id: params["provider_account_id"],
      credential: params["credential"]
    }
  end
end
