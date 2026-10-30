defmodule Courier.UnsubscribeToken do
  @moduledoc """
  One minted one-click unsubscribe token, and the message it belongs to.

  RFC 8058 §3.1 asks for an opaque, hard-to-forge component in the
  `List-Unsubscribe` URI: "The URI SHOULD include an opaque identifier or another
  hard-to-forge component **in addition to, or instead of,** the plaintext names
  of the list and the subscriber." This row is that component, and it holds the
  three facts the unsubscribe needs — which user, which notification type, which
  address — **without the address being derivable from the token**.


  The token is 32 bytes from `:crypto.strong_rand_bytes/1`, URL-safe base64 with
  no padding, and it exists in exactly two places: the `List-Unsubscribe` header
  of the message it was minted for, and the mail client that received it. courier
  stores `:sha256` of it in hex and never the bytes.

  So:

    * **An attacker cannot unsubscribe somebody by guessing.** The space is
      2^256, and RFC 8058 §6 says the same requirement for a different reason —
      "a malicious party sends spam with List-Unsubscribe links for a victim
      list, with the intention of causing list unsubscriptions from the victim
      list as a side effect".
    * **A database dump cannot unsubscribe anybody.** There is nothing in this
      table to replay. This is the same reasoning `identity` uses for its opaque
      tokens and the opposite of `Courier.SecretBox`'s, and the difference is the
      direction of the operation: a webhook signing secret has to be read *back*
      to sign with, and an unsubscribe token never does anything but be looked up.


  No expiry, and that is a decision rather than an omission. The header is read by
  mail clients for as long as somebody keeps the message, and Gmail's requirement
  is that the endpoint *works* — an endpoint that answers 404 for a mail read
  eight months later is a broken deliverability promise, and a clock is how you
  build one by accident. The harm a leaked token does is one address stopping one
  notification type, which is the recipient's own right exercised by somebody
  holding their mail, and it is undone by the `PUT` beside it in
  `/v1/notification_preferences/{user_id}`.

  No `account_id`, and the reason is the same one `Courier.OutboxEvent` gives: a
  send courier makes is addressed to a *user*, and courier does not know which
  account that user is in. An account here would be a guess, and a guess in this
  column is a tenancy claim.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.Suppressions

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type :binary_id

  @token_bytes 32
  @token_length 43
  @digest_length 64

  @doc "The number of random bytes in a token."
  @spec token_bytes() :: pos_integer()
  def token_bytes, do: @token_bytes

  @doc """
  The token courier hands to the message and never keeps: `@token_bytes` random
  bytes in URL-safe base64 with the padding stripped.

  `Base.url_encode64/2` and not `Base.encode64/2` because the value goes in a URL
  path segment, and `+` and `/` in a path segment are a percent-encoding argument
  every mail client and every proxy will have a different opinion about.
  """
  @spec generate() :: String.t()
  def generate do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The digest a token is stored and looked up as.

  **SHA-256 and not a slower KDF**, and the reason is that this is a lookup and
  not a password. A password is verified against a hash an attacker may already
  hold, so the work factor is the defence; here the token is 32 bytes of
  `:crypto.strong_rand_bytes` and nobody hashing a candidate ever has the
  plaintext, so the only property that matters is that the digest cannot be
  inverted or collided — and slowing the endpoint's own lookup down to achieve
  that would be costing the legitimate request to defend against nothing.
  """
  @spec digest(String.t()) :: String.t()
  def digest(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  @doc "The length of a digest, so a test can assert the column is the shape this module writes."
  @spec digest_length() :: pos_integer()
  def digest_length, do: @digest_length

  @doc "The length of a token, for the same reason."
  @spec token_length() :: pos_integer()
  def token_length, do: @token_length

  @type t :: %__MODULE__{}

  schema "unsubscribe_tokens" do
    field :token_digest, :string
    field :user_id, Ecto.UUID
    field :notification_type, :string
    field :email, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for one minted token.

  `token_digest` is put rather than cast: the value comes from
  `Courier.Unsubscribes.issue/3` and there is no reason for a caller to be able to
  choose it, and the same reasoning `Courier.OutboxEvent` applies to `id`.

  `email` is normalised on the way in with the SAME function the send path and
  `Courier.Suppression` use, so a token minted for `Kaka@Example.com` and a send
  addressed to `kaka@example.com` are one mailbox as far as courier is concerned.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :notification_type, :email])
    |> validate_required([:user_id, :notification_type, :email])
    |> put_change(:token_digest, Map.fetch!(attrs, :token_digest))
    |> put_change(:email, Suppressions.normalize(Map.get(attrs, :email)))
    |> validate_type()
    |> validate_email()
    |> unique_constraint(:token_digest)
  end

  defp validate_email(changeset) do
    validate_change(changeset, :email, fn :email, email ->
      if Regex.match?(~r/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/, email),
        do: [],
        else: [email: "is not an email address"]
    end)
  end

  defp validate_type(changeset) do
    validate_change(changeset, :notification_type, fn :notification_type, type ->
      if type in Courier.Notifiers.types(), do: [], else: [notification_type: "is not a notification type"]
    end)
  end
end
