defmodule Courier.OutboxEnqueueTest do
  @moduledoc """
  WHO PUTS A JOB IN courier's QUEUE — which is not the question any other file in
  this suite asks.

  `Courier.Workers.ProcessOutboxWorkerTest` drives `perform/1` and asserts the
  publish, and 1301 green tests did that without ever noticing that nothing ever
  called the worker: `Oban.insert` appeared zero times in `lib/`, there was no
  cron plugin, and the supervision tree started Oban and left it empty. **A test
  that drives the consumer is not a test that the consumer runs.** The gap is one
  layer out from the relay, so this file asserts on the queue instead: after a
  real `Courier.Deliver`, what does `oban_jobs` hold, and what happens when the
  job the queue holds is run?

  Two triggers, and both are here:

    * **the fast path** — the write enqueues the relay, inside the transaction
      that wrote the row, so the window in which a committed row has nothing
      waiting to publish it is empty rather than small.
    * **the floor** — `config/config.exs`'s crontab, because a delivery becomes
      due by the clock and because a row written by any path that did not go
      through `Courier.Outbox` would otherwise be stranded forever.

  ## What the sweep half can and cannot prove, and why it starts the plugin

  `config/test.exs` sets `testing: :manual`, and under that Oban starts **no
  plugins at all** (`deps/oban/lib/oban/config.ex:108`), so the crontab cannot
  execute inside the suite. Rather than assert that a crontab is *configured* —
  which is a comment with a test's name on it — the sweep test starts
  `Oban.Cron` itself with courier's own crontab out of application env, tells it
  to evaluate, and reads what it inserted. That is Oban's real insertion path
  (`Oban.Cron.handle_info(:evaluate, …)` → `insert_scheduled_jobs/1`), not a
  hand-built job shaped like one, and the plugin is handed the sandbox connection
  so what it writes is what this test reads.

  Nothing sleeps. The plugin is driven by a `send/2` and waited on with
  `:sys.get_state/1`, which is a barrier and not a poll: the `:evaluate` message
  is ahead of the system message in the same mailbox.

  `async: true` — nothing here changes application env. The case that needs a
  refusing mail adapter to make the transaction unwind is in
  `Courier.OutboxEnqueueConfigTest`, which owns that swap for the whole VM.
  """

  use Courier.DataCase, async: true

  use Oban.Testing, repo: Courier.Repo

  alias Courier.Deliver
  alias Courier.Outbox
  alias Courier.OutboxEvent
  alias Courier.Workers.DeliverWebhookWorker
  alias Courier.Workers.DispatchWebhooksWorker
  alias Courier.Workers.ProcessOutboxWorker

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # The Oban instance the sweep's plugin runs under, which is not the suite's.
  # See `start_cron!/0`.
  @cron_instance Courier.OutboxEnqueueTest.Cron

  describe "the send path" do
    test "leaves a job in the queue, and the job's args name the row" do
      assert {:ok, %{event_id: event_id}} = deliver!("https://anywaye.com/verify?token=abc123")

      assert [job] = all_enqueued(worker: ProcessOutboxWorker)

      assert job.worker == "Courier.Workers.ProcessOutboxWorker"
      assert job.queue == to_string(ProcessOutboxWorker.__opts__()[:queue])
      assert job.args == %{"event_id" => event_id}
      assert job.state == "available"
    end

    test "two sends queue two jobs, and one run of the loop publishes both rows" do
      # The uniqueness key is the EVENT, not the worker. A key of `fields:
      # [:worker]` would queue one job and strand the second send until the next
      # sweep, which is the failure this file exists to rule out wearing the
      # costume of an optimization.
      assert {:ok, %{event_id: first}} = deliver!("https://anywaye.com/verify?token=abc123")
      assert {:ok, %{event_id: second}} = deliver!("https://anywaye.com/verify?token=def456")

      assert [job_one, job_two] = all_enqueued(worker: ProcessOutboxWorker)

      assert Enum.sort([job_one.args["event_id"], job_two.args["event_id"]]) ==
               Enum.sort([first, second])

      # **And the two jobs are not two units of work.** The relay claims a BATCH
      # from the table, which is core's loop, so the first run takes both rows and
      # the second finds nothing. The job is a trigger; the table is the work. A
      # test that asserted `published: 1` per job would be asserting that courier
      # does not implement the spec it cites.
      assert {:ok, %{published: 2}} = perform_queued(job_one)
      assert {:ok, %{published: 0}} = perform_queued(job_two)

      for event_id <- [first, second] do
        assert Repo.get!(OutboxEvent, event_id).published_at
      end
    end

    test "running the job the queue holds publishes the row it names" do
      assert {:ok, %{event_id: event_id}} = deliver!("https://anywaye.com/verify?token=abc123")

      assert [job] = all_enqueued(worker: ProcessOutboxWorker)
      assert {:ok, %{published: 1}} = perform_queued(job)

      assert_received {:nats_published, envelope}
      assert envelope["id"] == event_id
      assert Repo.get!(OutboxEvent, event_id).published_at
    end

    test "the row is not published before the job runs" do
      assert {:ok, %{event_id: event_id}} = deliver!("https://anywaye.com/verify?token=abc123")

      assert Repo.get!(OutboxEvent, event_id).published_at == nil
      refute_received {:nats_published, _envelope}
    end

    test "the job does not publish the row twice" do
      # The outbox's moduledoc promises consumers "the same `id`, so a consumer
      # that already saw it ignores the duplicate", and that promise is a claim
      # about the LOOP: at-least-once means a second pass is ordinary operation,
      # and the second pass must publish nothing.
      assert {:ok, %{event_id: event_id}} = deliver!("https://anywaye.com/verify?token=abc123")

      assert [job] = all_enqueued(worker: ProcessOutboxWorker)
      assert {:ok, %{published: 1}} = perform_queued(job)
      assert_received {:nats_published, first}
      stamped = Repo.get!(OutboxEvent, event_id).published_at

      assert {:ok, %{published: 0}} = perform_queued(job)

      refute_received {:nats_published, _second}
      assert Repo.get!(OutboxEvent, event_id).published_at == stamped
      assert first["id"] == event_id
    end
  end

  describe "the same event kicked twice" do
    test "neither later kick enqueues anything" do
      assert {:ok, %{event_id: event_id}} = deliver!("https://anywaye.com/verify?token=abc123")

      # The write already queued one, so both of these are the answer to "there is
      # already a relay waiting for this event". It is not an error: a kick that
      # finds the event already queued is the invariant holding, and a kick that
      # turned that into a failure would fail the SEND it was written next to.
      assert {:ok, %{conflict?: true}} = Outbox.enqueue_relay(event_id)
      assert {:ok, %{conflict?: true}} = Outbox.enqueue_relay(event_id)

      assert 1 == length(all_enqueued(worker: ProcessOutboxWorker))
    end

    test "and the event can be kicked again once its job has run" do
      # `states: :incomplete` rather than the default: the constraint is "no
      # PENDING job for this event", so a published event can be re-announced.
      # A key that outlived its job would make the sweep the only way back, which
      # is the coupling this attribute exists to avoid.
      assert {:ok, %{event_id: event_id}} = deliver!("https://anywaye.com/verify?token=abc123")

      assert [job] = all_enqueued(worker: ProcessOutboxWorker)
      assert {:ok, %{published: 1}} = perform_queued(job)

      # The job is executed in-process, so it is never deleted from `oban_jobs` the
      # way the queue would delete it; the row's state is what the constraint
      # reads, so clear it the way the queue's `jobs: :delete` leaves it.
      assert {1, nil} = Repo.delete_all(Oban.Job)

      assert {:ok, %{conflict?: false}} = Outbox.enqueue_relay(event_id)
      assert 1 == length(all_enqueued(worker: ProcessOutboxWorker))
    end
  end

  describe "the floor: the crontab's own job" do
    test "publishes a row that nothing enqueued" do
      # The row courier cannot strand: written with a plain `Repo.insert/1`, with
      # no `Courier.Outbox` in sight, which is what a repair, a restore or a
      # future call site looks like.
      row = insert_row_directly!()

      assert all_enqueued(worker: ProcessOutboxWorker) == []

      cron = start_cron!()
      send(cron, :evaluate)
      _barrier = :sys.get_state(cron)

      assert [job] = all_enqueued(worker: ProcessOutboxWorker)
      assert job.meta["cron"] == true
      assert job.meta["cron_expr"] == expr_for(ProcessOutboxWorker)

      assert {:ok, %{published: 1}} = perform_queued(job)

      assert Repo.get!(OutboxEvent, row.id).published_at
      assert_received {:nats_published, envelope}
      assert envelope["id"] == row.id
    end

    test "the crontab itself names every worker nothing enqueues" do
      scheduled = Enum.map(crontab(), &elem(&1, 1))

      # All three, and each for its own reason, which the configuration comment
      # in `config/config.exs` gives. `DeliverWebhookWorker` is the one that
      # cannot be enqueued at all: a delivery becomes due by the clock.
      assert ProcessOutboxWorker in scheduled
      assert DispatchWebhooksWorker in scheduled
      assert DeliverWebhookWorker in scheduled
    end

    test "every entry is a schedule Oban parses and a worker courier ships" do
      for {expr, worker} <- crontab() do
        assert {:ok, _expression} = Oban.Cron.parse(expr)
        assert Code.ensure_loaded?(worker), "#{inspect(worker)} does not exist"
        assert function_exported?(worker, :perform, 1), "#{inspect(worker)} is not an Oban worker"
      end
    end

    test "the plugin survives into the effective configuration outside the suite" do
      # `testing: :manual` strips plugins, so inside the suite the crontab is
      # inert BY CONSTRUCTION and every assertion above about it is about the
      # declaration. This is the one that says the declaration reaches a running
      # Oban: the same application env, testing off, asked what it would start.
      config =
        :courier
        |> Application.get_env(Oban, [])
        |> Keyword.put(:testing, :disabled)
        |> Oban.Config.new()

      assert [{Oban.Cron, _opts} | _rest] = config.plugins
    end
  end

  defp deliver!(url) do
    Deliver.welcome(%{
      user_id: @user_id,
      email: "kaka@example.com",
      name: "Kaka",
      url: url
    })
  end

  # An outbox row written the way a path that has not been through
  # `Courier.Outbox` would write one.
  defp insert_row_directly! do
    {:ok, row} =
      %OutboxEvent{}
      |> OutboxEvent.changeset(%{
        type: "courier.email.delivered",
        subject: "courier-sweep-probe",
        data: %{
          "message_id" => "courier-sweep-probe",
          "user_id" => @user_id,
          "notification_type" => "welcome",
          "email" => "kaka@example.com"
        }
      })
      |> Repo.insert()

    row
  end

  # Courier's OWN crontab, read out of application env, so this file cannot
  # prove anything about a schedule it wrote itself.
  defp crontab do
    :courier
    |> Application.get_env(Oban, [])
    |> Keyword.get(:plugins, [])
    |> Enum.find_value(fn
      {Oban.Cron, opts} -> Keyword.get(opts, :crontab)
      _other -> nil
    end)
  end

  defp expr_for(worker) do
    {expr, ^worker} = Enum.find(crontab(), fn {_expr, named} -> named == worker end)

    expr
  end

  # `Oban.Cron`, started by hand because the suite's `:manual` mode starts no
  # plugins at all. Three things have to be arranged for its real insertion path
  # (`handle_info(:evaluate, …)` → `insert_scheduled_jobs/1`) to run, and each is
  # arranged the way Oban's own supervisor arranges it rather than stubbed:
  #
  #   * **an instance name of its own.** `Oban.insert/3` reads the instance's
  #     configuration out of `Oban.Registry` (deps/oban/lib/oban.ex:705) and
  #     `Oban.Peer.leader?/1` looks its peer up under the same name, so the cron
  #     needs both. `Oban` is taken by the running suite's instance — `Oban.Registry`
  #     is `keys: :unique` — hence a second name.
  #   * **a peer that says it leads.** A plugin only inserts when it believes it is
  #     the leader, and `testing: :manual` tells every instance it is not
  #     (deps/oban/lib/oban/config.ex:110). `Oban.Peers.Isolated` with
  #     `leader?: true` is a leader; the suite's is not.
  #   * **the sandbox connection.** Without the allowance the plugin would write
  #     on a second connection: invisible to this transaction, and not cleaned up
  #     by the rollback that ends the test.
  defp start_cron! do
    conf =
      :courier
      |> Application.get_env(Oban, [])
      |> Oban.Config.new()
      |> Map.merge(%{name: @cron_instance, peer: {Oban.Peers.Isolated, [leader?: true]}})

    Registry.register(Oban.Registry, @cron_instance, conf)

    via = Oban.Registry.via(@cron_instance, Oban.Peer)

    start_supervised!(%{
      id: :courier_outbox_enqueue_peer,
      start: {Oban.Peers.Isolated, :start_link, [[conf: conf, name: via]]}
    })

    pid =
      start_supervised!(%{
        id: :courier_outbox_enqueue_cron,
        start: {Oban.Cron, :start_link, [[conf: conf, crontab: crontab()]]}
      })

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    pid
  end

  # Run a job READ BACK OUT of the queue rather than a fresh `perform_job(Worker,
  # %{})`. `Oban.Testing.perform_job/2` runs a job it built, which carries the
  # two stamps the queue writes when it claims one; a job loaded from `oban_jobs`
  # carries neither, and `Oban.Queues.Executor.record_finished/1` measures the
  # queue time between them. These are the queue's own stamps, in the queue's own
  # order — the difference between this file and `ProcessOutboxWorkerTest` is
  # entirely where the job came from.
  defp perform_queued(job) do
    persisted = Repo.get!(Oban.Job, job.id)
    claimed = %{persisted | attempted_at: DateTime.utc_now()}

    perform_job(%{claimed | scheduled_at: claimed.scheduled_at || claimed.inserted_at})
  end
end
