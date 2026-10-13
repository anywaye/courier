defmodule Courier.ComposeConfigTest do
  @moduledoc """
  The dev stack's mail adapter configuration is a real configuration, and it is
  reachable.

  ## What this test exists for

  `bin/dev up` runs courier as a **prod** release (`Dockerfile` sets
  `MIX_ENV=prod`). `Courier.MailerAdapter.adapter!/1` raises when
  `COURIER_MAIL_ADAPTER` is unset, and refuses `none` in `:prod`. Without a
  relay to point at, the container boots, hits `config/runtime.exs:200`, and
  raises — the developer sees a crash, not a configuration error.

  The fix is a mailpit service in `docker-compose.yml` and a set of SMTP
  environment variables pointing at it. This test reads that file and asserts
  the configuration is present and correct, so the failure mode is a red test
  naming the missing key rather than a container that will not start.

  ## Why this is not a YAML parse

  courier has no YAML dependency and adding one is a decision this repository
  has not made (`AGENTS.md`: "No dependency without approval"). So this reads
  the handful of keys the contract is made of, by indentation, and understands
  exactly that.

  ## It runs with no database

  `use ExUnit.Case`, not `Courier.DataCase`. The subject is a file on disk and
  nothing here touches `Courier.Repo`, so this belongs to the no-database tier.
  """

  # `async: true`: this test reads one file and touches no shared process, no
  # application environment and no database.
  use ExUnit.Case, async: true

  @compose_path "docker-compose.yml"

  # The SMTP configuration courier's dev stack must declare. Each entry is
  # {variable, expected_value}. A missing variable or a wrong value is a
  # failure.
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

  # The reads that are genuinely optional, each with the reason. This list is a
  # CONTRACT: adding a variable here is a decision that it needs no dev-stack
  # value, and the comment is what a reader six months from now will rely on.
  #
  # DECLARED ABOVE THE `describe` THAT USES IT, and that ordering is load-bearing
  # rather than stylistic: a module attribute is read at COMPILE time in file
  # order, so a `@optional_reads` defined in the reading section at the bottom
  # compiles to `nil` in the tests above — and `Map.keys(nil)` is a type warning,
  # which `--warnings-as-errors` turns into a red build.
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
    "SOME_APP_SSL_CERT_PATH" => "leftover from the Phoenix generator; never read on this path"
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

      # The exact command, and not merely the presence of a block: the image is
      # distroless (no shell), and a healthcheck's CMD form execs DIRECTLY —
      # the image's ENTRYPOINT (`/mailpit`) is NOT prepended to it. Measured
      # on axllent/mailpit:v1.22.0: `["CMD", "readyz"]` fails every check with
      # `exec: "readyz": executable file not found in $PATH` while the server
      # inside the container is perfectly fine, and `--health-check` is not a
      # flag the binary has — `readyz` is the subcommand that probes its own
      # HTTP API.
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

  # --- the check that would have caught all three ---------------------------

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
      # A reader that finds nothing and a file that supplies nothing agree with
      # each other, and that green check is over an empty set — the failure mode
      # AGENTS.md calls out for every other reader in this repository
      # ("a green check over nothing is worse than no check"). If the pattern in
      # `config/runtime.exs` is ever refactored, this goes red rather than
      # quietly passing a vacuous assertion.
      assert length(boot_required()) >= 6,
             "boot_required/0 found #{length(boot_required())} variables, " <>
               "expected at least 6. Either config/runtime.exs stopped saying " <>
               "\"environment variable X is missing\" in its refusals, or this " <>
               "reader has stopped understanding it. Both make the assertion " <>
               "above vacuous."
    end

    # THE UNDER-READ GUARD, and it is the test that would have caught the reader
    # this file shipped with.
    #
    # `boot_required/0` and `runtime_env_reads/0` are two independent readings of
    # the same file, so a variable can only be "read but unclassified" if this
    # file got it wrong somewhere. That is the check that turns a silent
    # under-read into a red test: the first version of `boot_required/0` matched
    # one syntax and missed `COURIER_ERROR_RELAY_TOKEN`, and NOTHING ELSE IN
    # THIS FILE NOTICED — the missing-variable assertion passed, because a
    # variable it had never heard of is not one it can report as missing.
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

  # --- reading ---------------------------------------------------------------

  # Every variable `config/runtime.exs` refuses to boot without.
  #
  # READ FROM THE FILE THAT RAISES, and that is the whole point. The list was
  # written out by hand four times in this packet's own history — once per
  # crash-loop, each time finding the next variable only after fixing the last
  # one — and a hand-written list in a test is a list that is correct until
  # someone adds a `raise` to `runtime.exs` and the test keeps passing.
  #
  # ## THE READER THAT UNDER-READ, AND WHY THIS ONE CANNOT
  #
  # The first version matched `System.get_env("X") || … raise` and reported five
  # variables. It was wrong, and the fifth was found by BOOTING rather than by
  # reading: `COURIER_ERROR_RELAY_TOKEN` is bound to a variable and refused three
  # dozen lines later —
  #
  #     error_relay_token = System.get_env("COURIER_ERROR_RELAY_TOKEN")
  #     …
  #     if is_nil(error_relay_token) do
  #       raise """environment variable COURIER_ERROR_RELAY_TOKEN is missing."""
  #
  # A reader keyed on the `||` shape cannot see that at all, so the assertion
  # "every boot-required variable is supplied" passed while courier was
  # crash-looping on it. **That is the exact failure this repository's own rules
  # name twice** — a green check over a partial set is worse than no check,
  # because it reads as coverage. A shape-based regex is the wrong instrument:
  # `runtime.exs` expresses "required" in more than one syntax.
  #
  # So this matches the REFUSAL'S OWN SENTENCE instead:
  #
  #     environment variable X is missing
  #
  # Every one of these raises names its variable in its message, because the
  # message is the only thing an operator sees at 3am. Keying on that sentence is
  # shape-independent: `|| raise`, `if is_nil(…) do raise`, `fetch_env!` and a
  # `case` all produce it, and a refactor that changed the syntax without
  # changing the refusal would not change this either.
  #
  # `COURIER_MAIL_ADAPTER` is in the list and is NOT in `runtime.exs`, because its
  # refusal lives in `Courier.MailerAdapter.adapter!/1` — a module this reader does
  # not parse. That is a stated gap, not a silent one, and it has its own
  # assertions above.
  @spec boot_required() :: [String.t()]
  defp boot_required do
    from_runtime =
      "config/runtime.exs"
      |> File.read!()
      |> then(&Regex.scan(~r/environment variable ([A-Z_]+) is missing/, &1))
      |> Enum.map(fn [_, name] -> name end)

    Enum.uniq(["COURIER_MAIL_ADAPTER" | from_runtime])
  end

  # Every variable `runtime.exs` READS, which is a superset of the ones it
  # refuses without. Used to catch a reader that under-reads: a variable read and
  # neither required nor listed as optional is a variable this file has stopped
  # understanding.
  @spec runtime_env_reads() :: [String.t()]
  defp runtime_env_reads do
    "config/runtime.exs"
    |> File.read!()
    |> then(&Regex.scan(~r/get_env\("([A-Z_]+)"\)/, &1))
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  # The reads that are genuinely optional, each with the reason. This list is a
  # CONTRACT: adding a variable here is a decision that it needs no dev-stack
  # value, and the comment is what a reader six months from now will rely on.

  # Extracts the block for a named service. Returns nil if the service is not
  # found. The block is the raw text from the service name to the next service
  # at the same indent level.
  @spec service_block(String.t(), String.t()) :: String.t() | nil
  defp service_block(compose, name) do
    lines = String.split(compose, "\n")

    # Find the service line: `  name:` at indent 2
    start_idx =
      Enum.find_index(lines, fn line ->
        indent(line) == 2 and String.trim(line) == "#{name}:"
      end)

    if start_idx == nil do
      nil
    else
      # Take everything AFTER the service name line until the next line at
      # indent 2 that ends with `:` (the next service)
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.take_while(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or indent(line) > 2 or not String.ends_with?(trimmed, ":")
      end)
      |> Enum.join("\n")
    end
  end

  # Extracts the `environment:` block from a service block and parses it into
  # a map of KEY => value.
  @spec env_block(String.t() | nil) :: %{optional(String.t()) => String.t()}
  defp env_block(service_block) do
    case extract_block(service_block, "environment") do
      nil -> %{}
      block -> parse_kv_block(block)
    end
  end

  # The service names courier's `depends_on:` names, as a list.
  #
  # NOT `parse_kv_block/1` on the raw block, and the reason is the shape compose's
  # two forms take. `depends_on:` is either a LIST (`- postgres`) or a MAP
  # (`postgres:` then a nested `condition:`), and the map form is nested one
  # level deeper than a key. Flattening it with `parse_kv_block/1` yields
  # `%{"postgres" => "", "condition" => "service_healthy"}` — which reads like a
  # dependency on two services, one of them called `condition`. The first draft
  # of this file did exactly that and its failure message printed
  #
  #     Got: %{"condition" => "service_healthy", "postgres" => ""}
  #
  # as the evidence that mailpit was missing, on a file whose `depends_on` was
  # correct. A failure message that describes the reader's bug instead of the
  # file's is worse than a crash, because it sends the reader to look in the
  # wrong place.
  @spec depends_on_services(String.t() | nil) :: [String.t()]
  defp depends_on_services(nil), do: []

  defp depends_on_services(service_block) do
    service_block
    |> extract_block("depends_on")
    |> list_of_nested_keys()
  end

  # The `condition:` courier waits on for one named service, or nil when the
  # service is not in `depends_on:` at all.
  #
  # This is the difference between "waits for mailpit to be healthy" and "waits
  # for mailpit's container to exist", which are different guarantees and look
  # nearly identical in the file.
  @spec depends_on_condition(String.t() | nil, String.t()) :: String.t() | nil
  defp depends_on_condition(nil, _name), do: nil

  defp depends_on_condition(service_block, name) do
    service_block
    |> extract_block("depends_on")
    |> condition_for(name)
  end

  # The `condition:` line nested under ONE named service, and NOT the first
  # `condition:` in the block.
  #
  # Courier's `depends_on:` names more than one service, so a reader that
  # answered with the block's FIRST `condition:` would report `postgres`'s
  # condition for `mailpit` — and pass a file whose mailpit condition had been
  # deleted, which is the exact bug this assertion exists to catch. The name is
  # scoped: find that service's own key, then the line under it, and nothing
  # else.
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

  # The keys of a nested map block, at indent 6 — the level compose puts a
  # `depends_on:` service name, one deeper than the `depends_on:` itself.
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

  # Extracts a named block (e.g., `environment:`, `depends_on:`) from a service
  # block. Returns the raw text of the block, or nil if not found.
  #
  # NIL IN, NIL OUT, and that is the load-bearing clause. Every reader below
  # this one used to call `String.split/2` on the service block directly, so a
  # compose file with no `mailpit` service at all — the exact state this file
  # exists to catch — crashed three of the ten tests with
  #
  #     ** (ArgumentError) no argument of type String
  #
  # and the stack trace pointed at a helper function rather than at
  # `docker-compose.yml`. AGENTS.md's rule is that a reader raises rather than
  # under-reads, and that rule exists to stop a *green* check over nothing; it
  # is not a licence to answer a missing file with a crash when the answer the
  # assertion wants is simply "absent". So every reader here treats a missing
  # service as an empty one and lets the assertion print what it found.
  @spec extract_block(String.t() | nil, String.t()) :: String.t() | nil
  defp extract_block(nil, _name), do: nil

  defp extract_block(service_block, name) do
    lines = String.split(service_block, "\n")

    # Find the block start: a line at indent 4 that is exactly `name:`
    start_idx =
      Enum.find_index(lines, fn line ->
        indent(line) == 4 and String.trim(line) == "#{name}:"
      end)

    if start_idx == nil do
      nil
    else
      # Take everything after the block start until the next line at indent 4
      # that is not a list item
      lines
      |> Enum.drop(start_idx + 1)
      |> Enum.take_while(fn line ->
        trimmed = String.trim(line)
        trimmed == "" or indent(line) > 4 or String.starts_with?(trimmed, "- ")
      end)
      |> Enum.join("\n")
    end
  end

  # Parses a block of `key: value` lines into a map.
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

  # Extracts a scalar field value from a service block.
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

  # Extracts a list field from a service block. A list field is a key at
  # indent 4 followed by `- ` items at a deeper indent.
  @spec list_field(String.t() | nil, String.t()) :: [String.t()]
  defp list_field(nil, _name), do: []

  defp list_field(service_block, name) do
    lines = String.split(service_block, "\n")

    # Find the list start: a line at indent 4 that is exactly `name:`
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

  # Whether a named block exists in a service block.
  @spec has_block?(String.t() | nil, String.t()) :: boolean()
  defp has_block?(nil, _name), do: false

  defp has_block?(service_block, name) do
    service_block
    |> String.split("\n")
    |> Enum.any?(fn line ->
      indent(line) == 4 and String.trim(line) == "#{name}:"
    end)
  end

  # Extracts the healthcheck's `test:` command from a service block, as the
  # list of arguments after the `test:` key. Returns nil if there is none.
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

  # Parses a compose list of quoted strings, e.g. `["CMD", "/mailpit", "readyz"]`,
  # into the list of arguments. Under-reads rather than raises: a form this
  # reader does not recognise is a nil, and the assertion names what it found.
  @spec parse_command_list(String.t()) :: [String.t()] | nil
  defp parse_command_list(value) do
    parts = Regex.scan(~r/"([^"]*)"/, value)

    case parts do
      [] -> nil
      matches -> Enum.map(matches, fn [_, arg] -> arg end)
    end
  end

  # --- helpers ---------------------------------------------------------------

  @spec indent(String.t()) :: non_neg_integer()
  defp indent(line) do
    String.length(line) - String.length(String.trim_leading(line, " "))
  end
end
