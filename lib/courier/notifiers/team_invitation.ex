defmodule Courier.Notifiers.TeamInvitation do
  @moduledoc "Notifier for the `team_invitation` type."
  @behaviour Courier.Notifier

  def type, do: "team_invitation"
  def kind, do: :transactional
  def required, do: [:email, :url, :account_name, :invited_by]
  def subject_template, do: nil

  def build(payload) do
    Courier.Mailers.build(type(), payload)
  end
end