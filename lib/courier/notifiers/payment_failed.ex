defmodule Courier.Notifiers.PaymentFailed do
  @moduledoc "Notifier for the `payment_failed` type."
  @behaviour Courier.Notifier

  def type, do: "payment_failed"
  def kind, do: :transactional
  def required, do: [:email, :amount_display]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end