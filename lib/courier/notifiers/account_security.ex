defmodule Courier.Notifiers.AccountSecurity do
  @moduledoc "Notifier for the `account_security` type."
  @behaviour Courier.Notifier

  def type, do: "account_security"
  def kind, do: :transactional
  def required, do: [:email, :reason]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end