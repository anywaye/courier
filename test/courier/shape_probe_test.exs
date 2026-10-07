defmodule CourierWeb.ShapeProbeTest do
  use Courier.DataCase, async: false

  alias Courier.Repo

  test "transaction shapes" do
    IO.inspect(Repo.transaction(fn -> {:ok, 1} end), label: "T-OK")
    IO.inspect(Repo.transaction(fn -> Repo.rollback(:x) end), label: "T-ROLLBACK")

    IO.inspect(Repo.transaction(fn -> Repo.transaction(fn -> {:ok, 2} end) end),
      label: "T-NEST-OK"
    )

    IO.inspect(Repo.transaction(fn -> Repo.transaction(fn -> Repo.rollback(:y) end) end),
      label: "T-NEST-ROLLBACK"
    )

    IO.inspect(Repo.transaction(fn -> {:error, :e} end), label: "T-ERR-RETURN")
  end
end
