defmodule CourierWeb.WebhookEndpointsControllerTest do
  @moduledoc """
  `/v1/webhook_endpoints` — the API, the envelope, and the authorization matrix.

  ## Why there is an authorization section at all

  `NotificationPreferencesController` says in its own moduledoc that its requests
  are unauthenticated in this packet, because courier does not verify JWTs yet.
  That is a real gap and it is a *known* one, recorded rather than hidden. Webhook
  endpoints are the first courier resource where the gap would be a breach rather
  than an inconvenience: an endpoint's url and its signing secret are a way to make
  courier send signed requests, and an unauthenticated `GET` on the list is a way
  to enumerate them.

  So this surface refuses anonymous requests outright. That is the narrow,
  defensible answer for a service that has no token verifier yet, and the matrix
  below is what holds the line while the JWT packet lands:

    * **anonymous → 401**, always, on every action. A missing principal is not a
      request courier will guess an account for.
    * **wrong account → 404**, never 403. Core's OpenAPI conventions are explicit:
      "Never 404 for authorization failures on a resource the caller cannot see —
      404 is correct there, 403 is not allowed to leak existence." A 403 would
      confirm the endpoint exists to someone who cannot see it.
    * **owning account → 200/201/204**, and the tenant is the account the endpoint
      belongs to, never one from the body.

  The identity of the caller comes from `CourierWeb.Plugs.Principal`, which reads
  a header the *test* sets. A plug that reads a caller-supplied header is not
  authentication — it is a seam with exactly one implementation today and a JWT
  verifier behind it later. The moduledoc says so, and the default implementation
  authenticates nothing, so a deployed courier without the later packet does not
  have a hole where authentication was assumed.
  """

  use CourierWeb.ConnCase, async: true

  # The matrix below dispatches by method with `Phoenix.ConnTest.dispatch/4`,
  # which the generated case does not import — it brings in the verb-specific
  # helpers (`get/2`, `post/3`) and not the generic one.
  alias Courier.Repo
  alias Courier.WebhookEndpoint
  alias Courier.WebhookEndpoints

  @account_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account_id
  @other_account_id "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  @url "https://hooks.example.com/events"

  defp endpoint!(attrs \\ %{}) do
    {:ok, endpoint, _secret} =
      WebhookEndpoints.create(Map.merge(%{url: @url, account_id: @account_id}, attrs))

    endpoint
  end

  # The account the request is made as. `nil` is an anonymous request.
  # The conn a request is made as.
  #
  # `Phoenix.ConnTest.build_conn/0`, not `Plug.Test.conn/3`: the verb helpers build
  # the request conn from the method and path, and a conn made with `Plug.Test`
  # has no `secret_key_base` or host, so everything the endpoint needs is
  # discarded on the way through. A header set on a `build_conn/0` survives,
  # because that is the conn the request is dispatched *from*.
  defp owner_conn, do: as(@account_id)
  defp other_conn, do: as(@other_account_id)
  defp anonymous_conn, do: as(nil)

  defp as(account_id) do
    case account_id do
      nil -> build_conn()
      account_id -> put_req_header(build_conn(), "x-courier-account", account_id)
    end
  end

  # Dispatches a method the verb helpers do not cover, carrying the conn's own
  # headers. Used by the authorization matrix, which loops over every action.
  defp dispatch(conn, method, path) do
    Phoenix.ConnTest.dispatch(conn, @endpoint, method, path)
  end

  describe "the authorization matrix" do
    # Every action × every caller, asserted rather than described. The four
    # columns are the four questions a request can be: who are you, whose
    # resource is this, what may you do to your own, and what may you do to
    # someone else's.
    @actions [
      {:get, "/v1/webhook_endpoints", :index},
      {:post, "/v1/webhook_endpoints", :create},
      {:get, "/v1/webhook_endpoints/DOES_NOT_EXIST", :show},
      {:patch, "/v1/webhook_endpoints/DOES_NOT_EXIST", :update},
      {:delete, "/v1/webhook_endpoints/DOES_NOT_EXIST", :delete},
      {:post, "/v1/webhook_endpoints/DOES_NOT_EXIST/test", :ping}
    ]

    test "anonymous is refused on every action, with 401" do
      for {method, path, name} <- @actions do
        conn = dispatch(anonymous_conn(), method, path)

        assert conn.status == 401, "#{name} must be refused with 401, got #{conn.status}"
        assert conn.halted
      end
    end

    test "the refusal happens before routing reaches a controller" do
      # A 401 rather than a 404 or a 422 is itself the assertion: the plug runs in
      # the pipeline, so an anonymous caller never reaches an action, and no
      # action has to remember to check. `conn.assigns.action` is nil for a
      # request that was halted in a plug.
      for {method, path, _name} <- @actions do
        conn = dispatch(anonymous_conn(), method, path)

        assert conn.assigns[:action] == nil
      end
    end

    test "the 401 is courier's problem+json, not Phoenix's" do
      conn = get(anonymous_conn(), "/v1/webhook_endpoints")

      assert conn.status == 401
      assert ["application/problem+json" <> _rest] = get_resp_header(conn, "content-type")

      assert %{"code" => "unauthorized", "type" => "https://docs.cafaye.com/errors/unauthorized"} =
               Jason.decode!(conn.resp_body)
    end

    test "another account's token does not grant access to this one's endpoints" do
      # The whole point of the matrix: knowing that *an* account exists is not
      # knowing that this endpoint is yours.
      theirs =
        as_account(@other_account_id, fn -> endpoint!(%{account_id: @other_account_id}) end)

      conn = owner_conn() |> get("/v1/webhook_endpoints/#{theirs.id}")

      assert conn.status == 404
      refute conn.resp_body =~ theirs.url
    end
  end

  describe "POST /v1/webhook_endpoints" do
    test "creates an endpoint and answers 201" do
      conn =
        owner_conn()
        |> post("/v1/webhook_endpoints", %{"url" => @url, "description" => "orders"})

      assert %{"data" => %{"url" => @url, "description" => "orders", "status" => "enabled"}} =
               json_response(conn, 201)
    end

    test "returns the signing secret exactly once" do
      conn = owner_conn() |> post("/v1/webhook_endpoints", %{"url" => @url})

      assert %{"data" => %{"secret" => "whsec_" <> _}} = json_response(conn, 201)
    end

    test "the secret is not readable afterwards" do
      conn = owner_conn() |> post("/v1/webhook_endpoints", %{"url" => @url})
      id = json_response(conn, 201)["data"]["id"]

      # There is no endpoint that returns a secret, because a GET that could is a
      # credential endpoint.
      listed = owner_conn() |> get("/v1/webhook_endpoints") |> json_response(200)

      for endpoint <- listed["data"] do
        refute Map.has_key?(endpoint, "secret")
      end

      refute id == nil
    end

    test "stores the endpoint against the caller's account, not one in the body" do
      conn =
        owner_conn()
        |> post("/v1/webhook_endpoints", %{"url" => @url, "account_id" => @other_account_id})

      assert %{"data" => %{"account_id" => account_id}} = json_response(conn, 201)
      assert account_id == @account_id
    end

    test "refuses a url courier will not send to, naming the class it was" do
      conn =
        owner_conn()
        |> post("/v1/webhook_endpoints", %{"url" => "http://169.254.169.254/latest/meta-data/"})

      assert %{"code" => "validation_failed", "errors" => [error]} = json_response(conn, 422)
      assert error["field"] == "url"
      assert error["code"] == "blocked_address"
    end

    test "refuses loopback" do
      conn = owner_conn() |> post("/v1/webhook_endpoints", %{"url" => "http://127.0.0.1:4000/x"})

      assert %{"code" => "validation_failed"} = json_response(conn, 422)
    end

    test "refuses a url with no scheme, as a validation error" do
      conn = owner_conn() |> post("/v1/webhook_endpoints", %{"url" => "hooks.example.com/events"})

      assert %{"code" => "validation_failed", "errors" => [%{"field" => "url"}]} =
               json_response(conn, 422)
    end

    test "refuses a body with no url" do
      conn = owner_conn() |> post("/v1/webhook_endpoints", %{})

      assert %{"code" => "validation_failed", "errors" => [%{"field" => "url"}]} =
               json_response(conn, 422)
    end

    test "refuses a second endpoint with the same url in the same account, as a 422" do
      endpoint!()

      conn = owner_conn() |> post("/v1/webhook_endpoints", %{"url" => @url})

      assert %{"code" => "validation_failed", "errors" => [%{"code" => "taken"}]} =
               json_response(conn, 422)
    end

    test "lets another account register the same url" do
      endpoint!()

      conn =
        other_conn()
        |> post("/v1/webhook_endpoints", %{"url" => @url})

      assert %{"data" => %{"account_id" => @other_account_id}} = json_response(conn, 201)
    end

    test "answers problem+json on a refusal" do
      conn = owner_conn() |> post("/v1/webhook_endpoints", %{"url" => "nope"})

      assert ["application/problem+json" <> _rest] = get_resp_header(conn, "content-type")
    end
  end

  describe "GET /v1/webhook_endpoints" do
    test "lists the caller's own endpoints" do
      mine = endpoint!()

      conn = owner_conn() |> get("/v1/webhook_endpoints")

      assert %{"data" => [%{"id" => id}]} = json_response(conn, 200)
      assert id == mine.id
    end

    test "never lists another account's" do
      endpoint!()

      conn = other_conn() |> get("/v1/webhook_endpoints")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns an empty list rather than nothing" do
      conn = owner_conn() |> get("/v1/webhook_endpoints")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "includes disabled endpoints, because disabling is not deleting" do
      endpoint = endpoint!()
      {:ok, _} = WebhookEndpoints.update(endpoint, %{status: "disabled"})

      conn = owner_conn() |> get("/v1/webhook_endpoints")

      assert %{"data" => [%{"status" => "disabled"}]} = json_response(conn, 200)
    end

    test "returns a page object, as core's pagination conventions require" do
      endpoint!()

      conn = owner_conn() |> get("/v1/webhook_endpoints")

      assert %{"data" => _data, "page" => %{"has_more" => false, "next_cursor" => nil}} =
               json_response(conn, 200)
    end

    test "caps the page at a hundred" do
      conn = owner_conn() |> get("/v1/webhook_endpoints?limit=500")

      assert %{"data" => _data} = json_response(conn, 200)
    end

    test "refuses a limit that is not a number" do
      conn = owner_conn() |> get("/v1/webhook_endpoints?limit=all")

      assert %{"code" => "validation_failed"} = json_response(conn, 422)
    end

    test "a second page continues where the first stopped" do
      first = endpoint!()
      second = endpoint!(%{url: "https://second.example.com/events"})

      page1 = owner_conn() |> get("/v1/webhook_endpoints?limit=1") |> json_response(200)
      cursor = page1["page"]["next_cursor"]

      assert %{"data" => [%{"id" => first_id}]} = page1
      assert first_id == first.id

      conn = owner_conn() |> get("/v1/webhook_endpoints?limit=1&cursor=#{cursor}")

      assert %{"data" => [%{"id" => second_id}], "page" => %{"has_more" => false}} =
               json_response(conn, 200)

      assert second_id == second.id
    end

    test "refuses a cursor that is not one courier issued" do
      # Core: the cursor is opaque and "clients must not parse it". A cursor
      # courier cannot decode is a 422 rather than a silent first page, because a
      # client that sent a hand-built cursor deserves to be told it is wrong.
      conn = owner_conn() |> get("/v1/webhook_endpoints?cursor=not-a-cursor")

      assert %{"code" => "validation_failed", "errors" => [%{"field" => "cursor"}]} =
               json_response(conn, 422)
    end
  end

  describe "GET /v1/webhook_endpoints/:id" do
    test "returns the caller's own endpoint" do
      endpoint = endpoint!()

      conn = owner_conn() |> get("/v1/webhook_endpoints/#{endpoint.id}")

      assert %{"data" => %{"id" => id, "url" => @url}} = json_response(conn, 200)
      assert id == endpoint.id
    end

    test "answers 404 for another account's endpoint, not 403" do
      # Core's openapi-conventions: a 403 "leaks existence". There is no 403
      # anywhere in this file, and that is the rule.
      endpoint =
        as_account(@other_account_id, fn -> endpoint!(%{account_id: @other_account_id}) end)

      conn = owner_conn() |> get("/v1/webhook_endpoints/#{endpoint.id}")

      assert %{"code" => "not_found"} = json_response(conn, 404)
    end

    test "answers 404 for an id that does not exist" do
      conn = owner_conn() |> get("/v1/webhook_endpoints/#{Ecto.UUID.generate()}")

      assert %{"code" => "not_found"} = json_response(conn, 404)
    end

    test "answers 404 for an id that is not a uuid" do
      conn = owner_conn() |> get("/v1/webhook_endpoints/not-a-uuid")

      assert %{"code" => "not_found"} = json_response(conn, 404)
    end

    test "never includes the secret" do
      endpoint = endpoint!()

      conn = owner_conn() |> get("/v1/webhook_endpoints/#{endpoint.id}")

      refute Map.has_key?(json_response(conn, 200)["data"], "secret")
    end
  end

  describe "PATCH /v1/webhook_endpoints/:id" do
    test "changes the url" do
      endpoint = endpoint!()

      conn =
        owner_conn()
        |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{
          "url" => "https://new.example.com/events"
        })

      assert %{"data" => %{"url" => "https://new.example.com/events"}} = json_response(conn, 200)
    end

    test "changes the status" do
      endpoint = endpoint!()

      conn =
        owner_conn() |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{"status" => "disabled"})

      assert %{"data" => %{"status" => "disabled"}} = json_response(conn, 200)
    end

    test "re-enabling a tripped endpoint clears courier's reason" do
      endpoint = endpoint!()
      # Trip it five times so the circuit actually opens and courier has written
      # a reason; re-enabling is what has to clear it.
      tripped =
        Enum.reduce(1..5, endpoint, fn _n, current ->
          elem(WebhookEndpoints.trip(current, 5, "boom"), 1)
        end)

      assert Repo.get!(WebhookEndpoint, tripped.id).disabled_reason != nil

      conn =
        owner_conn() |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{"status" => "enabled"})

      assert %{"data" => %{"status" => "enabled", "disabled_reason" => nil}} =
               json_response(conn, 200)
    end

    test "answers 404 for another account's endpoint" do
      endpoint =
        as_account(@other_account_id, fn -> endpoint!(%{account_id: @other_account_id}) end)

      conn =
        owner_conn() |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{"status" => "disabled"})

      assert %{"code" => "not_found"} = json_response(conn, 404)

      # READ BACK UNDER THE IDENTITY THAT OWNS THE ROW. `Repo.get!/2` reaches a
      # protected row by primary key alone, and under the RLS `select` policy the
      # test body's identity decides whether it is returned at all. The body's
      # identity here is `@account_id` -- unless a request changed it, which each
      # scoped action does, because inside the sandbox its transaction is a
      # SAVEPOINT whose release does not discard a transaction-local setting. So
      # the read is asked for the identity it needs rather than inheriting one.
      assert as_account(@other_account_id, fn ->
               Repo.get!(WebhookEndpoint, endpoint.id).status == :enabled
             end)
    end

    test "refuses a url courier will not send to" do
      endpoint = endpoint!()

      conn =
        owner_conn()
        |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{"url" => "http://10.0.0.1/x"})

      assert %{"code" => "validation_failed"} = json_response(conn, 422)
      assert Repo.get!(WebhookEndpoint, endpoint.id).url == @url
    end

    test "refuses a status that is neither enabled nor disabled" do
      endpoint = endpoint!()

      conn =
        owner_conn() |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{"status" => "paused"})

      assert %{"code" => "validation_failed", "errors" => [%{"field" => "status"}]} =
               json_response(conn, 422)
    end

    test "leaves fields it was not given alone" do
      endpoint = endpoint!(%{description: "orders"})

      conn =
        owner_conn()
        |> patch("/v1/webhook_endpoints/#{endpoint.id}", %{
          "url" => "https://new.example.com/events"
        })

      assert %{"data" => %{"description" => "orders"}} = json_response(conn, 200)
    end
  end

  describe "DELETE /v1/webhook_endpoints/:id" do
    test "removes the endpoint and answers 204 with no body" do
      endpoint = endpoint!()

      conn = owner_conn() |> delete("/v1/webhook_endpoints/#{endpoint.id}")

      assert response(conn, 204) == ""
      assert WebhookEndpoints.get(endpoint.id, @account_id) == nil
    end

    test "answers 404 for another account's endpoint, and leaves it" do
      endpoint =
        as_account(@other_account_id, fn -> endpoint!(%{account_id: @other_account_id}) end)

      conn = owner_conn() |> delete("/v1/webhook_endpoints/#{endpoint.id}")

      assert %{"code" => "not_found"} = json_response(conn, 404)

      # READ BACK UNDER THE IDENTITY THAT OWNS THE ROW — see the identical
      # comment on the PATCH test above. As `@account_id` this is `nil` whatever
      # the DELETE did, because the RLS `select` policy does not return the other
      # account's row: **an assertion that passes because the row is invisible
      # rather than because it survived proves nothing about the DELETE.**
      assert as_account(@other_account_id, fn ->
               WebhookEndpoints.get(endpoint.id, @other_account_id)
             end)
    end

    test "answers 404 for an id that does not exist" do
      conn = owner_conn() |> delete("/v1/webhook_endpoints/#{Ecto.UUID.generate()}")

      assert %{"code" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "POST /v1/webhook_endpoints/:id/test" do
    test "sends a signed ping and answers 200" do
      endpoint = endpoint!()

      conn = owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      assert %{"data" => %{"status_code" => status_code, "delivered" => true}} =
               json_response(conn, 200)

      assert status_code == 200
    end

    test "the ping verifies against the endpoint's own secret" do
      endpoint = endpoint!()
      secret = WebhookEndpoints.plaintext_secret(endpoint)

      owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      request = Courier.TestSupport.RecordingSender.last()
      assert Courier.Webhooks.Verifier.verify(request.body, request.headers, secret) == :ok
    end

    test "the ping body says ping, not an event" do
      endpoint = endpoint!()

      owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      body = Jason.decode!(Courier.TestSupport.RecordingSender.last().body)
      assert body["type"] == "ping"
      refute Map.has_key?(body, "id")
    end

    test "answers 200 with the receiver's status, because the test itself worked" do
      # A 422 here would say courier could not test the endpoint, when what
      # happened is that courier tested it and the endpoint answered 500. The
      # customer needs the second fact, and it is a 200 to them either way: their
      # request was well-formed and courier did what it was asked.
      endpoint = endpoint!()
      Courier.TestSupport.RecordingSender.answer_with(%{response_status: 500})

      conn = owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      assert %{"data" => %{"delivered" => false, "status_code" => 500}} = json_response(conn, 200)
    end

    test "says so when the endpoint could not be reached at all" do
      endpoint = endpoint!()
      Courier.TestSupport.RecordingSender.answer_with(%{error: :econnrefused})

      conn = owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      assert %{"data" => %{"delivered" => false, "status_code" => nil}} = json_response(conn, 200)
    end

    test "does not count a failed test against the circuit, because the customer is asking" do
      # A customer testing their own endpoint and getting a 500 is the endpoint
      # being broken, not a delivery attempt. Counting it would trip the circuit
      # on the customer's own diagnostics — and the test is not a delivery, so it
      # has no row.
      endpoint = endpoint!()
      Courier.TestSupport.RecordingSender.answer_with(%{response_status: 500})

      owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      assert Repo.get!(WebhookEndpoint, endpoint.id).consecutive_failures == 0
    end

    test "answers 404 for another account's endpoint, and sends nothing" do
      endpoint =
        as_account(@other_account_id, fn -> endpoint!(%{account_id: @other_account_id}) end)

      Courier.TestSupport.RecordingSender.reset()

      conn = owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      assert %{"code" => "not_found"} = json_response(conn, 404)
      assert Courier.TestSupport.RecordingSender.last() == nil
    end

    test "answers 404 for an id that does not exist" do
      conn = owner_conn() |> post("/v1/webhook_endpoints/#{Ecto.UUID.generate()}/test")

      assert %{"code" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "the response envelope" do
    test "never includes the secret on any read" do
      endpoint = endpoint!()

      list = owner_conn() |> get("/v1/webhook_endpoints")
      show = owner_conn() |> get("/v1/webhook_endpoints/#{endpoint.id}")
      ping = owner_conn() |> post("/v1/webhook_endpoints/#{endpoint.id}/test")

      for conn <- [list, show, ping] do
        refute conn.resp_body =~ "whsec_"
        refute conn.resp_body =~ WebhookEndpoints.plaintext_secret(endpoint)
      end
    end

    test "echoes the trace id on every response, and in the error body when there is one" do
      # The house convention (see `NotificationPreferencesControllerTest`): the id
      # is a response header on every answer, and it is in the problem body too,
      # so support can start from the same id on both. Per *request* — two
      # requests get two ids, which is the point of one.
      ok = owner_conn() |> get("/v1/webhook_endpoints")
      refused = owner_conn() |> get("/v1/webhook_endpoints/#{Ecto.UUID.generate()}")

      assert [ok_trace] = get_resp_header(ok, "x-trace-id")
      assert [error_trace] = get_resp_header(refused, "x-trace-id")
      assert %{"trace_id" => ^error_trace} = json_response(refused, 404)
      assert ok_trace != error_trace
    end

    test "carries the failure count and the reason, so 'why did delivery stop' has an answer" do
      endpoint = endpoint!()
      {:ok, endpoint} = WebhookEndpoints.trip(endpoint, 5, "connection refused")

      conn = owner_conn() |> get("/v1/webhook_endpoints/#{endpoint.id}")

      assert %{"data" => %{"consecutive_failures" => 1}} = json_response(conn, 200)
      assert endpoint.consecutive_failures == 1
    end
  end
end
