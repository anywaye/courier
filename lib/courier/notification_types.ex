defmodule Courier.NotificationTypes do
  @moduledoc """
  Context for the `notification_types` table: the DB-backed registry of
  notification types courier can send. Global catalog (operator-managed).
  """

  import Ecto.Query

  alias Courier.NotificationType
  alias Courier.Repo

  @doc "Lists all types, seeding platform defaults on first access."
  @spec list() :: [NotificationType.t()]
  def list do
    case :persistent_term.get({__MODULE__, :cache}, nil) do
      nil ->
        seed_defaults()
        refresh_cache()

      cached ->
        cached
    end
  end

  defp refresh_cache do
    rows = Repo.all(from t in NotificationType, order_by: t.inserted_at)
    :persistent_term.put({__MODULE__, :cache}, rows)
    rows
  end

  @doc "Gets a single type by name."
  @spec get(String.t()) :: NotificationType.t() | nil
  def get(type) do
    Enum.find(list(), &(&1.type == type))
  end

  @doc "Creates a type."
  @spec create(map()) :: {:ok, NotificationType.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    result =
      %NotificationType{}
      |> NotificationType.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, _} -> refresh_cache()
      _ -> :ok
    end

    result
  end

  @doc "Updates a type."
  @spec update(String.t(), map()) :: {:ok, NotificationType.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update(type, attrs) do
    result =
      case Repo.get_by(NotificationType, type: type) do
        nil -> {:error, :not_found}
        nt -> nt |> NotificationType.changeset(attrs) |> Repo.update()
      end

    case result do
      {:ok, _} -> refresh_cache()
      _ -> :ok
    end

    result
  end

  @doc "Deletes a type."
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(type) do
    result =
      case Repo.get_by(NotificationType, type: type) do
        nil -> {:error, :not_found}
        nt -> Repo.delete(nt); :ok
      end

    case result do
      :ok -> refresh_cache()
      _ -> :ok
    end

    result
  end

  @doc "Seeds platform default types if none exist."
  @spec seed_defaults() :: :ok
  def seed_defaults do
    if Repo.aggregate(NotificationType, :count, :id) == 0 do
      defaults()
      |> Enum.each(fn d ->
        %NotificationType{}
        |> NotificationType.changeset(d)
        |> Repo.insert()
      end)
    end

    refresh_cache()
    :ok
  end

  @doc "Returns the list of type names."
  @spec types() :: [String.t()]
  def types do
    list() |> Enum.map(& &1.type)
  end

  @doc "Returns the kind for a type."
  @spec kind(String.t()) :: :transactional | :bulk
  def kind(type) do
    case get(type) do
      nil -> :transactional
      nt -> String.to_atom(nt.kind)
    end
  end

  @doc "Returns required fields for a type."
  @spec required(String.t()) :: [atom()]
  def required(type) do
    case get(type) do
      nil -> []
      nt -> Enum.map(nt.required, &String.to_atom/1)
    end
  end

  @doc "Returns subject template for a type."
  @spec subject_template(String.t()) :: String.t() | nil
  def subject_template(type) do
    case get(type) do
      nil -> nil
      nt -> nt.subject
    end
  end

  @doc "Renders body for a type/format from DB templates."
  @spec render_body(String.t(), :html | :text, keyword()) :: String.t()
  def render_body(type, format, assigns) do
    case get(type) do
      nil -> ""
      nt ->
        src = if format == :html, do: nt.html_template, else: nt.text_template
        EEx.eval_string(src, assigns: assigns) |> IO.iodata_to_binary()
    end
  end

  # Default types, in the order the platform names them. Templates are read
  # from priv/notifiers/<type>/ so they stay editable without Elixir.
  @default_types ~w(welcome password_reset team_invitation account_security
                    email_change_current email_change_new receipt payment_failed)

  defp defaults do
    dir = Path.join(:code.priv_dir(:courier), "notifiers")

    Enum.flat_map(@default_types, fn type ->
      type_dir = Path.join(dir, type)

      with {:ok, json} <- File.read(Path.join(type_dir, "notifier.json")),
           {:ok, meta} <- Jason.decode(json),
           {:ok, html} <- File.read(Path.join(type_dir, "body.html.eex")),
           {:ok, text} <- File.read(Path.join(type_dir, "body.text.eex")) do
        [
          %{
            "type" => meta["type"] || type,
            "kind" => meta["kind"] || "transactional",
            "required" => meta["required"] || [],
            "subject" => meta["subject"],
            "html_template" => html,
            "text_template" => text
          }
        ]
      else
        _ ->
          # Fall back to platform types that ship as compiled EEx templates.
          []
      end
    end)
  end
end