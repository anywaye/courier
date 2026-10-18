defmodule Courier.Notifiers do
  @moduledoc """
  Registry of notification types courier knows how to send.

  Types may be registered two ways, so a consumer never needs Elixir to add
  one:

    * **Modules** implementing `Courier.Notifier` (compile-time, type-safe),
      listed in `config :courier, :notifiers`.
    * **Directories** on disk, pointed at by `COURIER_NOTIFIERS_DIR`. Each
      subdirectory is one type: `notifier.json` (metadata) plus
      `body.html.eex` / `body.text.eex` (templates). Loaded at boot.

  `types/0`, `kind/1`, `required/1`, `subject_template/1`,
  `template_path/2` and `build/2` are the seam `Courier.Mailers` and
  `Courier.Deliver` read through.
  """

  @typedoc "A registered notifier: a module or a metadata map."
  @type notifier :: module() | map()

  @doc "All registered notifiers (modules + loaded directories)."
  @spec all() :: [notifier()]
  def all do
    base = Application.get_env(:courier, :notifiers, [])
    base ++ Courier.Notifiers.Loader.load()
  end

  @doc "The type name for a registered notifier, or nil."
  @spec type_for(notifier()) :: String.t() | nil
  def type_for(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :type, 0) do
      module.type()
    end
  end

  def type_for(%{type: type}) when is_binary(type), do: type
  def type_for(_), do: nil

  @doc "The notifier entry for a type name (string or atom), or nil."
  @spec get(String.t() | atom()) :: notifier() | nil
  def get(type) do
    name = to_string(type)

    Enum.find(all(), fn entry ->
      type_for(entry) == name
    end)
  end

  @doc "Every registered type name, in registration order."
  @spec types() :: [String.t()]
  def types do
    all()
    |> Enum.map(&type_for/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "What `type` is for, defaulting to :transactional."
  @spec kind(String.t() | atom()) :: :transactional | :bulk
  def kind(type) do
    case get(type) do
      nil -> :transactional
      mod when is_atom(mod) -> if function_exported?(mod, :kind, 0), do: mod.kind(), else: :transactional
      %{kind: k} when k in [:transactional, :bulk] -> k
      _ -> :transactional
    end
  end

  @doc "Whether `type` is bulk mail."
  @spec bulk?(String.t() | atom()) :: boolean()
  def bulk?(type), do: kind(type) == :bulk

  @doc "Required fields for `type`."
  @spec required(String.t() | atom()) :: [atom()]
  def required(type) do
    case get(type) do
      nil -> []
      mod when is_atom(mod) -> if function_exported?(mod, :required, 0), do: mod.required(), else: []
      %{required: r} when is_list(r) -> r
      _ -> []
    end
  end

  @doc "Subject template override for `type`, or nil (falls back to config)."
  @spec subject_template(String.t() | atom()) :: String.t() | nil
  def subject_template(type) do
    case get(type) do
      mod when is_atom(mod) ->
        if function_exported?(mod, :subject_template, 0), do: mod.subject_template(), else: nil

      %{subject: s} when is_binary(s) ->
        s

      _ ->
        nil
    end
  end

  @doc "Template file path for `type`/`format` when loaded from disk, else nil."
  @spec template_path(String.t() | atom(), :html | :text) :: String.t() | nil
  def template_path(type, format) do
    case get(type) do
      %{html_path: p} when format == :html and is_binary(p) -> p
      %{text_path: p} when format == :text and is_binary(p) -> p
      _ -> nil
    end
  end

  @doc "Builds the message for `type` and `payload`."
  @spec build(String.t() | atom(), map()) ::
          {:ok, Swoosh.Email.t()} | {:error, atom() | {:invalid_payload, Ecto.Changeset.t()}}
  def build(type, payload) when is_map(payload) do
    case get(type) do
      nil -> {:error, :unknown_notification_type}
      mod when is_atom(mod) -> mod.build(payload)
      _map -> Courier.Mailers.build(type, payload)
    end
  end
end