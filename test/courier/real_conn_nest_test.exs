defmodule Courier.RealConnNestTest do
  # Deliberately NOT DataCase/ConnCase: this test needs a REAL connection, not
  # the sandbox's, to decide whether nested-rollback-then-outer-commit is a
  # production property or a sandbox artifact.
  use ExUnit.Case, async: false

  alias Courier.Repo

  @moduletag :real_conn

  test "nested rollback then outer commit on a real connection" do
    {:ok, conn} = Postgrex.start_link(
      hostname: "localhost",
      port: 5432,
      database: "courier_test",
      username: "courier_app",
      password: System.get_env("COURIER_APP_DB_PASSWORD", "postgres")
    )

    try do
      # An inner rollback, then the outer commits.
      result =
        Postgrex.transaction(conn, fn conn ->
          {:ok, _} = Postgrex.query(conn, "SELECT 1", [])

          inner =
            Postgrex.transaction(conn, fn conn ->
              {:ok, _} = Postgrex.query(conn, "SELECT 1", [])
              Postgrex.rollback(conn, :taken)
            end)

          {:outer_continues, inner}
        end)

      IO.inspect(result, label: "REAL-NEST-ROLLBACK")
    after
      GenServer.stop(conn)
    end
  end
end
