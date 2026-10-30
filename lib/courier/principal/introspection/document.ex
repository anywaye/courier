defmodule Courier.Principal.Introspection.Document do
  @moduledoc """
  What courier makes of identity's answer to `POST /v1/introspections`.

  A pure function of the body. No socket, no configuration, no clock — which is
  the reason this is a module of its own rather than a private function inside
  `Courier.Principal.Introspection`: every rule below is then a table over a
  literal, and the resolver's own tests are left holding the one question they are
  about.


      {:ok, principal}      a live token, with an account courier can place
      :error                identity says the token cannot be used — a 401
      {:error, :unreadable} identity did not answer in a shape courier reads — a 503

  The split between the second and the third is the whole design. `:error` means
  **identity answered the question** and the answer was no; `{:error, :unreadable}`
  means **courier could not read the answer**, which is courier's problem rather
  than the caller's. Collapsing them is the one mistake available here, and it is
  the mistake that tells a caller holding a perfectly good token that their token
  is the problem — which is a lie that costs a rotation, a support ticket and an
  engineer an afternoon.


  Unknown, revoked, expired, and one whose owner has been removed from the account
  are all `200 {"active": false}` upstream — identity collapsed them on purpose,
  because a caller who can tell them apart learns whether a leaked value is still
  live. **Nothing here re-expands them.** There is no branch on `exp`, no branch
  on a `revoked` claim, and no clock in this module, which is the structural
  reason the four cannot come apart here.


  `sub` is the **user** a token names. `account_id` is the tenancy boundary and it
  is required. A document that is active and carries no `account_id` is therefore
  a caller courier cannot place, and it is answered exactly as an inactive token
  is: `:error`.

  `Map.fetch/2` with no default, and that is not a style choice — it is what makes
  the fallback inexpressible in the one function that decides the account. The
  subject is read two functions below and is a perfectly good uuid, which is
  exactly why a fallback would be so easy to write by accident.


  MD7 in the manager's `anywaye/notes/decisions.md` is open: core's conventions require
  `scopes`, gateway's verifier reads `scope`, and identity emits **both, byte for
  byte** so that whichever name wins is a one-line removal and no credential has
  to be reissued. courier therefore reads the union and assumes neither is the
  only one. A resolver that read one name would work perfectly until MD7 is ruled,
  and then work perfectly for nobody.

  A claim that is present and is **not a string** is `{:error, :unreadable}`
  rather than an empty set. That is the load-bearing half of the rule: the array
  shape is the one a losing side of MD7 could plausibly adopt, and reading an
  array as "no scopes" is the silent version of the bug — a token holding
  `["webhooks:write"]` would authenticate and appear to hold nothing, which is the
  one reading nobody can debug afterwards.

  A document carrying **neither** name is an empty set, deliberately. RFC 7662
  makes the claim optional, identity's `IntrospectionResponse` requires only
  `active`, and refusing would mean inventing a requirement identity does not
  state. The cost is written down in the test that asserts it: if identity ever
  stopped emitting both, every caller would still authenticate on `account_id`
  alone, and nothing would say so.
  """

  alias Courier.Principal

  @scope_claims ["scopes", "scope"]

  @typedoc "A decoded introspection body, or the bytes identity sent."
  @type input :: map() | binary()

  @doc """
  The principal an introspection body describes, or why there is not one.
  """
  @spec from(input()) :: {:ok, Principal.t()} | :error | {:error, :unreadable}
  def from(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> from(decoded)
      {:error, _reason} -> {:error, :unreadable}
    end
  end

  def from(document) when is_map(document) do
    case Map.fetch(document, "active") do
      {:ok, true} -> build(document)
      {:ok, false} -> :error
      _absent_or_malformed -> {:error, :unreadable}
    end
  end

  def from(_other), do: {:error, :unreadable}

  defp build(document) do
    case account_id(document) do
      {:ok, account_id} ->
        case scopes(document) do
          {:ok, scopes} ->
            {:ok, %Principal{account_id: account_id, subject: subject(document), scopes: scopes}}

          {:error, :unreadable} ->
            {:error, :unreadable}
        end

      :error ->
        :error

      {:error, :unreadable} ->
        {:error, :unreadable}
    end
  end

  defp account_id(document) do
    case Map.fetch(document, "account_id") do
      {:ok, value} when is_binary(value) -> cast_account(value)
      {:ok, _wrong_type} -> {:error, :unreadable}
      :error -> :error
    end
  end

  defp cast_account(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :unreadable}
    end
  end

  defp subject(document) do
    with {:ok, value} when is_binary(value) <- Map.fetch(document, "sub"),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      uuid
    else
      _absent_or_malformed -> nil
    end
  end

  defp scopes(document) do
    Enum.reduce_while(@scope_claims, {:ok, []}, fn name, {:ok, found} ->
      case claim(document, name) do
        {:ok, scopes} -> {:cont, {:ok, found ++ scopes}}
        {:error, :unreadable} -> {:halt, {:error, :unreadable}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, found |> Enum.uniq() |> Enum.sort()}
      {:error, :unreadable} -> {:error, :unreadable}
    end
  end

  defp claim(document, name) do
    case Map.fetch(document, name) do
      {:ok, value} when is_binary(value) -> {:ok, split(value)}
      :error -> {:ok, []}
      {:ok, _wrong_type} -> {:error, :unreadable}
    end
  end

  defp split(value), do: value |> String.split(~r/\s+/, trim: true)
end
