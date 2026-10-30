defmodule Courier.HealthTest do
  @moduledoc """
  The readiness check is the one place a probe is allowed to touch the database,
  and it is called from a request path that must never raise. These tests pin
  both halves: it reports `:ok` when the database answers, and it never lets an
  exception escape.
  """

  use Courier.DataCase, async: true

  alias Courier.Health

  test "ready?/0 reports :ok when the database answers a query" do
    assert :ok == Health.ready?()
  end

  test "ready?/1 reports :ok for the running repo" do
    assert :ok == Health.ready?(Courier.Repo)
  end

  test "ready?/1 never raises — a repo that is not running comes back as an error tuple" do
    assert {:error, _reason} = Health.ready?(NotARunningRepo)
  end
end
