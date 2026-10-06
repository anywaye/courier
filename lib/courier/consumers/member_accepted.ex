defmodule Courier.Consumers.MemberAccepted do
  @moduledoc """
  `identity.member.accepted` → an in-app notification: "you're in".

  ## THE EVENT, AND THE PAYLOAD IT CARRIES

  identity publishes this from `internal/outbox/tenancy.go` (`NewMemberAccepted`),
  in the same transaction as the membership it describes — an event without a
  membership announces somebody joined who did not, and a membership without the
  event leaves a consumer's member list permanently one short. **Measured there,
  and not re-derived here**: the payload carries exactly three fields —

      account_id, user_id, role

  — and the subject is the account id. It is emitted when an invitation is
  redeemed and the membership is created (`internal/accounts/service.go`, the
  accept flow).

  ## THE NAME DIVERGENCE, CONSUMED AND NOT RESOLVED

  core's catalog (`core/docs/event-naming.md`) calls this fact
  `identity.member.joined`; identity publishes `accepted` per the packet decision
  recorded in the source comment at `tenancy.go:55-70`. **This handler subscribes
  to what is actually published** — a subscription to a type no publisher declares
  fails on somebody else's deploy (core's rule 6) — and the divergence is
  reported rather than renamed: `REPORT-courier-consumer-memberaccepted-01.md`.

  ## THE SURFACE DECISION: IN-APP, AND THE PAYLOAD IS WHY

  Two delivery surfaces exist in courier, and the payload decides which one is
  actionable:

    * **In-app notification** — `Courier.Notifications.record/2` takes an account,
      a recipient and a type. The payload **has** `user_id`, which is a real
      person: they just accepted, so the row exists. **This surface is actionable
      now**, and this is the first production caller `Courier.Notifications` has
      ever had.
    * **Email** — `Courier.Mailers` + `Courier.Deliver`. The payload has **no
      address**, and courier has deliberately no identity client
      (`REPORT-courier-consumer-invite-01.md` §2.6 — a second identity client in
      exchange for one field was refused, and the refusal stands). The mail a
      member would want ("you joined account X") also needs `account_name`,
      which the payload does not carry and courier cannot look up.

  **So this handler records a notification and mails nobody.** Not a gap to be
  filled in later: the unblock is one line in identity's `NewMemberAccepted`
  (carry the member's address), and until it lands, a mail with a blank where
  the address — or the account name — should be is the exact failure the invite
  packet refused to send. The refusal is named in the report, not coded here:
  a handler that never attempts email has no email-refusal branch to write.

  ## THE NOTIFICATION TYPE IS `welcome`, AND THAT IS A CLOSED-VOCABULARY DECISION

  `Courier.Notifications.types/0` is `welcome`, `mention`, `assignment`,
  `comment`, `billing`. A member who just accepted is being told they are in:
  `welcome` is that type. **Inventing a `member_joined` type was considered and
  rejected**, and the reason is the in-app packet's own warning: a new type is a
  decision about how a consumer renders it, this module renders nothing, and
  "naming a type with no renderer behind it is how a type ships that nothing can
  display" (`REPORT-courier-inapp-notifications-01.md`). `welcome` has a
  renderer's worth of semantics behind it already; a second name for the same
  fact would not have.

  ## WHAT `params` CARRIES, AND WHAT IT DELIBERATELY DOES NOT

  `params` is `%{"role" => role}` — the one fact a renderer needs that is not
  already a column on the event row. Three absences are decisions:

    * **No `account_id` in params.** It is a column on `notification_events`;
      duplicating it into jsonb would be two copies of one fact that can
      disagree, which is the failure `Courier.Notifications`' own moduledoc
      refuses for the two rows it writes.
    * **No account name.** The payload does not carry one and courier cannot
      look one up — the same absence that makes the email unactionable. A
      renderer shows the account by id, or by whatever name IT can resolve;
      courier writing a blank where the name should be is the one outcome this
      packet exists to prevent.
    * **No `record_type`/`record_id`.** The event happened to a membership, and
      the payload carries no membership id — a polymorphic reference to a row
      courier cannot name is a pointer that 04s, which is the failure
      `Courier.NotificationEvent`'s moduledoc lists as the reason the pair is
      validated in the first place.

  ## THE HANDLER TAKES THE ROW, NOT THE ENVELOPE

  `handle/1` is given the `consumed_events` row rather than the envelope as it
  arrived — the same principle as `Courier.Consumers.MemberInvited`, and for the
  same two reasons: the payload a handler acts on is **byte for byte the payload
  courier stored**, including on a redelivery days later, and what a peer
  receives is the row courier recorded rather than a re-rendering that could
  drift from it.

  ## WHAT THIS HANDLER ADDS TO COURIER'S VOCABULARY

  Nothing beyond the parse refusals every handler has. A payload it can parse is
  recorded through `Courier.Notifications.record/2` and whatever that answers —
  `{:ok, _}`, `{:error, {:event, changeset}}`, `{:error, {:notification, _}}` —
  is returned **unchanged**. A handler that translated another module's refusals
  into its own dialect would put every future caller in the position of matching
  on strings nobody else produces.
  """

  alias Courier.ConsumedEvent
  alias Courier.Notifications

  @type membership :: %{
          required(:account_id) => String.t(),
          required(:user_id) => String.t(),
          required(:role) => String.t()
        }

  # The three fields identity publishes, checked by NAME so the reason names the
  # one that was wrong. Order is the payload's own, so the message a caller sees
  # is the payload's rather than a hash order's.
  @fields ~w(account_id user_id role)

  @event_type "identity.member.accepted"

  @doc """
  The type this handler is for.

  Named as a function rather than only as the attribute below because the two
  must be the same string, and a test asserting they are is cheaper than a
  refactor that changes one.

  **The attribute is `@event_type` and NOT `@type`** — the built-in typespec
  macro this module's `@type membership :: %{...}` already uses, so a
  `fetch_type(%ConsumedEvent{type: @type})` pattern would compare the row's type
  against a **typespec** and every row would fail to match. The same trap, and
  the same reason, as `Courier.Consumers.MemberInvited`.
  """
  @spec type() :: String.t()
  def type, do: @event_type

  @doc """
  Parses one delivered `consumed_events` row into a membership, or refuses it.

  **One function with `handle/1`, not two, and that is the registry's contract.**
  `Courier.Consumers` calls `handle/1`, treats `{:ok, _}` as "done" and marks the
  row handled on it — so `handle/1` is the whole job: parse, then act. A handler
  whose `handle/1` only parsed would be marked handled while nothing had been
  recorded, which is the exact failure the invite packet was about, reached one
  layer in.

  `{:ok, membership}` or one of:

    * `{:error, :unreadable_envelope}` — a row with no `id` to attribute a
      refusal to
    * `{:error, :not_this_event}` — a type this handler is not for
    * `{:error, {:incomplete_payload, field}}` — a payload field missing, or not
      a string

  **The shape is checked before the value is read**, and that ordering is the
  point: `to_string/1` on a list would render `["member"]` into a membership
  naming a string that was never there. A refusal produced *by* the malformed
  field cannot quote it correctly.
  """
  @spec handle(ConsumedEvent.t() | map()) :: {:ok, map()} | {:error, term()}
  def handle(row) do
    with {:ok, membership} <- parse(row), do: notify(membership)
  end

  @doc """
  Parses one row into a membership, or refuses it. Public because every arm
  below is a refusal that must happen before anything is written.
  """
  @spec parse(ConsumedEvent.t() | map()) :: {:ok, membership()} | {:error, term()}
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
  Records the notification, or passes `Courier.Notifications`' answer through.

  `{:ok, %{event: _, notifications: [_]}}` on success. On a refusal the answer is
  `Courier.Notifications`' own, unchanged — see the moduledoc on why this handler
  adds no vocabulary of its own.

  **The account comes from the payload and the recipient from the payload, and
  neither is invented.** The member who accepted is the recipient: `user_id` is
  a real person, which is the whole reason this surface is actionable. The
  account is the event's subject and payload `account_id` — the same value, read
  from the payload because that is what the publisher sent and the row stored.
  """
  @spec notify(membership()) ::
          {:ok, %{event: term(), notifications: [term()]}} | {:error, term()}
  def notify(membership) do
    Notifications.record(membership.account_id,
      type: "welcome",
      recipient: {"user", membership.user_id},
      params: %{"role" => membership.role}
    )
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
