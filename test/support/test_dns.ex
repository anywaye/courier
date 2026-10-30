defmodule Courier.TestSupport.TestDns do
  @moduledoc """
  A DNS resolver that answers from a table the test writes, so SSRF decisions can
  be tested against the attack they exist for without touching the network.

  The attack this stands in for is a public name that answers with a private
  address. Reproducing it for real would mean a name anyone can register, so the
  answers live here:

      Courier.TestSupport.TestDns.resolve({:canned, ["127.0.0.1"]})
      Courier.TestSupport.TestDns.resolve({:canned, []})
      Courier.TestSupport.TestDns.resolve({:canned, :timeout})

  It never calls `:inet`, so a test cannot pass or fail because of what a real
  resolver decided about a real name, and a `{:canned, []}` case says "the name
  does not resolve" rather than "the name under test happens to".
  """

  @behaviour Courier.Webhooks.Dns

  @impl Courier.Webhooks.Dns
  def resolve({:canned, answers}) when is_list(answers) do
    case answers do
      [] -> {:error, :nxdomain}
      answers -> {:ok, answers}
    end
  end

  def resolve({:canned, reason}), do: {:error, reason}
end
