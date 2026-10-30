defmodule Courier.IdempotencyTest do
  @moduledoc """
  The arithmetic behind `Idempotency-Key`, tested without a plug pipeline.

  The half that is easy to get quietly wrong is not the replay — it is the three
  ways a claim can be *refused*, and the expiry, because each of them is the
  difference between "a retry is free" and "a retry is a duplicate". Every
  refusal below is therefore a test of its own rather than a branch inside a
  larger test, and the one that matters most is the last: a key the caller has
  not used for a day has to behave as though it had never been used, with no
  sweeper job to make that true.
  """

  use Courier.DataCase, async: true

  alias Courier.Idempotency
  alias Courier.IdempotencyKey

  @account "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @other_account "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"
  @key "11111111-1111-1111-1111-111111111111"
  @other_key "22222222-2222-2222-2222-222222222222"
  @endpoint "/v1/webhook_endpoints"
  @other_endpoint "/v1/webhook_endpoints/8f3c2b1a-0000-4000-8000-000000000001/test"

  @moduletag account: @account

  defp claim_key(overrides \\ %{}) do
    attrs =
      Enum.into(overrides, %{
        account_id: @account,
        endpoint: @endpoint,
        idempotency_key: @key,
        request_hash: "a" <> String.duplicate("0", 63)
      })

    Idempotency.claim(attrs)
  end

  describe "claiming a key" do
    test "succeeds, and the row says the request is in flight" do
      assert {:ok, claim} = claim_key()
      assert claim.state == :in_flight
      assert claim.response_status == nil
      assert claim.response_body == nil
    end

    test "stores the claim against the (account, endpoint, key) triple core names" do
      assert {:ok, claim} = claim_key()
      assert claim.account_id == @account
      assert claim.endpoint == @endpoint
      assert claim.idempotency_key == @key
    end

    test "expires the claim 24 hours out, which is core's retention" do
      before = DateTime.utc_now()
      assert {:ok, claim} = claim_key()
      after_call = DateTime.utc_now()

      assert DateTime.diff(claim.expires_at, before) >= 86_400
      assert DateTime.diff(claim.expires_at, after_call) <= 86_400
    end

    test "a second claim on the same triple is refused as :taken" do
      assert {:ok, _claim} = claim_key()
      assert {:error, :taken} = claim_key()
    end

    test "the same key under another account is a different key" do
      assert {:ok, _claim} = claim_key()

      assert {:ok, _other} =
               as_account(@other_account, fn -> claim_key(%{account_id: @other_account}) end)
    end

    test "the same key on another endpoint is a different key" do
      assert {:ok, _claim} = claim_key()
      assert {:ok, _other} = claim_key(%{endpoint: @other_endpoint})
    end

    test "another key on the same triple is a different key" do
      assert {:ok, _claim} = claim_key()
      assert {:ok, _other} = claim_key(%{idempotency_key: @other_key})
    end
  end

  describe "reading a claim back" do
    test "finds a claim that is inside its window" do
      assert {:ok, claim} = claim_key()
      assert %IdempotencyKey{} = found = Idempotency.fetch(@account, @endpoint, @key)
      assert found.id == claim.id
    end

    test "is nil for a triple nobody has claimed" do
      assert Idempotency.fetch(@account, @endpoint, @key) == nil
    end

    test "is nil once the claim has expired" do
      expired = DateTime.add(DateTime.utc_now(), -60, :second)
      assert {:ok, _claim} = claim_key(%{expires_at: expired})
      assert Idempotency.fetch(@account, @endpoint, @key) == nil
    end

    test "is nil for another account's claim, because the scope includes the principal" do
      assert {:ok, _claim} = claim_key()

      assert as_account(@other_account, fn ->
               Idempotency.fetch(@other_account, @endpoint, @key)
             end) == nil
    end
  end

  describe "retention" do
    test "an expired claim is discarded, so a day-old key behaves as a new one" do
      expired = DateTime.add(DateTime.utc_now(), -60, :second)
      assert {:ok, first} = claim_key(%{expires_at: expired})

      assert {:ok, second} = claim_key()
      claimed_id = second.id
      assert second.id != first.id

      assert Repo.aggregate(IdempotencyKey, :count) == 1
      assert %IdempotencyKey{id: ^claimed_id} = Idempotency.fetch(@account, @endpoint, @key)
    end

    test "an unexpired claim is NOT discarded by another claim of the same triple" do
      assert {:ok, _first} = claim_key()
      assert {:error, :taken} = claim_key()
      assert Repo.aggregate(IdempotencyKey, :count) == 1
    end

    test "purge_expired/0 removes expired claims and keeps live ones" do
      expired = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:ok, _gone} = claim_key(%{idempotency_key: @key, expires_at: expired})
      assert {:ok, _kept} = claim_key(%{idempotency_key: @other_key})

      assert {1, nil} = Idempotency.purge_expired()
      assert [%IdempotencyKey{idempotency_key: @other_key}] = Repo.all(IdempotencyKey)
    end
  end

  describe "completing a claim" do
    test "stores the response verbatim and flips the state" do
      assert {:ok, claim} = claim_key()
      body = Jason.encode!(%{data: %{secret: "whsec_" <> String.duplicate("a", 43)}})

      assert {:ok, completed} =
               Idempotency.complete(claim.id, 201, body, "application/json; charset=utf-8")

      assert completed.state == :completed
      assert completed.response_status == 201
      assert completed.response_body == body
      assert completed.response_content_type == "application/json; charset=utf-8"
    end

    test "the stored response is what fetch/3 hands back, replays included" do
      assert {:ok, claim} = claim_key()
      {:ok, _completed} = Idempotency.complete(claim.id, 201, "{}", "application/json")

      assert %IdempotencyKey{state: :completed, response_body: "{}"} =
               Idempotency.fetch(@account, @endpoint, @key)
    end
  end

  describe "releasing a claim" do
    test "frees the key immediately rather than at the end of the window" do
      assert {:ok, claim} = claim_key()
      assert {1, nil} = Idempotency.release(claim.id)
      assert Idempotency.fetch(@account, @endpoint, @key) == nil
      assert {:ok, _reclaimed} = claim_key()
    end
  end

  describe "valid_key?/1" do
    test "accepts a uuid, which is what core says the header is" do
      assert Idempotency.valid_key?(@key)
      assert Idempotency.valid_key?(Ecto.UUID.generate())
    end

    test "refuses a non-uuid" do
      refute Idempotency.valid_key?("not-a-uuid")
      refute Idempotency.valid_key?("")
      refute Idempotency.valid_key?(String.duplicate("a", 5000))
    end

    test "refuses anything that is not a binary at all" do
      refute Idempotency.valid_key?(nil)
      refute Idempotency.valid_key?(%{})
      refute Idempotency.valid_key?(:not_a_key)
      refute Idempotency.valid_key?(12_345)
    end
  end
end
