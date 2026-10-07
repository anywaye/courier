defmodule Courier.Principal.IntrospectionUrlTest do
  @moduledoc """
  Where identity is, and with which key: the two halves of the introspection
  seam, asserted as FILES.

  ## Why this is a file-reading test

  The seam has two facts an operator must get right: the address courier dials
  (`COURIER_IDENTITY_URL`) and the credential it presents
  (`COURIER_IDENTITY_TOKEN`). Both are stated in more than one place —
  `config/runtime.exs`'s default, `Courier.Principal.Introspection.url/0`'s own
  fallback, `docker-compose.yml`, `config/deploy.yml`, the README's operator
  table — and they drifted: four statements of one port, none of them the port
  identity listens on. A wrong port does not degrade mail, it refuses every
  authenticated request, because the resolver is fail-closed by design: the
  symptom is a wall of 503s with nothing in the log pointing at the cause.

  The port is a CONTRACT BETWEEN TWO REPOSITORIES. identity's Dockerfile
  `EXPOSE 8080` and its compose `PORT: "8080"` are the authority; this
  repository's statements of it are the things that must agree with it. So the
  number is pinned here as a literal with its source cited, and the tree is
  grepped for the two wrong values — a corrected string is not a proof, a
  red-then-green agreement test is.

  ## It runs with no database

  `use ExUnit.Case`, not `Courier.DataCase`. Every subject here is a file on
  disk, so this belongs to the no-database tier.
  """

  use ExUnit.Case, async: true

  # identity's own port, and the single authoritative default. The port is
  # identity's fact, measured from its repository: `EXPOSE 8080` in
  # identity/Dockerfile and `PORT: "8080"` in identity/docker-compose.yml.
  # 4000 is courier's own Phoenix port — the copy-paste source of the bug.
  @identity_port 8080
  @runtime_default "http://identity:8080"

  # The two wrong statements this test exists to kill. A tree-wide grep for
  # them, in non-test files, is the honest form of "no second default exists":
  # it catches a wrong value in a file no thought of, which a per-file
  # assertion cannot.
  @wrong_statements ["identity:4000", "localhost:4001"]

  setup_all do
    {:ok,
     runtime: File.read!("config/runtime.exs"),
     introspection: File.read!("lib/courier/principal/introspection.ex"),
     compose: File.read!("docker-compose.yml"),
     deploy: File.read!("config/deploy.yml"),
     readme: File.read!("README.md")}
  end

  describe "the single authoritative default" do
    test "config/runtime.exs defaults COURIER_IDENTITY_URL to identity's port", %{
      runtime: runtime
    } do
      assert default = runtime_identity_url_default(runtime),
             "config/runtime.exs no longer contains " <>
               "System.get_env(\"COURIER_IDENTITY_URL\", \"…\") — this reader " <>
               "under-reads, and a green check over nothing is worse than no check"

      assert default == @runtime_default,
             "config/runtime.exs defaults COURIER_IDENTITY_URL to #{inspect(default)}, " <>
               "expected #{inspect(@runtime_default)}. identity listens on port #{@identity_port} " <>
               "(its Dockerfile EXPOSE 8080, its compose PORT: \"8080\"); 4000 is courier's " <>
               "own Phoenix port."
    end

    test "Courier.Principal.Introspection.url/0's own fallback agrees with it", %{
      introspection: source
    } do
      assert fallback = url_fallback(source),
             "lib/courier/principal/introspection.ex no longer contains " <>
               "def url, do: Application.get_env(:courier, :identity_url, \"…\") — " <>
               "this reader under-reads, and a green check over nothing is worse than no check"

      assert fallback == @runtime_default,
             "Introspection.url/0 falls back to #{inspect(fallback)}, expected " <>
               "#{inspect(@runtime_default)}. A third default that disagrees with " <>
               "runtime.exs is a resolver pointed at a port nobody listens on."
    end

    test "and the configured value in this environment states the same port" do
      # The "configured" half of the contract: config/test.exs sets
      # :identity_url, and Introspection.url/0 reads it. Never dialled here —
      # the transport is stubbed — so a test that reached the network would
      # fail rather than pass quietly.
      assert URI.parse(Courier.Principal.Introspection.url()).port == @identity_port,
             "Introspection.url() is #{inspect(Courier.Principal.Introspection.url())}, " <>
               "expected port #{@identity_port}"
    end
  end

  describe "the other statements of the same fact" do
    test "docker-compose.yml does not restate a different value", %{compose: compose} do
      # Absent means "defers to the runtime default": the compose file points
      # at the authority rather than restating it, which is the whole of the
      # fix. Present, it must be EQUAL — a restated value is a future drift
      # with a comment on it.
      env = compose |> service_block("courier") |> env_block()
      compose_value = Map.get(env, "COURIER_IDENTITY_URL")

      assert compose_value == nil or compose_value == @runtime_default,
             "docker-compose.yml sets COURIER_IDENTITY_URL=#{inspect(compose_value)}, " <>
               "which disagrees with the runtime default #{inspect(@runtime_default)}. " <>
               "Delete the line and let the default apply, or restate the same value."
    end

    test "config/deploy.yml points a production courier at identity's port", %{deploy: deploy} do
      # The deployment path is the one that matters most: it is the only
      # statement a production courier actually reads, and it is the one a
      # `kamal deploy` operator cannot see past.
      assert deploy_identity_url(deploy) == @runtime_default,
             "config/deploy.yml sets COURIER_IDENTITY_URL=#{inspect(deploy_identity_url(deploy))}, " <>
               "expected #{@runtime_default}. A deployed courier dials this value, " <>
               "so a wrong port here is a 503 on every authenticated request."
    end

    test "the README's operator table states identity's port", %{readme: readme} do
      assert readme =~ "identity:8080",
             "README.md's operator table does not state identity's port (8080) " <>
               "beside COURIER_IDENTITY_URL. An operator reads that table, not " <>
               "the source."
    end
  end

  describe "no second default exists in the tree" do
    test "no non-test file states a port identity does not listen on" do
      # A raise here rather than a nil: a reader that cannot list the tree has
      # not checked it, and "no wrong statements found" over an unread tree
      # is the green-check-over-nothing this repository refuses.
      wrong =
        "."
        |> walk()
        |> Enum.reject(&skip?/1)
        |> Enum.flat_map(fn path ->
          case File.read(path) do
            {:ok, contents} ->
              @wrong_statements
              |> Enum.filter(&String.contains?(contents, &1))
              |> Enum.map(&{path, &1})

            _unreadable ->
              []
          end
        end)

      assert wrong == [],
             "these files state a port identity does not listen on:\n" <>
               Enum.map_join(wrong, "\n", fn {path, statement} ->
                 "  #{path}: contains #{inspect(statement)}"
               end) <>
               "\n\nidentity listens on #{@identity_port}. One fact, one place: " <>
               "config/runtime.exs's default is the authority, and every other " <>
               "statement either defers to it or restates the same value."
    end
  end

  # --- reading ---------------------------------------------------------------

  # The default value of COURIER_IDENTITY_URL in config/runtime.exs, or nil if
  # the reader cannot find it. Nil is a FAILURE, not an answer: the assertion
  # above says so by name, because a reader that finds nothing and a file that
  # says nothing agree with each other.
  @spec runtime_identity_url_default(String.t()) :: String.t() | nil
  defp runtime_identity_url_default(runtime) do
    case Regex.run(~r/System\.get_env\("COURIER_IDENTITY_URL",\s*"([^"]+)"/, runtime) do
      [_, default] -> default
      nil -> nil
    end
  end

  # The fallback inside Introspection.url/0, or nil if the reader cannot find
  # it. Same nil-is-a-failure rule as above.
  @spec url_fallback(String.t()) :: String.t() | nil
  defp url_fallback(source) do
    case Regex.run(
           ~r/def url,\s*do:\s*Application\.get_env\(:courier,\s*:identity_url,\s*"([^"]+)"/,
           source
         ) do
      [_, fallback] -> fallback
      nil -> nil
    end
  end

  # The COURIER_IDENTITY_URL value in config/deploy.yml's `env.clear` block, or
  # nil if the reader cannot find it. Matches the KEY LINE only — a comment
  # mentioning the variable starts with `#` and never matches.
  @spec deploy_identity_url(String.t()) :: String.t() | nil
  defp deploy_identity_url(deploy) do
    case Regex.run(~r/^\s*COURIER_IDENTITY_URL:\s*(\S+)\s*$/m, deploy) do
      [_, url] -> url
      nil -> nil
    end
  end

  # The `environment:` block of a named service in docker-compose.yml, parsed
  # into a KEY => value map. A minimal reader for the one key this test asks
  # about; it understands exactly the `key: value` shape compose uses here.
  @spec env_block(String.t() | nil) :: %{optional(String.t()) => String.t()}
  defp env_block(nil), do: %{}

  defp env_block(service_block) do
    lines = String.split(service_block, "\n")

    start_idx =
      Enum.find_index(lines, fn line ->
        indent(line) == 4 and String.trim(line) == "environment:"
      end)

    if start_idx == nil do
      %{}
    else
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.take_while(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or indent(line) > 4 or String.starts_with?(trimmed, "- ")
      end)
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.contains?(&1, ":"))
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> {String.trim(k), strip_quotes(String.trim(v))}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()
    end
  end

  # The block for a named service: the raw text from `  name:` until the next
  # service at the same indent level.
  @spec service_block(String.t(), String.t()) :: String.t() | nil
  defp service_block(compose, name) do
    lines = String.split(compose, "\n")

    start_idx =
      Enum.find_index(lines, fn line ->
        indent(line) == 2 and String.trim(line) == "#{name}:"
      end)

    if start_idx == nil do
      nil
    else
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.take_while(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or indent(line) > 2 or not String.ends_with?(trimmed, ":")
      end)
      |> Enum.join("\n")
    end
  end

  # Strips one layer of matching double or single quotes from a value.
  @spec strip_quotes(String.t()) :: String.t()
  defp strip_quotes(value) do
    value
    |> String.trim()
    |> case do
      <<"\"", rest::binary>> -> String.trim_trailing(rest, "\"")
      <<"'", rest::binary>> -> String.trim_trailing(rest, "'")
      other -> other
    end
  end

  # The files the tree-wide grep skips, and the reason is the packet's: test
  # files are allowed to mention the wrong values (a test asserting their
  # absence is how this file works), and deps/_build/.git are not source.
  @spec skip?(String.t()) :: boolean()
  defp skip?(path) do
    parts = Path.split(path)
    "test" in parts or "deps" in parts or "_build" in parts or ".git" in parts
  end

  # --- helpers ---------------------------------------------------------------

  # Every entry under a directory, recursively. Elixir's File module has no
  # recursive ls, and adding a dependency for a tree walk is a decision this
  # repository has not made (`AGENTS.md`: "No dependency without approval").
  @spec walk(String.t()) :: [String.t()]
  defp walk(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      if File.dir?(path) do
        [path | walk(path)]
      else
        [path]
      end
    end)
  end

  @spec indent(String.t()) :: non_neg_integer()
  defp indent(line) do
    String.length(line) - String.length(String.trim_leading(line, " "))
  end
end
