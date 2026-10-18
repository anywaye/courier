defmodule Courier.Notifiers.EmailChangeCurrent do
  @moduledoc "Notifier for the `email_change_current` type."
  @behaviour Courier.Notifier

  def type, do: "email_change_current"
  def kind, do: :transactional
  def required, do: [:email, :url]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end