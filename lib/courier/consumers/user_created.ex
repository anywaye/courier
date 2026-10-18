defmodule Courier.Consumers.UserCreated do
  @moduledoc """
  `identity.user.created` → the welcome mail, and the packet's proof that the
  bus is two-ended.

  ## THE EVENT, AND WHY IT IS THE ONE THIS PACKET BUILDS AROUND

  identity publishes this from `internal/outbox/envelope.go`
  (`NewUserCreated`, verified there and **not re-derived here**), appended in
  the same transaction as the user row — an event without a user announces a
  signup that did not happen, and a user without the event is a person nobody
  ever welcoms. **Measured there**: the payload carries exactly two fields —

      user_id, email

  — the subject is the user id, `source` is `identity`, and the type is
  `identity.user.created`. It is emitted when a registration succeeds, BEFORE
  any email verification, so this is the first mail about a person the platform
  has ever sent.

  It was chosen over the other candidates for one reason: **it is the event
  courier can act on completely, with no lookup and no refusal.** The
  invitation event's accept URL is unrecoverable from any payload; the
  acceptance event carries no address. This one carries the recipient and the
  address, which is everything `Deliver.welcome/1` needs. A first consumer
  that refused by design would have left the platform's central promise — "a
  user signs up, and another service does something about it" — still
  unreachable, and the handler chain unexercised on its one positive path.

  ## NO CREDENTIAL IN THE PAYLOAD, AND THE PUBLISHER SAYS WHY

  identity's own comment on `NewUserCreated` is the boundary:

      The payload carries the user id and email and nothing else. In particular
      no password digest and no lockout state: the envelope goes to every
      subscriber on the platform, and this is the only place where that
      boundary is enforced.

  So a welcome mail needs no token and carries none. **The handler reads the
  two fields it needs BY NAME and discards the rest without a word** — the
  same discipline `Courier.Mailers` casts its payloads with — so a publisher
  that later adds a verification link, a display name or anything else cannot
  have it rendered by this handler incidentally. `Courier.Consumers.
  UserCreatedTest` proves the discard on the rendered mail rather than on the
  handler's return, and the one field a future identity build might add
  (a token) is the one this file's test plants and asserts absent.

  ## THE SEND GOES THROUGH `Courier.Deliver`, AND NOT AROUND IT

  Not `Courier.Mailer`, and not a provider call in this module: `Deliver` is
  where the preference check, the per-type unsubscribe check and the mailbox
  suppression check live, and a handler that dialled a provider itself would
  skip all three. A person who turned welcome mail off, or whose address
  hard-bounced, would get one anyway — the exact failure `Courier.Deliver`'s
  moduledoc says those checks exist to prevent. `welcome` is `:transactional`
  in `Courier.Mailers.kinds/0`, so the mail carries no unsubscribe header: the
  remedy courier could offer a person who just signed up is not a link in
  their first email.

  ## THE HANDLER TAKES THE ROW, NOT THE ENVELOPE

  `handle/1` is given the `consumed_events` row rather than the envelope as it
  arrived — the same principle as every handler before it, and for the same
  two reasons: the payload a handler acts on is **byte for byte the payload
  courier stored**, including on a redelivery days later, and what a peer
  receives is the row courier recorded rather than a re-rendering that could
  drift from it.

  ## WHAT THIS HANDLER DOES NOT DO

  It renders nothing of its own. There is a `welcome` template and a `welcome`
  subject in configuration, both of which predate this packet; the handler is
  the caller they were waiting for. It sends no verification mail and mints
  no link — verification is identity's flow and its own mail, and a
  verification link is a minted credential, which is the thing the payload
  boundary above is spent to keep off the bus.
  """

  alias Courier.ConsumedEvent
  alias Courier.Deliver

  @type user :: %{
          required(:user_id) => String.t(),
          required(:email) => String.t()
        }

  # The two fields identity publishes, checked by NAME so the reason names the
  # one that was wrong. Order is the payload's own, so the message a caller
  # sees is the payload's rather than a hash order's.
  @fields ~w(user_id email)

  @event_type "identity.user.created"

  @doc """
  The type this handler is for.

  Named as a function rather than only as the attribute below because the two
  must be the same string, and a test asserting they are is cheaper than a
  refactor that changes one.

  **The attribute is `@event_type` and NOT `@type`** — the built-in typespec
  macro this module's `@type user :: %{...}` already uses, so a
  `fetch_type(%ConsumedEvent{type: @type})` pattern would compare the row's
  type against a **typespec** and every row would fail to match. The same trap,
  and the same reason, as the three handlers before this one.
  """
  @spec type() :: String.t()
  def type, do: @event_type

  @doc """
  Parses one delivered `consumed_events` row into a user, or refuses it.

  **One function with `handle/1`, not two, and that is the registry's
  contract.** `Courier.Consumers` calls `handle/1`, treats `{:ok, _}` as
  "done" and marks the row handled on it — so `handle/1` is the whole job:
  parse, then act. A handler whose `handle/1` only parsed would be marked
  handled while nothing had been sent.

  `{:ok, user}` or one of:

    * `{:error, :unreadable_envelope}` — a row with no `id` to attribute a
      refusal to
    * `{:error, :not_this_event}` — a type this handler is not for
    * `{:error, {:incomplete_payload, field}}` — a payload field missing, or
      not a string

  **The shape is checked before the value is read**, and that ordering is the
  point: `to_string/1` on a list would render `["kaka@example.com"]` into a
  user naming an address that was never there. A refusal produced *by* the
  malformed field cannot quote it correctly.

  Everything else on the payload is discarded by the field list, which is the
  no-credential boundary enforced on the consuming side: see the moduledoc.
  """
  @spec handle(ConsumedEvent.t() | map()) :: {:ok, map()} | {:error, term()}
  def handle(row) do
    with {:ok, user} <- parse(row), do: deliver(user)
  end

  @doc """
  Parses one row into a user, or refuses it. Public because every arm below is
  a refusal that must happen before anything is dialled.
  """
  @spec parse(ConsumedEvent.t() | map()) :: {:ok, user()} | {:error, term()}
  def parse(%ConsumedEvent{id: id} = event) when is_binary(id) and id != "" do
    with :ok <- fetch_type(event),
         {:ok, data} <- fetch_data(event),
         {:ok, fields} <- fetch_fields(data) do
      {:ok, fields}
    end
  end

  def parse(%ConsumedEvent{}), do: {:error, :unreadable_envelope}
  def parse(_not_a_row), do: {:error, :unreadable_envelope}

  @doc """
  Sends the welcome mail, or passes `Courier.Deliver`'s answer through.

  `{:ok, %{message_id: _, event_id: _}}` when the payload can be rendered, and
  `Deliver`'s own refusal unchanged otherwise — a declined preference, a
  suppressed mailbox, a bodiless render. This handler adds no vocabulary of
  its own beyond the parse refusals: a handler that translated another
  module's refusals into its own dialect would put every future caller in the
  position of matching on strings nobody else produces.
  """
  @spec deliver(user()) :: {:ok, map()} | {:error, term()}
  def deliver(user) do
    Deliver.email("welcome", %{
      "user_id" => user.user_id,
      "email" => user.email
    })
  end

  defp fetch_type(%ConsumedEvent{type: @event_type}), do: :ok
  defp fetch_type(%ConsumedEvent{}), do: {:error, :not_this_event}

  defp fetch_data(%ConsumedEvent{data: data}) when is_map(data) do
    if map_size(data) == 0, do: {:error, {:incomplete_payload, "data"}}, else: {:ok, data}
  end

  defp fetch_data(%ConsumedEvent{}), do: {:error, {:incomplete_payload, "data"}}

  defp fetch_fields(data) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(data, field) do
        {:ok, value} when is_binary(value) ->
          {:cont, {:ok, Map.put(acc, String.to_atom(field), value)}}

        _missing_or_wrong_shape ->
          {:halt, {:error, {:incomplete_payload, field}}}
      end
    end)
  end
end
