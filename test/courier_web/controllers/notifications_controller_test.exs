defmodule CourierWeb.NotificationsControllerTest do
  @moduledoc """
  The JSON API over in-app notifications, the error envelope core requires around
  it, and the authorization on it: `application/problem+json`, a stable code, a
  `trace_id` that matches the `X-Trace-Id` response header, and a 404 for a row
  in another account or one that is not this recipient's.


  The test resolver (`Courier.TestSupport.HeaderResolver`) sets `subject: "test"`,
  so the controller addresses `{"user", "test"}`. Every notification this file
  seeds is recorded with that recipient, and every assertion that a notification
  is visible is an assertion that the controller read the subject from the
  principal rather than from the request. A notification recorded for a
  *different* recipient is not visible, and that is the assertion that the
  recipient is not caller-controlled.


  `CourierWeb.Plugs.Principal` decides who is asking and `notifications` records
  the account, so the three answers here are the three answers
  `WebhookEndpointsControllerTest` and `NotificationPreferencesControllerTest`
  give:

    * **anonymous → 401**, on all four actions.
    * **another account → 404**, on both marks, because core's conventions forbid
      a 403 that leaks existence.
    * **owning account → 200**, which is every other test in this file.

  The identity of the caller comes from a header the *test* sets. That is a seam
  with one implementation today and identity's JWT verifier behind it, not
  authentication; `CourierWeb.Plugs.Principal`'s moduledoc says so, and its
  default resolver authenticates nobody, so a deployed courier without that
  verifier refuses these requests rather than serving them to whoever asks.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.Notifications

  @account_id "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @moduletag account: @account_id
  @other_account_id "2b3c4d5e-6f7a-4b9c-8d1e-2f3a4b5c6d7e"

  @recipient {"user", "test"}

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp problem(conn) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body(conn)
  end

  defp as(account_id) do
    case account_id do
      nil -> build_conn()
      account_id -> put_req_header(build_conn(), "x-courier-account", account_id)
    end
  end

  defp owner_conn, do: as(@account_id)
  defp anonymous_conn, do: as(nil)

  defp record(account_id, attrs \\ []) do
    attrs = Keyword.put_new(attrs, :recipient, @recipient)

    {:ok, %{notifications: [notification]}} =
      Notifications.record(account_id, Keyword.put_new(attrs, :type, "welcome"))

    notification
  end

  describe "the authorization matrix" do
    @actions [
      {:get, "/v1/notifications", :index},
      {:get, "/v1/notifications/unread_count", :unread_count},
      {:post, "/v1/notifications/6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061/seen", :mark_seen},
      {:post, "/v1/notifications/6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061/read", :mark_read}
    ]

    test "anonymous is refused on all four actions, with 401" do
      for {method, path, name} <- @actions do
        conn = Phoenix.ConnTest.dispatch(anonymous_conn(), @endpoint, method, path)

        assert conn.status == 401, "#{name} must be refused with 401, got #{conn.status}"
        assert conn.halted
      end
    end

    test "the refusal happens before routing reaches a controller" do
      for {method, path, _name} <- @actions do
        conn = Phoenix.ConnTest.dispatch(anonymous_conn(), @endpoint, method, path)

        assert conn.assigns[:action] == nil
      end
    end

    test "the refusal is the same one the webhook endpoints answer, byte for byte" do
      here =
        anonymous_conn()
        |> get("/v1/notifications")
        |> refusal()

      there =
        anonymous_conn()
        |> get("/v1/webhook_endpoints")
        |> refusal()

      assert here == there
    end

    test "another account's row is a 404 on both marks" do
      notification = as_account(@other_account_id, fn -> record(@other_account_id) end)

      for action <- [:mark_seen, :mark_read] do
        conn =
          owner_conn()
          |> post("/v1/notifications/#{notification.id}/#{action}")

        assert conn.status == 404
        assert %{"code" => "not_found", "status" => 404} = problem(conn)
      end
    end

    test "an account_id in the query cannot reach another account's rows" do
      record(@account_id)
      as_account(@other_account_id, fn -> record(@other_account_id, type: "comment") end)

      conn =
        owner_conn()
        |> get("/v1/notifications?account_id=#{@other_account_id}")

      assert conn.status == 200
      assert %{"data" => [_ | _]} = body(conn)
    end

    test "an account_id in the body cannot reach another account's rows" do
      notification = record(@account_id)

      conn =
        owner_conn()
        |> put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(
          @endpoint,
          :post,
          "/v1/notifications/#{notification.id}/seen",
          Jason.encode!(%{"account_id" => @other_account_id})
        )

      assert conn.status == 200
      assert %{"data" => %{"id" => id}} = body(conn)
      assert id == notification.id
    end
  end

  defp refusal(conn) do
    assert conn.status == 401

    conn
    |> body()
    |> Map.drop(["instance", "trace_id"])
  end

  describe "GET /v1/notifications" do
    test "answers 200 with an empty list for a recipient nobody has written for" do
      conn = get(owner_conn(), "/v1/notifications")

      assert conn.status == 200
      assert %{"data" => []} = body(conn)
    end

    test "lists a row written for this recipient, newest first" do
      first = record(@account_id, type: "welcome")
      second = record(@account_id, type: "comment")

      conn = get(owner_conn(), "/v1/notifications")

      assert %{"data" => notifications} = body(conn)
      assert Enum.map(notifications, & &1["id"]) == [second.id, first.id]
    end

    test "the unread filter narrows the list to the ones with no read_at" do
      unread = record(@account_id, type: "welcome")
      read = record(@account_id, type: "comment")

      {:ok, _} = Notifications.mark_read(@account_id, @recipient, read.id)

      conn = get(owner_conn(), "/v1/notifications?unread=true")

      assert %{"data" => notifications} = body(conn)
      assert Enum.map(notifications, & &1["id"]) == [unread.id]
    end

    test "unread=true as a string is the boolean the context filters on" do
      record(@account_id, type: "welcome")
      read = record(@account_id, type: "comment")
      {:ok, _} = Notifications.mark_read(@account_id, @recipient, read.id)

      conn = get(owner_conn(), "/v1/notifications?unread=true")

      assert %{"data" => [_ | _]} = body(conn)
      refute Enum.any?(body(conn)["data"], &(&1["id"] == read.id))
    end

    test "a row written for a different recipient is not listed" do
      record(@account_id, type: "welcome")

      as_account(@account_id, fn ->
        Notifications.record(@account_id, type: "comment", recipient: {"user", "someone-else"})
      end)

      conn = get(owner_conn(), "/v1/notifications")

      assert %{"data" => [_ | _]} = body(conn)
      assert length(body(conn)["data"]) == 1
    end

    test "a row written for another account is not listed" do
      record(@account_id, type: "welcome")
      as_account(@other_account_id, fn -> record(@other_account_id, type: "comment") end)

      conn = get(owner_conn(), "/v1/notifications")

      assert %{"data" => [_ | _]} = body(conn)
      assert length(body(conn)["data"]) == 1
    end

    test "limit caps the page size" do
      for _ <- 1..3, do: record(@account_id)

      conn = get(owner_conn(), "/v1/notifications?limit=2")

      assert %{"data" => notifications} = body(conn)
      assert length(notifications) == 2
    end

    test "after narrows the list to notifications older than the cursor" do
      older = record(@account_id, type: "welcome")
      newer = record(@account_id, type: "comment")

      conn =
        get(owner_conn(), "/v1/notifications?after=#{DateTime.to_iso8601(newer.inserted_at)}")

      assert %{"data" => notifications} = body(conn)
      assert Enum.map(notifications, & &1["id"]) == [older.id]
    end
  end

  describe "GET /v1/notifications/unread_count" do
    test "answers 0 for a recipient nobody has written for" do
      conn = get(owner_conn(), "/v1/notifications/unread_count")

      assert conn.status == 200
      assert %{"data" => %{"unread" => 0}} = body(conn)
    end

    test "agrees with the filtered list" do
      for _ <- 1..3, do: record(@account_id)
      read = record(@account_id, type: "comment")
      {:ok, _} = Notifications.mark_read(@account_id, @recipient, read.id)

      count_conn = get(owner_conn(), "/v1/notifications/unread_count")
      list_conn = get(owner_conn(), "/v1/notifications?unread=true")

      assert %{"data" => %{"unread" => count}} = body(count_conn)
      assert %{"data" => notifications} = body(list_conn)
      assert count == length(notifications)
    end

    test "a row written for another account is not counted" do
      record(@account_id, type: "welcome")
      as_account(@other_account_id, fn -> record(@other_account_id, type: "comment") end)

      conn = get(owner_conn(), "/v1/notifications/unread_count")

      assert %{"data" => %{"unread" => 1}} = body(conn)
    end
  end

  describe "POST /v1/notifications/:id/seen" do
    test "sets seen_at and answers with the row" do
      notification = record(@account_id)

      conn = post(owner_conn(), "/v1/notifications/#{notification.id}/seen")

      assert conn.status == 200
      assert %{"data" => data} = body(conn)
      assert data["id"] == notification.id
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(data["seen_at"])
    end

    test "a second call keeps the first seen_at" do
      notification = record(@account_id)

      first = post(owner_conn(), "/v1/notifications/#{notification.id}/seen")
      assert %{"data" => %{"seen_at" => seen_at}} = body(first)

      second = post(owner_conn(), "/v1/notifications/#{notification.id}/seen")
      assert %{"data" => %{"seen_at" => ^seen_at}} = body(second)
    end

    test "a row in another account is a 404" do
      notification = as_account(@other_account_id, fn -> record(@other_account_id) end)

      conn = post(owner_conn(), "/v1/notifications/#{notification.id}/seen")

      assert conn.status == 404
      assert %{"code" => "not_found", "status" => 404} = problem(conn)
    end

    test "a row addressed to a different recipient is a 404" do
      {:ok, %{notifications: [notification]}} =
        as_account(@account_id, fn ->
          Notifications.record(@account_id, type: "welcome", recipient: {"user", "someone-else"})
        end)

      conn = post(owner_conn(), "/v1/notifications/#{notification.id}/seen")

      assert conn.status == 404
      assert %{"code" => "not_found", "status" => 404} = problem(conn)
    end

    test "an id that is not a uuid is a 404, not a 422" do
      conn = post(owner_conn(), "/v1/notifications/not-a-uuid/seen")

      assert conn.status == 404
      assert %{"code" => "not_found", "status" => 404} = problem(conn)
    end
  end

  describe "POST /v1/notifications/:id/read" do
    test "sets read_at and seen_at, and answers with the row" do
      notification = record(@account_id)

      conn = post(owner_conn(), "/v1/notifications/#{notification.id}/read")

      assert conn.status == 200
      assert %{"data" => data} = body(conn)
      assert data["id"] == notification.id
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(data["read_at"])
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(data["seen_at"])
    end

    test "a second call keeps the first read_at and seen_at" do
      notification = record(@account_id)

      first = post(owner_conn(), "/v1/notifications/#{notification.id}/read")
      assert %{"data" => %{"read_at" => read_at, "seen_at" => seen_at}} = body(first)

      second = post(owner_conn(), "/v1/notifications/#{notification.id}/read")
      assert %{"data" => %{"read_at" => ^read_at, "seen_at" => ^seen_at}} = body(second)
    end

    test "seen then read sets both timestamps" do
      notification = record(@account_id)

      seen_conn = post(owner_conn(), "/v1/notifications/#{notification.id}/seen")
      assert %{"data" => %{"seen_at" => seen_at, "read_at" => nil}} = body(seen_conn)

      read_conn = post(owner_conn(), "/v1/notifications/#{notification.id}/read")
      assert %{"data" => %{"seen_at" => ^seen_at, "read_at" => read_at}} = body(read_conn)
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(read_at)
    end

    test "a row in another account is a 404" do
      notification = as_account(@other_account_id, fn -> record(@other_account_id) end)

      conn = post(owner_conn(), "/v1/notifications/#{notification.id}/read")

      assert conn.status == 404
      assert %{"code" => "not_found", "status" => 404} = problem(conn)
    end

    test "an id that is not a uuid is a 404, not a 422" do
      conn = post(owner_conn(), "/v1/notifications/not-a-uuid/read")

      assert conn.status == 404
      assert %{"code" => "not_found", "status" => 404} = problem(conn)
    end
  end

  describe "the error envelope" do
    test "is core's problem+json, with a stable type URI and a code that matches it" do
      conn = post(owner_conn(), "/v1/notifications/not-a-uuid/seen")

      assert %{"type" => type, "code" => "not_found"} = problem(conn)
      assert type == "https://docs.anywaye.com/errors/not_found"
    end

    test "carries a title, a status, and a detail" do
      conn = post(owner_conn(), "/v1/notifications/not-a-uuid/seen")

      assert %{"title" => "Not found", "status" => 404, "detail" => detail} = problem(conn)
      assert is_binary(detail)
    end

    test "names the instance the request was made to" do
      conn = post(owner_conn(), "/v1/notifications/not-a-uuid/seen")

      assert %{"instance" => "/v1/notifications/not-a-uuid/seen"} = problem(conn)
    end

    test "carries a trace_id that matches the X-Trace-Id response header" do
      conn = post(owner_conn(), "/v1/notifications/not-a-uuid/seen")

      assert %{"trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end
  end
end
