defmodule Courier.Webhooks.Verifier do
  @moduledoc """
  The consumer's half of the Standard Webhooks scheme: given the raw body, the
  three headers, and the shared secret, say whether the request is authentic and
  fresh.

  courier is a *producer* — nothing here receives webhooks, because billing owns
  inbound (§ "Do NOT build a general-purpose webhook inbound service"). It is
  here because the spec makes verification part of the same contract as signing
  (§Verifying signatures), because PLAN.md §3 says the tests must not assert the
  signer against itself, and because a producer that ships a tolerance but does
  not publish it leaves its consumers to guess the one number that decides
  whether a replay is a replay.

  Three rules, all from spec §Verifying signatures:

    * **Constant-time comparison.** "use a constant time comparison function to
      compare the calculated with the expected signature" — `:crypto.hash_equals/2`,
      never `==` on two signatures.
    * **A timestamp tolerance.** "Make sure to verify the `webhook-timestamp`
      header has a timestamp that is within some allowable tolerance of the
      current timestamp to prevent replay attacks." The spec does not name a
      number; every library in `refs/standard-webhooks/libraries/` uses five
      minutes, and so does this module.
    * **The id is the idempotency key.** The spec calls for it to be used as one;
      this module's job ends at authenticity, and the deduplication is the
      consumer's own row, not ours.

  The order of the answers is deliberate: *missing header* before *malformed
  timestamp* before *out of tolerance* before *mismatch*. A caller should not
  learn a signature is wrong before it has established the request is even
  well-formed, and a clock-skew report is more useful than a mismatch for a
  request whose timestamp is merely wrong.
  """

  alias Courier.Webhooks.Signature

  @version "v1"

  @tolerance 300

  @required_headers ["webhook-id", "webhook-timestamp", "webhook-signature"]

  @doc """
  The replay window, in seconds. Published to consumers; see `@tolerance`.
  """
  @spec tolerance() :: pos_integer()
  def tolerance, do: @tolerance

  @doc """
  Verifies `body` against `headers` with `secret`.

  `body` must be the bytes as received, not a re-serialization of a parsed
  payload: spec §Signature scheme calls re-serializing "a very common failure
  mode". `headers` is a map or keyword list of the three `webhook-` headers; a
  header whose name differs in case is not the spec's header.

  Returns `:ok`, or one of:

    * `{:error, {:missing_header, name}}` — not the spec's three headers
    * `{:error, :malformed_timestamp}` — `webhook-timestamp` is not an integer
    * `{:error, :timestamp_out_of_tolerance}` — outside the ±`tolerance/0` window
    * `{:error, :signature_mismatch}` — well-formed, fresh, and not ours

  An unknown signature identifier in a space-delimited list is skipped rather
  than rejected: the spec's `webhook-signature` "is a space delimited list" so a
  producer can sign with a current and a previous key during a rotation, and the
  list may carry `v1a` entries from a producer that has moved to the asymmetric
  scheme. Neither may stop the `v1` entry beside it from being found.
  """
  @spec verify(binary(), map() | [{String.t(), String.t()}], Signature.secret(), keyword()) ::
          :ok | {:error, term()}
  def verify(body, headers, secret, opts \\ []) when is_binary(body) do
    with {:ok, headers} <- fetch_headers(headers),
         {:ok, id} <- fetch_id(headers),
         {:ok, timestamp} <- fetch_timestamp(headers) do
      case check_tolerance(timestamp, opts) do
        :ok -> check_signatures(body, headers["webhook-signature"], id, timestamp, secret)
        {:error, _reason} = error -> error
      end
    end
  end

  defp fetch_headers(headers) do
    normalized = Map.new(headers)

    case Enum.reject(@required_headers, &Map.has_key?(normalized, &1)) do
      [] -> {:ok, normalized}
      [missing | _rest] -> {:error, {:missing_header, missing}}
    end
  end

  defp fetch_id(headers) do
    case Map.fetch!(headers, "webhook-id") do
      "" <> rest ->
        if String.contains?(rest, ".") do
          {:error, :malformed_id}
        else
          {:ok, rest}
        end

      _empty ->
        {:error, :malformed_id}
    end
  end

  defp fetch_timestamp(headers) do
    case Integer.parse(Map.fetch!(headers, "webhook-timestamp")) do
      {seconds, ""} -> {:ok, seconds}
      _not_an_integer -> {:error, :malformed_timestamp}
    end
  end

  defp check_tolerance(timestamp, opts) do
    tolerance = Keyword.get(opts, :tolerance, @tolerance)
    now = Keyword.get_lazy(opts, :now, &Signature.unix_now/0)
    drift = abs(now - timestamp)

    if drift <= tolerance, do: :ok, else: {:error, :timestamp_out_of_tolerance}
  end

  defp check_signatures(body, header, id, timestamp, secret) do
    base_string = Signature.base_string(id, timestamp, body)

    if Enum.any?(String.split(header, " ", trim: true), &matches?(&1, base_string, secret)) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  defp matches?(@version <> "," <> received, base_string, secret) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, Signature.sign_key(secret, @version), base_string)
      |> Base.encode64()

    :crypto.hash_equals(received, expected)
  end

  defp matches?(_other_identifier, _base_string, _secret), do: false
end
