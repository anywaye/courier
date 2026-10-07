defmodule CourierWeb.ScopeDebugTest do
  use Courier.DataCase, async: false

  alias Courier.Idempotency
  alias Courier.Repo
  alias Courier.Tenancy

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @moduletag account: @account

  test "debug outer around claim" do
    key = Ecto.UUID.generate()
    attrs = %{account_id: @account, endpoint: "/", idempotency_key: key, request_hash: "x"}

    IO.inspect(Idempotency.claim(attrs), label: "CLAIM-FIRST", limit: 4)
    IO.inspect(Idempotency.claim(attrs), label: "CLAIM-SECOND", limit: 4)

    IO.inspect(
      Tenancy.with_account(Repo, @account, fn -> {:ok, Idempotency.claim(attrs)} end),
      label: "OUTER-THIRD",
      limit: 5
    )

    IO.inspect(Tenancy.current_account_id(Repo), label: "GUC-AFTER")
  end
end
