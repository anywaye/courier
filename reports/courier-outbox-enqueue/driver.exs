# THE DRIVER for reports/courier-outbox-enqueue/prove-outbox-enqueue.sh
#
# Run by that script through `mix run --no-start`, against the probe database the
# script creates. Never run it by hand against a development database: it
# migrates, it writes, and it resets rows.
#
# WHAT IT MEASURES, AND WHY IT NEEDS ITS OWN DATABASE. `config/test.exs` hard-codes
# the database name, so pointing courier at anything else means replacing the
# repository configuration here — before it is started, exactly as the queue
# identity packet's driver does. The probe rows are courier's own, written by
# `Courier.Deliver`, and nothing is mocked and no SQL is hand-written for the
# write under test.
#
# TWO ARMS.
#
#   enqueue   `Courier.Deliver.welcome/1` end to end, then ask the queue what it
#             holds. THE CLAIM UNDER TEST: a send leaves behind a job somebody can
#             run, and running THAT job publishes the row.
#   sweep     a row written with a plain `Repo.insert/1` — no enqueue anywhere —
#             published by a job shaped exactly the way the crontab builds one.
#             THE FLOOR: nothing that writes an outbox row has to remember to
#             enqueue, or the row is stranded for good.
#
# NOTHING IS DRIVEN BY `perform/1` DIRECTLY. Every arm below runs the job the
# queue actually holds, which is the whole difference this packet is about: a test
# that drives the consumer proves the consumer works and says nothing about who
# calls it.
defmodule CourierOutboxProbe.Driver do
  @moduledoc false

  alias Courier.Deliver
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Workers.ProcessOutboxWorker

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  def run(argv) do
    # The migrator and the Postgrex type cache both log at info/debug, and a log
    # that carries four hundred migration lines buries the seven numbers this
    # driver exists to print.
    Logger.configure(level: :error)

    url =
      System.get_env("COURIER_OUTBOX_PROBE_URL") ||
        raise("COURIER_OUTBOX_PROBE_URL is unset")

    Application.put_env(:courier, Courier.Repo,
      url: url,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      log: false
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:swoosh)
    # `Oban.insert/3` reads the instance's configuration out of `Oban.Registry`
    # (deps/oban/lib/oban.ex:705), so `mix run --no-start` needs the :oban
    # APPLICATION started even though no Oban instance is. That application is
    # two registries and nothing else (deps/oban/lib/oban/application.ex).
    {:ok, _} = Application.ensure_all_started(:oban)
    {:ok, _} = Courier.Repo.start_link()
    Ecto.Migrator.run(Courier.Repo, migrations_path(), :up, all: true)

    # An Oban INSTANCE, in the same `:manual` shape `config/test.exs` uses: the
    # queue accepts inserts and nothing executes in the background, so every arm
    # below runs exactly the job the queue holds and nothing else. Started AFTER
    # the migration because Oban refuses to start without `oban_jobs`.
    oban_config =
      :courier
      |> Application.get_env(Oban, [])
      |> Keyword.put(:repo, Courier.Repo)
      |> Keyword.put(:testing, :manual)

    {:ok, _pid} = Oban.start_link(oban_config)

    [arm | _rest] = argv
    reset()

    case arm do
      "enqueue" -> enqueue_arm()
      "sweep" -> sweep_arm()
      other -> raise("unknown arm #{inspect(other)}")
    end
  end

  # The claim: a send leaves a job, the job's args name the row it is for, and
  # running the job the queue holds marks that row published.
  defp enqueue_arm do
    {:ok, result} =
      Deliver.welcome(%{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        url: "https://cafaye.com/verify?token=probe"
      })

    row = Repo.get!(OutboxEvent, result.event_id)
    jobs = jobs()

    say("outbox rows after one send: #{count(OutboxEvent)}")
    say("oban jobs after one send:  #{length(jobs)}")
    say("event_id the send returned:  #{row.id}")

    case jobs do
      [job] ->
        say("job worker:  #{job.worker}")
        say("job queue:   #{job.queue}")
        say("job state:   #{job.state}")
        say("job args:    #{inspect(job.args)}")
        say("args name the row: #{job.args["event_id"] == row.id}")

        # The job the QUEUE holds, not a hand-built one.
        {:ok, summary} = run_job(job)
        say("performed the queued job: #{inspect(summary)}")
        say("row published_at: #{inspect(Repo.get!(OutboxEvent, row.id).published_at)}")
        say("row published: #{published?(row)}")
        say("published envelopes handed back: #{published_count()}")

      other ->
        say("job list: #{inspect(Enum.map(other, &{&1.worker, &1.args}))}")
    end
  end

  # The floor: a row nobody enqueued is still published by the crontab's job.
  defp sweep_arm do
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

    say("row written with a plain Repo.insert/1: #{row.id}")
    say("oban jobs before the sweep:          #{length(jobs())}")

    # Exactly the changeset `Oban.Cron.build_changeset/4` builds for
    # `{"* * * * *", Courier.Workers.ProcessOutboxWorker}`: no args, and the four
    # meta keys the plugin sets (deps/oban/lib/oban/cron.ex:346).
    {:ok, job} =
      ProcessOutboxWorker.new(%{}, meta: %{cron: true, cron_expr: "* * * * *"})
      |> Oban.insert()

    say("the sweep's job: #{job.worker} #{inspect(job.args)} meta=#{inspect(job.meta)}")

    {:ok, summary} = run_job(job)
    say("performed the sweep's job: #{inspect(summary)}")
    say("row published_at:          #{inspect(Repo.get!(OutboxEvent, row.id).published_at)}")
    say("row published:             #{published?(row)}")
    say("published envelopes handed back: #{published_count()}")
  end

  # `Oban.Testing.perform_job/2` runs a job it BUILT, which carries
  # `attempted_at` and `scheduled_at`; a job read back out of `oban_jobs` carries
  # neither, and `Oban.Queues.Executor.record_finished/1` measures the queue time
  # between them (deps/oban/lib/oban/queues/executor.ex:199). These are the two
  # stamps the queue itself writes when it claims a job, so this is the queue's
  # step in the queue's order — not a stub around the thing under test.
  defp run_job(job) do
    persisted = Repo.get!(Oban.Job, job.id)
    claimed = %{persisted | attempted_at: DateTime.utc_now()}

    Oban.Testing.perform_job(
      %{claimed | scheduled_at: claimed.scheduled_at || claimed.inserted_at},
      repo: Courier.Repo
    )
  end

  # Read back from the database rather than off the struct: `published_at` is set
  # by the relay's own UPDATE, and the point of the number is what a consumer
  # would see.
  defp published?(row), do: not is_nil(Repo.get!(OutboxEvent, row.id).published_at)

  defp jobs, do: Repo.all(Oban.Job)

  defp count(schema), do: Repo.aggregate(schema, :count)

  # `Swoosh.Adapters.Test` is not configured here (the probe boots the real
  # adapter config, which in :test is Test anyway), and NATS is not dialled: the
  # publisher is the Noop stand-in from config/test.exs, which hands every
  # envelope back to the calling process. So "published" is countable without a
  # socket.
  defp published_count, do: drain(:nats_published)

  defp drain(tag) do
    receive do
      {^tag, _envelope} -> 1 + drain(tag)
    after
      0 -> 0
    end
  end

  defp reset do
    Repo.delete_all(Oban.Job)
    Repo.delete_all(OutboxEvent)
    Repo.delete_all(Courier.Suppression)
  end

  defp migrations_path do
    Application.app_dir(:courier, "priv/repo/migrations")
  end

  defp say(line), do: IO.puts(line)
end

CourierOutboxProbe.Driver.run(System.argv())