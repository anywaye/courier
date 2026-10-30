defmodule Courier.Webhooks.Signature do
  @moduledoc """
  The Standard Webhooks signature, byte for byte as
  `reference/standard-webhooks/spec/standard-webhooks.md` specifies it.

  PLAN.md §7 adopted the spec for courier's outbound webhooks and said "No
  custom scheme", so this module has no opinions of its own. Every name, every
  delimiter, and every encoding below is the spec's:

  | what | spec section | value |
  | ---- | ------------ | ----- |
  | base string | §Signature scheme | `msg_id.timestamp.payload` — "the message's: ID, timestamp and body are concatenated (delimited by full-stops)" |
  | algorithm | §Signature scheme, symmetric row | `HMAC-SHA256` |
  | signature identifier | §Signature scheme, symmetric row | `v1` |
  | serialized signature | §Signature scheme | `v1,<base64>`, space-delimited when there is more than one |
  | secret serialization | §Signature scheme, symmetric row | `whsec_` + base64, random, 24–64 bytes |
  | headers | §Webhook headers | `webhook-id`, `webhook-timestamp`, `webhook-signature` |

  Two rules from the spec are load-bearing and easy to break:

    * **The bytes that are sent are the bytes that are signed.** The spec warns
      at §Signature scheme that "even a stray space can cause the signature to be
      invalid", so this module signs a `payload` binary the caller already has,
      and never a term it re-encodes for its own convenience. `headers/4` takes
      the same binary the sender puts on the wire.
    * **Neither the id nor the timestamp may contain a full stop.** The spec says
      so directly: a `.` in the id would let a caller append fields to the base
      string. `new_id/0` generates ids that cannot, and the verifier refuses an
      id that does.

  `Courier.Webhooks.Verifier` is the other half: what a consumer of a courier
  webhook runs, kept next to the signer so the two cannot drift.
  """

  @secret_prefix "whsec_"
  @version "v1"
  @digest :sha256

  @secret_bytes 32

  @id_prefix "msg_"

  @typedoc "A serialized signing secret: `whsec_` followed by base64 key bytes."
  @type secret :: String.t()

  @typedoc "The three headers the spec defines, and nothing else."
  @type headers :: %{optional(String.t()) => String.t()}

  @doc """
  Signs `payload` and returns the spec's serialized form: `v1,<base64>`.

  The HMAC key is the *decoded* bytes behind the `whsec_` prefix, which is what
  the spec's secret serialization means and what every reference library does
  with the secret it is handed.
  """
  @spec sign(secret(), String.t(), String.t() | integer(), binary()) :: String.t()
  def sign(secret, msg_id, timestamp, payload)
      when is_binary(payload) and (is_binary(timestamp) or is_integer(timestamp)) do
    timestamp = to_string(timestamp)

    "#{@version},#{encode(secret, base_string(msg_id, timestamp, payload))}"
  end

  @doc """
  The exact string the spec signs: `msg_id.timestamp.payload`.
  """
  @spec base_string(String.t(), String.t(), binary()) :: binary()
  def base_string(msg_id, timestamp, payload) do
    "#{msg_id}.#{timestamp}.#{payload}"
  end

  @doc """
  The three headers, and only the three headers.

  Same argument order as `sign/4` and the spec's own ordering of the three
  things being signed: the id, then the timestamp of the attempt, then the body.
  """
  @spec headers(secret(), String.t(), String.t() | integer(), binary()) :: headers()
  def headers(secret, msg_id, timestamp, payload) do
    timestamp = to_string(timestamp)

    %{
      "webhook-id" => msg_id,
      "webhook-timestamp" => timestamp,
      "webhook-signature" => sign(secret, msg_id, timestamp, payload)
    }
  end

  @doc """
  The three headers stamped with the current time.

  The spec's §Webhook headers is explicit that `webhook-timestamp` is "the
  timestamp of the attempt", not the time of the event: "Every time an attempt is
  retried the timestamp of the attempt is updated, while the timestamp of the
  original event remains the same." So the body may carry the event's own
  `time` and the header still says when this request went out.
  """
  @spec headers_now(secret(), String.t(), binary()) :: headers()
  def headers_now(secret, msg_id, payload) do
    headers(secret, msg_id, unix_now(), payload)
  end

  @doc """
  A fresh signing secret in the spec's serialization.

  The secret is a `whsec_` string because the spec asks for that serialization
  "to ensure keys are used as expected" and "to have a unique and consistent
  secret format"; it is also what a customer pastes into an official verifier.
  """
  @spec generate_secret() :: secret()
  def generate_secret do
    @secret_prefix <> Base.encode64(:crypto.strong_rand_bytes(@secret_bytes))
  end

  @doc """
  A fresh message id, prefixed `msg_` as the spec's examples are.

  Drawn from `:crypto.strong_rand_bytes/1` and base64url-encoded, so an id is
  unique, opaque, and — because base64url has no `.` — incapable of injecting a
  delimiter into the base string.
  """
  @spec new_id() :: String.t()
  def new_id do
    @id_prefix <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @doc """
  The HMAC key behind a serialized `whsec_` secret.

  Raises rather than returning a fallback: a secret that cannot be decoded is a
  secret that would sign with the wrong bytes, and a signature no consumer can
  verify is worse than a loud failure at the one place the secret is read.
  """
  @spec sign_key(secret(), String.t()) :: binary()
  def sign_key(<<"whsec_", encoded::binary>>, version) when version == @version do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) > 0 ->
        key

      _other ->
        raise ArgumentError, "webhook signing secret is not base64 after the whsec_ prefix"
    end
  end

  def sign_key(other, _version) do
    raise ArgumentError,
          "webhook signing secret must start with #{inspect(@secret_prefix)}, got: #{inspect(other)}"
  end

  @doc """
  Now, in the whole seconds the spec's `webhook-timestamp` is defined in.
  """
  @spec unix_now() :: integer()
  def unix_now, do: System.system_time(:second)

  defp encode(secret, base_string) do
    :hmac
    |> :crypto.mac(@digest, sign_key(secret, @version), base_string)
    |> Base.encode64()
  end
end
