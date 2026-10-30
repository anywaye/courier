defmodule Courier.WebhookEndpoint do
  @moduledoc """
  One account's subscription to courier's events at one URL.


  `secret` holds the sealing ciphertext, never the secret: `Courier.SecretBox`
  seals it on the way in and opens it on the way out, and no other module is
  allowed to read the column. The plaintext exists in exactly two places — the
  single `201` response that hands it to the customer, and the process that signs
  a delivery with it.

  The secret is generated rather than supplied, and is not a castable field. A
  body that names its own `secret` is ignored, for the same reason
  `NotificationPreference` does not cast `user_id`: a field the caller controls
  that names a credential is a field the caller owns.


  Two values, `enabled` and `disabled`, and `Courier.WebhookEndpoints` keeps them
  apart in `disabled_reason`. A customer disabling their own endpoint and courier
  tripping its circuit breaker are the same column and different worlds: the
  first is a decision the customer made and courier must not undo, the second is
  courier protecting them from an endpoint that has been failing, and which
  should clear itself the moment a delivery succeeds.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses [:enabled, :disabled]
  @max_url_length 2048
  @max_description_length 500

  @type t :: %__MODULE__{}

  @doc false
  def statuses, do: @statuses

  @doc false
  def max_url_length, do: @max_url_length

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  schema "webhook_endpoints" do
    field :account_id, Ecto.UUID
    field :url, :string
    field :description, :string
    field :secret, :string
    field :status, Ecto.Enum, values: @statuses, default: :enabled
    field :consecutive_failures, :integer, default: 0
    field :disabled_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for a new endpoint.

  The shape is checked, not the destination: `Courier.Webhooks.UrlGuard` is the
  module that decides whether courier will send anything to a URL, and it needs a
  resolver to do it. A changeset cannot hold a resolver, so it enforces what it
  can — an absolute http(s) URL with a host — and the context runs the guard
  before this is ever called. A URL that passes this and fails the guard is a
  422 naming the real reason; a URL that fails this is a 422 naming a typo.
  """
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :description, :status])
    |> put_account(attrs)
    |> validate_required([:url, :account_id])
    |> validate_url()
    |> validate_length(:url, max: @max_url_length)
    |> validate_length(:description, max: @max_description_length)
    |> unique_constraint(:url, name: :webhook_endpoints_account_id_url_index)
  end

  @doc """
  The changeset for changing an endpoint.

  Casts the same fields and never the secret: changing a description must not
  rotate the customer's signing key, because every consumer verifies with the
  secret they were handed at creation.
  """
  def update_changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:url, :description, :status])
    |> validate_url()
    |> validate_length(:url, max: @max_url_length)
    |> validate_length(:description, max: @max_description_length)
    |> unique_constraint(:url, name: :webhook_endpoints_account_id_url_index)
  end

  defp put_account(changeset, attrs) do
    case Map.get(attrs, :account_id) || Map.get(attrs, "account_id") do
      nil -> changeset
      account_id -> put_change(changeset, :account_id, account_id)
    end
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

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case url do
        url when is_binary(url) -> validate_absolute(url)
        _not_a_string -> [url: "is invalid"]
      end
    end)
  end

  defp validate_absolute(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        []

      _other ->
        [url: "is not an absolute http(s) url"]
    end
  end
end
