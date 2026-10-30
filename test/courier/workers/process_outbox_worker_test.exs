defmodule Courier.Workers.ProcessOutboxWorkerTest do
  @moduledoc """
  The relay is courier's only consumer of its own database: it claims unpublished
  rows in a batch, hands each to the publisher, and marks what it published.
  Delivery here is at-least-once, so what matters is that a row is never marked
  without being published and never published without being claimed — not that
  it is published exactly once.

  Nothing sleeps. Jobs are performed in-process with `perform_job/3`
  (Oban.Testing), so the row is marked before the assertion reads it.

  The two cases that change configuration — a one-row batch, and a publisher
  that fails — live in `Courier.Workers.ProcessOutboxWorkerConfigTest`, because
  application env is VM-global and this file is `async: true`.
  """

  use Courier.DataCase, async: true

  use Oban.Testing, repo: Courier.Repo

  alias Courier.Deliver
  alias Courier.OutboxEvent
  alias Courier.Workers.ProcessOutboxWorker

  @backoff_cap 60

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp payload(url) do
    %{
      user_id: @user_id,
      email: "kaka@example.com",
      name: "Kaka",
      url: url
    }
  end

  defp undelivered, do: Repo.all(OutboxEvent) |> Enum.reject(& &1.published_at)

  defp deliver!(url) do
    {:ok, result} = Deliver.welcome(payload(url))
    Repo.get!(OutboxEvent, result.event_id)
  end

  describe "perform/1" do
    test "publishes an undelivered event" do
      row = deliver!("https://anywaye.com/verify?token=abc123")

      assert {:ok, _result} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, published}
      assert published["type"] == "courier.email.delivered"
      assert published["id"] == row.id
    end

    test "publishes the envelope exactly as it was recorded" do
      row = deliver!("https://anywaye.com/verify?token=abc123")

      {:ok, _result} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, published}
      assert published == OutboxEvent.envelope(row)
    end

    test "marks the row published only after publishing it" do
      row = deliver!("https://anywaye.com/verify?token=abc123")

      {:ok, _result} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, _envelope}
      reloaded = Repo.get!(OutboxEvent, row.id)
      assert reloaded.published_at
      assert reloaded.attempt_count == 0
      assert reloaded.last_error == nil
    end

    test "publishes nothing when there is nothing to publish" do
      assert {:ok, result} = perform_job(ProcessOutboxWorker, %{})
      assert result == %{published: 0}

      refute_received {:nats_published, _envelope}
    end

    test "an already published row is not republished" do
      row = deliver!("https://anywaye.com/verify?token=abc123")
      {:ok, _result} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, _published}

      assert {:ok, %{published: 0}} = perform_job(ProcessOutboxWorker, %{})

      refute_received {:nats_published, _envelope}
      assert Repo.get!(OutboxEvent, row.id).published_at
    end

    test "a second run does not move the published_at stamp" do
      row = deliver!("https://anywaye.com/verify?token=abc123")
      {:ok, _result} = perform_job(ProcessOutboxWorker, %{})
      first_published_at = Repo.get!(OutboxEvent, row.id).published_at

      {:ok, _result} = perform_job(ProcessOutboxWorker, %{})

      assert Repo.get!(OutboxEvent, row.id).published_at == first_published_at
    end

    test "publishes a whole batch in one run" do
      for index <- 1..3, do: deliver!("https://anywaye.com/verify?token=#{index}")

      assert {:ok, %{published: 3}} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, _first}
      assert_received {:nats_published, _second}
      assert_received {:nats_published, _third}
      assert undelivered() == []
    end

    test "publishes oldest first, so subscribers see sends in the order they happened" do
      rows = for index <- 1..3, do: deliver!("https://anywaye.com/verify?token=#{index}")

      for {row, minutes} <- Enum.zip(rows, [3, 2, 1]) do
        row
        |> Ecto.Changeset.change(occurred_at: DateTime.add(DateTime.utc_now(), -minutes * 60))
        |> Repo.update!()
      end

      assert {:ok, %{published: 3}} = perform_job(ProcessOutboxWorker, %{})

      published =
        for _index <- 1..3 do
          assert_received {:nats_published, envelope}
          envelope["id"]
        end

      assert published == Enum.map(rows, & &1.id)
    end

    test "a row that has exhausted its attempts is not claimed again" do
      row = deliver!("https://anywaye.com/verify?token=abc123")

      row
      |> Ecto.Changeset.change(attempt_count: max_attempts())
      |> Repo.update!()

      assert {:ok, %{published: 0}} = perform_job(ProcessOutboxWorker, %{})

      refute_received {:nats_published, _envelope}
      assert Repo.get!(OutboxEvent, row.id).published_at == nil
    end

    test "a row with attempts left is still claimed" do
      row = deliver!("https://anywaye.com/verify?token=abc123")

      row
      |> Ecto.Changeset.change(attempt_count: max_attempts() - 1)
      |> Repo.update!()

      assert {:ok, %{published: 1}} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, _envelope}
    end
  end

  describe "backoff/1" do
    test "grows with the attempt, so a broken NATS is retried less and less often" do
      backoffs = for attempt <- 1..8, do: ProcessOutboxWorker.backoff(%Oban.Job{attempt: attempt})

      assert backoffs == Enum.sort(backoffs)
    end

    test "never waits longer than the cap" do
      for attempt <- 1..20 do
        assert ProcessOutboxWorker.backoff(%Oban.Job{attempt: attempt}) <= @backoff_cap
      end
    end

    test "never waits zero seconds, which would be a hot loop" do
      for attempt <- 1..20 do
        assert ProcessOutboxWorker.backoff(%Oban.Job{attempt: attempt}) > 0
      end
    end

    test "jitters, so two relays recovering at once do not retry in lockstep" do
      waits = for _attempt <- 1..50, do: ProcessOutboxWorker.backoff(%Oban.Job{attempt: 5})

      assert length(Enum.uniq(waits)) > 1
    end
  end

  describe "job options" do
    test "runs on the outbox queue the application configures" do
      assert ProcessOutboxWorker.__opts__()[:queue] == :outbox
    end

    test "gives up after the configured number of attempts" do
      assert ProcessOutboxWorker.__opts__()[:max_attempts] == max_attempts()
    end
  end

  defp max_attempts, do: Application.get_env(:courier, :outbox, [])[:max_attempts]
end
