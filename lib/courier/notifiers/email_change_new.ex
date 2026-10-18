defmodule Courier.Notifiers.EmailChangeNew do
  @moduledoc "Notifier for the `email_change_new` type."
  @behaviour Courier.Notifier

  def type, do: "email_change_new"
  def kind, do: :transactional
  def required, do: [:email, :previous_email]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end