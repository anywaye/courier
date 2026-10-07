defmodule CourierWeb.NotificationPreferencesController do
  @moduledoc """
  The JSON API over notification preferences:
  `GET` and `PUT /v1/notification_preferences/:user_id`.

  Three things are worth saying about the semantics, because each looks like an
  omission and is not:

    * **An unknown user is a 200, not a 404.** identity owns the user table.
      courier is asked about a user id and answers with that user's preferences,
      which for a user who has never touched the settings is three types, all on.
      A 404 would be courier claiming to know something about the requester it
      does not know.
    * **A user id that is not a uuid is a 422 before the body is looked at.** It
      is the one thing courier can check about the request without consulting
      anybody, and there is no point validating a body for a user courier cannot
      address.
    * **A user whose preferences belong to another account *is* a 404.** That is
      the one exception to the first of those, and it is an exception about what
      courier knows rather than about who is asking: with no stored rows courier
      knows nothing about the user, so there is nothing to withhold; with rows
      there is a resource, it belongs to somebody else, and core's conventions
      forbid the 403 that would otherwise confirm it exists.

  Every error is core's problem+json (`CourierWeb.Problem`), with the field named
  as the *request* named it — `preferences[0].notification_type` — because the
  body is what the caller can fix.

  ## Authorization

  Both actions read the account from `conn.assigns.current_account`, which
  `CourierWeb.Plugs.Principal` put there, and pass it to
  `Courier.NotificationPreferences` as the first argument.

  An `account_id` in a request cannot reach the row. It is not a field of a
  preference entry at all, so an entry carrying one is refused as the unknown
  key it is — the same answer as `emai_enabled`, and a stronger one than
  `user_id` gets, because `user_id` is a real field that the path overwrites. A
  `account_id` beside the batch, at the top level of the body, names nothing
  courier reads: the body's only key is `preferences`.

  Neither action reads the account from anywhere else, and neither has to check
  whether the caller may read the user: the context answers `{:error, :not_found}`
  and this module turns that into a 404. The check living in the context rather
  than here is deliberate — the same question is asked by `list/2` and
  `update/3`, and a controller that asked it a third way would be a third place
  for it to be wrong.
  """

  use CourierWeb, :controller

  alias Courier.NotificationPreferences
  alias Courier.Repo
  alias Courier.Tenancy
  alias CourierWeb.Problem

  @doc """
  Every notification type courier sends, with this user's stored answers.
  """
  def show(conn, %{"user_id" => user_id}) do
    scoped(conn, fn ->
      with {:ok, user_id} <- cast_user_id(user_id),
           {:ok, preferences} <-
             NotificationPreferences.list(conn.assigns.current_account, user_id) do
        json(conn, answer(user_id, preferences))
      else
        :error -> invalid_user_id(conn)
        {:error, :not_found} -> not_found(conn)
      end
    end)
  end

  @doc """
  Applies a batch of preferences and answers with the state the user now has.
  """
  def update(conn, %{"user_id" => user_id} = params) do
    scoped(conn, fn ->
      with {:ok, user_id} <- cast_user_id(user_id),
           {:ok, stored} <-
             NotificationPreferences.update(conn.assigns.current_account, user_id, params) do
        json(conn, answer(user_id, stored))
      else
        :error -> invalid_user_id(conn)
        {:error, :not_found} -> not_found(conn)
        {:error, changeset} -> validation_failed(conn, changeset)
      end
    end)
  end

  defp validation_failed(conn, changeset) do
    Problem.send(conn, 422, :validation_failed, detail(changeset), failed(changeset))
  end

  # The whole action runs inside one transaction carrying the caller's account,
  # so the row-level-security policies on `notification_preferences` have an
  # identity to key on. A plug cannot hold such a transaction open across the
  # controller — see `Courier.Tenancy` — so each action opens its own, with the
  # account `CourierWeb.Plugs.Principal` stashed.
  #
  # `{:error, _}` — a `Repo.rollback` that escaped the action — is unreachable
  # by construction: the context rolls back only inside its own inner
  # transaction. Handled as a 503 rather than matched away, on the same rule as
  # `CourierWeb.Plugs.Idempotency`'s own scoping: a refusal the caller retries.
  defp scoped(conn, fun) do
    case Tenancy.with_account(Repo, conn.assigns.current_account, fun) do
      {:ok, conn} -> conn
      {:error, _reason} -> unavailable(conn)
    end
  end

  defp unavailable(conn) do
    conn
    |> Problem.send(
      503,
      :unavailable,
      "courier could not scope this request to an account, so it is not serving it."
    )
    |> halt()
  end

  # The user's preferences exist and belong to another account, which is the same
  # answer a webhook endpoint in another account gets and for the same reason: a
  # 403 would tell a caller that this user id has preferences at all, which is
  # the only fact the 404 exists to withhold.
  defp not_found(conn) do
    Problem.send(conn, 404, :not_found, "No notification preferences with that user id.")
  end

  defp answer(user_id, preferences) do
    %{
      data: %{
        user_id: user_id,
        preferences: Enum.map(preferences, &preference/1)
      }
    }
  end

  # The three fields the API promises. `user_id` is in the path and answered at
  # the top of the body, and `id` is courier's row id, which the caller has no
  # use for. `account_id` is courier's tenancy key rather than the caller's to
  # read, so it is not in the body — a caller that already holds the account
  # knows it.
  defp preference(preference) do
    %{
      notification_type: preference.notification_type,
      email_enabled: preference.email_enabled,
      push_enabled: preference.push_enabled
    }
  end

  defp cast_user_id(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp invalid_user_id(conn) do
    Problem.send(conn, 422, :validation_failed, "The user id is not a uuid.", [
      %{"field" => "user_id", "code" => "invalid_format"}
    ])
  end

  # A changeset error is keyed by the field it is about and carries the index of
  # the entry it is in, which is how `preferences[0].notification_type` comes out
  # of a context that only knows about preference entries.
  defp failed(changeset) do
    Enum.map(changeset.errors, fn {field, {_message, opts}} ->
      %{"field" => field_path(field, opts), "code" => Keyword.get(opts, :code, "invalid_format")}
    end)
  end

  defp field_path(field, opts) do
    case Keyword.get(opts, :index) do
      nil -> to_string(field)
      index -> "preferences[#{index}].#{field}"
    end
  end

  defp detail(changeset) do
    "The preferences were not valid: " <>
      Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
        "#{field} #{message}"
      end)
  end
end
