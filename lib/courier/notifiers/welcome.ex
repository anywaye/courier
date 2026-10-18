defmodule Courier.Notifiers.Welcome do
  @moduledoc "Notifier for the `welcome` type."
  @behaviour Courier.Notifier

  def type, do: "welcome"
  def kind, do: :transactional
  def required, do: [:email]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end