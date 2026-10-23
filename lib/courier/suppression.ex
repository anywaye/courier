defmodule Courier.Suppression do
  @moduledoc """
  One provider's report about one address, and the state courier took from it.

  A row is **immutable**. Nothing in courier updates one, which is the whole
  reason the packet's precedence rule cannot be got wrong: `Courier.Suppressions`
  derives an address's state by folding over the rows that exist rather than by
  mutating one to a stronger value, so "a complaint is never downgraded by a later
  bounce" is not a rule somebody has to remember in a `case` — it is a property of
  there being nothing to update. See that module's moduledoc.

  `state` is courier's own vocabulary and not the provider's: a Postmark
  `HardBounce` and an SES `Permanent` are both `:undeliverable` here, because the
  question courier asks is not "what did Postmark call it" but "can this mailbox
  receive mail". `reason` keeps the provider's own words, bounded, because when an
  operator asks courier why an address is suppressed the useful answer is the
  provider's sentence and not courier's enum.

  ## `state` may be absent, and that is not a third value

  The column is `NOT NULL` in the database for every row a **provider** produces,
  and `create_email_suppressions` argues for it at length: "a hard bounce marks the
  address `undeliverable`, a complaint marks it `suppressed`, and there is no third
  'suppressed: true' boolean that cannot say which." All of that still holds — this
  is still an `Ecto.Enum` of two values, resolved in a changeset, with no database
  CHECK and no third value.

  What a later migration added is the possibility of **no** state, which is a
  different statement from a third one: it says the row is not a fact about the
  mailbox at all. Only `unsubscribe_changeset/2` can write one, and it never casts
  `state`, so "a row with no state" and "a row written by the unsubscribe
  endpoint" are the same row. `Courier.Suppressions.state/1` has folded that case
  to `nil` since before the column was nullable, and `suppressed?/1` and `find/1`
  filter on it already.

  ## The two columns a provider does not fill in

  `notification_type` and `user_id` are both nullable and both are set **only** by
  an unsubscribe, which is a report about an address that courier wrote itself
  rather than one a provider sent:

    * **`notification_type` is what makes a row an instruction rather than a
      fact.** RFC 8058's one-click unsubscribe stops ONE kind of mail. A bounce
      and a complaint carry a `state` and stop all of it, because they are facts
      about the mailbox; an unsubscribe carries **no state at all** — `nil` is the
      whole mechanism — and is read back by
      `Courier.Suppressions.unsubscribed?/2` against this column. `Courier.
      Unsubscribes` is where that argument is made in full; the migration's
      comment is where the consequence is, which is that a *stateful* unsubscribe
      row would mean a person who stops receiving product updates can no longer
      reset their password.
    * **`user_id` is the attribution a provider cannot give.** A bounce report
      names an address and nobody upstream knows which person it belongs to; a row
      that guessed would put a stranger's uuid on a fact about a mailbox. An
      unsubscribe is different — courier minted the token when it sent the message,
      so it knows, and core's `courier.notification.suppressed` schema requires the
      user as the envelope's subject. It is here so the row is interpretable on its
      own rather than only by joining to a token.

  ## What is deliberately absent

  There is no column for the provider's payload. A bounce report carries
  addresses, reasons, and sometimes a message snippet, and the four facts courier
  acts on are the four it stores. A schema that had a `payload` map would be a
  copy of somebody's inbox held for no operational reason, and
  `Courier.SuppressionsTest` asserts the field list so adding one is a decision
  somebody reads. The two above are the exceptions, and each is a fact courier
  knows rather than a fact somebody reported.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Courier.Suppressions

  @states [:undeliverable, :suppressed]

  # Bounded on the three free-text columns, and the bound is HERE rather than in a
  # `size:` on the column. A provider's reason is a sentence and a provider's
  # event id is an opaque identifier, but neither is courier's to size: a provider
  # that puts a payload in the reason should not be able to write a megabyte into
  # a table the send path reads, and a provider whose event id is 300 characters
  # should be refused by a changeset error rather than by a `varchar(255)`
  # truncation at runtime. Both columns are `text` in the migration so that this
  # is the only bound — see its moduledoc.
  @reason_length 500
  @message_id_length 512
  @provider_event_id_length 512

  @primary_key {:id, Ecto.UUID, autogenerate: true}

  @type t :: %__MODULE__{}

  @doc false
  def states, do: @states

  @doc false
  def reason_length, do: @reason_length

  schema "email_suppressions" do
    field :email, :string
    field :state, Ecto.Enum, values: @states
    field :provider, :string
    field :provider_event_id, :string

    field :reason, :string
    field :message_id, :string
    field :occurred_at, :utc_datetime_usec

    # The two an unsubscribe fills in and a provider never can. See the moduledoc;
    # `state` staying nil on such a row is the load-bearing half.
    field :notification_type, :string
    field :user_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  The changeset for one provider report.

  Every field is courier's or the provider's verbatim. Nothing here is
  caller-settable in a way that bypasses the vocabulary: `state` is
  `Ecto.Enum`, so a value outside `@states` is a cast error rather than a row that
  reads as something courier decided.

  `email` is normalised on the way in, and the address format is checked at the
  boundary rather than trusted — an event with an unparseable address is not an
  event courier can act on, and storing it would create a row that
  `suppressed?/1` could never match.

  `message_id` loses RFC 5322's angle brackets for the same reason `email` is
  downcased: providers quote the same identifier in more than one spelling, and two
  spellings must not be two rows.
  """
  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [
      :email,
      :state,
      :provider,
      :provider_event_id,
      :reason,
      :message_id,
      :occurred_at
    ])
    |> validate_required([:email, :state, :provider, :provider_event_id])
    |> put_change(:email, normalize_email(attrs))
    |> put_change(:message_id, normalize_message_id(attrs))
    |> validate_email()
    |> validate_length(:reason, max: @reason_length)
    |> validate_length(:message_id, max: @message_id_length)
    |> validate_length(:provider_event_id, max: @provider_event_id_length)
    # Matched BY NAME rather than on `:unique`, for the reason
    # `Courier.Idempotency.refusal/1` gives: a future unique index on this table
    # must not be able to silently become a refusal courier is asking about.
    |> unique_constraint([:provider, :provider_event_id],
      name: :email_suppressions_provider_idempotency_index
    )
  end

  @doc """
  The changeset for a **one-click unsubscribe** (RFC 8058), which is the same
  table written by courier rather than by a provider.

  **The difference from `changeset/2` is one line that is not there**: `state` is
  neither cast nor required. Everything else — the normalisation of the address,
  the format check, the three length bounds, the unique index on
  `(provider, provider_event_id)` — is the same function for the same reasons, and
  the two changesets are kept apart rather than merged behind a flag because a
  `state`-carrying row and a `state`-less one are different facts about a mailbox
  and a caller that could ask for either by passing an option would eventually ask
  for the wrong one.

  Why a state-less row is the whole mechanism rather than a detail: a bounce and a
  complaint are facts about the mailbox and refuse every notification type courier
  sends, and an unsubscribe is an instruction about ONE type. `Courier.Deliver`
  consults this table for a password reset as firmly as it does for a newsletter,
  so a `:suppressed` state here would be a person who stops receiving product
  updates and then cannot reset their password. A `nil` state is invisible to the
  fold in `Courier.Suppressions.state/1` — the same way a soft bounce records
  nothing — and visible to `Courier.Suppressions.unsubscribed?/2`.

  `user_id` is put rather than cast, for the reason `changeset/2` puts
  `email`: the value comes from the token courier minted, and nothing about a
  request should be able to choose whose answer this is.
  """
  def unsubscribe_changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [:email, :provider, :provider_event_id, :reason, :notification_type, :user_id])
    |> validate_required([:email, :provider, :provider_event_id, :notification_type])
    |> put_change(:email, normalize_email(attrs))
    |> validate_email()
    |> validate_length(:reason, max: @reason_length)
    |> validate_length(:provider_event_id, max: @provider_event_id_length)
    # The SAME index and matched by the SAME name. The unsubscribe is idempotent
    # because of this constraint and nothing else, exactly as a redelivered report
    # is — and a second index or a second name would be two mechanisms for one
    # property.
    |> unique_constraint([:provider, :provider_event_id],
      name: :email_suppressions_provider_idempotency_index
    )
  end

  defp normalize_email(%{email: email}), do: Suppressions.normalize(email)
  defp normalize_email(_attrs), do: nil

  # RFC 5322 §3.6.4's angle brackets are HEADER syntax, not part of the identifier.
  # `Courier.Deliver.tag/2` writes `<courier-<uuid>@anywaye.com>` on the wire, and
  # providers quote that value back in whichever form their own parser hands them:
  # Postmark's `MessageID` carries the brackets, SES's `originalHeaders` carries
  # them, and a raw SMTP bounce's `In-Reply-To` sometimes does not. Storing the two
  # spellings as two rows would make "did this bounce tie back to that send" a
  # question about the provider rather than about the send.
  #
  # The `@anywaye.com` suffix is left in place, and that is deliberate: it is part of
  # the identifier, and stripping it would be a heuristic that collapses
  # `courier-x@anywaye.com` and `courier-x@elsewhere.test` into one value. The
  # bounce ties back through `outbox_events.message_id`, which courier stores
  # bracket-free, so the bracket is the only difference courier has to absorb.
  defp normalize_message_id(%{message_id: "<" <> rest = id}) do
    if String.ends_with?(rest, ">"), do: String.trim(rest, ">") |> String.trim(), else: id
  end

  defp normalize_message_id(%{message_id: id}) when is_binary(id), do: String.trim(id)
  defp normalize_message_id(_attrs), do: nil

  defp validate_email(changeset) do
    validate_change(changeset, :email, fn :email, email ->
      # The same shape `Courier.Mailers` validates a recipient with, and for the
      # same reason: one definition of "an address courier can send to", so the
      # ingest boundary and the compose boundary cannot disagree about it.
      if Regex.match?(~r/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/, email),
        do: [],
        else: [email: "is not an email address"]
    end)
  end
end
