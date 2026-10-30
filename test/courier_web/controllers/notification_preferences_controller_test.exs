defmodule CourierWeb.NotificationPreferencesControllerTest do
  @moduledoc """
  The JSON API over notification preferences, the error envelope core requires
  around it, and the authorization on it: `application/problem+json`, a stable
  code, a `trace_id` that matches the `X-Trace-Id` header, per-field errors on a
  422, and a 404 for a user whose preferences belong to another account.


  `CourierWeb.Plugs.Principal` decides who is asking and `notification_preferences`
  records the account, so the three answers here are the three answers
  `WebhookEndpointsControllerTest` gives:

    * **anonymous → 401**, on both verbs, and the *same* 401 the webhook
      endpoints answer — asserted here by comparing the two bodies, because
      "it is behind a plug" is a claim about the router and "it is refused the
      way everything else is refused" is a claim about what a client receives.
    * **another account → 404**, on both verbs, because core's conventions forbid
      a 403 that leaks existence. The 404 is on the *user*, and it is only there
      once somebody has written rows for that user: a user courier has never been
      asked about is still a 200 with the defaults, because courier does not own
      users and cannot tell an account's user from one that does not exist.
    * **owning account → 200**, which is every other test in this file.

  The identity of the caller comes from a header the *test* sets. That is a seam
  with one implementation today and identity's JWT verifier behind it, not
  authentication; `CourierWeb.Plugs.Principal`'s moduledoc says so, and its
  default resolver authenticates nobody, so a deployed courier without that
  verifier refuses these requests rather than serving them to whoever asks.
  """

  use CourierWeb.ConnCase, async: true

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @account_id "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"

  @moduletag account: @account_id
  @other_account_id "2b3c4d5e-6f7a-4b9c-8d1e-2f3a4b5c6d7e"

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
  defp other_conn, do: as(@other_account_id)
  defp anonymous_conn, do: as(nil)

  defp get_preferences(conn, user_id) do
    conn
    |> get("/v1/notification_preferences/#{user_id}")
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp put_preferences(conn, user_id, params) do
    put(conn, "/v1/notification_preferences/#{user_id}", params)
  end

  describe "the authorization matrix" do
    @actions [
      {:get, "/v1/notification_preferences/6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061", :show},
      {:put, "/v1/notification_preferences/6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061", :update}
    ]

    test "anonymous is refused on both actions, with 401" do
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
        |> get("/v1/notification_preferences/#{@user_id}")
        |> refusal()

      there =
        anonymous_conn()
        |> get("/v1/webhook_endpoints")
        |> refusal()

      assert here == there
    end

    test "another account cannot read this one's preferences" do
      written =
        owner_conn()
        |> put_preferences(@user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })
        |> body()

      assert %{"data" => %{"preferences" => [welcome | _]}} = written
      assert welcome["email_enabled"] == false

      other =
        other_conn()
        |> get("/v1/notification_preferences/#{@user_id}")
        |> body()
        |> get_in(["data", "preferences"])

      unknown_user =
        other_conn()
        |> get("/v1/notification_preferences/#{Ecto.UUID.generate()}")
        |> body()
        |> get_in(["data", "preferences"])

      assert other == unknown_user

      assert Enum.all?(other, & &1["email_enabled"])

      assert %{"email_enabled" => false} =
               owner_conn()
               |> get_preferences(@user_id)
               |> get_in(["data", "preferences"])
               |> Enum.find(&(&1["notification_type"] == "welcome"))
    end

    test "another account cannot write this one's preferences, and writes nothing" do
      owner_conn()
      |> put_preferences(@user_id, %{
        "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
      })
      |> assert_status(200)

      conn =
        other_conn()
        |> put_preferences(@user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "push_enabled" => false}]
        })

      assert conn.status == 404

      assert %{"data" => %{"preferences" => preferences}} =
               owner_conn() |> get_preferences(@user_id)

      welcome = Enum.find(preferences, &(&1["notification_type"] == "welcome"))
      assert welcome["email_enabled"] == false
      assert welcome["push_enabled"] == true
    end

    test "an account that has never been asked about a user gets the defaults, not a 404" do
      conn = other_conn() |> get("/v1/notification_preferences/#{@user_id}")

      assert conn.status == 200

      assert %{
               "data" => %{
                 "user_id" => @user_id,
                 "preferences" => [
                   _welcome,
                   _reset,
                   _invitation,
                   _security,
                   _change_current,
                   _change_new,
                   _receipt,
                   _payment_failed
                 ]
               }
             } =
               body(conn)
    end

    test "an account_id beside the batch is not the account the row is stored against" do
      conn =
        owner_conn()
        |> put_preferences(@user_id, %{
          "account_id" => @other_account_id,
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })

      assert conn.status == 200

      assert %{"email_enabled" => false} =
               owner_conn()
               |> get_preferences(@user_id)
               |> get_in(["data", "preferences"])
               |> Enum.find(&(&1["notification_type"] == "welcome"))
    end

    test "an account_id inside an entry is a 422 naming the field" do
      conn =
        owner_conn()
        |> put_preferences(@user_id, %{
          "preferences" => [
            %{"notification_type" => "welcome", "account_id" => @other_account_id}
          ]
        })

      assert conn.status == 422
      assert %{"errors" => [%{"field" => "preferences[0].account_id"}]} = body(conn)
    end
  end

  defp assert_status(conn, status) do
    assert conn.status == status
    conn
  end

  defp refusal(conn) do
    assert conn.status == 401

    conn
    |> body()
    |> Map.drop(["instance", "trace_id"])
  end

  describe "GET /v1/notification_preferences/:user_id" do
    test "answers 200 with every notification type, on, for a user with no rows" do
      conn = get(owner_conn(), "/v1/notification_preferences/#{@user_id}")

      assert %{"data" => %{"user_id" => @user_id, "preferences" => preferences}} = body(conn)

      assert Enum.map(preferences, & &1["notification_type"]) ==
               ~w(welcome password_reset team_invitation account_security email_change_current email_change_new receipt payment_failed)

      assert Enum.all?(preferences, &(&1["email_enabled"] and &1["push_enabled"]))
    end

    test "answers with what the user actually stored" do
      put_preferences(owner_conn(), @user_id, %{
        "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
      })

      assert %{"data" => %{"preferences" => preferences}} =
               get_preferences(owner_conn(), @user_id)

      by_type = Map.new(preferences, &{&1["notification_type"], &1})
      assert by_type["welcome"]["email_enabled"] == false
      assert by_type["welcome"]["push_enabled"] == true
      assert by_type["password_reset"]["email_enabled"] == true
    end

    test "a user id that is not a uuid is a 422, not a 500" do
      conn = get(owner_conn(), "/v1/notification_preferences/not-a-uuid")

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)

      assert %{"errors" => [%{"field" => "user_id", "code" => "invalid_format"}]} = problem(conn)
    end

    test "an unknown user is not a 404: courier does not own users, so there is nothing to find" do
      conn =
        get(owner_conn(), "/v1/notification_preferences/00000000-0000-0000-0000-000000000000")

      assert conn.status == 200

      assert %{
               "data" => %{
                 "preferences" => [
                   _welcome,
                   _reset,
                   _invitation,
                   _security,
                   _change_current,
                   _change_new,
                   _receipt,
                   _payment_failed
                 ]
               }
             } =
               body(conn)
    end
  end

  describe "PUT /v1/notification_preferences/:user_id" do
    test "turns one channel off and answers with the stored state" do
      conn =
        put_preferences(owner_conn(), @user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })

      assert %{"data" => %{"user_id" => @user_id, "preferences" => preferences}} = body(conn)

      welcome = Enum.find(preferences, &(&1["notification_type"] == "welcome"))
      assert welcome["email_enabled"] == false
    end

    test "the change is visible to the next GET" do
      put_preferences(owner_conn(), @user_id, %{
        "preferences" => [%{"notification_type" => "team_invitation", "email_enabled" => false}]
      })

      assert %{"data" => %{"preferences" => preferences}} =
               get_preferences(owner_conn(), @user_id)

      assert Enum.find(preferences, &(&1["notification_type"] == "team_invitation"))[
               "email_enabled"
             ] ==
               false
    end

    test "is idempotent: the same request twice is the same answer" do
      params = %{"preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]}

      first = body(put_preferences(owner_conn(), @user_id, params))
      second = body(put_preferences(owner_conn(), @user_id, params))

      assert first == second
    end

    test "one user's change does not touch another's" do
      other = "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

      put_preferences(owner_conn(), @user_id, %{
        "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
      })

      assert %{"data" => %{"preferences" => preferences}} = get_preferences(owner_conn(), other)
      assert Enum.find(preferences, &(&1["notification_type"] == "welcome"))["email_enabled"]
    end

    test "a preference courier does not send is a 422 naming the field" do
      conn =
        put_preferences(owner_conn(), @user_id, %{
          "preferences" => [%{"notification_type" => "weekly_digest", "email_enabled" => false}]
        })

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)

      assert [%{"field" => "preferences[0].notification_type"}] = body(conn)["errors"]
    end

    test "a channel courier does not have is a 422, not a silently ignored typo" do
      conn =
        put_preferences(owner_conn(), @user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "emai_enabled" => false}]
        })

      assert %{"code" => "validation_failed"} = problem(conn)
      assert [%{"field" => "preferences[0].emai_enabled"}] = body(conn)["errors"]
    end

    test "a rejected batch stores nothing" do
      conn =
        put_preferences(owner_conn(), @user_id, %{
          "preferences" => [
            %{"notification_type" => "welcome", "email_enabled" => false},
            %{"notification_type" => "nope"}
          ]
        })

      assert conn.status == 422

      assert %{"data" => %{"preferences" => preferences}} =
               get_preferences(owner_conn(), @user_id)

      assert Enum.all?(preferences, & &1["email_enabled"])
    end

    test "a body that is not a list of preferences is a 422" do
      conn = put_preferences(owner_conn(), @user_id, %{"preferences" => "welcome"})

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)
      assert [%{"field" => "preferences"}] = body(conn)["errors"]
    end

    test "an empty body is a 422" do
      conn = put_preferences(owner_conn(), @user_id, %{})

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)
    end

    test "a malformed body is a 400, because the client could not have known" do
      conn =
        owner_conn()
        |> put_req_header("content-type", "application/json")
        |> put("/v1/notification_preferences/#{@user_id}", "{not json")

      assert %{"code" => "bad_request", "status" => 400} = problem(conn)
    end

    test "a user id that is not a uuid is a 422 before the body is looked at" do
      conn = put_preferences(owner_conn(), "not-a-uuid", %{"preferences" => []})

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)
    end
  end

  describe "the error envelope" do
    test "is core's problem+json, with a stable type URI and a code that matches it" do
      conn = put_preferences(owner_conn(), @user_id, %{"preferences" => []})

      assert %{"type" => type, "code" => "validation_failed"} = problem(conn)
      assert type == "https://docs.anywaye.com/errors/validation_failed"
    end

    test "carries a title, a status, and a detail" do
      conn = put_preferences(owner_conn(), @user_id, %{"preferences" => []})

      assert %{"title" => "Validation failed", "status" => 422, "detail" => detail} =
               problem(conn)

      assert is_binary(detail)
    end

    test "names the instance the request was made to" do
      conn = put_preferences(owner_conn(), @user_id, %{"preferences" => []})

      assert %{"instance" => "/v1/notification_preferences/" <> @user_id} = problem(conn)
    end

    test "carries a trace_id that matches the X-Trace-Id response header" do
      conn = put_preferences(owner_conn(), @user_id, %{"preferences" => []})

      assert %{"trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end

    test "carries the same trace_id for a request that went nowhere" do
      conn = get(owner_conn(), "/v1/notification_preferences/not-a-uuid")

      assert %{"trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end

    test "lists the field that failed, for support to read" do
      conn = get(owner_conn(), "/v1/notification_preferences/not-a-uuid")

      assert %{"errors" => [%{"field" => "user_id"}]} = problem(conn)
    end

    test "a 404 for an unknown route is core's envelope too" do
      conn = get(build_conn(), "/v1/nope")

      assert %{"code" => "not_found", "status" => 404, "trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end
  end
end
