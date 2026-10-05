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

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
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

  # How many endpoint rows exist for one account.
  #
  # Scoped to the tenancy key on purpose. `Repo.aggregate(WebhookEndpoint, :count)`
  # is a claim about every other test in the repository as much as about this one:
  # it is green only while nothing else has ever written a row, and it turns red
  # the instant one is visible — a statement about the order the suite happened to
  # run in, not about `Courier.WebhookEndpoints`. Each test below that asserts
  # "no row was written" mints its own account, so it is counting only what its
  # own call could have written.
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
    # Storing it and finding out later would leave a row courier has to remember
    # is undeliverable; the customer gets the answer at the moment they ask.
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
