defmodule CourierWeb.Plugs.IdempotencyTest do
  @moduledoc """
  `Idempotency-Key`, over real requests through the real router.

  `Courier.IdempotencyTest` covers the storage. This file covers the half that
  only a running pipeline can show, and the half that matters most is not the
  happy path — it is that a retry **does not mutate twice**. So the assertions
  below are about the world after the second request, not about the status code
  it returned:

    * a create retried with one key leaves **one** endpoint, and the second
      response is the first response byte for byte — including the `whsec_`
      secret, which exists nowhere else and cannot be re-derived;
    * a ping retried with one key sends **nothing** the second time, asserted by
      clearing the recording sender and finding nothing recorded;
    * a request that did not succeed leaves **no row**, so the retry runs.

  The last one is the assertion that a failed request is not pinned for a day, and
  it is the reason a 4xx is not stored. See `Courier.Idempotency`'s moduledoc.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.Idempotency
  alias Courier.IdempotencyKey
  alias Courier.Repo
  alias Courier.TestSupport.RecordingSender
  alias Courier.WebhookEndpoints
  alias CourierWeb.Plugs.Idempotency, as: KeyPlug

  @account "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account
  @other_account "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  @url "https://hooks.example.com/events"
  @other_url "https://hooks.example.com/other"
  @path "/v1/webhook_endpoints"

  @key "11111111-1111-1111-1111-111111111111"
  @other_key "22222222-2222-2222-2222-222222222222"

  setup do
    RecordingSender.reset()
    :ok
  end

  # The conn a request is made as: the test's account header, and the idempotency
  # key if the test asked for one. `build_conn/0` rather than `Plug.Test.conn/3`
  # for the reason `webhook_endpoints_controller_test.exs` documents: the verb
  # helpers need a conn with a `secret_key_base` and a host, and a header set on
  # a `build_conn/0` survives because that is the conn the request dispatches from.
  defp as(account_id, key) do
    build_conn()
    |> conn_key(key)
    |> put_req_header("x-courier-account", account_id)
  end

  defp owner(key \\ nil), do: as(@account, key)
  defp other(key), do: as(@other_account, key)

  # A header is only set when the test asked for one, so "no key" is a conn with
  # no such header rather than a conn with an empty one — `put_req_header/3` with
  # `nil` would send the string "nil".
  defp conn_key(conn, nil), do: conn
  defp conn_key(conn, key), do: put_req_header(conn, KeyPlug.key_header(), key)

  defp claims, do: Repo.aggregate(IdempotencyKey, :count)

  defp endpoint_count, do: Repo.aggregate(Courier.WebhookEndpoint, :count)

  # PER-ACCOUNT COUNTS, each run UNDER ITS OWN IDENTITY.
  #
  # Two reasons, and the second is the one that took a driver test to find.
  #
  # First: a whole-table `Repo.aggregate(..., :count)` is a claim about every
  # other test in the repository as much as about this one, and under an RLS
  # `select` policy it is also a claim about the policy -- a body holding
  # `@account`'s identity reads one row and the assertion fails with
  #
  #     left:  1
  #     right: 2
  #
  # on a test whose two requests both did the right thing.
  #
  # Second: **a count taken from the test body is scoped to whatever identity the
  # body happens to hold, and `CourierWeb.Plugs.TenantIdentity` changes it.** The
  # plug opens its transaction with `begin_account/2`, and inside the sandbox that
  # is a SAVEPOINT whose RELEASE does not discard a transaction-local setting.
  # Measured, on a driver test that printed the identity at each step:
  #
  #     identity at start:          6f5d4c3b-...  (@account)
  #     identity after OWNER post:  6f5d4c3b-...  (unchanged)
  #     identity after OTHER post:  7a6e5d4c-...  (the other account)
  #
  # **That is a property of the sandbox, not a production leak**, and the
  # difference is the whole of `Courier.Tenancy`'s argument for `is_local := true`:
  # in production the plug's transaction is the OUTERMOST one, so `COMMIT`
  # discards the setting in the database with nothing in courier to forget. The
  # sandbox's transaction sits OUTSIDE the plug's and nothing commits it until the
  # test ends.
  #
  # So each count asks for the identity it wants rather than inheriting one, and
  # `as_account/2` puts the previous one back so one count cannot colour the next.
  defp endpoints_for(account_id) do
    as_account(account_id, fn ->
      Repo.aggregate(
        Ecto.Query.from(e in Courier.WebhookEndpoint, where: e.account_id == ^account_id),
        :count
      )
    end)
  end

  defp claims_for(account_id) do
    as_account(account_id, fn ->
      Repo.aggregate(
        Ecto.Query.from(k in IdempotencyKey, where: k.account_id == ^account_id),
        :count
      )
    end)
  end

  defp an_endpoint do
    {:ok, endpoint, _secret} = WebhookEndpoints.create(%{url: @url, account_id: @account})
    endpoint
  end

  describe "a request without a key" do
    test "is processed normally, and records nothing" do
      # core: "Requests without the key are processed normally. Retrying without
      # a key is the client's bug." The proof it is processed *normally* and not
      # silently deduplicated is that it really creates a second row — and the two
      # urls differ, because `url` is unique per account and a duplicate is a 422
      # for a reason that has nothing to do with idempotency.
      assert owner() |> post(@path, %{url: @url}) |> json_response(201)
      assert owner() |> post(@path, %{url: @other_url}) |> json_response(201)

      assert endpoint_count() == 2
      assert claims() == 0
    end

    test "carries no Idempotency-Replayed header" do
      conn = owner() |> post(@path, %{url: @url})

      assert get_resp_header(conn, KeyPlug.replayed_header()) == []
    end
  end

  describe "a key that is not a uuid" do
    test "is a 422, because core says the header is a uuid" do
      conn = owner("not-a-uuid") |> post(@path, %{url: @url})

      assert %{"code" => "validation_failed", "status" => 422} = json_response(conn, 422)

      assert [error] = conn |> json_response(422) |> Map.fetch!("errors")
      assert error["field"] == "Idempotency-Key"
      assert error["code"] == "invalid_format"
    end

    test "is refused before the endpoint exists, and claims nothing" do
      assert owner(String.duplicate("a", 5000)) |> post(@path, %{url: @url}) |> json_response(422)

      assert endpoint_count() == 0
      assert claims() == 0
    end

    test "a header sent twice is treated as no header at all" do
      # There is no rule saying which of two values wins, and picking the first
      # would make the answer depend on a proxy's mood. So it is not a key.
      #
      # `put_req_header/3` *replaces*, so a duplicate cannot be built with it;
      # `prepend_req_headers/2` can, which is what a proxy that appends its own
      # header actually produces.
      conn =
        owner()
        |> prepend_req_headers([
          {KeyPlug.key_header(), @key},
          {KeyPlug.key_header(), @other_key}
        ])
        |> post(@path, %{url: @url})

      assert KeyPlug.present(conn) == nil
      assert json_response(conn, 201)
      assert claims() == 0
    end
  end

  describe "a retry with the same key and the same body" do
    test "returns the first response, byte for byte" do
      first = owner(@key) |> post(@path, %{url: @url}) |> json_response(201)
      second = owner(@key) |> post(@path, %{url: @url}) |> json_response(201)

      # Including the signing secret. It is the one field that exists in exactly
      # one response and cannot be produced twice, so a replay that re-derived it
      # rather than replaying it would hand out a secret the row never had.
      assert first["data"]["secret"] == second["data"]["secret"]
      assert first == second
    end

    test "creates ONE endpoint, which is the entire point" do
      owner(@key) |> post(@path, %{url: @url}) |> json_response(201)
      owner(@key) |> post(@path, %{url: @url}) |> json_response(201)

      assert endpoint_count() == 1
    end

    test "says so, with Idempotency-Replayed: true, on the second response only" do
      first = owner(@key) |> post(@path, %{url: @url})
      second = owner(@key) |> post(@path, %{url: @url})

      assert get_resp_header(first, KeyPlug.replayed_header()) == []
      assert get_resp_header(second, KeyPlug.replayed_header()) == ["true"]
    end

    test "the replayed response is problem-shaped in no way: it is the 201 itself" do
      owner(@key) |> post(@path, %{url: @url})
      replayed = owner(@key) |> post(@path, %{url: @url})

      assert json_response(replayed, 201)
      assert response_content_type(replayed, :json)
    end

    test "a ping retried with one key sends nothing the second time" do
      endpoint = an_endpoint()
      path = "/v1/webhook_endpoints/#{endpoint.id}/test"

      first = owner(@key) |> post(path) |> json_response(200)
      assert RecordingSender.last() != nil, "the first ping should have been sent"

      RecordingSender.reset()
      second_conn = owner(@key) |> post(path)
      second = json_response(second_conn, 200)

      assert get_resp_header(second_conn, KeyPlug.replayed_header()) == ["true"]
      assert first == second

      assert RecordingSender.last() == nil,
             "the replay sent a webhook: a retried ping has to reach the " <>
               "customer's endpoint once, not twice"
    end
  end

  describe "the same key with a different body" do
    test "is a 409 idempotency_key_reused, and nothing is created" do
      owner(@key) |> post(@path, %{url: @url}) |> json_response(201)

      reused = owner(@key) |> post(@path, %{url: "https://hooks.example.com/other"})

      assert %{
               "code" => "idempotency_key_reused",
               "status" => 409,
               "type" => "https://errors.cafaye.com/idempotency_key_reused"
             } = json_response(reused, 409)

      assert endpoint_count() == 1
    end

    test "the envelope is core's: code is the last segment of type, and trace_id is present" do
      owner(@key) |> post(@path, %{url: @url}) |> json_response(201)

      body =
        owner(@key)
        |> post(@path, %{url: "https://hooks.example.com/other"})
        |> json_response(409)

      assert body["type"] |> String.split("/") |> List.last() == body["code"]
      assert is_binary(body["trace_id"])
    end
  end

  describe "a request that did not succeed" do
    test "leaves no row, so the same key can be used again" do
      # A stored 4xx would pin the caller's own mistake for 24 hours: they fix the
      # url, retry with the same key, and get a 409 about a key they never reused.
      assert owner(@key) |> post(@path, %{url: "not-a-url"}) |> json_response(422)
      assert claims() == 0

      assert owner(@key) |> post(@path, %{url: @url}) |> json_response(201)
      assert endpoint_count() == 1
    end

    test "and the fixed retry is not a replay" do
      owner(@key) |> post(@path, %{url: "not-a-url"}) |> json_response(422)
      retried = owner(@key) |> post(@path, %{url: @url})

      assert get_resp_header(retried, KeyPlug.replayed_header()) == []
    end
  end

  describe "the scope of a key" do
    test "the same key under another account is a different key" do
      # core: "The same key on a different endpoint or principal is a different
      # key." Two tenants choosing the same uuid must both get their endpoint.
      assert owner(@key) |> post(@path, %{url: @url}) |> json_response(201)
      assert other(@key) |> post(@path, %{url: @url}) |> json_response(201)

      # COUNTED PER ACCOUNT, and that is the whole point of this assertion now.
      # A whole-table `Repo.aggregate(..., :count)` is a claim about every other
      # test in the repository as much as about this one (AGENTS.md, on
      # `tenancy.yml`'s own entry points), and it is now also a claim about the
      # RLS `select` policy: this test body runs with the file's identity, so a
      # whole-table count reads **one** row and the assertion fails with
      #
      #     left:  1
      #     right: 2
      #
      # on a test whose two requests both did the right thing. Two rows, each
      # counted in its own account, is the claim this test is actually about --
      # and it is the shape that cannot be satisfied by a boundary that refuses
      # one account to see the other, since neither count can be inflated by
      # reading across.
      assert endpoints_for(@account) == 1
      assert endpoints_for(@other_account) == 1

      # The same, for the key claims: two accounts, two rows, counted each in its
      # own account.
      assert claims_for(@account) == 1
      assert claims_for(@other_account) == 1
    end

    test "the same key on another endpoint is a different key" do
      endpoint = an_endpoint()

      # `@other_url`, not `@url`: `an_endpoint/0` already took `@url`, and a
      # duplicate url is a 422 for a reason that has nothing to do with this.
      assert owner(@key) |> post(@path, %{url: @other_url}) |> json_response(201)

      assert owner(@key)
             |> post("/v1/webhook_endpoints/#{endpoint.id}/test")
             |> json_response(200)
    end
  end

  describe "a key whose first request is still running" do
    test "is a 409 conflict, which core's reserved list also puts at 409" do
      # Not `idempotency_key_reused`: the bodies are identical, and telling a
      # client its key was reused with a different body when it was not is the
      # kind of lie a retry loop is built on. `conflict` is core's word for a
      # request that collides with current state, and the detail says to retry.
      seed_in_flight()

      conn = owner(@key) |> post(@path, %{url: @url})

      assert %{"code" => "conflict", "status" => 409, "detail" => detail} =
               json_response(conn, 409)

      assert detail =~ "Idempotency-Key"
      assert endpoint_count() == 0
    end

    # A row in the state a genuinely concurrent request would leave behind, rather
    # than two real requests racing: a race needs a scheduler to lose, and a test
    # that depends on winning one is a flaky test wearing a correctness hat. The
    # state is the same state the plug reads, so what is under test is the plug's
    # reading of it.
    defp seed_in_flight do
      assert {:ok, _row} =
               Idempotency.claim(%{
                 account_id: @account,
                 endpoint: @path,
                 idempotency_key: @key,
                 request_hash: "z" <> String.duplicate("0", 63)
               })
    end
  end

  describe "request_hash/1" do
    test "two bodies differing only in key order are the same request" do
      # Otherwise a client that reformats its JSON between a call and its retry
      # gets a 409 it did nothing to cause.
      assert KeyPlug.request_hash(body_conn(%{"a" => 1, "b" => 2})) ==
               KeyPlug.request_hash(body_conn(%{"b" => 2, "a" => 1}))
    end

    test "two bodies that mean different things are different requests" do
      assert KeyPlug.request_hash(body_conn(%{"url" => "a"})) !=
               KeyPlug.request_hash(body_conn(%{"url" => "b"}))
    end

    test "a nested value is part of the hash" do
      assert KeyPlug.request_hash(body_conn(%{"a" => [%{"b" => 1}]})) !=
               KeyPlug.request_hash(body_conn(%{"a" => [%{"b" => 2}]}))
    end

    test "an empty body hashes, rather than crashing" do
      # `POST /v1/webhook_endpoints/{id}/test` sends no body at all, so the
      # unfetched case is the one the ping path actually takes. Both conns are on
      # the same path, so the only thing that can differ is the body.
      no_body = Plug.Test.conn(:post, @path)
      empty_body = body_conn(%{})

      assert is_binary(KeyPlug.request_hash(no_body))
      assert KeyPlug.request_hash(no_body) == KeyPlug.request_hash(empty_body)
    end

    test "the path is part of the hash" do
      assert KeyPlug.request_hash(Plug.Test.conn(:post, "/a", %{})) !=
               KeyPlug.request_hash(Plug.Test.conn(:post, "/b", %{}))
    end

    defp body_conn(params), do: Plug.Test.conn(:post, "/v1/webhook_endpoints", params)
  end
end
