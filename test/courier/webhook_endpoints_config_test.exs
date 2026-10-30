defmodule Courier.WebhookEndpointsConfigTest do
  @moduledoc """
  The one behaviour of `Courier.WebhookEndpoints` that changes configuration: the
  resolver the SSRF guard checks addresses with.

  The whole point of the guard is that the *answer* is what gets checked, and the
  configured test resolver answers a public address. So the case that matters most
  — a name that resolves to a private address, refused by the context before it
  becomes a row — cannot be written in `Courier.WebhookEndpointsTest`, where every
  hostname resolves somewhere public. It lives here with a resolver that answers
  `10.0.0.5`, and `on_exit` puts the real one back.

  `async: false` because application env is VM-global: while this module holds a
  private-address resolver, an async endpoint test would register a URL against it
  and pass or fail on an answer neither of them asked for.
  """

  use Courier.DataCase, async: false

  alias Courier.TestSupport.TestDns
  alias Courier.WebhookEndpoint
  alias Courier.WebhookEndpoints

  @account_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @moduletag account: @account_id

  setup do
    original = Application.get_env(:courier, :dns_resolver)
    on_exit(fn -> Application.put_env(:courier, :dns_resolver, original) end)
    :ok
  end

  defp resolve_to(answers) do
    Application.put_env(:courier, :dns_resolver, {TestDns, {:canned, answers}})
  end

  defp create(url), do: create(url, @account_id)

  defp create(url, account_id) do
    WebhookEndpoints.create(%{url: url, account_id: account_id})
  end

  defp rows_for(account_id) do
    Repo.aggregate(from(e in WebhookEndpoint, where: e.account_id == ^account_id), :count)
  end

  test "a name that resolves to a private address is refused, and no row is written" do
    resolve_to(["10.0.0.5"])
    account_id = Ecto.UUID.generate()

    assert {:error, :blocked_address} = create("https://rebind.example.com/events", account_id)
    assert rows_for(account_id) == 0
  end

  test "a name that resolves to the metadata service is refused" do
    resolve_to(["169.254.169.254"])
    account_id = Ecto.UUID.generate()

    assert {:error, :blocked_address} = create("https://metadata.example.com/latest/", account_id)
    assert rows_for(account_id) == 0
  end

  test "a name whose answers are mixed is refused" do
    resolve_to(["93.184.216.34", "127.0.0.1"])

    assert {:error, :blocked_address} = create("https://mixed.example.com/events")
  end

  test "a name that does not resolve is refused rather than stored" do
    resolve_to(:nxdomain)
    account_id = Ecto.UUID.generate()

    assert {:error, :dns_failure} = create("https://nowhere.example.com/events", account_id)
    assert rows_for(account_id) == 0
  end

  test "a public name under the same resolver is accepted" do
    resolve_to(["93.184.216.34"])

    assert {:ok, endpoint, _secret} = create("https://hooks.example.com/events")
    assert endpoint.url == "https://hooks.example.com/events"
  end

  test "an update to a hostile url is refused the same way a create is" do
    resolve_to(["93.184.216.34"])
    {:ok, endpoint, _secret} = create("https://hooks.example.com/events")

    resolve_to(["10.0.0.5"])

    assert {:error, :blocked_address} =
             WebhookEndpoints.update(endpoint, %{url: "https://rebind.example.com/events"})

    assert Repo.get!(WebhookEndpoint, endpoint.id).url == "https://hooks.example.com/events"
  end
end
