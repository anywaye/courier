defmodule Courier.Suppressions do
  @moduledoc """
  What courier knows about an address's deliverability, and what it does about it.

  This is the question SMTP never answers. A submission protocol's whole reply is
  "accepted for delivery", so a courier that sends and hears nothing will mail a
  mailbox that stopped existing three months ago, forever — and a sending domain
  that keeps writing to dead addresses is a domain that gets suspended. The
  provider tells us; this module is what courier does with being told.


      :undeliverable   a HARD bounce. RFC 5321 §5.1.1 permanent failure — no such
                       user, a null reverse path. A fact about the MAILBOX.
      :suppressed      a COMPLAINT. RFC 2142 §5, an abuse report, a "report spam".
                       An instruction from the PERSON, about the MAIL.

  Both stop the send, and that is the decision rather than the fallback. Mailing a
  dead address costs a sending domain its reputation; mailing somebody who
  marked you as spam costs more than that. The argument is the asymmetry: being
  wrong towards sending is expensive and cumulative, being wrong towards not
  sending costs one message to one person who was about to mark you as spam
  anyway.

  They are kept as two values rather than one boolean because they mean different
  things and an operator's response to each is different. A pile of
  `:undeliverable` is list hygiene. A pile of `:suppressed` is a content and
  sender-reputation problem, and a per-address suppression does not fix it — so an
  operator who can only see "true" cannot tell which of the two they are looking
  at.

  **`:suppressed` outranks `:undeliverable`.** A complaint is the recipient's
  instruction; a bounce is a fact about a mailbox, and a later fact does not
  withdraw an instruction.


  Rows are immutable. The state is a fold:

      nothing at all                  -> `nil`
      rows, none carrying a state     -> `nil`
      any row `:suppressed`           -> `:suppressed`
      otherwise any row               -> `:undeliverable`

  So "a later bounce cannot undo a complaint" is not a rule in a `case` somebody
  has to remember; it is a consequence of there being no `Repo.update/2` on this
  table. `Courier.SuppressionsTest` asserts it from both directions for exactly
  that reason — a design whose correctness lives in an UPDATE is a design whose
  correctness a future edit can remove.


  RFC 5321 §4.2.2 temporary failure — mailbox full, greylisted, "try again in
  four hours". Suppressing on one is how a suppression list starts eating live
  addresses: one provider's bad afternoon becomes a thousand addresses courier
  will never write to again, with nothing in the data to say which of them were
  ever real. `ingest/2` accepts a soft bounce, stores **no row**, and answers
  `{:ok, :ignored}`.

  The answer is deliberately a different shape from `{:ok, :new, row}`. A caller
  that counted `:ignored` as a failure would retry forever; one that counted it as
  `:new` would be counting a row that does not exist.


  `(provider, provider_event_id)` is unique, and a delivery that loses it is
  answered `{:ok, :duplicate, row}` — the row that won, so the caller can report a
  consistent answer either way. Real providers retry: Postmark retries on a timeout
  and on any 5xx, and a courier restarting with a batch in flight will see that
  batch again. A "have I seen this?" check in Elixir would be a race; the index
  cannot be.


  A suppression has no `account_id`. An address is an address, and courier's
  send-path question — "may I write to this mailbox?" — has no tenant in it: one
  account's hard bounce for `ops@example.com` is just as true of every other
  account's mail to `ops@example.com`, and the damage a dead address does is to
  the shared sending domain. Scoping the row to an account would make a
  cross-tenant leak available (a list of somebody else's addresses) to fix a
  problem that is not a cross-tenant one.

  What this costs is worth stating: **the table is never exposed through any
  route**, so no caller can read an address out of it, and a suppression can only
  ever be observed as its effect on courier's own sends. That is the same posture
  as the send path — the answer is "no mail went out", never "here is a list".


  Writing lowercases and trims; `suppressed?/1`, `state/1`, `find/1` and
  `history/1` lowercase what they are given. Both halves matter and they are
  separate: a row stored mixed-case is invisible to a lowercasing lookup, and a
  caller that spells an address differently between the ingest and the send would
  get a different answer for the same mailbox.
  """

  import Ecto.Query

  alias Courier.Repo
  alias Courier.Suppression

  @kinds [:hard_bounce, :soft_bounce, :complaint]

  @typedoc """
  One report from a provider, in courier's own vocabulary.

  `:kind` is what the provider called it, normalised; `:state` is what courier
  takes from it, and a soft bounce has no state because courier takes nothing.
  """
  @type event :: %{
          required(:provider) => String.t(),
          required(:provider_event_id) => String.t(),
          required(:email) => String.t(),
          required(:kind) => atom(),
          optional(:reason) => String.t() | nil,
          optional(:message_id) => String.t() | nil,
          optional(:occurred_at) => DateTime.t() | nil
        }

  @doc false
  def kinds, do: @kinds

  @doc "The states a suppression can carry."
  def states, do: Suppression.states()

  @doc """
  The address courier stores and looks up: downcased and trimmed, nothing else.

  Not lowercased *further* than that. Stripping `+tag` or dots would be a
  deliverability heuristic belonging to a provider's address hygiene, and applying
  one here would make courier suppress a mailbox the provider never reported — the
  one direction this whole table is written against.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def normalize(other), do: other

  @doc """
  Records one provider report.

  `{:ok, :new, row}`, `{:ok, :duplicate, row}`, or `{:error, changeset}`.
  """
  @spec record(map()) ::
          {:ok, :new | :duplicate, Suppression.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    %Suppression{}
    |> Suppression.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} ->
        {:ok, :new, row}

      {:error, %{__struct__: Ecto.Changeset} = changeset} ->
        duplicate_or(changeset, attrs)
    end
  end

  defp duplicate(attrs) do
    Suppression
    |> where(
      [s],
      s.provider == ^attrs[:provider] and s.provider_event_id == ^attrs[:provider_event_id]
    )
    |> limit(1)
    |> Repo.one()
    |> case do
      %Suppression{} = row -> {:ok, :duplicate, row}
      nil -> {:error, :duplicate_without_a_row}
    end
  end

  @doc """
  Acts on one provider report: the HTTP surface's entry point.

  Returns `{:ok, :new | :duplicate, row}` for a kind courier suppresses on,
  `{:ok, :ignored}` for a kind it deliberately does nothing about, and
  `{:error, :unsupported_kind}` for one it will not guess at.
  """
  @spec ingest(event()) ::
          {:ok, :new | :duplicate, Suppression.t()} | {:ok, :ignored} | {:error, term()}
  def ingest(%{kind: kind} = event) when kind in [:hard_bounce, :complaint] do
    record(Map.put(event, :state, state_for(kind)))
  end

  def ingest(%{kind: :soft_bounce}), do: {:ok, :ignored}

  def ingest(%{kind: other}) do
    _ = other
    {:error, :unsupported_kind}
  end

  @doc """
  Records a one-click unsubscribe (RFC 8058): the recipient has asked not to
  receive one notification type at one address.

  This is the **same table, the same unique index and the same answer shapes** as
  `record/1`, and that is the point: an unsubscribe is a report about an address
  like any other, so the mechanism for making a retry harmless is the mechanism
  that already exists. `{:ok, :new, row}` and `{:ok, :duplicate, row}` are the
  same two answers a redelivered bounce gets, and `Courier.Unsubscribes` counts
  them the same way.

  **Two differences from a provider report, and both are the absence of a fact
  rather than a new one:**

    * **`state` is not set.** A bounce and a complaint are facts about the
      MAILBOX and stop every type courier sends; an unsubscribe is an instruction
      about one type, and this table is consulted for a password reset as firmly
      as for a newsletter. So the row carries no state, which makes it invisible
      to `state/1` and `find/1` — the fold already ignores rows with no state, and
      that is how a soft bounce records nothing — and visible to
      `unsubscribed?/2`. See `Courier.Unsubscribes` for the whole argument, and
      `Courier.Suppression.unsubscribe_changeset/2` for the one line that differs.
    * **`provider` is courier's own name for the surface.** `"unsubscribe"`, beside
      `"resend"`, in the half of the unique index every other reader of this table
      already groups by. An operator asking "why is this address not getting
      product updates" gets a row that says who wrote it and why in `reason`.

  `provider_event_id` is the unsubscribe token's id, which is what makes a second
  `POST` a `:duplicate` rather than a second row.
  """
  @spec unsubscribe(map()) ::
          {:ok, :new | :duplicate, Suppression.t()} | {:error, Ecto.Changeset.t()}
  def unsubscribe(attrs) when is_map(attrs) do
    %Suppression{}
    |> Suppression.unsubscribe_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, :new, row}
      {:error, %{__struct__: Ecto.Changeset} = changeset} -> duplicate_or(changeset, attrs)
    end
  end

  @doc """
  Whether `email` has asked not to receive `notification_type`.

  The send path's question, and it is asked per type on purpose: the answer for
  one type says nothing about any other, which is the property that keeps an
  unsubscribe from stopping a password reset.

  **A row with no `notification_type` never matches**, whatever the address is, so
  this cannot be reached by a bounce or a complaint even if a caller passed a type
  — a hard bounce stops the send two questions earlier, in `state/1`.
  """
  @spec unsubscribed?(String.t() | nil, String.t()) :: boolean()
  def unsubscribed?(email, notification_type)
      when is_binary(email) and is_binary(notification_type) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> where([s], s.notification_type == ^notification_type)
    |> where([s], is_nil(s.state))
    |> limit(1)
    |> Repo.exists?()
  end

  def unsubscribed?(_email, _notification_type), do: false

  @doc """
  The row courier already holds for this `(provider, provider_event_id)`, or `nil`.


  It is here so that a caller who needs the row AND an event to be atomic can ask
  before it inserts. `record/1` and `unsubscribe/1` find a duplicate by inserting
  and catching the unique violation, then reading the winning row back — which is
  correct and is the right shape, but it only works **outside** a transaction.
  PostgreSQL aborts a whole transaction on a statement error, so the read that
  follows the failed insert answers `25P02 current transaction is aborted`:

      Suppressions.unsubscribe(attrs)

      Suppressions.unsubscribe(attrs)

  So the lookup can only ever be *wrong* in the direction of thinking a report is
  new, and the insert that follows then loses the index and the caller rolls the
  whole transaction back. The index is still the arbiter. `Courier.InboundReports`
  has measured all of this at length; this is its one function, extracted so the
  unsubscribe path is the same path rather than a second copy of it.
  """
  @spec find_by_event(String.t() | nil, String.t() | nil) :: Suppression.t() | nil
  def find_by_event(provider, provider_event_id)
      when is_binary(provider) and is_binary(provider_event_id) do
    Suppression
    |> where([s], s.provider == ^provider and s.provider_event_id == ^provider_event_id)
    |> limit(1)
    |> Repo.one()
  end

  def find_by_event(_provider, _provider_event_id), do: nil

  @doc "Whether courier will refuse to write to `email`."
  @spec suppressed?(String.t() | nil) :: boolean()
  def suppressed?(email) when is_binary(email) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> where([s], not is_nil(s.state))
    |> limit(1)
    |> Repo.exists?()
  end

  def suppressed?(_email), do: false

  @doc """
  The address's state, or `nil` when nothing suppresses it.

  The fold, in full: any `:suppressed` wins, otherwise any row wins.
  """
  @spec state(String.t() | nil) :: :undeliverable | :suppressed | nil
  def state(email) when is_binary(email) do
    email = normalize(email)

    cond do
      has_state?(email, :suppressed) -> :suppressed
      has_state?(email, :undeliverable) -> :undeliverable
      true -> nil
    end
  end

  def state(_email), do: nil

  @doc """
  The row the state was decided from, or `nil`.

  Chosen with the same precedence as `state/1`, so an operator reading a row is
  not shown a bounce for an address that was actually suppressed by a complaint.
  """
  @spec find(String.t() | nil) :: Suppression.t() | nil
  def find(email) when is_binary(email) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> where([s], not is_nil(s.state))
    |> order_by([s], desc: fragment("? = 'suppressed'", s.state), asc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def find(_email), do: nil

  @doc """
  Every report courier holds about `email`, oldest first.

  Sorted by `inserted_at` rather than left to PostgreSQL: an unordered `Repo.all/1`
  returns rows in the server's order, and a caller that compares two lists without
  sorting both sides is making a claim about the server.
  """
  @spec history(String.t() | nil) :: [Suppression.t()]
  def history(email) when is_binary(email) do
    Suppression
    |> where([s], s.email == ^normalize(email))
    |> order_by([s], asc: s.inserted_at, asc: s.id)
    |> Repo.all()
  end

  def history(_email), do: []

  defp state_for(:hard_bounce), do: :undeliverable
  defp state_for(:complaint), do: :suppressed

  defp has_state?(email, state) do
    Suppression
    |> where([s], s.email == ^email and s.state == ^state)
    |> limit(1)
    |> Repo.exists?()
  end

  defp duplicate?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        to_string(Keyword.get(opts, :constraint_name)) ==
          "email_suppressions_provider_idempotency_index"
    end)
  end

  defp duplicate_or(changeset, attrs) do
    if duplicate?(changeset), do: duplicate(attrs), else: {:error, changeset}
  end
end
