defmodule Courier.ChartTest do
  @moduledoc """
  courier's Helm chart is a real deploy artifact, and its content is the
  contract the substrate's `Application` pulls.

  ## What this test proves

  The chart at `chart/` is the deploy artifact for the cafaye launch
  stack — the Argo `Application` in
  `kit/templates/substrate/manifests/applications/courier.yaml` names
  `oci://ghcr.io/cafaye/charts` chart `courier` targetRevision `0.1.0`,
  and this chart is what that artifact contains. The test asserts the
  chart's content, not that a file exists:

  * `Chart.yaml`'s `name` and `version` are `courier` and `0.1.0` —
    the seam between the chart and the `Application`'s `targetRevision`.
  * The readiness probe path is `/readyz` — the fleet's contract, baked
    into the template. An Argo/rollout gate that reads `/healthz`
    accepts a container that cannot reach its database.
  * Secrets are referenced by name, never inlined — a credential in
    `values.yaml` is a credential in git.
  * The image tag is not `latest` — a floating tag is a deploy that
    changes when somebody else pushes.

  ## Every absence assertion is paired with a presence one

  The secret-reference assertion is paired with the presence of the
  `secretName` value and the `envFrom` wiring in the deployment
  template, because a boundary that deletes everything passes every
  "deletes nothing" test.

  ## It runs with no database

  `use ExUnit.Case`, not `Courier.DataCase`. Every claim here is about
  files on disk, so this belongs to the no-database tier — and a chart
  that could only be checked against a running postgres would be one
  a database-less runner silently skips.
  """

  use ExUnit.Case, async: true

  @chart_dir Path.join(__DIR__, "../../chart")

  defp read_file(path) do
    Path.join(@chart_dir, path) |> File.read!()
  end

  describe "Chart.yaml" do
    test "names the chart courier at version 0.1.0 — the seam the Application pins" do
      chart_yaml = read_file("Chart.yaml")

      assert chart_yaml =~ ~r/^name: courier$/m
      assert chart_yaml =~ ~r/^version: 0\.1\.0$/m
    end
  end

  describe "the deployment template" do
    test "bakes the readiness probe path as /readyz" do
      deployment = read_file("templates/deployment.yaml")

      assert deployment =~ ~r/path: \/readyz/
    end

    test "references the secret by name via envFrom, never inlines a credential" do
      deployment = read_file("templates/deployment.yaml")
      values = read_file("values.yaml")

      # The wiring: envFrom secretRef is present.
      assert deployment =~ ~r/envFrom:/
      assert deployment =~ ~r/secretRef:/

      # The reference: secretName is a name, not a value.
      assert values =~ ~r/^secretName: courier-secrets$/m

      # The absence: no credential is inlined in values.yaml.
      refute values =~ ~r|DATABASE_URL:\s*ecto://|
      refute values =~ ~r|SECRET_KEY_BASE:\s*[a-zA-Z0-9]{40,}|
      refute values =~ ~r|COURIER_IDENTITY_TOKEN:\s*\S|
      refute values =~ ~r|COURIER_SECRET_BOX_KEY:\s*\S|
      refute values =~ ~r|COURIER_SMTP_PASSWORD:\s*\S|
    end

    test "sets the image tag to a value, never latest" do
      values = read_file("values.yaml")

      assert values =~ ~r/^  tag: "0\.1\.0"$/m
      refute values =~ ~r|tag: latest|
    end
  end

  describe "the service port" do
    test "agrees with the container port the generator baked in" do
      values = read_file("values.yaml")
      deployment = read_file("templates/deployment.yaml")

      # The container port is 4000 (from the Elixir language table).
      assert deployment =~ ~r/containerPort: 4000/

      # The service port must match — a Service that forwards to a
      # different port than the container listens on routes to nothing.
      assert values =~ ~r/^  port: 4000$/m
    end
  end

  describe "the generated Application template" do
    test "is absent — the substrate owns courier's Application" do
      # The generator emits chart/templates/application.yaml, but the
      # substrate already owns courier's Application in
      # kit/templates/substrate/manifests/applications/courier.yaml.
      # Two Applications named `courier` in `argocd` fight each other.
      refute File.exists?(Path.join(@chart_dir, "templates/application.yaml"))
    end
  end
end
