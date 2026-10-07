defmodule Courier.ShapeProbe2Test do
  use Courier.DataCase, async: false

  alias Courier.IdempotencyKey
  alias Courier.Repo
  alias Courier.Tenancy

  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @moduletag account: @account

  defp attrs(key) do
    %{
      account_id: @account,
      endpoint: "/probe",
      idempotency_key: key,
      request_hash: "x",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end

  defp insert_then_rollback(attrs) do
    Repo.transaction(fn ->
      case %IdempotencyKey{} |> IdempotencyKey.changeset(attrs) |> Repo.insert() do
        {:ok, key} -> {:ok, key}
        {:error, _cs} -> Repo.rollback(:taken)
      end
    end)
  end

  test "hand-rolled nesting" do
    key = Ecto.UUID.generate()

    IO.inspect(
      Tenancy.with_account(Repo, @account, fn -> {:ok, insert_then_rollback(attrs(key))} end),
      label: "NEST-FIRST",
      limit: 4
    )

    IO.inspect(
      Tenancy.with_account(Repo, @account, fn -> {:ok, insert_then_rollback(attrs(key))} end),
      label: "NEST-SECOND",
      limit: 4
    )
  end
end
