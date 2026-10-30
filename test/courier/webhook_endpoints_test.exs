defmodule Courier.WebhookEndpointsTest do
  @moduledoc """
  `webhook_endpoints`: the rows courier signs for. What this file pins down is
  the set of promises the table makes to the rest of the system, because every
  one of them is something a later packet would otherwise have to reverse-engineer
  from a migration.

    * `account_id` is the tenancy key, unique with `url`, and it is never cast
      from a request body
    * the signing secret is generated here, returned once, and stored sealed
    * `status` is two values and nothing else
    * a disabled endpoint is still a row — disabling is not deleting, because
      deleting loses the history a support conversation needs
  """

  use Courier.DataCase, async: true

  alias Courier.WebhookEndpoint
  alias Courier.WebhookEndpoints

  @account_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @other_account_id "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  @moduletag account: @account_id

  defp attrs(overrides \\ %{}) do
    Map.merge(%{url: "https://hooks.example.com/events", account_id: @account_id}, overrides)
  end

  defp create!(overrides \\ %{}) do
    {:ok, endpoint, _secret} = WebhookEndpoints.create(attrs(overrides))
    endpoint
  end

  defp rows_for(account_id) do
    Repo.aggregate(from(e in WebhookEndpoint, where: e.account_id == ^account_id), :count)
  end

  describe "create/1" do
    test "stores the endpoint" do
      endpoint = create!()

      assert endpoint.id
      assert endpoint.url == "https://hooks.example.com/events"
      assert endpoint.account_id == @account_id
      assert endpoint.status == :enabled
      assert %DateTime{time_zone: "Etc/UTC"} = endpoint.inserted_at
    end

    test "generates a secret and hands it back exactly once" do
      {:ok, _endpoint, secret} = WebhookEndpoints.create(attrs())

      assert String.starts_with?(secret, "whsec_")
    end

    test "keeps the description it was given" do
      endpoint = create!(%{description: "production orders"})

      assert endpoint.description == "production orders"
    end

    test "a description is optional" do
      endpoint = create!()

      assert endpoint.description == nil
    end

    test "refuses a url with no scheme, on shape rather than on the guard" do
      assert {:error, changeset} =
               WebhookEndpoints.create(attrs(%{url: "hooks.example.com/events"}))

      assert %{url: ["is not an absolute http(s) url"]} = errors_on(changeset)
    end

    test "refuses a url that is not a string" do
      assert {:error, :invalid_url} = WebhookEndpoints.create(attrs(%{url: 42}))
    end

    test "refuses a url longer than a url can be" do
      long = "https://example.com/" <> String.duplicate("a", 2048)

      assert {:error, changeset} = WebhookEndpoints.create(attrs(%{url: long}))
      assert %{url: ["should be at most 2048 character(s)"]} = errors_on(changeset)
    end

    test "refuses a url with no host" do
      assert {:error, changeset} = WebhookEndpoints.create(attrs(%{url: "https:///events"}))
      assert %{url: ["is not an absolute http(s) url"]} = errors_on(changeset)
    end

    test "refuses an account with no id" do
      assert {:error, changeset} = WebhookEndpoints.create(attrs(%{account_id: nil}))
      assert %{account_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "refuses an account id that is not a uuid" do
      assert {:error, changeset} = WebhookEndpoints.create(attrs(%{account_id: "not-a-uuid"}))
      assert errors_on(changeset).account_id != []
    end

    test "refuses a second endpoint with the same url in the same account" do
      create!()

      assert {:error, changeset} = WebhookEndpoints.create(attrs())
      assert %{url: ["has already been taken"]} = errors_on(changeset)
    end

    test "the same url in another account is a different endpoint" do
      create!()

      assert {:ok, _other, _secret} =
               as_account(@other_account_id, fn ->
                 WebhookEndpoints.create(attrs(%{account_id: @other_account_id}))
               end)
    end

    test "stores nothing when the changeset is rejected" do
      account_id = Ecto.UUID.generate()

      {:error, _changeset} =
        WebhookEndpoints.create(attrs(%{url: 42, account_id: account_id}))

      assert rows_for(account_id) == 0
    end

    test "stores nothing when the url is refused as an SSRF target" do
      account_id = Ecto.UUID.generate()

      assert {:error, :blocked_address} =
               WebhookEndpoints.create(
                 attrs(%{url: "http://169.254.169.254/latest/meta-data/", account_id: account_id})
               )

      assert rows_for(account_id) == 0
    end

    test "the guard runs before the insert, so a refused url never becomes a row" do
      account_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               WebhookEndpoints.create(
                 attrs(%{url: "file:///etc/passwd", account_id: account_id})
               )

      assert errors_on(changeset).url != []
      assert rows_for(account_id) == 0
    end
  end

  describe "get/2" do
    test "returns an endpoint in the account that owns it" do
      endpoint = create!()

      assert WebhookEndpoints.get(endpoint.id, @account_id).id == endpoint.id
    end

    test "returns nothing for an account that does not own it" do
      endpoint = create!()

      assert WebhookEndpoints.get(endpoint.id, @other_account_id) == nil
    end

    test "returns nothing for an id that is not a uuid" do
      assert WebhookEndpoints.get("not-a-uuid", @account_id) == nil
    end

    test "returns nothing for an id that does not exist" do
      assert WebhookEndpoints.get(Ecto.UUID.generate(), @account_id) == nil
    end
  end

  describe "list/1" do
    test "returns the account's own endpoints" do
      mine = create!()
      theirs = create!(%{url: "https://other.example.com/events"})

      assert {:ok, _theirs, _secret} =
               as_account(@other_account_id, fn ->
                 WebhookEndpoints.create(%{
                   url: "https://theirs.example.com/x",
                   account_id: @other_account_id
                 })
               end)

      found = WebhookEndpoints.list(@account_id)

      assert Enum.map(found, & &1.id) == [mine.id, theirs.id]
      refute theirs.id == nil
    end

    test "returns another account's nothing" do
      create!()

      assert WebhookEndpoints.list(@other_account_id) == []
    end

    test "returns an empty list rather than nil when there are none" do
      assert WebhookEndpoints.list(@account_id) == []
    end

    test "includes disabled endpoints, because disabling is not deleting" do
      endpoint = create!()
      {:ok, _disabled} = WebhookEndpoints.update(endpoint, %{status: "disabled"})

      assert [found] = WebhookEndpoints.list(@account_id)
      assert found.status == :disabled
    end

    test "orders by creation, oldest first, so a list reads as a history" do
      first = create!()
      second = create!(%{url: "https://second.example.com/events"})

      assert Enum.map(WebhookEndpoints.list(@account_id), & &1.id) == [first.id, second.id]
    end
  end

  describe "enabled/1" do
    test "returns the account's enabled endpoints" do
      enabled = create!()
      disabled = create!(%{url: "https://off.example.com/events"})
      {:ok, _} = WebhookEndpoints.update(disabled, %{status: "disabled"})

      assert [found] = WebhookEndpoints.enabled(@account_id)
      assert found.id == enabled.id
    end

    test "returns nothing when every endpoint is disabled" do
      endpoint = create!()
      {:ok, _} = WebhookEndpoints.update(endpoint, %{status: "disabled"})

      assert WebhookEndpoints.enabled(@account_id) == []
    end

    test "never returns another account's endpoint" do
      create!()

      assert WebhookEndpoints.enabled(@other_account_id) == []
    end
  end

  describe "update/2" do
    test "changes the url" do
      endpoint = create!()

      assert {:ok, updated} =
               WebhookEndpoints.update(endpoint, %{url: "https://new.example.com/events"})

      assert updated.url == "https://new.example.com/events"
    end

    test "changes the description" do
      endpoint = create!()

      assert {:ok, updated} = WebhookEndpoints.update(endpoint, %{description: "staging"})
      assert updated.description == "staging"
    end

    test "disables and re-enables" do
      endpoint = create!()

      assert {:ok, disabled} = WebhookEndpoints.update(endpoint, %{status: "disabled"})
      assert disabled.status == :disabled

      assert {:ok, enabled} = WebhookEndpoints.update(disabled, %{status: "enabled"})
      assert enabled.status == :enabled
    end

    test "a status that is neither enabled nor disabled is refused" do
      endpoint = create!()

      assert {:error, changeset} = WebhookEndpoints.update(endpoint, %{status: "paused"})
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "leaves the fields it was not given alone" do
      endpoint = create!(%{description: "production"})

      assert {:ok, updated} =
               WebhookEndpoints.update(endpoint, %{url: "https://new.example.com/events"})

      assert updated.description == "production"
    end

    test "keeps the secret across an update" do
      endpoint = create!()
      secret = WebhookEndpoints.plaintext_secret(endpoint)

      assert {:ok, updated} = WebhookEndpoints.update(endpoint, %{description: "renamed"})
      assert WebhookEndpoints.plaintext_secret(updated) == secret
    end

    test "refuses a url another endpoint in the same account already has" do
      create!()
      other = create!(%{url: "https://other.example.com/events"})

      assert {:error, changeset} =
               WebhookEndpoints.update(other, %{url: "https://hooks.example.com/events"})

      assert %{url: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects a url that is not absolute" do
      endpoint = create!()

      assert {:error, changeset} = WebhookEndpoints.update(endpoint, %{url: "nope"})
      assert errors_on(changeset).url != []
    end

    test "leaves the row alone when the update is rejected" do
      endpoint = create!()

      {:error, _changeset} = WebhookEndpoints.update(endpoint, %{url: "nope"})
      assert Repo.get!(WebhookEndpoint, endpoint.id).url == "https://hooks.example.com/events"
    end
  end

  describe "delete/2" do
    test "removes the endpoint" do
      endpoint = create!()

      assert {:ok, _deleted} = WebhookEndpoints.delete(endpoint)
      assert WebhookEndpoints.get(endpoint.id, @account_id) == nil
    end

    test "deleting an endpoint that is already gone is not an error" do
      endpoint = create!()
      {:ok, _} = WebhookEndpoints.delete(endpoint)

      reloaded = Repo.get(WebhookEndpoint, endpoint.id)

      assert reloaded == nil
    end
  end

  describe "failure counting" do
    test "starts at zero for a new endpoint" do
      assert create!().consecutive_failures == 0
    end

    test "records a failure without disabling until the threshold is reached" do
      endpoint = create!()

      assert {:ok, counted} = WebhookEndpoints.trip(endpoint, 5, "connection refused")

      assert counted.status == :enabled
      assert counted.consecutive_failures == 1
      assert counted.disabled_reason == nil
    end

    test "disables with a reason once the threshold is reached" do
      endpoint = create!()

      assert {:ok, tripped} = fail_n_times(endpoint, 5, 5, "connection refused")

      assert tripped.status == :disabled
      assert tripped.consecutive_failures == 5
      assert tripped.disabled_reason == "5 consecutive failures, last: connection refused"
    end

    test "the count survives a disabled endpoint being counted again" do
      endpoint = create!()
      {:ok, tripped} = fail_n_times(endpoint, 5, 5, "boom")

      assert {:ok, tripped} = WebhookEndpoints.trip(tripped, 5, "still broken")
      assert tripped.consecutive_failures == 6
    end

    test "the reason names the count and the last failure, so it reads as an explanation" do
      endpoint = create!()

      {:ok, _} = WebhookEndpoints.trip(endpoint, 5, "connection refused")
      {:ok, _} = WebhookEndpoints.trip(endpoint, 5, "connection refused")
      {:ok, _} = WebhookEndpoints.trip(endpoint, 5, "i/o timeout")
      {:ok, tripped} = WebhookEndpoints.trip(endpoint, 5, "i/o timeout")
      {:ok, tripped} = WebhookEndpoints.trip(tripped, 5, "i/o timeout")

      assert tripped.consecutive_failures == 5
      assert tripped.disabled_reason == "5 consecutive failures, last: i/o timeout"
    end

    test "the count grows even when every call is handed the same stale struct" do
      endpoint = create!()

      for _attempt <- 1..5 do
        assert {:ok, _} = WebhookEndpoints.trip(endpoint, 5, "boom")
      end

      assert Repo.get!(WebhookEndpoint, endpoint.id).consecutive_failures == 5
    end

    defp fail_n_times(endpoint, count, threshold, reason) do
      Enum.reduce(1..count, {:ok, endpoint}, fn _attempt, {:ok, current} ->
        WebhookEndpoints.trip(current, threshold, reason)
      end)
    end

    test "clears the count and the reason when a delivery succeeds" do
      endpoint = create!()
      {:ok, tripped} = WebhookEndpoints.trip(endpoint, 5, "boom")
      {:ok, tripped} = WebhookEndpoints.trip(tripped, 5, "boom again")

      assert {:ok, recovered} = WebhookEndpoints.record_success(tripped)
      assert recovered.consecutive_failures == 0
      assert recovered.status == :enabled
      assert recovered.disabled_reason == nil
    end

    test "a success does not re-enable an endpoint a person turned off" do
      endpoint = create!()
      {:ok, turned_off} = WebhookEndpoints.update(endpoint, %{status: "disabled"})

      assert {:ok, recovered} = WebhookEndpoints.record_success(turned_off)
      assert recovered.status == :disabled
      assert recovered.consecutive_failures == 0
      assert recovered.disabled_reason == nil
    end

    test "a customer re-enabling a tripped endpoint clears courier's reason and count" do
      endpoint = create!()
      {:ok, tripped} = fail_n_times(endpoint, 5, 5, "boom")

      assert tripped.status == :disabled
      assert tripped.disabled_reason != nil

      assert {:ok, enabled} = WebhookEndpoints.update(tripped, %{status: "enabled"})
      assert enabled.status == :enabled
      assert enabled.disabled_reason == nil
      assert enabled.consecutive_failures == 0
    end

    test "a customer toggling their own endpoint keeps courier's count of how it behaves" do
      endpoint = create!()
      {:ok, counted} = WebhookEndpoints.trip(endpoint, 5, "boom")
      assert counted.consecutive_failures == 1

      {:ok, turned_off} = WebhookEndpoints.update(counted, %{status: "disabled"})

      assert {:ok, enabled} = WebhookEndpoints.update(turned_off, %{status: "enabled"})
      assert enabled.status == :enabled
      assert enabled.consecutive_failures == 1
      assert enabled.disabled_reason == nil
    end
  end

  describe "the row itself" do
    test "carries no foreign key to accounts, because courier does not own them" do
      assert %{rows: [[fks]]} =
               Repo.query!("""
               SELECT count(*) FROM information_schema.table_constraints
               WHERE table_name = 'webhook_endpoints' AND constraint_type = 'FOREIGN KEY'
               """)

      assert fks == 0
    end

    test "is unique on account and url, in the database and not only in the changeset" do
      create!()

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.query(
                 "INSERT INTO webhook_endpoints (id, account_id, url, secret, status, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, $3, $4, 'enabled', now(), now())",
                 [
                   Ecto.UUID.dump!(Ecto.UUID.generate()),
                   Ecto.UUID.dump!(@account_id),
                   "https://hooks.example.com/events",
                   "sealed"
                 ]
               )
    end

    test "accepts only the two statuses, enforced by the database too" do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO webhook_endpoints (id, account_id, url, secret, status, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, $3, $4, 'paused', now(), now())",
                 [
                   Ecto.UUID.dump!(Ecto.UUID.generate()),
                   Ecto.UUID.dump!(@account_id),
                   "https://hooks.example.com/events",
                   "sealed"
                 ]
               )
    end

    test "stores the id as a uuid, so one account cannot infer another's volume" do
      endpoint = create!()

      assert {:ok, uuid} = Ecto.UUID.cast(endpoint.id)
      assert uuid == endpoint.id
    end
  end
end
