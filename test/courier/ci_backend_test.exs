defmodule Courier.CIBackendTest do
  @moduledoc """
  The CI backend switch names a backend kit ships, and it is reachable.


  `ci/backend` is the one-line switch kit's `backends/README.md` defines:
  `instabox` runs the pipeline in a sandbox, `github-actions` keeps
  `ci/ci.yml` as the runner. A value kit does not ship is a
  pipeline no backend will ever pick up — the tree would report green on a
  runner that never ran it. This test reads that file and asserts the value is
  one of the two backends kit's table names, so the failure mode is a red test
  naming the unknown backend rather than a silent no-run.


  `use ExUnit.Case`, not `Courier.DataCase`. The subject is a file on disk and
  nothing here touches `Courier.Repo`, so this belongs to the no-database tier.
  """

  use ExUnit.Case, async: true

  @shipped_backends ~w(github-actions instabox)

  @backend_path "ci/backend"

  test "ci/backend names a backend kit ships" do
    backend = File.read!(@backend_path) |> String.trim()

    assert backend in @shipped_backends,
           "ci/backend names #{inspect(backend)}, which is not one of " <>
             "the backends kit ships (#{Enum.join(@shipped_backends, ", ")}). " <>
             "A backend nothing runs is a pipeline that never executes."
  end
end
