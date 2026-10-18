defmodule Courier.Consumers.SessionsRevoked do
  @moduledoc """
  `identity.session.revoked` → the notice a person is owed when their
  credentials end: "your password was changed", or "your email address moved".

  ## THE EVENT, AND WHY THIS HANDLER CAN ACT ON IT

  identity publishes this from `internal/outbox/recovery.go`
  (`NewSessionsRevoked`), in the same transaction as the revocation it
  describes — an event without a revocation announces a compromise that did not
  happen, and a revocation without the event leaves the person unwarned. Two
  call sites: `RedeemPasswordReset` (reason `password reset`) and
  `ConfirmEmailChangeNew` (reason `email address changed`). **Measured there,
  and not re-derived here**: the payload carries exactly three fields —

      user_id, email, reason

  — and the subject is the user id. This is the first event courier consumes
  whose payload is **sufficient for a mail**: the invitation event was missing
  the one field that mattered (the accept URL, unrecoverable by design) and the
  acceptance event carried no address at all. This one carries the recipient
  and the fact, so the handler sends and nothing is looked up.

  ## THE DESIGN DECISION: TWO RENDERINGS, ONE TEMPLATE, A CLOSED SET

  The event covers TWO reasons with one type, and the handler branches on
  `reason` into two renderings of one `account_security` template:

      password reset         → "Your password was changed, …"
      email address changed  → "The email address on your account was changed, …"

  **Why branch at all, rather than mail a reason-agnostic notice.** Because the
  two facts have different remediations, and a notice that does not name which
  one happened forces the reader to guess: a person whose password was changed
  resets it — they still control the address a reset link goes to — while a
  person whose address was moved cannot use a mailed link at all, because the
  address the account now uses is not theirs. "Your account was updated" is the
  shape of mail people learn to ignore, and this is the one mail they must not.

  **Why one template, not two.** One type, one subscription, one
  `notification_type` on the bus. The reason is a rendering choice, not a mail
  type — the same way `welcome` branches on `@url` presence in one template.
  Two templates would double the `kinds` and `required` tables for a fact that
  is one shape: credentials ended, act accordingly.

  **Why an unknown reason is a refusal, not a default.** The closed set is the
  publisher's contract: `validateReason` in the same file refuses a third value
  at build time, and core's payload schema (`additionalProperties: false`,
  `required: [user_id, reason]`) pins the shape. But the publisher's validation
  is not the consumer's boundary — a different publisher, an older build, a
  buggy middlebox — sends what it likes, and the consumer that trusts the
  publisher is the consumer that **renders the wrong reason**: a notice saying
  "your email address was moved" about an admin revocation is a false claim
  about somebody's account, delivered to their inbox. So the handler validates
  the reason itself and refuses `{:error, {:unknown_reason, reason}}` — the
  same fail-closed shape as `Courier.Suppressions`' `{:error,
  {:unknown_bounce_type, value}}`. The row walks its attempt budget and is then
  left alone to alert on, which is the honest shape for "this needs a decision
  in identity, not a retry".

  ## THE ADDRESS, AND WHICH ADDRESS IT IS

  For the email-change reason, the address in the payload is the **new** one —
  `ConfirmEmailChangeNew` reads the user after `SetEmail` in the same
  transaction, so the event carries the address the account now uses. That
  choice is identity's, measured and recorded in
  `REPORT-identity-event-payloads-01.md` §2.3: "a notice confirming a change
  belongs at the address the account now uses." This handler mails what the
  event carries and nothing else — the old-address-as-warning alternative is a
  payload change (the event is one field, not two), not a consumer change.

  ## THE HANDLER TAKES THE ROW, NOT THE ENVELOPE

  `handle/1` is given the `consumed_events` row rather than the envelope as it
  arrived — the same principle as `Courier.Consumers.MemberInvited` and
  `Courier.Consumers.MemberAccepted`, and for the same two reasons: the payload
  a handler acts on is **byte for byte the payload courier stored**, including
  on a redelivery days later, and what a peer receives is the row courier
  recorded rather than a re-rendering that could drift from it.

  ## THE SEND GOES THROUGH `Courier.Deliver`, AND NOT AROUND IT

  Not `Courier.Mailer`, and not a provider call in this module: `Deliver` is
  where the preference check, the per-type unsubscribe check and the mailbox
  suppression check live, and a handler that dialled a provider itself would
  skip all three. A person who disabled this type, or whose address
  hard-bounced, would get a security notice anyway — which is the exact failure
  `Courier.Deliver`'s moduledoc says those checks exist to prevent, reached
  from the consumer side.

  ## WHAT THIS HANDLER ADDS TO COURIER'S VOCABULARY

  One refusal of its own — `{:error, {:unknown_reason, reason}}` — and
  everything else it returns is `Courier.Deliver`'s or `Courier.Mailers`',
  unchanged. A handler that translated another module's refusals into its own
  dialect would put every future caller in the position of matching on strings
  nobody else produces.

  ## THE CORE ENUM GAP, REPORTED AND NOT APPLIED

  Adding `account_security` to `Courier.Mailers.types/0` means the
  `courier.email.delivered` event's `data.notification_type` can carry a fourth
  value, and `core/schemas/events/courier/email/delivered.schema.json` freezes
  that field to an enum of the three current names. The switch is one row here
  plus one enum value in core, and core is not this repository's to change:
  `REPORT-courier-consumer-sessionsrevoked-01.md`.
  """

  alias Courier.ConsumedEvent
  alias Courier.Deliver

  @type revocation :: %{
          required(:user_id) => String.t(),
          required(:email) => String.t(),
          required(:reason) => String.t()
        }

  # The three fields identity publishes, checked by NAME so the reason names
  # the one that was wrong. Order is the payload's own, so the message a caller
  # sees is the payload's rather than a hash order's.
  @fields ~w(user_id email reason)

  # The closed set of reasons identity publishes, transcribed from
  # `internal/outbox/recovery.go` (`ReasonPasswordReset`, `ReasonEmailChanged`)
  # rather than spelled as literals a refactor could silently diverge from.
  # The publisher validates the same set at build time; this is the consumer's
  # own copy of the boundary, because the publisher's validation is not the
  # consumer's.
  #
  # A LIST OF TWO STRINGS and not `~w(...)`: the sigil splits on whitespace, so
  # `~w(password reset email address changed)` is five words and a reason is a
  # phrase. The first draft had exactly that, and every valid reason was
  # refused as unknown — the handler would not mail the one event it was
  # written for, which reads exactly like a registry misconfiguration and is
  # not one.
  @reasons ["password reset", "email address changed"]

  @event_type "identity.session.revoked"

  @doc """
  The type this handler is for.

  Named as a function rather than only as the attribute below because the two
  must be the same string, and a test asserting they are is cheaper than a
  refactor that changes one.

  **The attribute is `@event_type` and NOT `@type`** — the built-in typespec
  macro this module's `@type revocation :: %{...}` already uses, so a
  `fetch_type(%ConsumedEvent{type: @type})` pattern would compare the row's type
  against a **typespec** and every row would fail to match. The same trap, and
  the same reason, as `Courier.Consumers.MemberInvited` and
  `Courier.Consumers.MemberAccepted`.
  """
  @spec type() :: String.t()
  def type, do: @event_type

  @doc """
  Parses one delivered `consumed_events` row into a revocation, or refuses it.

  **One function with `handle/1`, not two, and that is the registry's contract.**
  `Courier.Consumers` calls `handle/1`, treats `{:ok, _}` as "done" and marks
  the row handled on it — so `handle/1` is the whole job: parse, then act. A
  handler whose `handle/1` only parsed would be marked handled while nothing had
  been sent, which is the exact failure the invite packet was about, reached one
  layer in.

  `{:ok, revocation}` or one of:

    * `{:error, :unreadable_envelope}` — a row with no `id` to attribute a
      refusal to
    * `{:error, :not_this_event}` — a type this handler is not for
    * `{:error, {:incomplete_payload, field}}` — a payload field missing, or not
      a string

  **The shape is checked before the value is read**, and that ordering is the
  point: `to_string/1` on a list would render `["owner@example.com"]` into a
  revocation naming a string that was never there. A refusal produced *by* the
  malformed field cannot quote it correctly.

  The reason's VALUE is not checked here — only its shape. That check belongs to
  `deliver/1`, which is where the semantic refusals live, the same way
  `Courier.Consumers.MemberInvited` refuses the unrecoverable `url` in its own
  `deliver/1` and not in `parse/1`.
  """
  @spec handle(ConsumedEvent.t() | map()) :: {:ok, map()} | {:error, term()}
  def handle(row) do
    with {:ok, revocation} <- parse(row), do: deliver(revocation)
  end

  @doc """
  Parses one row into a revocation, or refuses it. Public because every arm
  below is a refusal that must happen before anything is dialled.
  """
  @spec parse(ConsumedEvent.t() | map()) :: {:ok, revocation()} | {:error, term()}
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
  Sends the notice, or passes `Courier.Deliver`'s answer through.

  `{:ok, %{message_id: _, event_id: _}}` when the payload can be rendered, or
  `{:error, {:unknown_reason, reason}}` when the reason is outside the closed
  set. On any other refusal the answer is `Courier.Deliver`'s own, unchanged —
  see the moduledoc on why this handler adds no vocabulary of its own.

  **The reason is validated HERE, before anything is dialled, and that ordering
  is the point**: a refusal produced after the provider was dialled would leave an
  outbox row and a `courier.email.delivered` event for mail nobody received —
  the silent-default failure the adapter work in this repository exists to end,
  reached from the consumer side. The check lives in `deliver/1` and not in
  `parse/1` so that a caller which reaches past `parse/1` — a test, a future
  caller — is refused by the same boundary rather than rendering the wrong
  reason.
  """
  @spec deliver(revocation()) :: {:ok, map()} | {:error, term()}
  def deliver(revocation) do
    with :ok <- fetch_reason(revocation) do
      Deliver.email("account_security", %{
        "user_id" => revocation.user_id,
        "email" => revocation.email,
        "reason" => revocation.reason
      })
    end
  end

  # THE CLOSED SET, CHECKED HERE AND NOWHERE ELSE IN THE HANDLER.
  #
  # `reason` is in `@fields`, so `fetch_fields/1` has already refused a missing
  # or non-string one; this is the second question — a value outside the two
  # identity publishes. The refusal names the value, because an operator
  # reading the row needs to know WHICH reason was unexpected in order to find
  # out who sent it.
  defp fetch_reason(%{reason: reason}) when reason in @reasons, do: :ok

  defp fetch_reason(%{reason: reason}) do
    {:error, {:unknown_reason, reason}}
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
