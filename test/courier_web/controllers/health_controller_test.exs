defmodule CourierWeb.HealthControllerTest do
  @moduledoc """
  Probe endpoints. `async: false` because the database-down cases stop and
  restart `Courier.Repo` under the application supervisor, which is shared
  state for the whole suite.
  """

  use CourierWeb.ConnCase, async: false

  describe "GET /healthz (liveness)" do
    test "returns 200 and the ok status", %{conn: conn} do
      conn = get(conn, ~p"/healthz")

      assert response(conn, 200) == ~s({"status":"ok"})
      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "responds with JSON", %{conn: conn} do
      conn = get(conn, ~p"/healthz")

      assert ["application/json; charset=utf-8" | _] = get_resp_header(conn, "content-type")
    end
  end

  describe "GET /readyz (readiness)" do
    test "returns 200 and the ok status when the database answers", %{conn: conn} do
      conn = get(conn, ~p"/readyz")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "responds with JSON", %{conn: conn} do
      conn = get(conn, ~p"/readyz")

      assert ["application/json; charset=utf-8" | _] = get_resp_header(conn, "content-type")
    end
  end

  describe "when the database is down" do
    setup do
      :ok = Supervisor.terminate_child(Courier.Supervisor, Courier.Repo)
      on_exit(&restart_repo/0)
      :ok
    end

    test "GET /readyz returns 503 with JSON naming the failed check", %{conn: conn} do
      conn = get(conn, ~p"/readyz")

      assert json_response(conn, 503) == %{
               "status" => "error",
               "checks" => %{"database" => "unavailable"}
             }
    end

    test "GET /readyz does not leak the database error to the client", %{conn: conn} do
      conn = get(conn, ~p"/readyz")

      refute conn.resp_body =~ ~r/ecto|repo|connect|refus|timeout|nxdomain|enoent|postgres/i
    end

    test "GET /healthz still returns 200 — liveness must not depend on the database", %{
      conn: conn
    } do
      conn = get(conn, ~p"/healthz")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end
  end

  defp restart_repo do
    {:ok, _pid} = Supervisor.restart_child(Courier.Supervisor, Courier.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Courier.Repo, :manual)
    :ok
  end
end
