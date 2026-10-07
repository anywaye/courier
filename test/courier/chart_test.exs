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

  ## The publish loop, and why the caller is asserted too

  The chart above is only the pull half. The push half is
  `.github/workflows/publish.yml` — kit's caller template
  (`kit/templates/publish/publish.yml`) copied verbatim: one `uses:` of
  kit's composed `publish.reusable.yml`, which builds and pushes the image
  `config/deploy.yml` deploys and packages and pushes this chart. The
  composition lives in kit (W84); a caller that inlines the steps has forked
  it, and the fork is the drift kit exists to prevent. So the test asserts
  the facts that make the loop work, not that a file exists:

  * the caller calls `cafaye/kit/.github/workflows/publish.reusable.yml@master`
    — there is exactly one composition and it is kit's;
  * it grants `packages: write` — a reusable workflow can request a
    permission but cannot grant itself one, and a caller that omits it gets
    a 401 at the push that reads like a wrong password;
  * it passes `push: true` — the reusable workflows default to `push: false`,
    so a caller that omits the input publishes nothing and says nothing;
  * the chart directory it names (the `chart-dir` input, defaulting to the
    reusable workflow's `chart/`) holds a `Chart.yaml` whose `version` is
    `0.1.0` — the OCI tag, and the `targetRevision` the substrate's
    `Application` pins. The chart version IS the tag; a service that bumps
    one and not the other is a service that never deploys.

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
  @workflow_path Path.join(__DIR__, "../../.github/workflows/publish.yml")

  # The substrate's `Application` pins this targetRevision
  # (`kit/templates/substrate/manifests/applications/courier.yaml`). It is a
  # constant here rather than a read of kit's tree: the gate must run where
  # kit is not checked out, and the claim is that the chart's version EQUALS
  # it — the equality is asserted, with both sides named in the failure
  # message, which is stronger than either file agreeing with itself.
  @target_revision "0.1.0"

  defp read_file(path) do
    Path.join(@chart_dir, path) |> File.read!()
  end

  defp workflow do
    File.read!(@workflow_path)
  end

  # One block of the workflow file — the `on:`, `permissions:` or `with:`
  # block — as its trimmed entries. Read by indentation, the way
  # `KamalConfig` reads the two Kamal files: courier has no YAML dependency
  # and adding one is a decision this repository has not made (`AGENTS.md`).
  # A block that is not there raises rather than reading as empty, because
  # an empty set agrees with every other empty set.
  defp block(workflow, key) do
    lines = String.split(workflow, "\n")

    start =
      Enum.find_index(lines, &(String.trim(&1) == key)) ||
        raise "the publish workflow declares no `#{key}` block"

    depth = indent(Enum.at(lines, start))

    lines
    |> Enum.drop(start + 1)
    |> Enum.take_while(&(indent(&1) > depth))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&String.starts_with?(&1, "#"))
  end

  # The job's `with:` block as a map of inputs. `push` and `chart-dir` are
  # the two the publish loop runs on: the reusable workflows default `push`
  # to false and `chart-dir` to `chart/`, so a caller that says nothing
  # publishes nothing from the wrong directory.
  defp with_block(workflow) do
    workflow
    |> block("with:")
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        [key] -> {String.trim(key), nil}
      end
    end)
    |> Enum.reject(fn {key, _} -> key == "" end)
    |> Map.new()
  end

  # The `uses:` value — the workflow this caller calls. Matched on the line
  # itself, so a comment mentioning a workflow (`# uses: …`) cannot satisfy
  # it: a comment is not a call.
  defp uses(workflow) do
    workflow
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*uses:\s*(\S+)\s*$/, line) do
        [_, value] -> value
        _ -> nil
      end
    end) ||
      raise "the publish workflow declares no `uses:`, so it calls nothing — " <>
              "a caller that inlines the steps has forked kit's composition"
  end

  # The directory the caller's `chart-dir:` input names, or the reusable
  # workflow's own default. `chart.reusable.yml` reads the chart's name and
  # version from the `Chart.yaml` in that directory and takes neither as an
  # input, so this is the directory the push actually publishes.
  defp chart_dir(with_block) do
    case with_block do
      %{"chart-dir" => dir} -> dir
      %{} -> "chart/"
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  describe "Chart.yaml" do
    test "names the chart courier at version 0.1.0 — the seam the Application pins" do
      chart_yaml = read_file("Chart.yaml")

      assert chart_yaml =~ ~r/^name: courier$/m
      assert chart_yaml =~ ~r/^version: 0\.1\.0$/m
    end
  end

  describe "the publish workflow" do
    test "exists — the chart and the image are published by nothing until this caller is copied" do
      assert File.exists?(@workflow_path)
    end

    test "triggers on a push to master — a workflow that runs on nothing publishes nothing" do
      on = block(workflow(), "on:")

      assert "push:" in on
      assert "branches: [master]" in on
    end

    test "calls kit's composed publish workflow — a caller that inlines the steps has forked the composition" do
      assert uses(workflow()) == "cafaye/kit/.github/workflows/publish.reusable.yml@master"
    end

    test "grants packages: write — a reusable workflow can request a permission but cannot grant itself one" do
      grants = block(workflow(), "permissions:")

      # The grant that is the caller's to make: omitting it is a 401 at the
      # push that reads like a wrong password rather than like a missing
      # grant.
      assert "packages: write" in grants

      # The checkout's grant, paired so a boundary that deleted every
      # permission does not pass — the same rule the secret-reference
      # assertion above follows.
      assert "contents: read" in grants
    end

    test "passes push: true — the reusable workflows default to false, so a caller that omits it publishes nothing and says nothing" do
      assert with_block(workflow())["push"] == "true"
    end

    test "the chart directory it names holds Chart.yaml at the version the substrate's Application pulls" do
      dir = chart_dir(with_block(workflow()))
      chart_path = Path.join([@chart_dir, dir, "Chart.yaml"])
      chart_yaml = File.read!(chart_path)

      chart_version =
        chart_yaml
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case Regex.run(~r/^version:\s*(\S+)\s*$/, line) do
            [_, version] -> version
            _ -> nil
          end
        end) ||
          raise "#{chart_path} declares no `version:`. The chart's version is the OCI tag the publish " <>
                  "workflow pushes and the targetRevision the substrate pulls — a Chart.yaml that " <>
                  "does not state one is a chart that publishes nothing."

      assert chart_version == @target_revision,
        "#{chart_path}'s version is #{inspect(chart_version)} and the substrate's Application pins " <>
          "targetRevision #{@target_revision} — the chart version IS the OCI tag, so the two must be " <>
          "equal: a service that bumps one and not the other is a service that never deploys"
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
      # The `s` flag lets `.` span the lines between the guard and the
      # apiVersion (the no-host guard and the fail sit between them).
      assert ingress =~ ~r/\{\{- if \.Values\.ingress\.enabled \}\}\n.*apiVersion: networking\.k8s\.io\/v1/ms

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
