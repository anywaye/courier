defmodule Courier.Notifiers.PasswordReset do
  @moduledoc "Notifier for the `password_reset` type."
  @behaviour Courier.Notifier

  def type, do: "password_reset"
  def kind, do: :transactional
  def required, do: [:email, :url]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end