defmodule Courier.Notifiers.Loader do
  @moduledoc """
  Loads notification types from a directory on disk, so a consumer can add a
  type without writing Elixir: drop a subdirectory containing `notifier.json`
  plus `body.html.eex` and `body.text.eex`, point `COURIER_NOTIFIERS_DIR` at
  the parent, and restart courier.

  Each loaded type becomes a map-based notifier registered at boot alongside
  the modules in `config :courier, :notifiers`.
  """

  @doc "Loads notifiers from `dir` (or `COURIER_NOTIFIERS_DIR`). Returns a list of maps."
  @spec load() :: [map()]
  def load do
    case System.get_env("COURIER_NOTIFIERS_DIR") do
      nil -> load_dir(default_dir())
      "" -> load_dir(default_dir())
      dir -> load_dir(dir)
    end
  end

  defp default_dir do
    # Shipped product types live here so a consumer needs no Elixir to use or
    # override them: mounting COURIER_NOTIFIERS_DIR replaces this directory.
    Path.join(:code.priv_dir(:courier), "notifiers")
  end

  def load_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&load_type/1)

      {:error, _} ->
        []
    end
  end

  defp load_type(dir) do
    json_path = Path.join(dir, "notifier.json")

    with {:ok, json} <- File.read(json_path),
         {:ok, meta} <- Jason.decode(json) do
      type = meta["type"]
      kind = parse_kind(meta["kind"])
      required = parse_required(meta["required"])
      subject = meta["subject"]

      html_path = Path.join(dir, "body.html.eex")
      text_path = Path.join(dir, "body.text.eex")

      [
        %{
          type: type,
          kind: kind,
          required: required,
          subject: subject,
          html_path: (if File.exists?(html_path), do: html_path),
          text_path: (if File.exists?(text_path), do: text_path)
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_kind("bulk"), do: :bulk
  defp parse_kind(_), do: :transactional

  defp parse_required(nil), do: []
  defp parse_required(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) -> String.to_atom(s)
      a when is_atom(a) -> a
    end)
  end

  defp parse_required(_), do: []
end