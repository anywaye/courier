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

  ## The one-click unsubscribe, and why it is inside that transaction

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
    if to_string(type) in Mailers.types() do
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

  # **After** the preference and not before, which is the order
  # `Courier.Suppressions`'s own moduledoc states: "does this person want this
  # mail?" is asked before "can this mailbox still receive it?". Both stop the
  # send; the order decides which refusal a caller is told about, and the user's
  # own answer is the one they can act on — changing an address they no longer
  # want mail at would be a strange remedy to offer.
  #
  # And **this one is per type while `fetch_address/1` is not**, which is the
  # whole reason a one-click unsubscribe is a state-less `email_suppressions` row
  # rather than a stateful one. It asks "has this person asked not to receive
  # *this* kind of mail at this address", and the answer for `product_update` says
  # nothing about `password_reset`. See `Courier.Unsubscribes`.
  defp fetch_unsubscribed(email, type) do
    if Suppressions.unsubscribed?(recipient(email), type) do
      {:error, {:unsubscribed, type}}
    else
      :ok
    end
  end

  # It is here rather than in an HTTP controller because a hard-bounced mailbox
  # does not get mail *whatever the caller asked for*, and every caller of this
  # module is a caller of that promise. `Courier.Suppressions` answers
  # `suppressed?/1` and `state/1`; the state is read rather than the boolean
  # because the two mean different things to whoever reads the refusal — a pile of
  # `:undeliverable` is list hygiene, a pile of `:suppressed` is a content and
  # sender-reputation problem — and a boolean would have thrown that away.
  #
  # `state/1` costs one `EXISTS` per state it tests, up to two, on the path every
  # send takes. That is a deliberate trade for a reason that is not performance: the
  # fold is documented as the precedence, and calling it is how a caller cannot
  # reimplement the precedence wrongly.
  defp fetch_address(email) do
    case Suppressions.state(recipient(email)) do
      nil -> :ok
      state -> {:error, {:suppressed_address, state}}
    end
  end

  # The last thing checked before the provider, and the cheapest thing to get
  # wrong: `Swoosh` delivers a bodiless email and answers a provider-shaped id, so
  # without this a message with nothing in it would be recorded as delivered and
  # published as `courier.email.delivered`. See `Courier.Mailers.body?/1`.
  defp fetch_body(email) do
    if Mailers.body?(email), do: :ok, else: {:error, :empty_message}
  end

  # The sender is chosen by the FROM DOMAIN, and it is the one step that can
  # refuse a send on a fact about the deployment rather than about the
  # recipient. See `Courier.TenantSendingDomains` for the whole model; what is
  # here is the decision, in the three shapes there are:
  #
  #   * a domain this account has a VERIFIED, ENABLED row for — the tenant's
  #     credential, opened by `Courier.TenantSendingDomains.adapter_config/1`
  #     and handed to the provider as a per-call config override.
  #   * a domain this account has a row for that is NOT usable — unverified,
  #     or revoked — a REFUSAL. This is the whole point of the per-tenant
  #     domain: a domain somebody claimed and did not prove (or proved and
  #     then gave up) must not silently fall back to the deployment
  #     credential, because that is one tenant's mail leaving on a domain it
  #     did not prove, which is the exact failure this table exists to
  #     prevent.
  #   * a domain with NO row at all:
  #       - the DEPLOYMENT's own configured from-domain — the deployment's
  #         own mail. The global adapter path is untouched and the deployment
  #         credential sends it, exactly as it does today. A deployment does
  #         not refuse its own mail for not having been claimed.
  #       - anything else — a REFUSAL. A from-address courier was never
  #         configured to send as is not "the deployment's own mail", and
  #         sending it on the deployment credential is a silent fallback to a
  #         domain the message does not come from. `{:no_sending_domain,
  #         domain}` is named for exactly that, and there is no branch below
  #         that reaches the provider without a sender.
  #
  # The account scoping is the table's row-level security, not a predicate
  # here: a domain another account registered is invisible to this query, so
  # the answer for it is the same `nil` as "never registered" — which is
  # correct, because a tenant cannot send from a domain it did not register
  # and cannot even learn that another tenant did.
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

  # The from-address is where the sender is chosen: `Courier.Mailers` builds
  # the message with the deployment-configured `from`, and the domain part of
  # that address is the key the credential lookup uses. Everything courier
  # sends today is from `no-reply@cafaye.com` — the deployment's own
  # configured domain — so every current send takes the deployment branch and
  # the global adapter path's behaviour is unchanged for the mail that exists.
  # A tenant's domain selects the tenant's credential, and a from-address that
  # is neither is refused rather than sent on the deployment key.
  defp from_domain(%Swoosh.Email{from: {_name, address}}) do
    address |> String.downcase() |> String.split("@") |> List.last()
  end

  # The provider call is inside the transaction on purpose. The send is the state
  # change and the row records it, and a row that exists for a send that did not
  # happen is a lie the platform will act on. The cost is that courier holds a
  # transaction open across a network call; that is the outbox's price, not a
  # mistake, and a send is one HTTP request.
  #
  # **The one-click unsubscribe token is minted in here too, and for the same
  # reason.** It is a row that exists because of this send, so a send that rolled
  # back must not leave one behind: a token nobody was ever offered is a live
  # credential for an unsubscribe, for an address about to be sent mail by somebody
  # else. `Courier.Unsubscribes.decorate_for/3` is one call and it decides the
  # whole thing — a transactional type comes back untouched with no row, a bulk one
  # comes back with the two RFC 8058 headers and a token — so the conditional does
  # not live in this module and cannot drift from the kind table.
  #
  # **The failure paths below return values, and never `Repo.rollback/1`.**
  # A rollback is control flow here — on every path that reaches one, nothing
  # has been written yet (`decorate_for/3` mints nothing for the transactional
  # types courier sends today, and a failed insert wrote nothing) — so
  # committing an empty transaction is observably identical to rolling one
  # back. The reason it is written this way rather than the shorter way is
  # that this transaction nests: `POST /v1/messages` runs it inside the
  # request's own `Courier.Tenancy.with_account/3` scope, and nested Ecto
  # transactions are NOT savepoints — an inner rollback fails the OUTER
  # commit as `{:error, :rollback}`, turning a provider refusal the caller
  # should retry into a 503 about scoping and crashing the idempotency store
  # in `before_send` on the already-doomed transaction. Measured, not
  # reasoned: those are the two red tests this shape answers.
  # (`Courier.Idempotency.claim/1` keeps the same rule for the same reason,
  # with `mode: :savepoint` on the operation rather than a transaction.)
  #
  # The one direction this is weaker than a rollback, stated rather than
  # hidden: a FUTURE bulk type's token row, minted by `decorate_for/3`
  # before the provider is dialled, would COMMIT on a provider refusal
  # instead of rolling back with the send. No bulk type exists today, and
  # adding one is a change in `cafaye/core` (the event enum) plus one row in
  # `Courier.Mailers.kinds/0` — whoever makes that change must revisit this
  # function, and this paragraph is how they will know.
  defp send_and_record(type, user_id, email, sender) do
    message_id = "courier-" <> Ecto.UUID.generate()

    case Repo.transaction(fn ->
           case Unsubscribes.decorate_for(type, user_id, email) do
             {:ok, email} ->
               case deliver_to_provider(tag(email, message_id), sender) do
                 {:ok, _metadata} -> record(type, user_id, message_id, email)
                 {:error, reason} -> {:error, {:provider, reason}}
               end

             {:error, reason} ->
               {:error, {:unsubscribe, reason}}
           end
         end) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      # The three failures are kept apart on the way out, because a caller acts on
      # them differently: a provider that said no is worth retrying, a row that
      # could not be written is an incident, and a token that could not be minted
      # is neither — nothing was sent, and the identical request is safe to repeat.
      {:ok, {:error, {:provider, reason}}} ->
        {:error, {:delivery_failed, reason}}

      {:ok, {:error, {:unsubscribe, reason}}} ->
        {:error, {:unsubscribe_failed, reason}}

      {:ok, {:error, %Ecto.Changeset{} = changeset}} ->
        {:error, {:event_not_recorded, changeset}}

      # A genuine commit failure rather than a refusal carried as data: the
      # transaction did not commit, so by the contract above nothing was sent
      # and nothing was recorded. Unreachable on every path the suite drives —
      # every refusal above arrives inside `{:ok, …}` — and handled as the
      # incident it would be rather than matched away, because a control that
      # raises `CaseClauseError` on a shape it cannot explain is one whose
      # failure nobody has diagnosed.
      {:error, reason} ->
        {:error, {:event_not_recorded, reason}}
    end
  end

  # Where the sender chosen by `fetch_sender/1` actually reaches the provider.
  # The deployment branch calls `Mailer.deliver/1` and is byte-for-byte what
  # courier did before this table existed — the global `config :courier,
  # Courier.Mailer` adapter and its credential. The tenant branch opens the
  # row's sealed credential and passes a per-call config override to
  # `Mailer.deliver/2`, which `Swoosh.Mailer.parse_config/4` merges OVER the
  # deployment's adapter configuration for this one send and persists nowhere.
  #
  # `adapter_config/1` answering `{:error, :invalid_credential}` is a refusal
  # like any other: a credential courier cannot open is a credential courier
  # cannot send with, and it becomes `{:error, {:delivery_failed, …}}` rather
  # than a crash or a silent fall back to the deployment key.
  defp deliver_to_provider(email, :deployment), do: Mailer.deliver(email)

  defp deliver_to_provider(email, {:tenant, row}) do
    case TenantSendingDomains.adapter_config(row) do
      {:ok, config} -> Mailer.deliver(email, config)
      {:error, reason} -> {:error, reason}
    end
  end

  # **The row and the relay job are written by one call, in one transaction.**
  # `Courier.Outbox.insert/1` is the whole outbox write path: it queues the
  # publish as part of the insert, so a committed row always has something waiting
  # to publish it and a rolled-back send leaves neither behind. See
  # `Courier.Outbox` for why the alternative — insert here, enqueue on the way out
  # — reintroduces the "the state changed and nobody was told" failure this table
  # exists to make impossible.
  defp record(type, user_id, message_id, email) do
    case Outbox.insert(
           %OutboxEvent{}
           |> OutboxEvent.changeset(%{
             type: Events.delivered_type(),
             subject: message_id,
             data: data(user_id, type, message_id, email)
           })
         ) do
      {:ok, event} ->
        {:ok, %{notification_type: type, message_id: message_id, event_id: event.id}}

      # A value, not a rollback, for the reason `send_and_record/3` gives: a
      # failed insert wrote nothing, so there is nothing to undo, and a nested
      # rollback would fail the request's own scoped commit. (`outbox_events`
      # carries no database-level uniqueness for a valid changeset to trip —
      # only indexes — so this failure is an Elixir-side changeset, decided
      # before any statement ran, and the enclosing transaction is healthy.)
      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # The send's own fields, and nothing from the payload: this goes to every
  # subscriber on the bus, and a verification token or an invitation id in there
  # would be a credential leak into a fan-out. The recipient is here because a
  # consumer that has to ask "who got this?" in order to act on it will not.
  defp data(user_id, type, message_id, email) do
    %{
      "message_id" => message_id,
      "user_id" => user_id,
      "notification_type" => type,
      "email" => recipient(email)
    }
  end

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address

  # A real Message-ID header carrying the id courier returns and records, so a
  # bounce or a complaint that quotes it can be tied back to the row.
  defp tag(email, message_id) do
    Swoosh.Email.header(email, "message-id", "<#{message_id}@cafaye.com>")
  end
end
