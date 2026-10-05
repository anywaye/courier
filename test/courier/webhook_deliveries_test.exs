defmodule Courier.WebhookDeliveriesTest do
  @moduledoc """
  The delivery record and the retry budget around it.

  PLAN.md §7 requires bounded budgets: "briefs forbid naive retries; consumers
  use bounded budgets". Everything here is about where the bound is, what the
  wait between attempts is, and what happens when the bound is reached — because
  an unbounded retry loop against a consumer that is gone is a way to keep
  hammering someone who has already asked courier to stop.

  The schedule is asserted as *recorded values*, never by sleeping. Nothing here
  waits for a backoff window to elapse: `backoff/1` is a function of the attempt
  number, and the test reads the number the delivery would have been given.
  """

  use Courier.DataCase, async: true

  alias Courier.WebhookDelivery
  alias Courier.WebhookDeliveries
  alias Courier.WebhookEndpoints

  @account_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The account this file seeds as. The suite runs as `courier_app`, a subject of
  # the row-level-security policies, so a write to a protected table with no
  # identity set is refused `42501` -- see `Courier.DataCase`.
  @moduletag account: @account_id

  defp endpoint! do
    {:ok, endpoint, _secret} =
      WebhookEndpoints.create(%{url: "https://hooks.example.com/events", account_id: @account_id})

    endpoint
  end

  defp config, do: Application.get_env(:courier, :webhooks)

  describe "backoff/1" do
    test "grows with the attempt, so a broken consumer is retried less and less often" do
      waits = for attempt <- 1..6, do: WebhookDeliveries.backoff(attempt)

      assert waits == Enum.sort(waits)
      assert length(Enum.uniq(waits)) == 6
    end

    test "doubles from the configured base" do
      # 300s, 600s, 1200s, 2400s, 4800s, 9600s — the numbers, not a property.
      base = config()[:backoff_base_seconds]

      for attempt <- 1..5 do
        without_jitter = WebhookDeliveries.backoff(attempt, jitter: false)

        assert without_jitter == base * 2 ** (attempt - 1)
      end
    end

    test "never waits longer than the cap" do
      cap = config()[:backoff_cap_seconds]

      for attempt <- 1..30 do
        assert WebhookDeliveries.backoff(attempt) <= cap
      end
    end

    test "reaches the cap and stays there" do
      cap = config()[:backoff_cap_seconds]

      assert WebhookDeliveries.backoff(20) <= cap
      assert WebhookDeliveries.backoff(20) == cap
    end

    test "never waits zero seconds, which would be a hot loop" do
      for attempt <- 1..20 do
        assert WebhookDeliveries.backoff(attempt) > 0
      end
    end

    test "jitters within a quarter of the wait, so a recovered consumer is not hit by every endpoint at once" do
      # The spec §Deliverability asks for "some level of random jitter to retries
      # to prevent cases where the failures are due to recurring load caused by
      # the webhook attempts themselves". A hundred endpoints recovering from one
      # outage would otherwise all retry on the same second.
      base = config()[:backoff_base_seconds]

      waits = for _attempt <- 1..50, do: WebhookDeliveries.backoff(1)

      assert Enum.all?(waits, &(&1 >= base and &1 <= base + div(base, 4)))
      assert length(Enum.uniq(waits)) > 1
    end

    test "the jitter is bounded by the base, so the wait still grows" do
      # Jitter added *on top of* an exponential would let a later attempt wait
      # less than an earlier one, and a consumer under load would then be hit
      # harder the more times courier had already failed to reach it. Bounded by
      # the wait rather than added to it, the ordering holds for every pair.
      waits = for attempt <- 1..8, do: WebhookDeliveries.backoff(attempt)

      assert waits == Enum.sort(waits)
      assert length(Enum.uniq(waits)) == 8
    end

    test "a full budget spans about a day, which is the shape the spec asks for" do
      # §Deliverability recommends "a retry schedule spanning multiple days". This
      # is eight attempts over roughly sixteen hours: the same shape at a scale
      # one service-sized courier can defend, rather than a week of hammering a
      # consumer that has already asked courier to stop.
      total =
        Enum.sum(
          for attempt <- 1..config()[:max_attempts],
              do: WebhookDeliveries.backoff(attempt, jitter: false)
        )

      hours = div(total, 3600)

      assert hours >= 12
      assert hours <= 48
    end
  end

  describe "the attempt budget" do
    test "is bounded, and the bound is configurable" do
      assert config()[:max_attempts] == 8
    end

    test "a delivery with attempts left is still claimable" do
      delivery = WebhookDeliveries.insert!(endpoint!(), event_id(1), attempt: 1)

      assert WebhookDeliveries.claimable?(delivery)
    end

    test "a delivery that has used its budget is not claimable" do
      delivery =
        WebhookDeliveries.insert!(endpoint!(), event_id(1), attempt: config()[:max_attempts])

      refute WebhookDeliveries.claimable?(delivery)
    end

    test "a succeeded delivery is never claimable again" do
      endpoint = endpoint!()
      WebhookDeliveries.insert!(endpoint, event_id(1))

      delivery =
        WebhookDeliveries.succeed!(endpoint, event_id(1), status_code: 200, duration_ms: 12)

      refute WebhookDeliveries.claimable?(delivery)
    end

    test "a delivery waiting on its backoff window is not claimable yet" do
      delivery =
        WebhookDeliveries.insert!(endpoint!(), event_id(1),
          attempt: 1,
          next_attempt_at: future(600)
        )

      refute WebhookDeliveries.claimable?(delivery)
    end

    test "a delivery whose window has passed is claimable again" do
      delivery =
        WebhookDeliveries.insert!(endpoint!(), event_id(1), attempt: 1, next_attempt_at: past(1))

      assert WebhookDeliveries.claimable?(delivery)
    end
  end

  describe "recording an attempt" do
    test "a success records the status code and the duration, and stops there" do
      endpoint = endpoint!()

      WebhookDeliveries.insert!(endpoint, event_id(1))

      delivery =
        WebhookDeliveries.succeed!(endpoint, event_id(1), status_code: 204, duration_ms: 43)

      assert delivery.status == :succeeded
      assert delivery.status_code == 204
      assert delivery.duration_ms == 43
      assert delivery.next_attempt_at == nil
    end

    test "a failure records the status code, the duration, and when to try again" do
      endpoint = endpoint!()

      before = DateTime.utc_now()

      WebhookDeliveries.insert!(endpoint, event_id(1))

      delivery =
        WebhookDeliveries.fail!(endpoint, event_id(1), status_code: 500, duration_ms: 120)

      assert delivery.status == :failed
      assert delivery.status_code == 500
      assert delivery.duration_ms == 120
      assert delivery.next_attempt_at
      assert DateTime.compare(delivery.next_attempt_at, before) in [:gt, :eq]
    end

    test "the second attempt is not scheduled before the first one's backoff has elapsed" do
      # The property the brief asks for, asserted on the recorded value rather
      # than by sleeping through the window: the wait after attempt N is a
      # function of N, and the schedule is non-decreasing, so attempt N+1 cannot
      # be due before attempt N's wait is over.
      endpoint = endpoint!()

      first = WebhookDeliveries.fail!(endpoint, event_id(1), status_code: 500, duration_ms: 10)
      second = WebhookDeliveries.fail!(endpoint, event_id(1), status_code: 500, duration_ms: 10)

      first_wait = DateTime.diff(first.next_attempt_at, first.attempted_at)
      second_wait = DateTime.diff(second.next_attempt_at, second.attempted_at)

      assert first_wait >= config()[:backoff_base_seconds]
      assert second_wait > first_wait
      assert second.attempt == 2
    end

    test "a transport failure with no status code is still recorded" do
      delivery =
        WebhookDeliveries.fail!(endpoint!(), event_id(1), status_code: nil, duration_ms: 15_000)

      assert delivery.status == :failed
      assert delivery.status_code == nil
      assert delivery.duration_ms == 15_000
    end

    test "a delivery that has run out of budget stops scheduling" do
      endpoint = endpoint!()
      WebhookDeliveries.insert!(endpoint, event_id(1))

      # Spend the whole budget, one recorded attempt at a time. The row is
      # exhausted on the last one, which is the assertion: the cap ends the
      # budget rather than letting an attempt past it.
      delivery =
        Enum.reduce(1..config()[:max_attempts], nil, fn _attempt, _last ->
          WebhookDeliveries.fail!(endpoint, event_id(1), status_code: 500, duration_ms: 10)
        end)

      assert delivery.attempt == config()[:max_attempts]
      assert delivery.status == :exhausted
      assert delivery.next_attempt_at == nil
      refute WebhookDeliveries.claimable?(delivery)
    end
  end

  describe "the webhook id" do
    test "is the same on a redelivery, so a consumer can deduplicate on it" do
      # PLAN.md §3: delivery is at-least-once, so every consumer is idempotent.
      # The only thing that makes that possible is an id that does not change
      # between attempts — the spec §Webhook metadata is explicit that it
      # "remains the same no matter how many times a webhook that has failed is
      # retried".
      endpoint = endpoint!()

      first = WebhookDeliveries.insert!(endpoint, event_id(1))
      failed = WebhookDeliveries.fail!(endpoint, event_id(1), status_code: 500, duration_ms: 10)
      retried = WebhookDeliveries.fail!(endpoint, event_id(1), status_code: 500, duration_ms: 10)

      assert first.webhook_id == failed.webhook_id
      assert failed.webhook_id == retried.webhook_id
      assert String.starts_with?(first.webhook_id, "msg_")
    end

    test "is stable across a reload, because it is stored not generated" do
      endpoint = endpoint!()
      delivery = WebhookDeliveries.insert!(endpoint, event_id(1))

      reloaded = Repo.get!(WebhookDelivery, delivery.id)

      assert reloaded.webhook_id == delivery.webhook_id
    end

    test "differs between two endpoints for the same event, so each has its own id" do
      # Two consumers of the same event are two deliveries, and a shared id would
      # make one of them look like a duplicate of the other.
      one = endpoint!()
      other = create_second!()

      assert WebhookDeliveries.insert!(one, event_id(1)).webhook_id !=
               WebhookDeliveries.insert!(other, event_id(1)).webhook_id
    end

    test "differs between two events for the same endpoint" do
      endpoint = endpoint!()

      assert WebhookDeliveries.insert!(endpoint, event_id(1)).webhook_id !=
               WebhookDeliveries.insert!(endpoint, event_id(2)).webhook_id
    end

    test "contains no full stop, so it cannot forge a base string" do
      delivery = WebhookDeliveries.insert!(endpoint!(), event_id(1))

      refute delivery.webhook_id =~ "."
    end

    test "is unique per endpoint and event, enforced by the database" do
      endpoint = endpoint!()
      WebhookDeliveries.insert!(endpoint, event_id(1))

      # Straight SQL, because `insert!/3` deliberately absorbs this violation —
      # it is the fan-out's idempotency. Proving the constraint exists means
      # bypassing the code that hides it.
      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.query(
                 "INSERT INTO webhook_deliveries (id, endpoint_id, event_id, webhook_id, status, attempt, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, $3::uuid, 'msg_x', 'pending', 0, now(), now())",
                 [
                   Ecto.UUID.dump!(Ecto.UUID.generate()),
                   Ecto.UUID.dump!(endpoint.id),
                   Ecto.UUID.dump!(event_id(1))
                 ]
               )
    end

    test "insert!/3 is idempotent, so a re-dispatched event does not duplicate a delivery" do
      endpoint = endpoint!()

      first = WebhookDeliveries.insert!(endpoint, event_id(1))
      second = WebhookDeliveries.insert!(endpoint, event_id(1))

      assert first.id == second.id
      assert second.webhook_id == first.webhook_id
      assert Repo.aggregate(WebhookDelivery, :count) == 1
    end
  end

  describe "the delivery row" do
    test "is removed with its endpoint, rather than left pointing at nothing" do
      endpoint = endpoint!()
      delivery = WebhookDeliveries.insert!(endpoint, event_id(1))

      {:ok, _} = WebhookEndpoints.delete(endpoint)

      assert Repo.get(WebhookDelivery, delivery.id) == nil
    end

    test "counts attempts from one, not from zero" do
      # Attempt 0 is a row that has not been tried. A delivery that exists has been
      # tried at least once, and an off-by-one here makes the first attempt look
      # like a retry.
      assert WebhookDeliveries.insert!(endpoint!(), event_id(1)).attempt == 0

      endpoint = create_second!()

      assert WebhookDeliveries.fail!(endpoint, event_id(2), status_code: 500, duration_ms: 1).attempt ==
               1
    end
  end

  defp create_second! do
    {:ok, endpoint, _secret} =
      WebhookEndpoints.create(%{
        url: "https://second.example.com/events",
        account_id: @account_id
      })

    endpoint
  end

  # Two distinct, fixed uuids. Written out rather than generated so a failure
  # names the same event every time it happens.
  defp event_id(1), do: "11111111-1111-1111-1111-111111111111"
  defp event_id(2), do: "22222222-2222-2222-2222-222222222222"

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp past(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
end
