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
  * The chart has an Ingress — the way in — gated on `ingress.enabled`
    and off by default, with the traefik edge and the cluster's
    `letsencrypt-prod` issuer named in values. W81 landed the Ingress in
    the generator after W85 generated this chart, so the chart had to be
    brought forward to match.

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

  describe "the ingress" do
    test "exists — the chart's way in, which W81 added to the generator after W85 generated this chart" do
      assert File.exists?(Path.join(@chart_dir, "templates/ingress.yaml"))
    end

    test "is gated on ingress.enabled — an ungated Ingress is always-on" do
      ingress = read_file("templates/ingress.yaml")

      # The guard is there.
      assert ingress =~ ~r/\{\{- if \.Values\.ingress\.enabled \}\}/

      # It precedes any apiVersion, so the whole document is inside the
      # gate — with the knob off, `helm template` emits no Ingress at all.
      assert ingress =~ ~r/\{\{- if \.Values\.ingress\.enabled \}\}\n.*apiVersion: networking\.k8s\.io\/v1/m

      # And the gate closes the document.
      assert ingress =~ ~r/\{\- end \}\}\s*$/
    end

    test "refuses to render an enabled Ingress with no host — a silent misroute" do
      ingress = read_file("templates/ingress.yaml")

      # An enabled Ingress with no host fails the render rather than
      # misrouting — the class of defect kit's /up healthcheck was.
      assert ingress =~ ~r/\{\{- if not \.Values\.ingress\.host \}\}/
      assert ingress =~ ~r/\{\{- fail /
    end

    test "carries the generator's values block — off by default, traefik edge, the cluster's issuer" do
      values = read_file("values.yaml")

      # Off by default: the substrate's first sync happens before any
      # operator has set a host, and a chart that suddenly routes
      # traffic is a defect.
      assert values =~ ~r/^ingress:\n  enabled: false$/m

      # The edge is Traefik, k3s's default ingress controller
      # (DEPLOYMENT.md).
      assert values =~ ~r/^  className: traefik$/m

      # The ClusterIssuer the substrate's install creates once per
      # cluster (kit step 7) — the chart names it and never creates it.
      assert values =~ ~r/^  clusterIssuer: letsencrypt-prod$/m
    end

    test "wires the Ingress's ingressClassName from the traefik value" do
      ingress = read_file("templates/ingress.yaml")
      values = read_file("values.yaml")

      # The template takes the class from the value, so the Ingress and
      # the values cannot disagree about the edge.
      assert ingress =~ ~r/ingressClassName: \{\{ \.Values\.ingress\.className \}\}/
      assert values =~ ~r/^  className: traefik$/m
    end
  end
end
