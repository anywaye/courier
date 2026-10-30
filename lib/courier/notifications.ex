defmodule Courier.Notifications do
  @moduledoc """
  The in-app notification record: something happened, and here it is for one
  person.


  It owns **the record**. courier already owns the delivery half —
  `Courier.NotificationPreferences` decides whether to send, `Courier.Mailers`
  composes, `Courier.Deliver` sends and writes the outbox row — and this module
  writes the thing that lets a service answer *"what was I told about, and which
  of those have I read?"*. That question was unanswerable before this: a
  notification courier delivered left no trace courier could later read.

  It **refuses**:

    * **Rendering.** There is no template, no body, no HTML and no partial
      anywhere in this tree, and `params` is jsonb rather than a rendered string
      precisely so there is nowhere for one to go. The reference implementation
      ships notification bodies as ERB fragments rendered through
      `ApplicationController.render` (`REF-jumpstart-inventory.md` §15.1 item 10);
      that is the single thing most worth *not* porting into an API-only
      service. `parlor` renders.
    * **Delivery.** Nothing here sends anything. `Courier.Deliver` is untouched
      by this module and does not call it; the two are deliberately unconnected,
      because coupling them would make recording contingent on sending — and a
      notification a person already has in their inbox must survive a mail that
      bounced.
    * **Unsubscribing from a notification.** `Courier.Unsubscribes` and
      `Courier.NotificationPreferences` are about email channels. An in-app
      record has no preference behind it, and this module has no opinion about
      whether one should exist.
    * **Tenant resolution.** The account arrives as an argument on every function
      here. It is never read out of a token, a header or a row.


  Every function takes `account_id` first and every query filters on it, which is
  what makes these statements **indexable** and what catches a policy written
  against the wrong column. The database is the boundary — `protect_table`
  installed `FORCE ROW LEVEL SECURITY` on both tables, and the suite connects as
  `courier_app`, a subject of it — but the predicate is not redundant with the
  policy. It is the reason the composite indexes lead with `account_id`, and it
  is the reason `account_id` is in the table at all.

  `record/2` writes the account onto **both** rows rather than deriving the
  notification's from the event it addresses. Deriving it would be one fewer
  parameter and one more way for the two rows to disagree.


  `record/2` writes the event and the notification **in one transaction**, and it
  **rolls that transaction back** if the second write fails rather than
  committing the first. That is not decoration: an event with no notification is a
  fan-out that has not happened, and a table that could hold one would let an
  unread count count it. A `Repo.transaction/1` that *returns* `{:error, …}` from
  its function **commits** — so the failure branch here is `Repo.rollback/1`, and
  the test that says so is named for it.

  Which is why there is no `record_event/2` and no `address/3`. Two public
  functions that have to be called together is one more thing to get wrong, and
  the failure is silent: a row nobody can see and an event nobody counts.


  The unique index is `(notification_event_id, recipient_type, recipient_id)`,
  and `record/2` leans on it rather than checking first. Two callers who both
  believe they were first produce **one** row, and both are told
  `{:ok, %{event: …, notification: …}}` where the notification is the stored one.

  The mechanism is `on_conflict: :nothing` **plus a re-read**, and the re-read is
  the half that is load-bearing: on the conflict branch `Repo.insert/2` answers
  `{:ok, struct}` with the struct's `id` **nil**, because it is handing back the
  proposed row rather than the stored one. A caller that answered a request with
  that struct would tell a person they have a notification whose id belongs to
  nothing. The re-read is one indexed lookup on the unique index, and it is the
  only way the returned row is the row that is stored.

  A `{:error, :conflict_without_a_row}` is therefore a **defect, not a
  condition**: the unique index matched a row and a query scoped to this account
  and this recipient cannot miss it. It is returned rather than raised so it
  cannot be mistaken for a validation failure, and it exists so the state cannot
  be reported as success.


  * `mark_seen/3` — "it appeared in a list". Sets `seen_at` if it is `nil`.
  * `mark_read/3` — "the person opened it". Sets **`read_at` and `seen_at`**.

  Both are idempotent in the sense that matters: a second call returns the same
  row with the **first** timestamp still in it. "When did they first see it" is a
  fact, and a call that moved it would be answering a different question with
  the same function. That is `coalesce` in the UPDATE rather than a check in
  Elixir, so two concurrent callers cannot each move it.

  **Neither ever clears** the other — an unread filter that resets on every page
  load is an unread count nobody can act on.

  `mark_read/3` sets `seen_at` too because opening something is a stronger
  statement than seeing it, and a deep link can open a notification that was
  never in a list. The database agrees: `check (read_at is null or seen_at is not
  null)` refuses a row that is read and unseen, so these two functions cannot
  disagree even if a future caller forgets.


  Not a 403, and not a different tuple. "Does this belong to you?" and "does this
  exist?" are the same question for a row the caller cannot see, and a distinct
  answer for the other case confirms the id is real — which is the leak
  `Courier.WebhookEndpoints.get/2` refuses to make and the shape
  `Courier.NotificationPreferences.update/3` already answers with.

  **The read half does not need a translated refusal and gets none.**
  `notification_preferences` had to catch a `Postgrex.Error` in `store_all/3`
  because its tenancy check was a read that the policy had already hidden, so the
  Elixir comparison became structurally unreachable. Here every query carries the
  predicate, so an absent row is `[]`/`nil` in Elixir and **no database error is
  ever translated to a 404**. That is a better shape and it is worth saying why
  the older one was not merely unlucky: *a context that has to rescue a permission
  error to implement a 404 is a context whose 404 depends on which role it is
  connected as.*
  """

  import Ecto.Query

  alias Courier.Notification
  alias Courier.NotificationEvent
  alias Courier.Repo

  @typedoc "A recipient is a kind plus an identifier: `{\"user\", \"<uuid>\"}`."
  @type recipient :: {String.t(), String.t()}

  @types [
    "welcome",
    "mention",
    "assignment",
    "comment",
    "billing"
  ]

  @doc """
  Every in-app notification type courier records, in the order the platform names
  them.

  The vocabulary `Courier.NotificationEvent.changeset/2` validates against. A new
  entry is a row here **and** a decision about how a consumer renders it — this
  module renders nothing, so that decision is somebody else's, and naming a type
  with no renderer behind it is how a type ships that nothing can display.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  Records one event and addresses it to **one or more** recipients.

  `attrs` is a keyword list or a map with atom keys:

    * `:type` — one of `types/0`. Required.
    * `:record_type` / `:record_id` — an optional polymorphic reference to
      whatever the event happened to. Both or neither.
    * `:params` — the structured facts, jsonb. Defaults to `%{}`.
    * `:recipients` — a **non-empty list** of `{type, id}` pairs. Required.
    * `:recipient` — one pair, as shorthand for a list of one.

  Returns `{:ok, %{event: event, notifications: notifications}}`,
  `{:error, {:recipients, changeset}}`, `{:error, {:event, changeset}}` or
  `{:error, {:notification, changeset}}` — **which stage failed is named**,
  because "your event type is not a type" and "your recipient is missing" are
  different mistakes and whoever fixed one should not have to read the other
  first.


  Because **one event addressed to one recipient is a fan-out of one, and the
  two tables exist to say otherwise.** The first version of this function took a
  single `:recipient` and inserted a fresh event row on every call, and the
  consequence was measured rather than argued:

      notifications_one_per_recipient_index   UNIQUE (notification_event_id,
                                                             recipient_type,
                                                             recipient_id)

  can never fire through that entry point, because every call has a new
  `notification_event_id`. The index was a promise the code could not keep and
  `on_conflict: :nothing` was unreachable code — **a check that cannot fail is
  not a check**, and this is its write-side twin.

  With `:recipients` the shape the reference implementation has is reachable: one
  event, one row per person, and the same person named twice in one list
  collapses to one row rather than two. The README's "one event, N recipients"
  is the reason the reference has two tables at all; a single-recipient API is
  one table with a foreign key.

  `:recipient` is kept as the shorthand because `record/2` writing one inbox
  entry is the overwhelmingly common call and making every caller write
  `[user: …]` to say one thing is noise.
  """
  @spec record(Ecto.UUID.t(), %{optional(atom()) => term()} | keyword()) ::
          {:ok, %{event: NotificationEvent.t(), notifications: [Notification.t()]}}
          | {:error, {:recipients | :event | :notification, Ecto.Changeset.t()}}
          | {:error, :conflict_without_a_row}
  def record(account_id, attrs) do
    attrs = normalize(attrs)

    with {:ok, recipients} <- recipients(recipients_of(attrs)) do
      write(account_id, Map.drop(attrs, [:recipient, :recipients]), recipients)
    end
  end

  @doc """
  One recipient's notifications, newest first.

  Options:

    * `:unread` — `true` for only the ones with no `read_at`. Anything else,
      including absent, means all of them.
    * `:limit` — how many. Defaults to 25, **capped at 100**, and both numbers
      are core's openapi conventions rather than courier's taste: cursor
      pagination everywhere, `limit` defaulting to 25 and capped at 100. A
      non-integer or non-positive limit is the default rather than an error: it
      is a query parameter, not a mistake anybody is helped by a 422 for.
    * `:after` — a `%DateTime{}`; only notifications older than it. This is the
      cursor for "the page before", and it is a **timestamp rather than an
      offset**: two notifications written in the same microsecond would make an
      offset skip one, and an inbox that skips one is worse than an inbox that
      repeats one.
    * `:preload_event` — `true` to load the event alongside. `false` by default,
      because an unread badge is the query that runs on every page load and it
      does not need the payload.

  Rows are ordered by `inserted_at` descending and then `id`, so the order is
  **total**. Two rows sharing a timestamp are ordered by a uuid, which is
  arbitrary but stable — a list that reshuffles between two identical calls is a
  pagination bug with no error message anywhere.

  A recipient nobody has been told anything about gets `[]`, not an error. That is
  the ordinary case: courier owns no users, so most recipients have never been
  written for.
  """
  @spec list(Ecto.UUID.t(), recipient(), keyword()) :: [Notification.t()]
  def list(account_id, {recipient_type, recipient_id}, opts \\ [])
      when is_binary(recipient_type) and is_binary(recipient_id) do
    Notification
    |> for_recipient(account_id, recipient_type, recipient_id)
    |> unread(opts)
    |> after_cursor(opts)
    |> newest_first()
    |> page_size(Keyword.get(opts, :limit, 25))
    |> maybe_preload_event(opts)
    |> Repo.all()
  end

  @doc """
  How many of one recipient's notifications have not been read.

  The number an unread badge shows, and the reason `read_at` exists rather than a
  boolean: "seen" is not "read", and a badge that counted seen would fall the
  moment somebody scrolled past something.

  It is a `count` rather than `length(list(account_id, recipient, unread: true))`,
  which is the same answer with the whole inbox's payload read to throw away —
  and, unlike the list, it cannot be served by the partial index unless the query
  is the partial one, which is why `unread/2` and `unread_count/2` build the same
  predicate rather than one delegating to the other.
  """
  @spec unread_count(Ecto.UUID.t(), recipient()) :: non_neg_integer()
  def unread_count(account_id, {recipient_type, recipient_id})
      when is_binary(recipient_type) and is_binary(recipient_id) do
    Notification
    |> for_recipient(account_id, recipient_type, recipient_id)
    |> where([notification], is_nil(notification.read_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Marks a notification seen, and `{:ok, it}`.

  Idempotent in the sense that matters: a second call returns the same row with
  the **first** `seen_at` still in it.

  `{:error, :not_found}` for a row in another account, or one this recipient is
  not — see the moduledoc. That is also the answer when the id is not a uuid at
  all, so a caller cannot learn anything about the row from the shape of the
  error.
  """
  @spec mark_seen(Ecto.UUID.t(), recipient(), Ecto.UUID.t() | String.t()) ::
          {:ok, Notification.t()} | {:error, :not_found}
  def mark_seen(account_id, recipient, id),
    do: mark(account_id, recipient, id, &mark_seen_query/1)

  @doc """
  Marks a notification read — **and seen**, because opening it is the stronger
  statement.

  See `Courier.Notification`'s moduledoc for why the two columns are separate and
  why this function writes both. Idempotent, and it never clears either.
  """
  @spec mark_read(Ecto.UUID.t(), recipient(), Ecto.UUID.t() | String.t()) ::
          {:ok, Notification.t()} | {:error, :not_found}
  def mark_read(account_id, recipient, id),
    do: mark(account_id, recipient, id, &mark_read_query/1)

  @doc """
  One notification, if it belongs to `account_id` **and** to `recipient`.

  `nil` rather than `{:error, :not_found}`, for the reason `list/3` returns `[]`:
  the two questions are the same question. `mark_seen/3` and `mark_read/3` return
  `{:error, :not_found}` because they are commands, and a command with nothing to
  do has to say so.
  """
  @spec get(Ecto.UUID.t(), recipient(), Ecto.UUID.t() | String.t()) :: Notification.t() | nil
  def get(account_id, recipient, id) do
    {recipient_type, recipient_id} = recipient

    case cast_id(id) do
      {:ok, id} ->
        Notification
        |> for_recipient(account_id, recipient_type, recipient_id)
        |> where([notification], notification.id == ^id)
        |> Repo.one()

      :error ->
        nil
    end
  end


  defp write(account_id, attrs, recipients) do
    Repo.transaction(
      fn ->
        with {:ok, event} <- insert_event(account_id, attrs) do
          case insert_notifications(account_id, event, recipients) do
            {:ok, notifications} -> %{event: event, notifications: notifications}
            {:error, tagged} -> Repo.rollback(tagged)
          end
        else
          {:error, tagged} -> Repo.rollback(tagged)
        end
      end,
      of: %{}
    )
  end

  @spec insert_event(Ecto.UUID.t(), map()) ::
          {:ok, NotificationEvent.t()} | {:error, {:event, Ecto.Changeset.t()}}
  defp insert_event(account_id, attrs) when is_binary(account_id) and is_map(attrs) do
    %NotificationEvent{}
    |> NotificationEvent.changeset(attrs)
    |> Ecto.Changeset.put_change(:account_id, account_id)
    |> Repo.insert()
    |> stage(:event)
  end

  @spec insert_notifications(Ecto.UUID.t(), NotificationEvent.t(), [recipient()]) ::
          {:ok, [Notification.t()]}
          | {:error, {:notification, Ecto.Changeset.t()}}
          | {:error, :conflict_without_a_row}
  defp insert_notifications(account_id, event, recipients) do
    Enum.reduce_while(recipients, {:ok, []}, fn recipient, {:ok, written} ->
      case insert_notification(account_id, event, recipient) do
        {:ok, notification} -> {:cont, {:ok, [notification | written]}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      {:error, _} = refused -> refused
    end
  end

  @spec insert_notification(Ecto.UUID.t(), NotificationEvent.t(), recipient()) ::
          {:ok, Notification.t()}
          | {:error, {:notification, Ecto.Changeset.t()}}
          | {:error, :conflict_without_a_row}
  defp insert_notification(account_id, event, {recipient_type, recipient_id})
       when is_binary(account_id) and is_binary(recipient_type) and is_binary(recipient_id) do
    %Notification{}
    |> Notification.changeset(%{
      notification_event_id: event.id,
      recipient_type: recipient_type,
      recipient_id: recipient_id
    })
    |> Ecto.Changeset.put_change(:account_id, account_id)
    |> Repo.insert(on_conflict: :nothing, conflict_target: conflict_target())
    |> stored_or_proposed(account_id, event, {recipient_type, recipient_id})
    |> stage(:notification)
  end

  defp conflict_target, do: [:notification_event_id, :recipient_type, :recipient_id]

  defp stored_or_proposed({:ok, _proposed}, account_id, event, {type, id}) do
    Notification
    |> for_recipient(account_id, type, id)
    |> where([notification], notification.notification_event_id == ^event.id)
    |> Repo.one()
    |> case do
      nil -> {:error, :conflict_without_a_row}
      stored -> {:ok, stored}
    end
  end

  defp stored_or_proposed(other, _account_id, _event, _recipient), do: other

  defp stage({:ok, struct}, _stage), do: {:ok, struct}
  defp stage({:error, changeset}, stage), do: {:error, {stage, changeset}}

  defp normalize(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize(attrs) when is_map(attrs), do: attrs

  defp recipients_of(attrs) do
    case Map.get(attrs, :recipients) do
      nil -> Map.get(attrs, :recipient)
      recipients -> recipients
    end
  end

  defp recipients({_type, _id} = pair) do
    if valid_pair?(pair), do: {:ok, [pair]}, else: refused()
  end

  defp recipients(list) when is_list(list) do
    if list != [] and Enum.all?(list, &valid_pair?/1) do
      {:ok, list}
    else
      refused()
    end
  end

  defp recipients(_other), do: refused()

  defp refused, do: {:error, {:recipients, recipients_changeset()}}

  defp valid_pair?({type, id}), do: is_binary(type) and is_binary(id) and id != ""
  defp valid_pair?(_other), do: false

  defp recipients_changeset do
    {%Notification{}, %{}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(
      :recipients,
      "is required: a non-empty list of {type, id} pairs",
      code: :required
    )
  end


  defp for_recipient(query, account_id, recipient_type, recipient_id) do
    where(
      query,
      [notification],
      notification.account_id == ^account_id and
        notification.recipient_type == ^recipient_type and
        notification.recipient_id == ^recipient_id
    )
  end

  defp unread(query, opts) do
    case Keyword.get(opts, :unread) do
      true -> where(query, [notification], is_nil(notification.read_at))
      _ -> query
    end
  end

  defp after_cursor(query, opts) do
    case Keyword.get(opts, :after) do
      nil -> query
      %DateTime{} = inserted_at -> where(query, [n], n.inserted_at < ^inserted_at)
      _ -> query
    end
  end

  defp newest_first(query) do
    order_by(query, [notification], desc: notification.inserted_at, desc: notification.id)
  end

  defp page_size(query, requested) when is_integer(requested) and requested > 0 do
    size = Kernel.min(requested, 100)
    limit(query, ^size)
  end

  defp page_size(query, _requested), do: limit(query, 25)

  defp maybe_preload_event(query, opts) do
    case Keyword.get(opts, :preload_event, false) do
      true -> preload(query, :event)
      _ -> query
    end
  end


  defp mark_seen_query(query) do
    now = DateTime.utc_now()

    update(query, [notification],
      set: [seen_at: fragment("coalesce(?, ?)", notification.seen_at, ^now)]
    )
  end

  defp mark_read_query(query) do
    now = DateTime.utc_now()

    update(query, [notification],
      set: [
        seen_at: fragment("coalesce(?, ?)", notification.seen_at, ^now),
        read_at: fragment("coalesce(?, ?)", notification.read_at, ^now)
      ]
    )
  end

  defp mark(account_id, {recipient_type, recipient_id}, id, stamping) do
    with {:ok, id} <- cast_id(id),
         {1, [notification]} <-
           Notification
           |> for_recipient(account_id, recipient_type, recipient_id)
           |> where([notification], notification.id == ^id)
           |> stamping.()
           |> select([notification], notification)
           |> Repo.update_all([]) do
      {:ok, notification}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_id(_other), do: :error
end
