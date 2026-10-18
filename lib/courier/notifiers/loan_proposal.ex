defmodule Courier.Notifiers.LoanProposal do
  @moduledoc "Notifier for the `loan_proposal` type."
  @behaviour Courier.Notifier

  def type, do: "loan_proposal"
  def kind, do: :transactional
  def required, do: [:email, :url]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end