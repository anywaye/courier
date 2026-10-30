defmodule Courier.Workers.ProcessOutboxWorkerConfigTest do
  @moduledoc """
  The relay's two configurable behaviours: how many rows it claims per run, and
  what it does when the publisher refuses.

  A refusal is reported as `{:error, summary}`, where the summary carries
  `published`, `failed`, and the first `reason` the publisher gave — Oban retries
  the job because of the error tuple, and the reason is what makes the retry
  readable in the job's own error rather than a bare atom with no count
  attached.

  `async: false` because both cases change application env, which the whole VM
  shares: while this module holds a one-row batch or a failing publisher, an
  async relay test would run against them instead of the real configuration.
  `on_exit` restores both before the next test starts.
  """

  use Courier.DataCase, async: false

  use Oban.Testing, repo: Courier.Repo

  alias Courier.Deliver
  alias Courier.OutboxEvent
  alias Courier.Workers.ProcessOutboxWorker

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  setup do
    original_outbox = Application.get_env(:courier, :outbox, [])
    original_publisher = Application.get_env(:courier, :nats_publisher)

    on_exit(fn ->
      Application.put_env(:courier, :outbox, original_outbox)
      Application.put_env(:courier, :nats_publisher, original_publisher)
    end)

    :ok
  end

  defp deliver!(index) do
    {:ok, result} =
      Deliver.welcome(%{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        url: "https://anywaye.com/verify?token=#{index}"
      })

    Repo.get!(OutboxEvent, result.event_id)
  end

  defp undelivered, do: Repo.all(OutboxEvent) |> Enum.reject(& &1.published_at)

  describe "batch size" do
    test "claims at most one batch per run" do
      for index <- 1..3, do: deliver!(index)

      Application.put_env(:courier, :outbox, outbox_config(batch_size: 2))

      assert {:ok, %{published: 2}} = perform_job(ProcessOutboxWorker, %{})

      assert length(undelivered()) == 1
      assert_received {:nats_published, _first}
      assert_received {:nats_published, _second}
      refute_received {:nats_published, _third}
    end

    test "the rows left over are skipped, not dropped: the next run picks them up" do
      for index <- 1..3, do: deliver!(index)

      Application.put_env(:courier, :outbox, outbox_config(batch_size: 2))
      {:ok, _result} = perform_job(ProcessOutboxWorker, %{})

      assert {:ok, %{published: 1}} = perform_job(ProcessOutboxWorker, %{})

      assert undelivered() == []
    end

    test "one batch of everything, when the batch is big enough" do
      for index <- 1..3, do: deliver!(index)

      Application.put_env(:courier, :outbox, outbox_config(batch_size: 50))

      assert {:ok, %{published: 3}} = perform_job(ProcessOutboxWorker, %{})

      assert undelivered() == []
    end
  end

  describe "a publisher that refuses" do
    setup do
      Application.put_env(:courier, :nats_publisher, Courier.TestSupport.RefusingPublisher)
      :ok
    end

    test "the job reports the error so Oban retries it with backoff" do
      deliver!(1)

      assert {:error, summary} = perform_job(ProcessOutboxWorker, %{})

      assert summary.failed == 1
    end

    test "the row is not marked published" do
      row = deliver!(1)

      assert {:error, %{reason: :nats_unavailable}} = perform_job(ProcessOutboxWorker, %{})

      assert Repo.get!(OutboxEvent, row.id).published_at == nil
    end

    test "the row remembers how many times it has failed and why" do
      row = deliver!(1)

      assert {:error, _summary} = perform_job(ProcessOutboxWorker, %{})

      reloaded = Repo.get!(OutboxEvent, row.id)
      assert reloaded.attempt_count == 1
      assert reloaded.last_error == "nats_unavailable"
    end

    test "one refused row does not hold up the rows behind it" do
      Application.put_env(:courier, :nats_publisher, Courier.TestSupport.RefusingPasswordReset)

      welcome = deliver!(1)

      {:ok, _result} =
        Deliver.password_reset(%{
          user_id: @user_id,
          email: "kaka@example.com",
          name: "Kaka",
          url: "https://anywaye.com/reset?token=abc123"
        })

      reset =
        Repo.all(OutboxEvent) |> Enum.find(&(&1.data["notification_type"] == "password_reset"))

      assert {:error, _summary} = perform_job(ProcessOutboxWorker, %{})

      assert_received {:nats_published, published}
      assert published["id"] == welcome.id
      assert Repo.get!(OutboxEvent, welcome.id).published_at

      assert Repo.get!(OutboxEvent, reset.id).published_at == nil
      assert Repo.get!(OutboxEvent, reset.id).attempt_count == 1
    end

    test "a row that has been refused often enough is left alone" do
      row = deliver!(1)

      row
      |> Ecto.Changeset.change(attempt_count: max_attempts() - 1)
      |> Repo.update!()

      assert {:error, _summary} = perform_job(ProcessOutboxWorker, %{})
      assert Repo.get!(OutboxEvent, row.id).attempt_count == max_attempts()

      assert {:ok, %{published: 0}} = perform_job(ProcessOutboxWorker, %{})
      assert Repo.get!(OutboxEvent, row.id).attempt_count == max_attempts()
    end
  end

  defp outbox_config(overrides) do
    Application.get_env(:courier, :outbox, []) |> Keyword.merge(overrides)
  end

  defp max_attempts, do: Application.get_env(:courier, :outbox, [])[:max_attempts]
end
