defmodule Courier.SendingDomains.Dns do
  @moduledoc """
  The resolver seam the sending-domain verification goes through.

  A behaviour rather than a direct `:inet_res` call for the same reason
  `Courier.Webhooks.Dns` exists: the proof is a DNS ANSWER, so a test that
  cannot control the answer cannot test the proof. The attack this one guards
  against is not SSRF but a false positive — a domain marked verified on a
  record set the tenant does not control — and the only way to make that
  impossible to test is to make the records injectable.

  The contract is deliberately the two record types the proof needs, and
  nothing else: MX (the inbound route) and TXT (the SPF and DKIM records).
  A resolver that can answer those two questions can verify a Cloudflare
  Email Sending onboarding; a resolver that can answer more is not one this
  module has a use for.

  Answers are normalised at this boundary — MX as `{preference, exchange}`
  with the exchange lowercased and trailing-dot-free, TXT as a list of
  strings — so the proof in `Courier.TenantSendingDomains` compares values
  and never has to know what `:inet_res` calls a record.
  """

  @typedoc "One MX answer: the preference and the exchange host, normalised."
  @type mx_record :: {preference :: integer(), exchange :: String.t()}

  @typedoc "One TXT answer, as a string."
  @type txt_record :: String.t()

  @doc """
  Every MX record `domain` publishes, or why the lookup failed.

  A name that exists and publishes no MX records is `{:ok, []}` — the proof
  treats that as a mismatch, not as a failure, because "the domain has no
  inbound route" and "the lookup broke" are different facts with different
  remedies.
  """
  @callback mx(domain :: String.t()) :: {:ok, [mx_record()]} | {:error, term()}

  @doc """
  Every TXT record `domain` publishes, or why the lookup failed.

  Same contract as `mx/1`, and the same reason the empty list is not an
  error: the proof is looking for specific records, and their absence is the
  answer it needs.
  """
  @callback txt(domain :: String.t()) :: {:ok, [txt_record()]} | {:error, term()}
end
