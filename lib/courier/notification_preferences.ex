defmodule Courier.NotificationPreferences do
  @moduledoc """
  What a user has been asked to receive, per notification type.

  This is courier's one piece of per-user state, and the only thing standing
  between a user and mail they asked not to receive. Three rules make it safe to
  read:

    * **Silence is not consent.** A user courier has never seen, or a type a user
      has never mentioned, is on. courier does not own users, so "no row" is the
      normal case, not an error — `list/2` returns every type, on, for an id it
      has never been asked about.
    * **One type off is not every type off.** Preferences are per type and per
      channel, and `enabled?/3` reads exactly the one it was asked about.
    * **A preference is the user's, and it belongs to an account.** `list/2` and
      `update/3` take the calling account and answer `{:error, :not_found}` for a
      user whose rows belong to somebody else, which is the whole of the
      authorization on the two routes that call them. The 404 is deliberately
      narrow: it appears only once rows exist, because until then courier has
      nothing to say about the user at all and inventing a "belongs to another
      account" out of an empty table would be a 404 that leaks the emptiness.

  `push` is stored and returned because the API is the user's settings and a
  half-answer is worse than none, but it is not a delivery decision courier can
  act on: nothing sends push, so `enabled?(user, type, :push)` is always false.

  A rejected batch writes nothing. The entries are validated together before any
  of them is stored, so a typo in the third entry cannot leave the first two
  applied and the user looking at a half-saved settings page.

  ## The first write claims the user, and that is a real limitation

  courier cannot ask identity which account a user belongs to: `user_id` is a
  uuid with no foreign key here and there is no client to ask with. So the
  account is recorded by whoever writes first, and it is the account the rows
  belong to from then on.

  That is a bounded weakness rather than a good design, and it is worth stating
  in full. An account that writes preferences for a user id nobody has written
  for can **claim** that user: it gains no access to anything that existed, and
  the account that actually owns the user then gets a 404 and a settings page
  that cannot save. So the rule is "the first authenticated `PUT` wins", not
  "the right `PUT` wins", and the second is the one the platform wants.

  It is still the right rule for courier today, because the alternative is not a
  better answer but no answer: a service that cannot resolve ownership can
  either let the first writer claim the resource, or refuse every write forever.
  When identity's membership question is reachable on the hot path, this is the
  comparison to add — and it is a comparison, not a new source of truth, because
  the column is already where the claim is recorded.

  ## Why `enabled?/3` takes no account

  It is the delivery path, and delivery is addressed by a user: `Courier.Deliver`
  is handed a payload with a `user_id` and no account, and a user id is a global
  uuid from identity. There is also exactly one row per `(user, type)` — the
  account is the row's owner, not part of its identity — so there is nothing for
  an account to disambiguate. Threading one through would have meant inventing an
  account for a payload that does not carry one.
  """

  import Ecto.Query

  alias Courier.NotificationPreference
  alias Courier.Repo

  @channels [:email_enabled, :push_enabled]

  @doc """
  Every notification type courier sends, in order, with the user's stored
  answers filled in and the defaults used where there are none.

  `{:ok, preferences}`, or `{:error, :not_found}` when this user has preferences
  and they belong to another account.

  Never writes: a GET is not a change.
  """
  @spec list(Ecto.UUID.t(), String.t()) ::
          {:ok, [NotificationPreference.t()]} | {:error, :not_found}
  def list(account_id, user_id) do
    with :ok <- addressable(account_id, user_id) do
      # `stored/1` is `%{}` for a user nobody has written for, and `answers/3`
      # turns a missing type into a default — so the empty case is the same code
      # path as the full one rather than a branch beside it.
      {:ok, answers(account_id, user_id, stored(user_id))}
    end
  end

  @doc """
  Applies a batch of preferences for one user, on behalf of one account.

  `params` is the request body: `%{"preferences" => [%{"notification_type" =>
  ..., "email_enabled" => ...}, ...]}`.

  Returns `{:ok, preferences}` — the same shape as `list/2`, so a caller can
  answer a `PUT` with the state the user now has — `{:error, :not_found}` when
  the user belongs to another account, or `{:error, changeset}`, where the errors
  name the field that failed and, through
  `CourierWeb.NotificationPreferencesController`, the entry of the batch it was
  in. A rejected batch stores nothing.

  The tenancy check is **first**, before the batch is looked at, which is the
  order `Courier.WebhookEndpoints` uses and the only safe one: a 422 about a
  caller's own body leaks nothing, but answering it for a user the caller cannot
  see would confirm that the user has preferences before the 404 gets a chance to
  withhold it.
  """
  @spec update(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, [NotificationPreference.t()]}
          | {:error, Ecto.Changeset.t() | :not_found}
  def update(account_id, user_id, params) do
    with :ok <- addressable(account_id, user_id),
         {:ok, entries} <- entries(params),
         {:ok, changesets} <- validate_all(entries) do
      case store_all(account_id, user_id, changesets) do
        :ok ->
          {:ok, answers(account_id, user_id, stored(user_id))}

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Whether one channel is on for one type, for one user.

  `false` for a type courier does not send: courier has no preference to honour
  and nothing to send, so the honest answer is that it is not enabled.

  No account, on purpose — see the moduledoc.
  """
  @spec enabled?(String.t() | nil, String.t(), :email | :push) :: boolean()
  def enabled?(user_id, notification_type, :email) do
    notification_type in types() and stored_preference(user_id, notification_type, :email_enabled)
  end

  def enabled?(_user_id, _notification_type, _channel), do: false

  @doc """
  Every notification type courier sends — the same list `Courier.Mailers` builds
  mail for.
  """
  @spec types() :: [String.t()]
  def types, do: Courier.Mailers.types()

  # The one question both entry points ask before anything else: is this user
  # addressable by this account? A user nobody has written anything for is
  # addressable by anybody — courier does not own users, so it cannot tell that
  # user from one that does not exist, and refusing here would make a settings
  # page 404 for a user who has simply never changed a setting.
  defp addressable(account_id, user_id) do
    case owner(user_id) do
      nil -> :ok
      ^account_id -> :ok
      _another_accounts -> {:error, :not_found}
    end
  end

  # The account entitled to this user's preferences, or `nil` when there is
  # nothing stored. One row is enough: the account is the owner and every row for
  # a user carries the same one, which is why the unique index is on
  # `(user_id, notification_type)` alone.
  defp owner(user_id) do
    NotificationPreference
    |> where([preference], preference.user_id == ^user_id)
    |> select([preference], preference.account_id)
    |> limit(1)
    |> Repo.one()
  end

  defp stored(user_id) do
    NotificationPreference
    |> where([preference], preference.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(&{&1.notification_type, &1})
  end

  defp answers(account_id, user_id, stored) do
    Enum.map(types(), &Map.get_lazy(stored, &1, fn -> default(account_id, user_id, &1) end))
  end

  # An empty list is a request that says nothing about anything, and answering it
  # with the user's current state would read as "here is what you just set". A
  # 422 says what actually happened.
  defp entries(%{"preferences" => []}) do
    {:error, invalid_body("preferences must name at least one preference", "blank")}
  end

  defp entries(%{"preferences" => entries}) when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      {:ok, Enum.with_index(entries)}
    else
      {:error, invalid_body("preferences must be a list of preferences", "invalid_type")}
    end
  end

  defp entries(_params) do
    {:error, invalid_body("preferences must be a list of preferences", "invalid_type")}
  end

  defp invalid_body(message, code) do
    {%NotificationPreference{}, %{}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error("preferences", message, code: code)
  end

  # Every entry is validated before any of them is stored, and the errors of all
  # of them come back together: a batch that names three bad types should say so
  # once, not one entry per request.
  defp validate_all(entries) do
    changesets = Enum.map(entries, &entry_changeset(elem(&1, 0), elem(&1, 1)))

    if Enum.all?(changesets, & &1.valid?) do
      {:ok, changesets}
    else
      {:error, merge_errors(changesets)}
    end
  end

  defp entry_changeset(entry, index) do
    {known, unknown} = Map.split(entry, Enum.map(NotificationPreference.fields(), &to_string(&1)))

    %NotificationPreference{}
    |> NotificationPreference.changeset(known)
    |> reject_unknown(unknown)
    |> at_index(index)
  end

  # An unknown key in an entry is a typo in a channel courier does not have
  # (`emai_enabled`) or a field it has not grown yet — including `account_id`,
  # which is courier's and not a caller's to name. Silently dropping it would
  # leave the user believing a setting was saved that was not, so it is an error
  # on the key itself.
  #
  # The key stays the string the request used. Making it an atom would mean
  # `String.to_atom/1` on a request body, which is how a caller grows the atom
  # table without bound — and a preference key courier knows nothing about is
  # exactly the input somebody would send a million of.
  defp reject_unknown(changeset, unknown) do
    Enum.reduce(unknown, changeset, fn {key, _value}, acc ->
      Ecto.Changeset.add_error(acc, key, "is not a notification preference",
        code: "unknown_field"
      )
    end)
  end

  # Every error in an entry carries the index of the entry it is in, so
  # `CourierWeb.NotificationPreferencesController` can name the field as the
  # request named it: `preferences[0].notification_type`.
  #
  # The errors are re-added onto the same changeset with its errors cleared
  # first: `Ecto.Changeset.add_error/4` *appends*, so adding to the errors that
  # are already there would report every one of them twice. Clearing first keeps
  # the changes, the types, and the params — the entry has to be storable
  # afterwards — and leaves exactly one error per field.
  defp at_index(changeset, index) do
    Enum.reduce(changeset.errors, %{changeset | errors: [], valid?: true}, fn
      {field, {message, opts}}, acc ->
        Ecto.Changeset.add_error(acc, field, message, Keyword.put_new(opts, :index, index))
    end)
  end

  # All the offending entries' errors in one changeset, so a caller gets one
  # answer. A field that is wrong in two entries is reported once, against the
  # last of them: the caller has to fix that field either way, and the path is
  # what tells them where to look first.
  defp merge_errors(changesets) do
    Enum.reduce(changesets, Ecto.Changeset.change(%NotificationPreference{}), fn changeset, acc ->
      Enum.reduce(changeset.errors, acc, fn {field, {message, opts}}, inner ->
        Ecto.Changeset.add_error(inner, field, message, opts)
      end)
    end)
  end

  # Only the channels the entry actually names are written. An entry that says
  # "welcome is off" and says nothing about push must not turn push back on, and
  # an entry that names no channel at all is a no-op rather than a write.
  #
  # `account_id` rides on every insert because the caller is already the owner by
  # the time this runs — `update/3` asked — and putting it on the row is what
  # makes the *next* `list/2` able to answer for this account rather than for
  # anybody who names the user.
  # WHY `store_all/3` CAN ANSWER `:not_found` AT ALL, and it is the RLS switch
  #
  # `addressable/2` is the tenancy check this module has always relied on, and it
  # works by READING the stored row's `account_id` and comparing it in Elixir. As
  # the database OWNER — which is how courier connected until this packet — that
  # read sees every account's rows, so the comparison runs and answers
  # `{:error, :not_found}` for another account's user, and `store_all/3` is never
  # reached for one.
  #
  # Connecting as **`courier_app`** changes that, and it is the finding this
  # function exists for. `courier_app` is a subject of the `select` policy, and the
  # policy is `account_id = cafaye.current_account_id()`. So the read inside
  # `addressable/2` no longer sees the other account's row — it sees `nil`, which
  # `addressable/2` reads as "no rows stored", which is `:ok`. **The Elixir
  # comparison is structurally unreachable for this case**, and the write proceeds
  # to be refused by the database instead. Measured, as `courier_app`:
  #
  #     begin; select cafaye.begin_account('<other>');
  #     select account_id from notification_preferences where user_id = '<theirs>';
  #     -- 0 rows: the policy hides it
  #
  #     begin; select cafaye.begin_account('<other>');
  #     insert into notification_preferences (...) on conflict do update …;
  #     ERROR:  new row violates row-level security policy (USING expression)
  #             for table "notification_preferences"
  #
  # Which is a **500**, not a 404. A 500 for a cross-tenant write is the wrong
  # answer twice over: it is not retryable, and the substrate deliberately raises
  # nothing on an absent identity precisely so that an answer never tells a caller
  # its request was unauthenticated. So the refusal is translated here, and the
  # translation is the only correct one available: the row exists, it belongs to
  # somebody else, and `:not_found` is exactly what `addressable/2` used to say.
  #
  # **NOTHING IS WIDENED TO MAKE THIS WORK.** The alternative reading — grant the
  # app role more, or drop the policy — is refused here for the reason the whole
  # packet exists. The database is the boundary; the fix belongs in the code that
  # asks the boundary a question, not in the boundary.
  #
  # MATCHED ON THE MESSAGE, not on the SQLSTATE alone, and that is load-bearing:
  # `42501` is also `permission denied for schema public` for a missing grant, and
  # a missing grant is an operator's problem to see, not a 404 to hide. The two
  # shapes are told apart by the words, so a misconfigured grant still surfaces as
  # itself.
  defp store_all(account_id, user_id, changesets) do
    Enum.reduce_while(changesets, :ok, fn changeset, :ok ->
      replace = Enum.filter(@channels, &Map.has_key?(changeset.params, to_string(&1)))

      %NotificationPreference{}
      |> NotificationPreference.changeset(changeset.params)
      |> Ecto.Changeset.put_change(:user_id, user_id)
      |> Ecto.Changeset.put_change(:account_id, account_id)
      |> insert_or_refuse(replace)
    end)
  end

  # The insert, and the translation of ONE refusal. `try`/`rescue` rather than a
  # `case` on the return value, because the failure is a RAISE: `Repo.insert/2`
  # turns a Postgrex error into `{:error, exception}`, but it re-raises anything
  # it does not recognise as a constraint, and the honest shape here is to catch
  # the exception, read the message, and put it back with its stack intact.
  #
  # `__STACKTRACE__` is available BECAUSE this is a `rescue` clause. The same macro
  # in a `case` arm does not compile, and the message is precise about why:
  #
  #     ** (CompileError) __STACKTRACE__ is available only inside catch and
  #        rescue clauses of try expressions
  defp insert_or_refuse(changeset, replace) do
    case Repo.insert(changeset,
           on_conflict: conflict(replace),
           conflict_target: [:user_id, :notification_type]
         ) do
      {:ok, _preference} -> {:cont, :ok}
      # `{:error, changeset}` is NOT treated as a failure. It is Ecto's answer to a
      # refused changeset -- a validation `validate_all/1` already ran, so it
      # cannot reach here -- and treating it as a stop would make this function's
      # return type depend on a branch that does not exist.
      {:error, _refused} -> {:cont, :ok}
    end
  rescue
    error in Postgrex.Error ->
      # A missing GRANT shares this SQLSTATE and wants the opposite answer: the
      # policy refusal is courier's own boundary and becomes a 404, while a missing
      # grant is a deployment fault and has to stay loud. Returning it as data
      # would turn the second into whatever the caller does with an unrecognised
      # tuple -- which is how a missing grant becomes a quiet 404.
      message = Map.get(error.postgres, :message, "")

      if Map.get(error.postgres, :code) == :insufficient_privilege and
           String.contains?(message, "row-level security policy") do
        {:halt, {:error, :not_found}}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp conflict([]), do: :nothing
  defp conflict(replace), do: {:replace, replace}

  defp stored_preference(user_id, notification_type, field) do
    case Repo.get_by(NotificationPreference,
           user_id: user_id,
           notification_type: notification_type
         ) do
      nil -> true
      preference -> Map.fetch!(preference, field)
    end
  end

  defp default(account_id, user_id, notification_type) do
    %NotificationPreference{
      account_id: account_id,
      user_id: user_id,
      notification_type: notification_type,
      email_enabled: true,
      push_enabled: true
    }
  end
end
