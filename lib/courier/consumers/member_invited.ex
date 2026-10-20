defmodule Courier.Consumers.MemberInvited do
  @moduledoc """
  `identity.member.invited` → an invitation email, and the refusal that is the
  honest answer for every event this bus will deliver.

  ## THE PAYLOAD GAP, WHICH IS THE SUBJECT OF THIS MODULE

  identity publishes this event from `internal/outbox/tenancy.go`, appended in
  the same transaction as the invitation row. **Measured there, and not
  re-derived here** (it was verified line-by-line on 2026-10-06 and re-checking
  it is not this packet's work): the payload carries exactly five fields —

      account_id, invitation_id, email, role, invited_by_id

  `Courier.Mailers`'s `team_invitation` requires `email`, `url`,
  `account_name`, `invited_by`. **One of the four is in the event.**

  | the template needs | in the event? | recoverable?                       |
  | ------------------ | ------------ | ---------------------------------- |
  | `email`           | yes          | —                                  |
  | `role`            | yes (`role`) | —                                  |
  | `account_name`    | **no**       | yes — `GET /v1/accounts/{id}`       |
  | `invited_by`      | **no**       | yes — the inviter's member record  |
  | `url`             | **no**       | **NO. See below.**                 |

  ## WHY `url` IS THE ONE THAT MATTERS, AND WHY NO LOOKUP CAN FIX IT

  The accept link is built from the invitation's one-time token, and **identity
  returns that token in the `201` and never again.** `internal/accounts/store.go`
  stores `token_digest`; `internal/httpapi/accounts.go` documents the token as
  "returned in the 201 and never again — there is no column holding it, only
  its SHA-256, and no operation that re-reads one." The event carries
  `invitation_id`, and `account_invitations` stores the digest, not the token.

  **So there is no link to render.** Not a missing field courier can fetch: a
  value that was returned once, to a different process, and then never stored.
  Any consumer of this event, in any language, on any bus, has exactly the same
  information courier has, and the same absence.

  ## SO THIS REFUSES, AND THE REFUSAL IS THE DELIVERABLE

  A `team_invitation` with an empty `url` renders `Accept the invitation:`
  followed by nothing — mail to a stranger, on a domain they have no reason to
  trust, ending in a broken promise. `Courier.Mailers` would refuse it anyway
  (`url` is in `required/1`); refusing here is the same answer with the *reason*
  attached, and it is attached to a row an operator can find.

  **The fix belongs in identity** and this repository does not touch identity.
  It is one line in `NewMemberInvited` — carry the token, or a redeemable URL,
  in the payload — and it is REPORTED rather than applied:
  `REPORT-courier-consumer-invite-01`.

  The alternative considered and rejected: look up `account_name` and the
  inviter's name over HTTP anyway. That is a second identity client — a second
  base URL, a second credential, a second failure mode, a second thing to keep
  in step with identity's `openapi.yaml` — in exchange for **a mail with a
  broken link in it**. Strictly worse than refusing, which is why the refusals
  here are refusals rather than "not implemented yet".

  ## WHY THE HANDLER STILL EXISTS, AND STILL PARSES

  Because the wiring is the part that has never been built, and a consumer that
  only appears once the payload is fixed means the first real event on this bus
  is also the first time the loop runs. Parsing the envelope, validating the
  five fields courier *can* read, and refusing the four it cannot — with each
  refusal named — is the whole contract, and it is proven from both sides in
  `Courier.Consumers.MemberInvitedTest`: a counterfactual that sends the mail
  when a `url` is present, so the refusal cannot be a function that refuses
  everything.

  ## NO TOKEN IN THE INVITATION STRUCT, AND THAT IS ASSERTED

  identity's own comment says the event "carries no token, and that is the
  important omission — the raw invitation token exists once, in the 201
  response, and no event on the platform carries a usable credential." The
  struct has no field for one, and the test asserts its absence: an envelope
  carrying a token would be evidence the publisher changed, and this handler
  would then be withholding mail it could send.

  ## THE HANDLER TAKES THE ROW, NOT THE ENVELOPE

  `handle/1` is given the `consumed_events` row rather than the envelope as it
  arrived. Same principle as `Courier.OutboxEvent.envelope/1` on the publishing
  side — build from the stored columns, so what a peer receives is the row
  courier recorded rather than a re-rendering that could drift from it — and it
  has a second consequence here: the payload a handler acts on is **byte for
  byte the payload courier stored**, including on a redelivery days later. A
  handler handed the live envelope could act on a publisher's newest shape for
  an event whose older copy was already refused.
  """

  alias Courier.ConsumedEvent
  alias Courier.Deliver

  @type invitation :: %{
          required(:email) => String.t(),
          required(:account_id) => String.t(),
          required(:invitation_id) => String.t(),
          required(:role) => String.t(),
          required(:invited_by_id) => String.t(),
          optional(:name) => String.t(),
          optional(:account_name) => String.t(),
          optional(:invited_by) => String.t(),
          optional(:url) => String.t()
        }

  # The five fields identity publishes, checked by NAME so the reason names the
  # one that was wrong. Order is the payload's own, so the message a caller sees
  # is the payload's rather than a hash order's.
  @fields ~w(account_id invitation_id email role invited_by_id)

  @event_type "identity.member.invited"

  @doc """
  The type this handler is for.

  Named as a function rather than only as the attribute below because the two
  must be the same string, and a test asserting they are is cheaper than a
  refactor that changes one.

  **The attribute is `@event_type` and NOT `@type`, and that is not a naming
  preference.** `@type` is the built-in typespec macro: this module declares
  `@type invitation :: %{...}` above, so a `fetch_type(%ConsumedEvent{type:
  @type})` pattern expands to comparing the row's type against a **typespec**,
  and every row fails to match. The first draft did exactly that and the symptom
  was `{:error, :not_this_event}` on a row whose type was correct — a handler
  refusing the one event it was written for, which reads exactly like a registry
  misconfiguration and is not one.
  """
  @spec type() :: String.t()
  def type, do: @event_type

  @doc """
  Parses one delivered `consumed_events` row into an invitation, or refuses it.

  **One function, not two, and that is the registry's contract.**
  `Courier.Consumers` calls `handle/1`, treats `{:ok, _}` as "done" and marks
  the row handled on it. A handler whose `handle/1` only *parsed* would
  therefore be marked handled while nothing had been sent — which is the exact
  failure this packet is about, reached one layer in, and the reason the split
  is `parse/1` (public, for tests) and `handle/1` (the whole job).

  The first draft had it the other way round and the integration test in
  `Courier.ConsumersTest` caught it: `handle/1` returned `{:ok, invitation}`,
  the loop marked the row handled, and no mail was ever sent. A unit test for
  `handle/1` alone would have been green throughout.
  """
  @spec handle(ConsumedEvent.t() | map()) :: {:ok, map()} | {:error, term()}
  def handle(row) do
    with {:ok, invitation} <- parse(row), do: deliver(invitation)
  end

  @doc """
  Parses one row into an invitation, or refuses it. Public because every arm
  below is a refusal that must happen before anything is dialled.

  `{:ok, invitation}` or one of:

    * `{:error, :unreadable_envelope}` — a row with no `id` to attribute a
      refusal to
    * `{:error, :not_this_event}` — a type this handler is not for
    * `{:error, {:incomplete_payload, field}}` — a payload field missing, or not
      a string

  **The shape is checked before the value is read**, and that ordering is the
  point: `to_string/1` on a list would render `["invitee@example.com"]` into an
  invitation naming a string that was never there. A refusal produced *by* the
  malformed field cannot quote it correctly.
  """
  @spec parse(ConsumedEvent.t() | map()) :: {:ok, invitation()} | {:error, term()}
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
  Sends the invitation, or refuses because the accept link is unrecoverable.

  `{:ok, %{message_id: _, event_id: _}}` when the payload can be rendered, and
  `{:error, :missing_acceptance_url}` when it cannot.

  **The refusal is checked before anything is dialled**, so it costs nothing and
  leaves no row claiming an invitation went out. `Courier.Mailers` would refuse
  the same payload on `url` being required; this one says so first and with a
  reason about the event rather than about the template.

  ## THE SEND GOES THROUGH `Courier.Deliver`, AND NOT AROUND IT

  Not `Courier.Mailer`, and not a provider call in this module: `Deliver` is
  where the preference check, the per-type unsubscribe check and the mailbox
  suppression check live, and a handler that dialled a provider itself would skip
  all three. An invitee who unsubscribed from team invitations, or whose address
  hard-bounced, would get one anyway — which is the exact failure
  `Courier.Deliver`'s moduledoc says those checks exist to prevent.
  """
  @spec deliver(invitation()) :: {:ok, map()} | {:error, term()}
  def deliver(invitation) do
    with :ok <- fetch_url(invitation) do
      Deliver.email("team_invitation", payload(invitation))
    end
  end

  # THE REFUSAL, AND IT IS NAMED RATHER THAN GUESSED AT.
  #
  # `url` absent is the case identity's design makes permanent: the token is
  # returned once and never stored, so no redelivery and no lookup will ever
  # supply it. The row walks its attempt budget and is then left alone to alert
  # on, which is the honest shape for something that needs a change in another
  # service rather than a retry.
  defp fetch_url(%{url: url}) when is_binary(url) and url != "", do: :ok
  defp fetch_url(_invitation), do: {:error, :missing_acceptance_url}

  # The mapping onto courier's own payload keys. `name` is the invitee's own
  # display name, which the event does not carry (the invitee may have no
  # account, which is the whole point of an invitation), so the template falls
  # back to its own greeting — `Courier.Mailers.greeting/1` handles a nil name
  # and this is not a blank in a person's inbox.
  defp payload(invitation) do
    %{
      "user_id" => user_id(invitation),
      "email" => invitation.email,
      "role" => invitation.role,
      "url" => invitation.url,
      "account_name" => fetch(invitation, :account_name),
      "invited_by" => fetch(invitation, :invited_by),
      "name" => fetch(invitation, :name)
    }
  end

  # `Map.get/3` and not `invitation[:account_name]`: a struct does not implement
  # `Access`, so the bracket form **raises** `FunctionClauseError` on a struct —
  # and raises from inside the consumer's handler, which is the one place a raise
  # becomes a failed row at best. The invitation is a plain map so it would work
  # today; the map form is what stops it becoming a struct in a later packet.
  defp fetch(map, key), do: Map.get(map, key)

  # `user_id` is required by `Courier.Deliver` — a send with no user has no
  # preferences to check and no user to attribute it to, and courier refuses
  # `:missing_user_id` rather than inventing an id.
  #
  # **The invitation id stands in for it, and that is a compromise with a named
  # cost.** An invitee has no user: the invitation exists precisely because
  # they have not signed up. So there is no user id to write. The invitation's
  # own id is used so the row is attributable and the preference check runs
  # against a stable key — and the cost is that an invitee who *does* have an
  # account is checked against the invitation's preferences, not their own.
  #
  # It is stated here rather than fixed because the fix belongs in identity: an
  # `invitee_user_id` on the event, nullable, would let courier branch on it and
  # check the right person's preferences —
  # `Courier.NotificationPreferences.enabled?/3` is the call that would gain a
  # real user id.
  defp user_id(invitation), do: invitation.invitation_id

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
