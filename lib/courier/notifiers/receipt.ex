defmodule Courier.Notifiers.Receipt do
  @moduledoc "Notifier for the `receipt` type."
  @behaviour Courier.Notifier

  def type, do: "receipt"
  def kind, do: :transactional
  def required, do: [:email, :amount_display]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end