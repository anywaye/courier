defmodule CourierWeb.NotificationsController do
  @moduledoc """
  The JSON API over in-app notifications: `GET /v1/notifications`,
  `GET /v1/notifications/unread_count`, and the two marks.


  A notification is addressed to `{"user", <a user id>}`, and the user id is the
  **caller's own identity subject** — the `sub` claim identity's introspection
  answer carries, which `Courier.Principal.Introspection.Document` puts on the
  principal. The `identity.member.accepted` consumer records
  `recipient: {"user", membership.user_id}` (see `Courier.Consumers.MemberAccepted`),
  and `membership.user_id` is the same kind of id: a user identity minted by
  identity. So the reader and the writer agree on the recipient **because both
  derive it from identity**, and the reader derives it from the token rather than
  from the request.

  This is the one place the plug change is load-bearing.
  `CourierWeb.Plugs.Principal` assigns the whole `Courier.Principal` struct, and
  this controller reads `subject` off it. A controller that addressed the
  recipient from a query parameter or a body field would be a surface where any
  caller could read anybody's inbox by naming their user id — the same failure
  `notification_preferences` refuses by taking the user id from the path and the
  account from the principal, and the same failure this surface refuses by taking
  the user id from the token and never from the request at all.


  `conn.assigns.current_account` is the tenancy key, and it is the account
  `CourierWeb.Plugs.Principal` resolved from the caller's token. An `account_id`
  in a query string or a body is not read: there is no code path here that takes
  an account from the request, so there is no test that can prove a body was
  ignored by showing the body was honoured and the account happened to match. The
  account is the caller's because the token says so, and a caller that could name
  an account would be a caller who could read another tenant's inbox.


  Not a 403, and not a 422. Core's conventions forbid a 403 that leaks the
  existence of a resource the caller cannot see, and `Courier.Notifications`
  answers `{:error, :not_found}` for exactly the two cases — a row in another
  account, and a row addressed to a different recipient — so the controller turns
  that into the same problem+json every other action sends. The 404 is also the
  answer for an id that is not a uuid at all, so the error shape leaks nothing
  about whether the row exists.


  `Courier.Notifications.mark_seen/3` and `mark_read/3` set `seen_at`/`read_at`
  with `coalesce`, so a second call returns the same row with the **first**
  timestamp still in it. That is idempotence in the sense that matters — "when
  did they first see it" is a fact, and a call that moved it would answer a
  different question — and it means a retry is safe without a key. The
  `Idempotency-Key` header is for a POST whose repeat would do the work twice;
  a mark whose repeat is a no-op does not need one, and the router does not put
  these two actions behind `:idempotent` for the same reason `PUT
  /v1/notification_preferences/:user_id` is not.
  """

  use CourierWeb, :controller

  alias Courier.Notifications
  alias Courier.Repo
  alias Courier.Tenancy
  alias CourierWeb.Problem

  @doc """
  One page of the caller's own notifications, newest first.

  Query parameters, each optional and each mapped onto `Courier.Notifications
  list/4`'s options:

    * `unread=true` — only the ones with no `read_at`. The string `"true"` and
      nothing else: the context filters on the boolean, so the controller is
      where the query string's `"true"` becomes the boolean `true`.
    * `limit` — how many. Parsed to an integer here; the context defaults it to
      25 and caps it at 100, and a value that is not a positive integer is the
      default rather than an error, because it is a query parameter and not a
      mistake anybody is helped by a 422 for.
    * `after` — an RFC 3339 timestamp, the cursor for "the page before". Parsed
      to a `%DateTime{}` here; the context applies it only to a `DateTime`, so a
      value that does not parse is ignored rather than refused, for the same
      reason `limit` is.
  """
  def index(conn, params) do
    scoped(conn, fn ->
      account_id = conn.assigns.current_account
      recipient = recipient(conn)

      notifications =
        Notifications.list(account_id, recipient,
          unread: parse_unread(params["unread"]),
          limit: parse_limit(params["limit"]),
          after: parse_after(params["after"])
        )

      json(conn, %{data: Enum.map(notifications, &notification_json/1)})
    end)
  end

  @doc """
  How many of the caller's notifications have not been read — the badge number.
  """
  def unread_count(conn, _params) do
    scoped(conn, fn ->
      account_id = conn.assigns.current_account
      recipient = recipient(conn)

      json(conn, %{data: %{unread: Notifications.unread_count(account_id, recipient)}})
    end)
  end

  @doc """
  Marks one of the caller's notifications seen, and answers with the row.

  `{:error, :not_found}` — a row in another account, one addressed to a
  different recipient, or an id that is not a uuid — is a 404, for the reason
  the moduledoc gives.
  """
  def mark_seen(conn, %{"id" => id}) do
    scoped(conn, fn ->
      account_id = conn.assigns.current_account
      recipient = recipient(conn)

      case Notifications.mark_seen(account_id, recipient, id) do
        {:ok, notification} -> json(conn, %{data: notification_json(notification)})
        {:error, :not_found} -> not_found(conn)
      end
    end)
  end

  @doc """
  Marks one of the caller's notifications read — and seen, because opening it is
  the stronger statement. Answers with the row, or a 404.
  """
  def mark_read(conn, %{"id" => id}) do
    scoped(conn, fn ->
      account_id = conn.assigns.current_account
      recipient = recipient(conn)

      case Notifications.mark_read(account_id, recipient, id) do
        {:ok, notification} -> json(conn, %{data: notification_json(notification)})
        {:error, :not_found} -> not_found(conn)
      end
    end)
  end

  defp recipient(conn) do
    {"user", conn.assigns.current_principal.subject}
  end

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

  defp notification_json(notification) do
    %{
      id: notification.id,
      notification_event_id: notification.notification_event_id,
      seen_at: notification.seen_at,
      read_at: notification.read_at
    }
  end

  defp not_found(conn) do
    Problem.send(conn, 404, :not_found, "No notification with that id.")
  end

  defp parse_unread("true"), do: true
  defp parse_unread(_other), do: nil

  defp parse_limit(nil), do: nil

  defp parse_limit(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      _other -> nil
    end
  end

  defp parse_after(nil), do: nil

  defp parse_after(cursor) do
    case DateTime.from_iso8601(cursor) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end
end
