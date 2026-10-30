defmodule Courier.TestSupport.KamalConfig do
  @moduledoc """
  Reads courier's two Kamal configuration files, and says what they say.

  It exists because of the shape of the thing it reads. `config/kamal-backup.yml`
  names four secrets; `config/deploy.yml` lists which secrets the container that
  reads that file is given; and **the pair is only correct together** —
  `kamal-backup validate` builds the accessory's environment from the deploy
  config and from nothing else, so a secret named in one and missing from the
  other is a valid YAML file in both that fails validation with
  `RESTIC_REPOSITORY or RESTIC_REPOSITORY_FILE is required`. A reader that looked
  at one file could not see that, which is why the file that matters most to this
  module is the one it reads from both sides.

  It lives in courier's own `test/support` rather than in a shared helper, so the
  next service that adopts a backup configuration copies one file and reads it —
  the same decision `Courier.TestSupport.OpenAPIPaths` records for itself.


  courier has no YAML dependency and adding one is a decision this repository has
  not made (`AGENTS.md`: "No dependency without approval"). So this reads the
  handful of keys the two contracts are made of, by indentation, and understands
  exactly that. The subset:

    * `
      whole. Both are dropped rather than parsed, because neither can change the
      meaning of a key this module reads.
    * a top-level key is a line at column 0 ending in `:`; a nested key is the
      same at a deeper column. Indentation is **derived from the file**, so a file
      indented with four spaces reads correctly rather than reading as empty.
    * a sequence entry is a `- ` at the indent of the key that owns it.
    * `secret: NAME` is a name and nothing else. This module refuses to
      recognise any other shape of value under a secret key, because the whole
      subject of the check is "is this a NAME", and a reader that accepted a
      literal would agree with a file that had a credential in it.

  Anything outside that subset raises. A reader that found nothing and a config
  that said nothing agree with each other, and a green check over nothing is
  worse than no check.


  A missing file, an empty file, a key that is absent, an accessory with no
  `env.secret`, a `databases:` list with no entries — each raises a message
  naming what it found instead of returning an empty set. That is the rule
  `Courier.TestSupport.OpenAPIPaths` states for itself and it applies here for
  the same reason: an empty set agrees with every other empty set.
  """

  @backup_path "config/kamal-backup.yml"
  @deploy_path "config/deploy.yml"

  @typedoc """
  What `config/kamal-backup.yml` says.

    * `:app` — the Kamal service name, and therefore the snapshot path and the
      `app:` restic tag.
    * `:accessory` — the accessory in `config/deploy.yml` this config belongs to.
    * `:databases` — one entry per database, each with its `name`, its `adapter`
      and the secret NAMES its `url` and `password` resolve from.
    * `:secrets` — every secret name the file names, anywhere.
    * `:schedule` — the `backup.schedule` value, as written.
    * `:paths?` — whether a `paths:` key is present, which is what decides
      whether any file snapshot is ever taken.
    * `:erb?` — whether the file still carries an ERB tag, which for this file
      would mean it was copied rather than rendered.
  """
  @type backup :: %{
          app: String.t() | nil,
          accessory: String.t() | nil,
          databases: [%{name: String.t() | nil, adapter: String.t() | nil, secrets: [String.t()]}],
          secrets: [String.t()],
          schedule: String.t() | nil,
          paths?: boolean(),
          erb?: boolean()
        }

  @typedoc """
  What `config/deploy.yml` says.

    * `:service` — the raw text after `service:`, which is an ERB tag
      (`<%= service %>`), so this is a **string about the file** rather than a
      resolved value. See `KamalConfig` for why it cannot be resolved here.
    * `:mounts` — every `files:` entry, verbatim.
    * `:accessory_secrets` — the secret names each accessory's `env.secret` lists.
    * `:accessories` — the accessory names declared under `accessories:`.
  """
  @type deploy :: %{
          service: String.t() | nil,
          mounts: [String.t()],
          accessory_secrets: %{optional(String.t()) => [String.t()]},
          accessories: [String.t()]
        }

  @doc """
  What `config/kamal-backup.yml` says, or a raised error naming what went wrong.
  """
  @spec backup!(Path.t()) :: backup()
  def backup!(path \\ @backup_path) do
    lines = read!(path)
    kept = significant(lines)

    erb? = Enum.any?(kept, &erb_tag?/1)
    level = top_level_indent!(path, kept)

    %{
      app: scalar(path, kept, level, "app"),
      accessory: scalar(path, kept, level, "accessory"),
      databases: databases!(path, kept, level),
      secrets: secrets_in(kept),
      schedule: schedule!(path, kept, level),
      paths?: Enum.any?(kept, &(key(&1) == "paths")),
      erb?: erb?
    }
  end

  @doc """
  What `config/deploy.yml` says, or a raised error naming what went wrong.
  """
  @spec deploy!(Path.t()) :: deploy()
  def deploy!(path \\ @deploy_path) do
    lines = read!(path)
    kept = significant(lines)
    level = top_level_indent!(path, kept)

    accessories = accessories!(path, kept, level)

    %{
      service: scalar(path, kept, level, "service"),
      mounts: mounts(kept),
      accessory_secrets: Map.new(accessories, &{&1, accessory_secrets!(path, kept, &1, level)}),
      accessories: accessories
    }
  end

  @doc """
  The snapshot path a database in `config/kamal-backup.yml` is written under.

  `databases/<app>/<name>/postgres.pgdump`, which is restic's own layout and the
  path a rename orphans.
  """
  @spec snapshot_path!(backup(), pos_integer()) :: String.t()
  def snapshot_path!(backup, index) do
    database =
      Enum.at(backup.databases, index - 1) ||
        raise "config/kamal-backup.yml declares #{length(backup.databases)} database(s); there is no #{index}."

    app =
      backup.app ||
        raise "config/kamal-backup.yml declares no `app:`, so no snapshot path can be built."

    name =
      database.name || raise "config/kamal-backup.yml databases[#{index}] declares no `name:`."

    "databases/#{app}/#{name}/postgres.pgdump"
  end

  @doc """
  Whether the backup config mounts itself into the accessory the deploy config
  declares, which is the only way the file is reachable from a deployment.

  The mount is matched on the **target** path inside the container rather than on
  the whole line: the source path may be written any number of ways and the
  destination is the part that has to be right, since that is where
  `kamal-backup` opens the file. A leading `/` on either side is not a
  difference — Docker treats them as the same mount.
  """
  @spec mounts_backup_config?(deploy(), String.t()) :: boolean()
  def mounts_backup_config?(deploy, container_path \\ "/app/config/kamal-backup.yml") do
    wanted = String.trim_leading(container_path, "/")

    Enum.any?(deploy.mounts, fn mount ->
      case split_mount(mount) do
        [_source, destination] -> destination == wanted
        _other -> false
      end
    end)
  end

  @doc """
  The two halves of a `host:container[:mode]` mount, with the mode dropped.
  """
  @spec split_mount(String.t()) :: [String.t()]
  def split_mount(mount) do
    mount
    |> String.split(":")
    |> Enum.map(&String.trim/1)
    |> case do
      [source, destination] ->
        [String.trim_leading(source, "/"), String.trim_leading(destination, "/")]

      [source, destination, _mode] ->
        [String.trim_leading(source, "/"), String.trim_leading(destination, "/")]

      _other ->
        []
    end
  end


  @spec read!(Path.t()) :: [String.t()]
  defp read!(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> drop_erb_blocks()

      {:error, reason} ->
        raise "could not read #{path}: #{:file.format_error(reason)}. " <>
                "A backup configuration that is not there is not a configuration, and a reader that " <>
                "treated a missing file as an empty one would agree with a file that says nothing."
    end
  end

  defp drop_erb_blocks(lines) do
    {kept, _inside?} =
      Enum.reduce(lines, {[], false}, fn line, {acc, inside?} ->
        trimmed = String.trim(line)

        cond do
          inside? ->
            {acc, not String.contains?(trimmed, "%>")}

          String.starts_with?(trimmed, "<%") and not String.contains?(trimmed, "%>") ->
            {acc, true}

          true ->
            {[line | acc], false}
        end
      end)

    Enum.reverse(kept)
  end

  defp significant(lines) do
    lines
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
  end

  defp erb_tag?(line) do
    String.contains?(String.trim(line), "<%")
  end

  defp top_level_indent!(path, lines) do
    case lines do
      [] ->
        raise "#{path} has no content outside comments. A configuration file of nothing but " <>
                "comments is a file nothing reads, and this reader would agree with it."

      _ ->
        lines
        |> Enum.map(&indent/1)
        |> Enum.min()
    end
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  defp scalar(path, lines, level, wanted) do
    lines
    |> Enum.filter(&(indent(&1) == level and key(&1) == wanted))
    |> case do
      [line] ->
        value(line)

      [] ->
        nil

      _many ->
        raise "#{path} declares `#{wanted}:` more than once, so which one is the configuration is a guess."
    end
  end

  defp schedule!(path, lines, level) do
    case scalar(path, lines, level, "backup") do
      nil ->
        nil

      _ ->
        case Enum.find(lines, &(indent(&1) > level and key(&1) == "schedule")) do
          nil ->
            raise "#{path} has a `backup:` block with no `schedule:` in it. The tool's own default " <>
                    "would then decide how often courier is backed up, which is a retention question " <>
                    "decided by a dependency rather than by this repository."

          line ->
            value(line)
        end
    end
  end

  defp databases!(path, lines, level) do
    key_line = Enum.find(lines, &(indent(&1) == level and key(&1) == "databases"))

    if is_nil(key_line) do
      raise "#{path} declares no `databases:`. A backup configuration with no database in it " <>
              "backs up nothing, and this reader would return an empty list that agreed with one."
    end

    start = Enum.find_index(lines, &(&1 == key_line))
    depth = indent(key_line)
    block = Enum.drop(lines, start + 1) |> Enum.take_while(&(indent(&1) > depth))

    entries = split_entries(block, depth)

    if entries == [] do
      raise "#{path} has a `databases:` key with no entries under it."
    end

    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {lines_for_entry, index} ->
      %{
        name: field(lines_for_entry, "name", path, index),
        adapter: field(lines_for_entry, "adapter", path, index),
        secrets: secrets_in(lines_for_entry)
      }
    end)
  end

  @spec split_entries([String.t()], non_neg_integer()) :: [[String.t()]]
  defp split_entries(block, depth) do
    {groups, current} =
      Enum.reduce(block, {[], nil}, fn line, {groups, current} ->
        trimmed = String.trim(line)

        if indent(line) > depth and String.starts_with?(trimmed, "- ") do
          {[current | groups], [String.replace_prefix(trimmed, "- ", "")]}
        else
          {groups, List.wrap(current) ++ [line]}
        end
      end)

    [current | groups]
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  defp field(lines, wanted, path, index) do
    case Enum.find(lines, &(key(&1) == wanted)) do
      nil -> nil
      line -> value(line)
    end
    |> case do
      nil ->
        raise "#{path} databases[#{index}] declares no `#{wanted}:`. `name` is the snapshot path " <>
                "and restic tag, and `adapter` is how the dump is taken; neither has a default worth inheriting."

      found ->
        found
    end
  end

  defp accessories!(path, lines, level) do
    key_line = Enum.find(lines, &(indent(&1) == level and key(&1) == "accessories"))

    if is_nil(key_line) do
      raise "#{path} declares no `accessories:`. The backup config names an accessory by name, and " <>
              "without this block there is nothing for that name to be."
    end

    depth = indent(key_line)
    start = Enum.find_index(lines, &(&1 == key_line))

    lines
    |> Enum.drop(start + 1)
    |> Enum.take_while(&(indent(&1) > depth))
    |> Enum.filter(&(indent(&1) == depth + 2))
    |> Enum.map(&String.trim_trailing(key(&1), ":"))
    |> case do
      [] -> raise "#{path} has an `accessories:` key with nothing under it."
      names -> names
    end
  end

  defp accessory_secrets!(path, lines, accessory, level) do
    depth = level + 2

    start =
      Enum.find_index(lines, fn line ->
        indent(line) == depth and key(line) == accessory
      end)

    if is_nil(start) do
      raise "#{path} declares no `#{accessory}` accessory."
    end

    block =
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(&(indent(&1) > depth))

    case Enum.find(block, &(indent(&1) == depth + 4 and key(&1) == "secret")) do
      nil ->
        raise "#{path} accessory `#{accessory}` has no `env.secret` list. Every secret " <>
                "config/kamal-backup.yml names must be listed there — the accessory's environment is built " <>
                "from that list and from nothing else."

      secret_line ->
        depth_of_list = indent(secret_line)

        lines
        |> Enum.drop(start + 1)
        |> Enum.take_while(&(indent(&1) > depth))
        |> Enum.drop_while(&(&1 != secret_line))
        |> Enum.drop(1)
        |> Enum.take_while(&seq_entry?(&1, depth_of_list))
        |> Enum.map(&(&1 |> String.trim_leading(" ") |> String.replace_prefix("- ", "")))
    end
  end

  defp mounts(lines) do
    lines
    |> Enum.filter(&(&1 |> String.trim() |> String.starts_with?("- ")))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("- ", "")))
    |> Enum.filter(&(&1 =~ ":"))
  end

  defp secrets_in(lines) do
    lines
    |> Enum.filter(&(key(&1) == "secret"))
    |> Enum.map(fn line ->
      case value(line) do
        "" ->
          raise "a `secret:` key in a Kamal configuration has no name after it. The name is the " <>
                  "whole content of the entry; a value here would be a credential in a file that is " <>
                  "committed, pasted into tickets and read over shoulders."

        name ->
          if name =~ ~r{[:/]} do
            raise "a `secret:` key reads as `#{inspect(name)}`, which looks like a VALUE rather than " <>
                    "the name of a Kamal secret. This reader only recognises names, because the " <>
                    "difference between the two is the difference between a config and a leaked credential."
          end

          name
      end
    end)
  end

  defp key(line) do
    line |> String.trim() |> String.split(":", parts: 2) |> hd() |> String.trim()
  end

  defp value(line) do
    case String.split(String.trim(line), ":", parts: 2) do
      [_key, value] -> String.trim(value)
      _one -> ""
    end
  end

  defp seq_entry?(line, owner_indent),
    do:
      indent(line) > owner_indent and String.trim_leading(line, " ") |> String.starts_with?("- ")
end
