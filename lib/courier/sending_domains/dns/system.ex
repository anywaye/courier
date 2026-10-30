defmodule Courier.SendingDomains.Dns.System do
  @moduledoc """
  The resolver courier ships: `:inet_res.resolve/3`, and nothing else.

  `:inet_res` is OTP's own DNS client — no dependency, no socket library, no
  second resolver dialect in the fleet. It answers MX as
  `{preference, exchange}` and TXT as a list of strings, both off the
  `
  compares values.


  `:inet_res.resolve/3` answers `{:ok, {dns_rec, header, query, answers,
  authority, additional}}` — the answers are the FOURTH element of the inner
  tuple, and each is a `
  the payload. Measured on OTP 29.1.1 against a real resolver:

      {ok,{dns_rec,{dns_header,...},
           [{dns_query,"protonmail.ch",mx,in,false}],
           [{dns_rr,"protonmail.ch",mx,in,0,1200,{5,"mail.protonmail.ch"},...}],
           [],[]}}

  The record is reached with `:erlang.element/2` rather than an Elixir record
  match because the `dns_rr` fields are positional and an extract-and-defrecord
  in a hot path is ceremony the proof does not need.


  `:inet_res` answers `{:error, reason}` for a name that does not resolve, a
  resolver that is unreachable, and a response it cannot parse. All of them
  are `{:error, _}` to the proof, and the proof treats them as "the domain
  could not be proven" — never as "the domain is fine". A verification that
  could pass on a broken resolver is a verification that proves nothing.
  """

  @behaviour Courier.SendingDomains.Dns

  @dns_rr_data 7

  @impl Courier.SendingDomains.Dns
  def mx(domain), do: resolve(domain, :mx)

  @impl Courier.SendingDomains.Dns
  def txt(domain), do: resolve(domain, :txt)

  defp resolve(domain, type) when is_binary(domain) do
    case inet_res().resolve(String.to_charlist(String.trim_trailing(domain, ".")), :in, type) do
      {:ok, {_rec, _header, _query, answers, _authority, _additional}} ->
        {:ok, parse(answers, type)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp inet_res do
    Application.get_env(:courier, :sending_domain_inet_res, :inet_res)
  end

  @doc false
  def parse_records(answers, type) when type in [:mx, :txt], do: parse(answers, type)

  defp parse(answers, :mx) do
    Enum.map(answers, fn rr ->
      {preference, exchange} = :erlang.element(@dns_rr_data, rr)
      {preference, exchange |> to_string() |> String.downcase() |> String.trim_trailing(".")}
    end)
  end

  defp parse(answers, :txt) do
    Enum.flat_map(answers, fn rr ->
      :erlang.element(@dns_rr_data, rr) |> Enum.map(&to_string/1)
    end)
  end
end
