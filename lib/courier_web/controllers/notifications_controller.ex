defmodule CourierWeb.NotificationsController do
  @moduledoc """
  The JSON API over in-app notifications: `GET /v1/notifications`,
  `GET /v1/notifications/unread_count`, and the two marks.

  ## THE RECIPIENT COMES FROM THE PRINCIPAL, AND THAT IS THE WHOLE DESIGN

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

  ## THE ACCOUNT COMES FROM THE PRINCIPAL, NEVER FROM THE REQUEST

  `conn.assigns.current_account` is the tenancy key, and it is the account
  `CourierWeb.Plugs.Principal` resolved from the caller's token. An `account_id`
  in a query string or a body is not read: there is no code path here that takes
  an account from the request, so there is no test that can prove a body was
  ignored by showing the body was honoured and the account happened to match. The
  account is the caller's because the token says so, and a caller that could name
  an account would be a caller who could read another tenant's inbox.

  ## A ROW IN ANOTHER ACCOUNT, OR ONE THAT IS NOT THIS RECIPIENT'S, IS A 404

  Not a 403, and not a 422. Core's conventions forbid a 403 that leaks the
  existence of a resource the caller cannot see, and `Courier.Notifications`
  answers `{:error, :not_found}` for exactly the two cases — a row in another
  account, and a row addressed to a different recipient — so the controller turns
  that into the same problem+json every other action sends. The 404 is also the
  answer for an id that is not a uuid at all, so the error shape leaks nothing
  about whether the row exists.

  ## THE MARKS ARE IDEMPOTENT BY CONSTRUCTION, AND SO TAKE NO IDEMPOTENCY-KEY

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
    account_id = conn.assigns.current_account
    recipient = recipient(conn)

    notifications =
      Notifications.list(account_id, recipient,
        unread: parse_unread(params["unread"]),
        limit: parse_limit(params["limit"]),
        after: parse_after(params["after"])
      )

    json(conn, %{data: Enum.map(notifications, &notification_json/1)})
  end

  @doc """
  How many of the caller's notifications have not been read — the badge number.
  """
  def unread_count(conn, _params) do
    account_id = conn.assigns.current_account
    recipient = recipient(conn)

    json(conn, %{data: %{unread: Notifications.unread_count(account_id, recipient)}})
  end

  @doc """
  Marks one of the caller's notifications seen, and answers with the row.

  `{:error, :not_found}` — a row in another account, one addressed to a
  different recipient, or an id that is not a uuid — is a 404, for the reason
  the moduledoc gives.
  """
  def mark_seen(conn, %{"id" => id}) do
    account_id = conn.assigns.current_account
    recipient = recipient(conn)

    case Notifications.mark_seen(account_id, recipient, id) do
      {:ok, notification} -> json(conn, %{data: notification_json(notification)})
      {:error, :not_found} -> not_found(conn)
    end
  end

  @doc """
  Marks one of the caller's notifications read — and seen, because opening it is
  the stronger statement. Answers with the row, or a 404.
  """
  def mark_read(conn, %{"id" => id}) do
    account_id = conn.assigns.current_account
    recipient = recipient(conn)

    case Notifications.mark_read(account_id, recipient, id) do
      {:ok, notification} -> json(conn, %{data: notification_json(notification)})
      {:error, :not_found} -> not_found(conn)
    end
  end

  # The recipient is the caller's own identity subject, and it is read from the
  # principal the plug assigned — never from the request. A `nil` subject (a
  # token that carried no `sub`, or the test resolver's stand-in) addresses
  # `{"user", nil}`, which matches no row: an inbox for a caller courier cannot
  # place is an empty inbox, not an error and not a guess.
  defp recipient(conn) do
    {"user", conn.assigns.current_principal.subject}
  end

  # The five fields the API promises, and no others. `id` is courier's row id,
  # which a client needs to mark a row; `notification_event_id` is the event the
  # row is about, which a client needs to correlate; `seen_at` and `read_at` are
  # the two facts the marks write. `account_id` is courier's tenancy key rather
  # than the caller's to read, so it is not in the body — a caller that already
  # holds the account knows it. `recipient_type`/`recipient_id` are the
  # addressing, and they are the caller's own by construction, so they are not
  # echoed either: a response that echoed the recipient would be a response that
  # confirmed a fact the request never established.
  defp notification_json(notification) do
    %{
      id: notification.id,
      notification_event_id: notification.notification_event_id,
      seen_at: notification.seen_at,
      read_at: notification.read_at
    }
  end

  # A row in another account, or one that is not this recipient's, is the same
  # answer a webhook endpoint in another account gets and for the same reason: a
  # 403 would tell a caller that this id has a notification at all, which is the
  # only fact the 404 exists to withhold.
  defp not_found(conn) do
    Problem.send(conn, 404, :not_found, "No notification with that id.")
  end

  # `"true"` and nothing else. The context's `unread/2` filters on the boolean
  # `true`, so the string `"true"` would be ignored if it were passed through —
  # and a client that sent `?unread=true` and got every row back would have no
  # way to tell the filter was not applied from the fact that it was not.
  defp parse_unread("true"), do: true
  defp parse_unread(_other), do: nil

  # An integer or `nil`, and the context does the rest: `nil` and a non-positive
  # integer are the default of 25, and anything above 100 is capped. Parsing here
  # rather than passing the string through is what makes `?limit=50` mean 50 —
  # the context's `page_size/2` treats a non-integer as the default, so a string
  # would silently become 25.
  defp parse_limit(nil), do: nil

  defp parse_limit(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      _other -> nil
    end
  end

  # A `%DateTime{}` or `nil`, and the context applies the cursor only to a
  # `DateTime`. RFC 3339 is the format the `after` cursor is documented in, and a
  # value that does not parse is ignored rather than refused — the same rule
  # `limit` follows, and the same reason: a query parameter is not a mistake
  # anybody is helped by a 422 for.
  defp parse_after(nil), do: nil

  defp parse_after(cursor) do
    case DateTime.from_iso8601(cursor) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end
end
