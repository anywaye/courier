defmodule Courier.Notifiers do
  @moduledoc """
  Registry of notification types courier knows how to send.

  Types are discovered from `config :courier, :notifiers` (a list of modules
  implementing `Courier.Notifier`). courier ships no types of its own; the
  consuming application registers the ones it uses. `types/0`, `kind/1`,
  `required/1`, and `build/2` are the seam `Courier.Mailers` and
  `Courier.Deliver` read through, so neither module needs to know which types
  exist.
  """

  @typedoc "A registered notifier module."
  @type notifier :: module()

  @doc "All registered notifier modules."
  @spec all() :: [notifier()]
  def all do
    Application.get_env(:courier, :notifiers, [])
  end

  @doc "The type name for a registered notifier, or nil."
  @spec type_for(notifier()) :: String.t() | nil
  def type_for(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :type, 0) do
      module.type()
    end
  end

  @doc "The notifier module for a type name (string or atom), or nil."
  @spec get(String.t() | atom()) :: notifier() | nil
  def get(type) do
    name = to_string(type)

    Enum.find(all(), fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :type, 0) and mod.type() == name
    end)
  end

  @doc "Every registered type name, in registration order."
  @spec types() :: [String.t()]
  def types do
    all()
    |> Enum.map(&type_for/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc "What `type` is for, defaulting to :transactional for unregistered types."
  @spec kind(String.t() | atom()) :: :transactional | :bulk
  def kind(type) do
    case get(type) do
      nil -> :transactional
      mod -> if function_exported?(mod, :kind, 0), do: mod.kind(), else: :transactional
    end
  end

  @doc "Whether `type` is bulk mail."
  @spec bulk?(String.t() | atom()) :: boolean()
  def bulk?(type) do
    kind(type) == :bulk
  end

  @doc "Required fields for `type`."
  @spec required(String.t() | atom()) :: [atom()]
  def required(type) do
    case get(type) do
      nil -> []
      mod -> if function_exported?(mod, :required, 0), do: mod.required(), else: []
    end
  end

  @doc "Build the message for `type` and `payload`."
  @spec build(String.t() | atom(), map()) ::
          {:ok, Swoosh.Email.t()} | {:error, atom() | {:invalid_payload, Ecto.Changeset.t()}}
  def build(type, payload) when is_map(payload) do
    case get(type) do
      nil -> {:error, :unknown_notification_type}
      mod -> mod.build(payload)
    end
  end
end