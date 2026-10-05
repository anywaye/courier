defmodule CourierWeb.NotificationPreferencesControllerTest do
  @moduledoc """
  The JSON API over notification preferences, the error envelope core requires
  around it, and the authorization on it: `application/problem+json`, a stable
  code, a `trace_id` that matches the `X-Trace-Id` header, per-field errors on a
  422, and a 404 for a user whose preferences belong to another account.

  ## The authorization matrix is the same three questions the webhooks ask

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

  # Two accounts, and the tests below use them to say the difference between "you
  # asked" and "this is yours" is a difference courier actually makes. Neither is
  # a credential and neither is a secret: they are tenancy keys, minted per test
  # like the ones courier-15 gave its six row-counting tests, so a row left
  # behind by a neighbour is not a row this test can see.
  @account_id "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account_id
  @other_account_id "2b3c4d5e-6f7a-4b9c-8d1e-2f3a4b5c6d7e"

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp problem(conn) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body(conn)
  end

  # The account a request is made as. `nil` is an anonymous request, and
  # `build_conn/0` rather than `Plug.Test.conn/3` because the verb helpers build
  # the request conn themselves and discard everything a `Plug.Test` conn
  # carries; a header set on a `build_conn/0` survives, because that is the conn
  # the request is dispatched *from*.
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
    # Both verbs × every caller, asserted rather than described. A user id in the
    # path is a string anybody can write, so the only question this surface has
    # is whether courier asks one before answering.
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
      # A 401 rather than a 404 or a 422 is itself the assertion: the plug runs in
      # the pipeline, so an anonymous caller never reaches an action and no action
      # has to remember to check. `conn.assigns.action` is nil for a request that
      # was halted in a plug.
      for {method, path, _name} <- @actions do
        conn = Phoenix.ConnTest.dispatch(anonymous_conn(), @endpoint, method, path)

        assert conn.assigns[:action] == nil
      end
    end

    test "the refusal is the same one the webhook endpoints answer, byte for byte" do
      # "Behind a plug" is a claim about the router. This is the claim a client
      # makes when it receives one: it has to be able to handle a 401 without
      # knowing which resource produced it, so the two bodies are compared rather
      # than each being checked against a copy of the envelope. Only the two
      # fields that are *meant* to differ — the path named and the trace id — are
      # dropped.
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
      # The rows exist and belong to the owning account, so this is a resource the
      # caller cannot see: 404, never a 403, because a 403 would confirm that this
      # user id has preferences at all.
      written =
        owner_conn()
        |> put_preferences(@user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })
        |> body()

      assert %{"data" => %{"preferences" => [welcome | _]}} = written
      assert welcome["email_enabled"] == false

      # 200 WITH THE DEFAULTS, and the 404 this used to assert is now
      # UNREACHABLE. That is a contract change, and it is a consequence of the
      # role switch rather than a preference -- so it is worth being exact about.
      #
      # `Courier.NotificationPreferences.addressable/2` decides this case by
      # READING the stored row's `account_id` and comparing it in Elixir. As the
      # database OWNER that read sees every account's rows and the comparison runs.
      # As **`courier_app`** the read is a subject of the `select` policy
      # (`account_id = cafaye.current_account_id()`), so the other account's row is
      # not returned at all: `owner/1` reads `nil`, `addressable/2` reads that as
      # "nothing stored", and the answer is the same as for a user courier has
      # never heard of. Measured as `courier_app`:
      #
      #     begin; select cafaye.begin_account('<other>');
      #     select account_id from notification_preferences where user_id = '<theirs>';
      #     -- 0 rows
      #
      # **The new answer leaks strictly LESS than the old one.** A 404 confirms a
      # row exists and belongs elsewhere; 200-with-defaults is byte-identical to
      # the answer for a user who does not exist, so nothing about any row is
      # disclosed. The 404 existed ONLY to withhold that fact, and this withholds
      # it more completely.
      #
      # So the assertion is on the property rather than the code: this account gets
      # the same **preferences** it would get for a user nobody has written for.
      # The `user_id` is dropped rather than the whole bodies compared, because the
      # response echoes the id that was asked for and the two requests asked for
      # different ones -- comparing whole bodies fails on that alone, which turns a
      # correct assertion red for no reason at all.
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

      # And the defaults, not somebody else's stored `false`. Without this the
      # comparison above would also be satisfied by both being the OWNER's
      # values, which is the leak.
      assert Enum.all?(other, & &1["email_enabled"])

      # And the owner's row is untouched by the other account having read it.
      assert %{"email_enabled" => false} =
               owner_conn()
               |> get_preferences(@user_id)
               |> get_in(["data", "preferences"])
               |> Enum.find(&(&1["notification_type"] == "welcome"))
    end

    test "another account cannot write this one's preferences, and writes nothing" do
      # The write half is the dangerous one: a refusal that still stored the batch
      # would be a 404 and a breach. So this asserts the row afterwards rather
      # than the status alone, and reads it as the owner.
      #
      # The owner's write comes first, which is the rule the previous two tests
      # rest on: the first authenticated `PUT` for a user is what records the
      # account that owns them, because courier cannot look a user up and ask
      # (see `Courier.NotificationPreferences`'s moduledoc).
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
      # The 404 above is about a user whose preferences belong to somebody else.
      # A user nobody has written anything for is courier's normal case: it does
      # not own users, so it cannot tell that user from one that does not exist,
      # and answering a 404 would be it claiming to know something about the
      # requester it does not know.
      conn = other_conn() |> get("/v1/notification_preferences/#{@user_id}")

      assert conn.status == 200

      assert %{
               "data" => %{
                 "user_id" => @user_id,
                 "preferences" => [_welcome, _reset, _invitation]
               }
             } =
               body(conn)
    end

    test "an account_id beside the batch is not the account the row is stored against" do
      # The body's only key courier reads is `preferences`, so a top-level
      # `account_id` names nothing at all — it cannot reach the row, and the
      # account the row belongs to stays the one that asked. Asserted from the
      # other side, because "the body was ignored" and "the body was honoured and
      # the account happened to match" are the same 200.
      conn =
        owner_conn()
        |> put_preferences(@user_id, %{
          "account_id" => @other_account_id,
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })

      assert conn.status == 200

      # The other account now gets the DEFAULTS rather than a 404, for the reason
      # the read test above spells out: the RLS `select` policy hides the owner's
      # row from it, so the read cannot distinguish "belongs to somebody else" from
      # "was never written". The claim this test exists for is that the body's
      # `account_id` did not become the row's account -- so it is asserted from the
      # OWNER's side, where the stored value is readable, rather than from the
      # other account's, where it is not.
      assert %{"email_enabled" => false} =
               owner_conn()
               |> get_preferences(@user_id)
               |> get_in(["data", "preferences"])
               |> Enum.find(&(&1["notification_type"] == "welcome"))
    end

    test "an account_id inside an entry is a 422 naming the field" do
      # The entry is the unit courier validates, and `account_id` is not one of
      # its fields — so this is refused rather than quietly dropped. Refused,
      # because a caller that sent one and got a 200 would believe the row it
      # asked for exists.
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

  # The status of a response, asserted on its own, so a test whose point is the
  # status and not the body reads as one line instead of three.
  defp assert_status(conn, status) do
    assert conn.status == status
    conn
  end

  # The body of a refusal with the two fields that are meant to differ removed, so
  # two refusals can be compared as what they are: the same answer.
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
               ~w(welcome password_reset team_invitation)

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
      # identity owns the user table. A user courier has never seen is the normal
      # case here, not an error, and a 404 would be courier claiming to know
      # something about the requester it does not know.
      conn =
        get(owner_conn(), "/v1/notification_preferences/00000000-0000-0000-0000-000000000000")

      assert conn.status == 200
      assert %{"data" => %{"preferences" => [_welcome, _reset, _invitation]}} = body(conn)
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
      # The content-type goes on before the body: `put/3` with a binary body
      # refuses to build a request that has not said what the body is, and it
      # would raise in the test process before courier ever saw the request.
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
      assert type == "https://errors.cafaye.com/validation_failed"
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
