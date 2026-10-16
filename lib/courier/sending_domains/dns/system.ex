defmodule Courier.SendingDomains.Dns.System do
  @moduledoc """
  The resolver courier ships: `:inet_res.resolve/3`, and nothing else.

  `:inet_res` is OTP's own DNS client — no dependency, no socket library, no
  second resolver dialect in the fleet. It answers MX as
  `{preference, exchange}` and TXT as a list of strings, both off the
  `#dns_rr.data` field, and both are normalised by this module so the proof
  compares values.

  ## The return shape, measured rather than remembered

  `:inet_res.resolve/3` answers `{:ok, {dns_rec, header, query, answers,
  authority, additional}}` — the answers are the FOURTH element of the inner
  tuple, and each is a `#dns_rr{}` record whose `data` field (element 7) is
  the payload. Measured on OTP 29.1.1 against a real resolver:

      {ok,{dns_rec,{dns_header,...},
           [{dns_query,"protonmail.ch",mx,in,false}],
           [{dns_rr,"protonmail.ch",mx,in,0,1200,{5,"mail.protonmail.ch"},...}],
           [],[]}}

  The record is reached with `:erlang.element/2` rather than an Elixir record
  match because the `dns_rr` fields are positional and an extract-and-defrecord
  in a hot path is ceremony the proof does not need.

  ## What a lookup failure means here

  `:inet_res` answers `{:error, reason}` for a name that does not resolve, a
  resolver that is unreachable, and a response it cannot parse. All of them
  are `{:error, _}` to the proof, and the proof treats them as "the domain
  could not be proven" — never as "the domain is fine". A verification that
  could pass on a broken resolver is a verification that proves nothing.
  """

  @behaviour Courier.SendingDomains.Dns

  # The `#dns_rr{}` field positions in OTP 29's `inet_dns.hrl`: domain, type,
  # class, cnt, ttl, data, tm, bm, func. `data` is the sixth field after the
  # record name, i.e. element 7 of the tuple.
  @dns_rr_data 7

  @impl Courier.SendingDomains.Dns
  def mx(domain), do: resolve(domain, :mx)

  @impl Courier.SendingDomains.Dns
  def txt(domain), do: resolve(domain, :txt)

  defp resolve(domain, type) when is_binary(domain) do
    case :inet_res.resolve(String.to_charlist(String.trim_trailing(domain, ".")), :in, type) do
      {:ok, {_rec, _header, _query, answers, _authority, _additional}} ->
        {:ok, parse(answers, type)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # MX: `data` is `{Prefer, Exchange}`, both charlists. The exchange is
  # normalised the same way the schema normalises a domain — lowercased,
  # trailing dot removed — because the proof compares it against a literal
  # and `route1.mx.cloudflare.net.` is not the same string as
  # `route1.mx.cloudflare.net`.
  defp parse(answers, :mx) do
    Enum.map(answers, fn rr ->
      {preference, exchange} = :erlang.element(@dns_rr_data, rr)
      {preference, exchange |> to_string() |> String.downcase() |> String.trim_trailing(".")}
    end)
  end

  # TXT: `data` is a list of charlists (one per string in the record). Each
  # becomes a string; the proof searches them by content.
  defp parse(answers, :txt) do
    Enum.flat_map(answers, fn rr ->
      :erlang.element(@dns_rr_data, rr) |> Enum.map(&to_string/1)
    end)
  end
end
