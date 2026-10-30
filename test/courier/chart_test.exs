defmodule Courier.ChartTest do
  @moduledoc """
  courier's Helm chart is a real deploy artifact, and its content is the
  contract the substrate's `Application` pulls.


  The chart at `chart/` is the deploy artifact for the anywaye launch
  stack — the Argo `Application` in
  `kit/templates/substrate/manifests/applications/courier.yaml` names
  `oci://ghcr.io/anywaye/charts` chart `courier` targetRevision `0.1.0`,
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


  The chart above is only the pull half. The push half is
  `ci/publish.yml` — kit's caller template
  (`kit/templates/publish/publish.yml`) copied verbatim: one `uses:` of
  kit's composed `publish.reusable.yml`, which builds and pushes the image
  `config/deploy.yml` deploys and packages and pushes this chart. The
  composition lives in kit (W84); a caller that inlines the steps has forked
  it, and the fork is the drift kit exists to prevent. So the test asserts
  the facts that make the loop work, not that a file exists:

  * the caller calls `anywaye/kit/ci/publish.reusable.yml@master`
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


  The secret-reference assertion is paired with the presence of the
  `secretName` value and the `envFrom` wiring in the deployment
  template, because a boundary that deletes everything passes every
  "deletes nothing" test.


  `use ExUnit.Case`, not `Courier.DataCase`. Every claim here is about
  files on disk, so this belongs to the no-database tier — and a chart
  that could only be checked against a running postgres would be one
  a database-less runner silently skips.
  """

  use ExUnit.Case, async: true

  @repo_root Path.join(__DIR__, "../..")
  @chart_dir Path.join(@repo_root, "chart")
  @workflow_path Path.join(@repo_root, "ci/publish.yml")

  @target_revision "0.1.0"

  defp read_file(path) do
    Path.join(@chart_dir, path) |> File.read!()
  end

  defp workflow do
    File.read!(@workflow_path)
  end

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

  defp chart_dir(inputs) do
    case inputs do
      %{"chart-dir" => dir} -> dir
      %{} -> "chart/"
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  @committed_digest "sha256:fcdc20752f78d9d49047f4f2ec4948ea1cabcb94df1e7ea81704e594207714d0"

  defp helm_template(args \\ []) do
    {output, status} =
      System.cmd("helm", ["template", "courier", @chart_dir] ++ args, stderr_to_stdout: true)

    {output, status}
  end

  defp capture_digest(values_yaml) do
    case Regex.run(~r/^  digest: "?([^"\s]+)"?$/m, values_yaml) do
      [_, digest] -> digest
      _ -> nil
    end
  end

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
      assert uses(workflow()) == "anywaye/kit/ci/publish.reusable.yml@master"
    end

    test "grants packages: write — a reusable workflow can request a permission but cannot grant itself one" do
      grants = block(workflow(), "permissions:")

      assert "packages: write" in grants

      assert "contents: read" in grants
    end

    test "passes push: true — the reusable workflows default to false, so a caller that omits it publishes nothing and says nothing" do
      assert with_block(workflow())["push"] == "true"
    end

    test "the chart directory it names holds Chart.yaml at the version the substrate's Application pulls" do
      dir = chart_dir(with_block(workflow()))
      chart_path = Path.join([@repo_root, dir, "Chart.yaml"])
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

      assert deployment =~ ~r/envFrom:/
      assert deployment =~ ~r/secretRef:/

      assert values =~ ~r/^secretName: courier-secrets$/m

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

      assert deployment =~ ~r/containerPort: 4000/

      assert values =~ ~r/^  port: 4000$/m
    end
  end

  describe "the generated Application template" do
    test "is absent — the substrate owns courier's Application" do
      refute File.exists?(Path.join(@chart_dir, "templates/application.yaml"))
    end
  end

  describe "the ingress" do
    test "exists — the chart's way in, which W81 added to the generator after W85 generated this chart" do
      assert File.exists?(Path.join(@chart_dir, "templates/ingress.yaml"))
    end

    test "is gated on ingress.enabled — an ungated Ingress is always-on" do
      ingress = read_file("templates/ingress.yaml")

      assert ingress =~ ~r/\{\{- if \.Values\.ingress\.enabled \}\}/

      assert ingress =~
               ~r/\{\{- if \.Values\.ingress\.enabled \}\}\n.*apiVersion: networking\.k8s\.io\/v1/ms

      assert ingress =~ ~r/\{\- end \}\}\s*$/
    end

    test "refuses to render an enabled Ingress with no host — a silent misroute" do
      ingress = read_file("templates/ingress.yaml")

      assert ingress =~ ~r/\{\{- if not \.Values\.ingress\.host \}\}/
      assert ingress =~ ~r/\{\{- fail /
    end

    test "carries the generator's values block — off by default, traefik edge, the cluster's issuer" do
      values = read_file("values.yaml")

      assert values =~ ~r/^ingress:\n  enabled: false$/m

      assert values =~ ~r/^  className: traefik$/m

      assert values =~ ~r/^  clusterIssuer: letsencrypt-prod$/m
    end

    test "wires the Ingress's ingressClassName from the traefik value" do
      ingress = read_file("templates/ingress.yaml")
      values = read_file("values.yaml")

      assert ingress =~ ~r/ingressClassName: \{\{ \.Values\.ingress\.className \}\}/
      assert values =~ ~r/^  className: traefik$/m
    end
  end

  describe "the image digest — the one that reaches the pod" do

    test "commits a digest that is sha256:<64 hex> and equal to the registry's current image" do
      values = read_file("values.yaml")
      digest = capture_digest(values)

      assert digest == @committed_digest

      assert digest =~ ~r/^sha256:[0-9a-f]{64}$/
    end

    test "renders repository@digest when a digest is committed" do
      {rendered, status} = helm_template()
      assert status == 0, "helm template failed: #{rendered}"
      assert rendered =~ ~s(image: "ghcr.io/anywaye/courier@#{@committed_digest}")
      refute rendered =~ ~s(image: "ghcr.io/anywaye/courier:0.1.0")
    end

    test "renders repository:tag when the digest is empty — the fresh-clone path before the first publish" do
      {rendered, status} = helm_template(["--set", "image.digest="])
      assert status == 0, "helm template with empty digest failed: #{rendered}"
      assert rendered =~ ~s(image: "ghcr.io/anywaye/courier:0.1.0")
      refute rendered =~ ~s(image: "ghcr.io/anywaye/courier@sha256:)
    end

    test "a malformed digest is refused — it must not render repository@not-a-digest" do

      for bad <- ["not-a-digest", "sha256:zzzz"] do
        {output, status} = helm_template(["--set", "image.digest=#{bad}"])

        assert status != 0,
               "helm template should refuse digest #{inspect(bad)}, but rendered: #{output}"

        assert output =~ "image.digest",
               "the refusal for #{inspect(bad)} does not name the field: #{output}"

        assert output =~ bad,
               "the refusal for #{inspect(bad)} does not name the value it refused: #{output}"
      end
    end

    test "keeps the committed-tag path in values.yaml — a fresh clone with no digest renders exactly as today" do
      values = read_file("values.yaml")

      assert values =~ ~r/^  tag: "0\.1\.0"$/m

      deployment = read_file("templates/deployment.yaml")
      assert deployment =~ ".Values.image.digest"
      assert deployment =~ ".Values.image.repository"
      assert deployment =~ ".Values.image.tag"
    end

    test "the Deployment template carries the digest-conditional and its refusal" do
      deployment = read_file("templates/deployment.yaml")

      assert deployment =~ ~r/\{\{- if \.Values\.image\.digest \}\}/

      assert deployment =~
               ~r/image: "\{\{ \.Values\.image\.repository \}\}@\{\{ \.Values\.image\.digest \}\}"/

      assert deployment =~
               ~r/image: "\{\{ \.Values\.image\.repository \}\}:\{\{ \.Values\.image\.tag \}\}"/

      assert deployment =~ ~r/regexMatch.*sha256:\[0-9a-f\]\{64\}/
      assert deployment =~ ~r/\{\{- fail/
    end
  end
end
