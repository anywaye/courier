defmodule Courier.Notifier do
  @moduledoc """
  The contract a notification type implements.

  A notifier is the courier equivalent of a `noticed` Event class: one module
  per notification type, declaring how it is rendered and what it needs. courier
  itself ships none of these — they are registered by the consuming application
  via `config :courier, :notifiers, [MyApp.Notifiers.Receipt, ...]`. The
  modules courier's own tests register are the platform's defaults, and a
  product that wants a new type adds a module rather than editing a list.

  Implementing this behaviour is the whole of adding a type. `Courier.Notifiers`
  discovers registered modules, and `Courier.Deliver.deliver/2` drives them.
  """

  @typedoc "The notification type's name, as a string."
  @type type :: String.t()

  @typedoc "What a message is for."
  @type kind :: :transactional | :bulk

  @callback type() :: type()

  @callback kind() :: kind()

  @callback required() :: [atom()]

  @callback build(payload :: map()) ::
              {:ok, Swoosh.Email.t()} | {:error, atom() | {:invalid_payload, Ecto.Changeset.t()}}

  @callback subject_template() :: String.t() | nil

  @optional_callbacks [subject_template: 0]
end