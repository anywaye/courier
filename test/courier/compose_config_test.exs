defmodule Courier.ComposeConfigTest do
  @moduledoc """
  The dev stack's mail adapter configuration is a real configuration, and it is
  reachable.


  `bin/dev up` runs courier as a **prod** release (`Dockerfile` sets
  `MIX_ENV=prod`). `Courier.MailerAdapter.adapter!/1` raises when
  `COURIER_MAIL_ADAPTER` is unset, and refuses `none` in `:prod`. Without a
  relay to point at, the container boots, hits `config/runtime.exs:200`, and
  raises — the developer sees a crash, not a configuration error.

  The fix is a mailpit service in `docker-compose.yml` and a set of SMTP
  environment variables pointing at it. This test reads that file and asserts
  the configuration is present and correct, so the failure mode is a red test
  naming the missing key rather than a container that will not start.


  courier has no YAML dependency and adding one is a decision this repository
  has not made (`AGENTS.md`: "No dependency without approval"). So this reads
  the handful of keys the contract is made of, by indentation, and understands
  exactly that.


  `use ExUnit.Case`, not `Courier.DataCase`. The subject is a file on disk and
  nothing here touches `Courier.Repo`, so this belongs to the no-database tier.
  """

  use ExUnit.Case, async: true

  @compose_path "docker-compose.yml"

  @required_smtp_vars [
    {"COURIER_MAIL_ADAPTER", "smtp"},
    {"COURIER_SMTP_HOST", "mailpit"},
    {"COURIER_SMTP_PORT", "1025"},
    {"COURIER_SMTP_AUTH", "never"},
    {"COURIER_SMTP_TLS", "never"},
    {"COURIER_SMTP_SSL", "false"}
  ]

  setup_all do
    {:ok, compose: File.read!(@compose_path)}
  end

  @optional_reads %{
    "COURIER_OWNER_DATABASE_URL" =>
      "the OWNER dsn, for bin/migrate only — not required at boot by design",
    "COURIER_ERROR_REPORTING_DSN" => "error reporting is off unless this is set",
    "COURIER_ERROR_SINK_DSN" => "the relay's sink; no sink means errors are counted, not sent",
    "COURIER_RELEASE" => "a release label with a default",
    "DEPLOYMENT_ENVIRONMENT" => "a resource attribute with a default",
    "COURIER_FORCE_SSL" =>
      "the SSL redirect opt-in; absent means plain HTTP, which is what the dev stack wants",
    "NATS_URL" =>
      "the event bus, and absent is a supported state: no connection, no " <>
        "publisher, and outbox rows accumulate. kit's compose supplies the broker " <>
        "for the stack, not for a bare `mix phx.server`",
    "PHX_HOST" => "defaults to example.com — see the follow-up in the packet report",
    "PHX_SERVER" => "behind a proxy in kit's stack; ignored when unset",
    "RELEASE_COMMAND" =>
      "set by the release's own bin script, never by the dev stack: `start` for " <>
        "bin/server, `eval` for bin/migrate. It is how config/runtime.exs tells a " <>
        "one-shot migrate boot from the server, so it needs no dev-stack value " <>
        "and its absence means serving",
    "POOL_SIZE" => "the repo size, defaulted at runtime.exs",
    "DNS_CLUSTER_QUERY" => "kit's postgres clustering; irrelevant to one node",
    "SOME_APP_SSL_KEY_PATH" => "leftover from the Phoenix generator; never read on this path",
    "SOME_APP_SSL_CERT_PATH" => "leftover from the Phoenix generator; never read on this path",
    "COURIER_BILLING_URL" =>
      "optional — where the payment-failure warning's reader goes to update their " <>
        "card. Unset means the mail asks in words instead of linking, which is the " <>
        "supported state on a deployment with no billing screens; the dev stack " <>
        "needs no value for the consumer's tests to pass.",
    "COURIER_INBOUND_RESEND_SECRET" =>
      "optional — a hard bounce or a spam complaint is discarded and courier goes on mailing an address that has said it is gone; the inbound route answers 500. A Cloudflare-only box has no webhook to configure and boots with no provider. The dev stack carries a placeholder so the surface can be exercised."
  }

  describe "the mailpit service" do
    test "exists in the compose file", %{compose: compose} do
      assert service_block(compose, "mailpit") != nil,
             "#{@compose_path} declares no `mailpit` service. Without it courier " <>
               "has no relay to point at, and `bin/dev up` fails when the release " <>
               "hits `config/runtime.exs:200` and raises on an unset " <>
               "COURIER_MAIL_ADAPTER."
    end

    test "uses a pinned image", %{compose: compose} do
      block = service_block(compose, "mailpit")
      image = scalar_field(block, "image")

      assert image =~ ~r/^axllent\/mailpit:v\d/,
             "mailpit image is #{inspect(image)}, expected a pinned " <>
               "axllent/mailpit:<tag>. A floating tag is a stack that changes " <>
               "under you between two runs of the same command."
    end

    test "publishes the web UI port", %{compose: compose} do
      block = service_block(compose, "mailpit")
      ports = list_field(block, "ports")

      assert Enum.any?(ports, &String.contains?(&1, ":8025")),
             "mailpit publishes no port mapping to 8025 (the web UI). " <>
               "Published ports: #{inspect(ports)}. A developer needs the web " <>
               "UI to read what courier sent."
    end

    test "does not publish the SMTP port", %{compose: compose} do
      block = service_block(compose, "mailpit")
      ports = list_field(block, "ports")

      refute Enum.any?(ports, &String.contains?(&1, ":1025")),
             "mailpit publishes port 1025 (SMTP) to the host. The SMTP port " <>
               "is only needed by courier inside the compose network; " <>
               "publishing it lets anything on the machine send mail through " <>
               "the catcher. Published ports: #{inspect(ports)}."
    end

    test "has a healthcheck that probes the readyz endpoint", %{compose: compose} do
      block = service_block(compose, "mailpit")

      assert has_block?(block, "healthcheck"),
             "mailpit has no healthcheck. `docker compose up --wait` can only " <>
               "mean something if there is a health signal to wait for, and " <>
               "courier's readiness depends on mailpit being reachable."

      command = healthcheck_command(block)

      assert command == ["CMD", "/mailpit", "readyz"],
             "mailpit healthcheck is #{inspect(command)}, expected " <>
               "[\"CMD\", \"/mailpit\", \"readyz\"]. A healthcheck that cannot run " <>
               "leaves the container permanently unhealthy, and courier's " <>
               "readiness — which waits on this service — never arrives."
    end

    test "is on the platform network", %{compose: compose} do
      block = service_block(compose, "mailpit")
      networks = list_field(block, "networks")

      assert "platform" in networks,
             "mailpit is not on the `platform` network. Networks: #{inspect(networks)}. " <>
               "Courier reaches it by service name over that network."
    end
  end

  describe "courier's SMTP configuration" do
    test "declares every required SMTP variable", %{compose: compose} do
      block = service_block(compose, "courier")
      env = env_block(block)

      for {var, expected} <- @required_smtp_vars do
        actual = Map.get(env, var)

        assert actual == expected,
               "#{@compose_path} courier service declares #{var}=#{inspect(actual)}, " <>
                 "expected #{inspect(expected)}. Without the correct SMTP " <>
                 "configuration the release raises at boot."
      end
    end

    test "points at mailpit by service name", %{compose: compose} do
      block = service_block(compose, "courier")
      env = env_block(block)

      assert Map.get(env, "COURIER_SMTP_HOST") == "mailpit",
             "COURIER_SMTP_HOST is #{inspect(Map.get(env, "COURIER_SMTP_HOST"))}, " <>
               "expected \"mailpit\" (the compose service name)."
    end

    test "uses no authentication", %{compose: compose} do
      block = service_block(compose, "courier")
      env = env_block(block)

      assert Map.get(env, "COURIER_SMTP_AUTH") == "never",
             "COURIER_SMTP_AUTH is #{inspect(Map.get(env, "COURIER_SMTP_AUTH"))}, " <>
               "expected \"never\". Mailpit accepts everything unauthenticated."
    end

    test "depends on mailpit", %{compose: compose} do
      block = service_block(compose, "courier")
      services = depends_on_services(block)

      assert "mailpit" in services,
             "courier `depends_on` does not name mailpit. Got: #{inspect(services)}. " <>
               "Without it courier's container starts in parallel with the catcher " <>
               "and loses the race, so the first send of a fresh `bin/dev up` is " <>
               "the one that fails."
    end

    test "waits for mailpit to be healthy rather than merely started", %{
      compose: compose
    } do
      block = service_block(compose, "courier")
      condition = depends_on_condition(block, "mailpit")

      assert condition == "service_healthy",
             "courier waits on mailpit with `#{inspect(condition)}`, expected " <>
               "\"service_healthy\". A bare service name in `depends_on` waits only " <>
               "for the container to START, and mailpit's SMTP listener is not " <>
               "accepting connections the instant the process is up."
    end
  end


  describe "every boot-required variable" do
    test "is supplied by this compose file", %{compose: compose} do
      env = compose |> service_block("courier") |> env_block()
      missing = Enum.reject(boot_required(), &Map.has_key?(env, &1))

      assert missing == [],
             "#{@compose_path} does not supply #{inspect(missing)}.\n\n" <>
               "Each is a `System.get_env(…) || raise` in config/runtime.exs, " <>
               "so the container boots, evaluates the file top to bottom, and " <>
               "crash-loops at whichever raise comes first — one variable at a " <>
               "time, each failure naming only itself. Supply every one and the " <>
               "class of defect is gone rather than its latest instance.\n\n" <>
               "Supplied: #{inspect(Enum.sort(Map.keys(env)))}"
    end

    test "the required list is not empty, because an empty one passes" do
      assert length(boot_required()) >= 6,
             "boot_required/0 found #{length(boot_required())} variables, " <>
               "expected at least 6. Either config/runtime.exs stopped saying " <>
               "\"environment variable X is missing\" in its refusals, or this " <>
               "reader has stopped understanding it. Both make the assertion " <>
               "above vacuous."
    end

    test "every variable runtime.exs reads is either required or declared optional" do
      classified =
        MapSet.new(boot_required()) |> MapSet.union(MapSet.new(Map.keys(@optional_reads)))

      unclassified = Enum.reject(runtime_env_reads(), &MapSet.member?(classified, &1))

      assert unclassified == [],
             "config/runtime.exs reads #{inspect(unclassified)} and this file " <>
               "can say nothing about whether the dev stack supplies them.\n\n" <>
               "Classify each one: add it to boot_required/0's source pattern if a " <>
               "refusal names it, or to @optional_reads with the reason it needs " <>
               "no dev-stack value. An unclassified read is the shape this " <>
               "assertion exists to catch."
    end
  end


  @spec boot_required() :: [String.t()]
  defp boot_required do
    from_runtime =
      "config/runtime.exs"
      |> File.read!()
      |> then(&Regex.scan(~r/environment variable ([A-Z_]+) is missing/, &1))
      |> Enum.map(fn [_, name] -> name end)

    Enum.uniq(["COURIER_MAIL_ADAPTER" | from_runtime])
  end

  @spec runtime_env_reads() :: [String.t()]
  defp runtime_env_reads do
    "config/runtime.exs"
    |> File.read!()
    |> then(&Regex.scan(~r/get_env\("([A-Z_]+)"\)/, &1))
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end


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

  @spec env_block(String.t() | nil) :: %{optional(String.t()) => String.t()}
  defp env_block(service_block) do
    case extract_block(service_block, "environment") do
      nil -> %{}
      block -> parse_kv_block(block)
    end
  end

  @spec depends_on_services(String.t() | nil) :: [String.t()]
  defp depends_on_services(nil), do: []

  defp depends_on_services(service_block) do
    service_block
    |> extract_block("depends_on")
    |> list_of_nested_keys()
  end

  @spec depends_on_condition(String.t() | nil, String.t()) :: String.t() | nil
  defp depends_on_condition(nil, _name), do: nil

  defp depends_on_condition(service_block, name) do
    service_block
    |> extract_block("depends_on")
    |> condition_for(name)
  end

  @spec condition_for(String.t() | nil, String.t()) :: String.t() | nil
  defp condition_for(nil, _name), do: nil

  defp condition_for(block, name) do
    lines = String.split(block, "\n")

    start =
      Enum.find_index(lines, fn line ->
        indent(line) == 6 and String.trim(line) == "#{name}:"
      end)

    if start == nil do
      nil
    else
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(fn line -> indent(line) > 6 end)
      |> Enum.find_value(fn line ->
        if indent(line) == 8 and String.starts_with?(String.trim(line), "condition:") do
          line |> String.trim() |> String.split(":", parts: 2) |> List.last() |> strip_quotes()
        end
      end)
    end
  end

  @spec list_of_nested_keys(String.t() | nil) :: [String.t()]
  defp list_of_nested_keys(nil), do: []

  defp list_of_nested_keys(block) do
    block
    |> String.split("\n")
    |> Enum.filter(fn line ->
      trimmed = String.trim(line)
      indent(line) == 6 and String.ends_with?(trimmed, ":")
    end)
    |> Enum.map(fn line ->
      line |> String.trim() |> String.trim_trailing(":") |> String.trim()
    end)
  end

  @spec extract_block(String.t() | nil, String.t()) :: String.t() | nil
  defp extract_block(nil, _name), do: nil

  defp extract_block(service_block, name) do
    lines = String.split(service_block, "\n")

    start_idx =
      Enum.find_index(lines, fn line ->
        indent(line) == 4 and String.trim(line) == "#{name}:"
      end)

    if start_idx == nil do
      nil
    else
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.take_while(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or indent(line) > 4 or String.starts_with?(trimmed, "- ")
      end)
      |> Enum.join("\n")
    end
  end

  @spec parse_kv_block(String.t()) :: %{optional(String.t()) => String.t()}
  defp parse_kv_block(block) do
    block
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
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

  @spec scalar_field(String.t() | nil, String.t()) :: String.t() | nil
  defp scalar_field(nil, _name), do: nil

  defp scalar_field(service_block, name) do
    service_block
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      trimmed = String.trim(line)

      if indent(line) == 4 and String.starts_with?(trimmed, "#{name}:") do
        case String.split(trimmed, ":", parts: 2) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
      end
    end)
  end

  @spec list_field(String.t() | nil, String.t()) :: [String.t()]
  defp list_field(nil, _name), do: []

  defp list_field(service_block, name) do
    lines = String.split(service_block, "\n")

    start_idx =
      Enum.find_index(lines, fn line ->
        indent(line) == 4 and String.trim(line) == "#{name}:"
      end)

    if start_idx == nil do
      []
    else
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.take_while(fn line ->
        trimmed = String.trim(line)

        trimmed == "" or
          String.starts_with?(trimmed, "#") or
          (indent(line) > 4 and String.starts_with?(trimmed, "- "))
      end)
      |> Enum.map(fn line ->
        line |> String.trim() |> String.trim_leading("- ") |> String.trim()
      end)
      |> Enum.reject(&String.starts_with?(&1, "#"))
    end
  end

  @spec has_block?(String.t() | nil, String.t()) :: boolean()
  defp has_block?(nil, _name), do: false

  defp has_block?(service_block, name) do
    service_block
    |> String.split("\n")
    |> Enum.any?(fn line ->
      indent(line) == 4 and String.trim(line) == "#{name}:"
    end)
  end

  @spec healthcheck_command(String.t() | nil) :: [String.t()] | nil
  defp healthcheck_command(service_block) do
    case extract_block(service_block, "healthcheck") do
      nil ->
        nil

      block ->
        block
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          trimmed = String.trim(line)

          if indent(line) == 6 and String.starts_with?(trimmed, "test:") do
            case String.split(trimmed, ":", parts: 2) do
              [_, value] -> parse_command_list(String.trim(value))
              _ -> nil
            end
          end
        end)
    end
  end

  @spec parse_command_list(String.t()) :: [String.t()] | nil
  defp parse_command_list(value) do
    parts = Regex.scan(~r/"([^"]*)"/, value)

    case parts do
      [] -> nil
      matches -> Enum.map(matches, fn [_, arg] -> arg end)
    end
  end


  @spec indent(String.t()) :: non_neg_integer()
  defp indent(line) do
    String.length(line) - String.length(String.trim_leading(line, " "))
  end
end
