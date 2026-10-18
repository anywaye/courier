defmodule Courier.Notifiers do
  @moduledoc """
  Registry of notification types courier knows how to send. Backed by the
  `notification_types` table (DB), so types can be added at runtime via the
  HTTP API without Elixir or restarts.
  """

  alias Courier.NotificationTypes

  @spec all() :: [Courier.NotificationType.t()]
  def all, do: NotificationTypes.list()

  @spec types() :: [String.t()]
  def types, do: NotificationTypes.types()

  @spec get(String.t() | atom()) :: Courier.NotificationType.t() | nil
  def get(type), do: NotificationTypes.get(to_string(type))

  @spec kind(String.t() | atom()) :: :transactional | :bulk
  def kind(type), do: NotificationTypes.kind(to_string(type))

  @spec bulk?(String.t() | atom()) :: boolean()
  def bulk?(type), do: kind(type) == :bulk

  @spec required(String.t() | atom()) :: [atom()]
  def required(type), do: NotificationTypes.required(to_string(type))

  @spec subject_template(String.t() | atom()) :: String.t() | nil
  def subject_template(type), do: NotificationTypes.subject_template(to_string(type))

  @spec render_body(String.t(), :html | :text, keyword()) :: String.t()
  def render_body(type, format, assigns) do
    NotificationTypes.render_body(to_string(type), format, assigns)
  end

  @spec build(String.t() | atom(), map()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def build(type, payload) when is_map(payload) do
    Courier.Mailers.build(to_string(type), payload)
  end
end