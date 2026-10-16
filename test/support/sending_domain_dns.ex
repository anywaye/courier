defmodule Courier.TestSupport.SendingDomainDns do
  @moduledoc """
  A DNS resolver that answers from a table the test writes, so the sending-domain
  proof can be tested against the record sets it exists for without touching
  the network.

  The proof's attack is a false positive — a domain marked verified on a
  record set the tenant does not control — and the only way to make that
  impossible to test is to make the records injectable. The answers live in
  one named ETS table the test creates, seeds and deletes:

      :ets.insert(Courier.TestSupport.SendingDomainDns.table(),
        {:mx, "cf-bounce.tenant.com"},
        [{1, "route1.mx.cloudflare.net"}, {2, "route2.mx.cloudflare.net"}, {3, "route3.mx.cloudflare.net"}])

      :ets.insert(Courier.TestSupport.SendingDomainDns.table(),
        {:txt, "cf-bounce.tenant.com"},
        ["v=spf1 include:_spf.mail.cloudflare.net ~all"])

  It never calls `:inet_res`, so a test cannot pass or fail because of what a
  real resolver decided about a real name, and an unseeded name says
  `{:error, :nxdomain}` rather than "the name under test happens to".

  The records are returned exactly as seeded — the proof compares values, and
  a double that normalised on the way out would be a second implementation of
  the normalisation the system resolver does, which is the thing the suite
  would then not be checking.
  """

  @behaviour Courier.SendingDomains.Dns

  @table :courier_test_sending_domain_dns

  @doc "The named ETS table the answers live in. Tests create and delete it."
  @spec table() :: atom()
  def table, do: @table

  @impl Courier.SendingDomains.Dns
  def mx(domain), do: lookup(:mx, domain)

  @impl Courier.SendingDomains.Dns
  def txt(domain), do: lookup(:txt, domain)

  defp lookup(type, domain) do
    case :ets.lookup(@table, {type, domain}) do
      [{_key, records}] -> {:ok, records}
      [] -> {:error, :nxdomain}
    end
  end
end
