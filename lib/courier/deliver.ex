defmodule Courier.Deliver do
  @moduledoc """
  Where courier's three promises meet: the user's preference wins, the
  provider's answer is recorded, and the event describing the send is written in
  the same transaction as the send.

      iex> welcome(%{user_id: user_id, email: email, name: name, url: url})
      {:ok, %{notification_type: "welcome", message_id: message_id, event_id: event_id}}

  The order of the checks is the contract:

    1. **The type is one courier sends.** `:unknown_notification_type` — courier
       does not guess what a caller meant.
    2. **The payload names a user.** `:missing_user_id` — there are no
       preferences to check without one, and no user to attribute the send to.
    3. **The payload can be rendered.** `{:error, {:invalid_payload, changeset}}`
       — refused *before* the provider is asked, because a provider that accepts
       a mail courier cannot build has now sent something to a person.
    4. **The user wants it.** `:suppressed` — no mail, no event, no record of a
       send that did not happen.
    5. **They have unsubscribed from this type.** `{:error, {:unsubscribed, type}}`
       — the recipient pressed the one-click unsubscribe button in a previous
       message (RFC 8058) and courier recorded it. **Per type, not per address**,
       which is the whole reason it is a question of its own.
    6. **The mailbox can receive it.** `{:error, {:suppressed_address, state}}` —
       a hard bounce (RFC 5321 §5.1.1, `:undeliverable`) or a spam complaint
       (RFC 2142 §5, `:suppressed`) recorded by a provider. Also before the
       provider is asked, and also no mail, no event, no record.
    7. **The message has something in it.** `{:error, :empty_message}` — a
       rendered message with neither a text nor an HTML body. `Swoosh` would
       accept it and answer a provider-shaped id, so this is the last check before
       the transaction rather than an afterthought inside it.

  Steps 4, 5 and 6 are three different questions and the order is deliberate: "does
  this person want this mail?" is asked before "can this mailbox still receive
  it?", because the user's own answer is the one they can act on. Steps 5 and 6
  are both about the address and are **not** the same question — 5 is about one
  notification type and 6 is about the mailbox itself, so a person who
  unsubscribed from product updates still gets their password reset. All three
  stop the send: mailing a dead address costs a sending domain its reputation, and
  mailing somebody who unsubscribed or marked you as spam costs more.

  What is left is one transaction: the provider is called and the outbox row is
  written. If the provider refuses, the transaction rolls back and there is
  nothing claiming a mail went out; if it accepts, the row is there to be
  published and the caller gets the message id and the event's id.


  courier's own id (`courier-<uuid>`) is what `subject` and the platform's
  events carry, and it stays. But the provider assigns its own id to the
  message — Cloudflare owns the `Message-ID` and refuses a caller-supplied one,
  so the message that goes out is not the one courier tagged — and the
  provider's OWN bounce and delivery reports quote **its** id, not courier's.
  So the adapter's receipt id is recorded beside courier's in
  `outbox_events.provider_message_id`, in the same transaction as the send, and
  `Courier.InboundReports` joins a report back to the send on either id. A
  receipt that carries no id (a 2xx body with no `message_id`, a shape the
  adapter supports deliberately) records none, and a report courier cannot tie
  to a send still records its suppression and says so — see
  `Courier.InboundReports`.


  A bulk message carries `List-Unsubscribe` and `List-Unsubscribe-Post` (RFC 8058
  §3.1) pointing at a token courier mints for that message, and the token is a
  **row** — so it is written in the same transaction as the send, for the same
  reason the outbox row is. A send that rolled back must not leave a live
  unsubscribe credential behind for a message nobody received.

  Which messages carry the headers is not decided here: `Courier.Unsubscribes.
  decorate_for/3` asks `Courier.Mailers.kind/1`, and all six of courier's types
  are `:transactional`, so today every message comes back untouched and no token
  is minted. `Courier.Unsubscribes` is where that is argued.

  Nothing here touches NATS. The relay that publishes is
  `Courier.Workers.ProcessOutboxWorker`.
  """

  alias Courier.Events
  alias Courier.Mailer
  alias Courier.Mailers
  alias Courier.NotificationPreferences
  alias Courier.Outbox
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppressions
  alias Courier.TenantSendingDomains
  alias Courier.Unsubscribes

  @doc """
  Sends the `welcome` mail — the payload of the platform's user-created event.
  """
  @spec welcome(map()) :: {:ok, map()} | {:error, term()}
  def welcome(payload), do: deliver(:welcome, payload)

  @doc """
  Sends the `password_reset` mail.
  """
  @spec password_reset(map()) :: {:ok, map()} | {:error, term()}
  def password_reset(payload), do: deliver(:password_reset, payload)

  @doc """
  Sends the `team_invitation` mail.
  """
  @spec team_invitation(map()) :: {:ok, map()} | {:error, term()}
  def team_invitation(payload), do: deliver(:team_invitation, payload)

  @doc """
  Sends the `account_security` mail — the notice a person is owed when their
  credentials end: "your password was changed", or "the email address on your
  account was moved".

  The payload carries `user_id`, `email` and `reason`; the template branches on
  `reason` into the two wordings. The reason is validated against its closed set
  by the caller (`Courier.Consumers.SessionsRevoked`) before it reaches here —
  this function renders what it is given, and `Courier.Mailers` requires the
  `reason` so a payload without one is refused rather than rendered into the
  wrong branch.
  """
  @spec account_security(map()) :: {:ok, map()} | {:error, term()}
  def account_security(payload), do: deliver(:account_security, payload)

  @doc """
  Sends the `receipt` mail — the record of a settled payment, and the first
  mail courier sends about MONEY rather than about credentials or membership.

  The payload carries `email` and `amount_display` (required) and
  `invoice_id` (optional): the amount arrives **already rendered** rather than
  as integer minor units, and that is the consumer's job rather than this
  module's — courier has no Money concept and no currency table, and a
  receipt that rendered a number itself would be this repository inventing
  one. See `Courier.Consumers.PaymentSucceeded` for the shape of the event
  this renders and for why the address is on it at all.
  """
  @spec receipt(map()) :: {:ok, map()} | {:error, term()}
  def receipt(payload), do: deliver(:receipt, payload)

  @doc """
  Sends the `payment_failed` mail — the warning a person is owed when a
  payment attempt did not go through, and the receipt's other half.

  The payload carries the same fields the receipt's does — `email` and
  `amount_display` (required), `invoice_id` (optional) — because billing
  builds both events with one builder and one `amount` shape. The retry
  schedule (`next_payment_attempt` on the wire) is deliberately absent from
  the mail: naming it would make courier render a date, and the schedule
  belongs to the processor. See `Courier.Consumers.PaymentFailed` for the
  event and for why the copy asks for the update without announcing an
  ending it cannot see.
  """
  @spec payment_failed(map()) :: {:ok, map()} | {:error, term()}
  def payment_failed(payload), do: deliver(:payment_failed, payload)

  @doc """
  Sends the `email_change_current` mail — the notice to the address the account
  uses today, warning its owner that somebody asked to move it.

  The payload carries `user_id`, `email` and `url`; the `url` is the
  confirmation link the current address's owner acts on. This is the only
  warning an account owner gets that somebody is moving their address, so the
  type is `:transactional` and carries no unsubscribe header: a person who
  must act on an address change must always be able to receive the mail about
  it.
  """
  @spec email_change_current(map()) :: {:ok, map()} | {:error, term()}
  def email_change_current(payload), do: deliver(:email_change_current, payload)

  @doc """
  Sends the `email_change_new` mail — the notice to the address the account is
  moving to, naming the address it is moving from.

  The payload carries `user_id`, `email` and `previous_email`. Like its
  sibling, it is a security notice: `:transactional`, no unsubscribe header.
  """
  @spec email_change_new(map()) :: {:ok, map()} | {:error, term()}
  def email_change_new(payload), do: deliver(:email_change_new, payload)

  @doc """
  Sends the mail for `type`, for a caller that has the type as data rather than
  as a function to call.
  """
  @spec email(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def email(type, payload), do: deliver(type, payload)

  defp deliver(type, payload) do
    with {:ok, type} <- fetch_type(type),
         {:ok, user_id} <- fetch_user_id(payload),
         {:ok, email} <- Mailers.build(type, payload),
         :ok <- fetch_preference(user_id, type),
         :ok <- fetch_unsubscribed(email, type),
         :ok <- fetch_address(email),
         :ok <- fetch_body(email),
         {:ok, sender} <- fetch_sender(email) do
      send_and_record(type, user_id, email, sender)
    end
  end

  defp fetch_type(type) do
    if to_string(type) in Courier.Notifiers.types() do
      {:ok, to_string(type)}
    else
      {:error, :unknown_notification_type}
    end
  end

  defp fetch_user_id(payload) do
    case Mailers.user_id(payload) do
      nil -> {:error, :missing_user_id}
      user_id -> {:ok, user_id}
    end
  end

  defp fetch_preference(user_id, type) do
    if NotificationPreferences.enabled?(user_id, type, :email) do
      :ok
    else
      {:error, :suppressed}
    end
  end

  defp fetch_unsubscribed(email, type) do
    if Suppressions.unsubscribed?(recipient(email), type) do
      {:error, {:unsubscribed, type}}
    else
      :ok
    end
  end

  defp fetch_address(email) do
    case Suppressions.state(recipient(email)) do
      nil -> :ok
      state -> {:error, {:suppressed_address, state}}
    end
  end

  defp fetch_body(email) do
    if Mailers.body?(email), do: :ok, else: {:error, :empty_message}
  end

  defp fetch_sender(email) do
    domain = from_domain(email)

    case TenantSendingDomains.for_domain(domain) do
      %Courier.TenantSendingDomain{verified_at: nil} ->
        {:error, {:unverified_sending_domain, domain}}

      %Courier.TenantSendingDomain{status: :revoked} ->
        {:error, {:revoked_sending_domain, domain}}

      %Courier.TenantSendingDomain{} = row ->
        {:ok, {:tenant, row}}

      nil ->
        if domain == Mailers.deployment_domain() do
          {:ok, :deployment}
        else
          {:error, {:no_sending_domain, domain}}
        end
    end
  end

  defp from_domain(%Swoosh.Email{from: {_name, address}}) do
    address |> String.downcase() |> String.split("@") |> List.last()
  end

  defp send_and_record(type, user_id, email, sender) do
    message_id = "courier-" <> Ecto.UUID.generate()

    case Repo.transaction(fn ->
           case Unsubscribes.decorate_for(type, user_id, email) do
             {:ok, email} ->
               case deliver_to_provider(tag(email, message_id), sender) do
                 {:ok, receipt} ->
                   record(type, user_id, message_id, provider_message_id(receipt), email)

                 {:error, reason} ->
                   {:error, {:provider, reason}}
               end

             {:error, reason} ->
               {:error, {:unsubscribe, reason}}
           end
         end) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, {:provider, reason}}} ->
        {:error, {:delivery_failed, reason}}

      {:ok, {:error, {:unsubscribe, reason}}} ->
        {:error, {:unsubscribe_failed, reason}}

      {:ok, {:error, %Ecto.Changeset{} = changeset}} ->
        {:error, {:event_not_recorded, changeset}}

      {:error, reason} ->
        {:error, {:event_not_recorded, reason}}
    end
  end

  defp deliver_to_provider(email, :deployment), do: Mailer.deliver(email)

  defp deliver_to_provider(email, {:tenant, row}) do
    case TenantSendingDomains.adapter_config(row) do
      {:ok, config} -> Mailer.deliver(email, config)
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(type, user_id, message_id, provider_message_id, email) do
    case Outbox.insert(
           %OutboxEvent{}
           |> OutboxEvent.changeset(%{
             type: Events.delivered_type(),
             subject: message_id,
             provider_message_id: provider_message_id,
             data: data(user_id, type, message_id, email)
           })
         ) do
      {:ok, event} ->
        {:ok, %{notification_type: type, message_id: message_id, event_id: event.id}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp provider_message_id(%{id: id}) when is_binary(id), do: id
  defp provider_message_id(%{"id" => id}) when is_binary(id), do: id
  defp provider_message_id(_receipt), do: nil

  defp data(user_id, type, message_id, email) do
    %{
      "message_id" => message_id,
      "user_id" => user_id,
      "notification_type" => type,
      "email" => recipient(email)
    }
  end

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address

  defp tag(email, message_id) do
    Swoosh.Email.header(email, "message-id", "<#{message_id}@anywaye.com>")
  end
end
