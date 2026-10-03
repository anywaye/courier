# THE DRIVER for reports/courier-queue-identity/prove-queue-identity.sh
#
# Run by that script through `mix run --no-start`, once per arm, against a
# database whose OWNER is a NOSUPERUSER — which is the only way to see what
# courier does on the stack it deploys to. Never run it by hand against a
# development database: it migrates, it writes, and it resets rows.
#
# WHY `--no-start` AND WHY THE REPO CONFIG IS REPLACED HERE
#
# `config/test.exs` hardcodes `username: "postgres"`, and on a Homebrew cluster
# `postgres` is `rolsuper=t rolbypassrls=t` — it bypasses RLS whatever FORCE
# says. Everything this file measures would come out "fine" and every conclusion
# would be wrong. So the repo is re-pointed at a URL supplied in the
# environment, BEFORE it is started, and the driver starts it itself. Nothing is
# mocked and no SQL is hand-written for the read under test: the reads are
# courier's own `WebhookEndpoints.enabled/1` and courier's own workers.
#
# `mix run --no-start` also means no Oban, no PubSub, no endpoint. The workers
# are driven by calling `perform/1` with a hand-built `%Oban.Job{}`, which is the
# same struct Oban hands them. Nothing is enqueued anywhere — see
# REPORT-courier-queue-identity-01.md §6 for why that is a separate finding and
# not this file's to fix.

defmodule CourierQueueProbe.Driver do
  @moduledoc false

  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Tenancy
  alias Courier.WebhookDelivery
  alias Courier.WebhookEndpoints
  alias Courier.Workers.DeliverWebhookWorker
  alias Courier.Workers.DispatchWebhooksWorker

  @account_a "11111111-1111-4111-8111-111111111111"
  @account_b "22222222-2222-4222-8222-222222222222"

  # Two accounts, one enabled endpoint and one outbox event each, so "the fan-out
  # reached nothing" and "the fan-out reached one of two accounts" are different
  # answers and neither is a tautology about the harness.
  @seed [
    %{account_id: @account_a, url: "https://a.example.com/hooks"},
    %{account_id: @account_b, url: "https://b.example.com/hooks"}
  ]

  def run(argv) do
    url = System.get_env("COURIER_QUEUE_PROBE_URL") || raise("COURIER_QUEUE_PROBE_URL is unset")

    Application.put_env(:courier, Courier.Repo,
      url: url,
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      log: false
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Courier.Repo.start_link()

    [mode | rest] = argv
    apply_mode(String.to_existing_atom(mode), rest)
    :ok
  end

  # ----------------------------------------------------------------- modes --

  defp apply_mode(:migrate, _) do
    path = Application.app_dir(:courier, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, path, :up, all: true)

    say("MIGRATIONS=up")
    say("CURRENT_ROLE=#{current_role()}")
  end

  defp apply_mode(:seed, _) do
    Enum.each(@seed, fn %{account_id: account_id, url: url} ->
      with_account(account_id, fn ->
        case WebhookEndpoints.create(%{url: url, account_id: account_id}) do
          {:ok, _endpoint, _secret} -> :ok
          other -> raise("could not seed an endpoint for #{account_id}: #{inspect(other)}")
        end
      end)

      # Through the real changeset, not a hand-built struct: `OutboxEvent` sets
      # its own primary key (`autogenerate: false`) and its own `source` and
      # `occurred_at`, and a struct literal would insert a NULL `id` — a fixture
      # failure wearing the costume of a measurement.
      Repo.insert!(
        OutboxEvent.changeset(%OutboxEvent{}, %{
          type: "email.delivered",
          subject: "courier-probe-#{account_id}",
          data: %{"message_id" => "courier-probe-#{account_id}"},
          account_id: account_id
        })
      )
    end)

    say("SEEDED_ACCOUNTS=2")
    # 0 here is CORRECT and is the first sighting of the defect, one layer down:
    # the two inserts committed (each under its own account's identity) and the
    # owner can then see NEITHER of them, because the identity went away with the
    # transaction that wrote them. Counting as the owner would report the fixture
    # as missing; the harness counts it again as the superuser.
    say("ENDPOINT_ROWS_VISIBLE_TO_OWNER_AFTER_SEED=#{count("webhook_endpoints")}")
    say("OUTBOX_ROWS_VISIBLE_TO_OWNER_AFTER_SEED=#{count("outbox_events")}")
  end

  # Put the fixtures back to their just-seeded state so every arm measures the
  # same starting point. Without this, the first arm to run would mark the events
  # dispatched and every later arm would measure `claimed nothing` — which reads
  # exactly like the defect and is not it.
  defp apply_mode(:reset, _) do
    reset!()

    say("RESET_DELIVERY_ROWS=#{count("webhook_deliveries")}")
    say("RESET_UNDISPATCHED_EVENTS=#{undispatched_events()}")
  end

  defp apply_mode(:arm, [which]) do
    which = String.to_existing_atom(which)

    say("== arm: #{which} ==")
    say("CURRENT_ROLE=#{current_role()}")

    reset!()
    say("IDENTITY_BEFORE=#{inspect(Tenancy.current_account_id(Repo))}")
    say("ENDPOINT_ROWS_VISIBLE=#{count("webhook_endpoints")}")

    run_dispatch(which)
    run_deliver(which)

    say("ARM=#{which}")
  end

  # --------------------------------------------------------------- dispatch --

  defp run_dispatch(:without) do
    # EXACTLY what Oban does: hand the worker a job and read the answer.
    measure("DISPATCH", fn -> DispatchWebhooksWorker.perform(job(DispatchWebhooksWorker)) end)
  end

  defp run_dispatch(:with) do
    # The same call, with an identity on the transaction around it. This is the
    # control: if it produces deliveries and the bare call does not, the ONLY
    # difference between the two is the identity.
    measure("DISPATCH", fn ->
      with_account(@account_a, fn -> DispatchWebhooksWorker.perform(job(DispatchWebhooksWorker)) end)
    end)
  end

  defp run_dispatch(:superuser) do
    # The same bare call on a role that bypasses RLS. This is why a green suite
    # is not evidence: identical code, identical rows, different role.
    measure("DISPATCH", fn -> DispatchWebhooksWorker.perform(job(DispatchWebhooksWorker)) end)
  end

  # ---------------------------------------------------------------- deliver --

  # The sibling worker on the same queue and the same protected table. It was
  # found while measuring the first one and is measured here rather than
  # reported from a reading of its source; see the report §4.
  defp run_deliver(:without) do
    fresh_dispatch()
    measure("DELIVER", fn -> DeliverWebhookWorker.perform(job(DeliverWebhookWorker)) end)
  end

  defp run_deliver(:with) do
    fresh_dispatch()

    measure("DELIVER", fn ->
      with_account(@account_a, fn -> DeliverWebhookWorker.perform(job(DeliverWebhookWorker)) end)
    end)
  end

  defp run_deliver(:superuser) do
    fresh_dispatch()
    measure("DELIVER", fn -> DeliverWebhookWorker.perform(job(DeliverWebhookWorker)) end)
  end

  # ----------------------------------------------------------------- shared --

  # Every arm resets before each worker, because the two share rows: `dispatch`
  # creates the deliveries `deliver` then claims. Measuring `deliver` on the
  # leftovers of `dispatch` would be measuring the wrong thing — and, worse,
  # measuring `deliver` after a `dispatch` that fanned out to nothing would show
  # "no deliveries claimed", which is the same sentence as the defect and a
  # completely different cause.
  defp fresh_dispatch do
    reset!()

    case DispatchWebhooksWorker.perform(job(DispatchWebhooksWorker)) do
      {:ok, _} -> :ok
      other -> raise("the dispatch did not run before the deliver arm: #{inspect(other)}")
    end
  end

  defp reset! do
    Repo.delete_all(WebhookDelivery)
    Repo.update_all(OutboxEvent, set: [webhooks_dispatched_at: nil])
  end

  defp with_account(account_id, fun) do
    # `with_account/3` answers `{:ok, value} | {:error, reason}`, and an
    # `{:error, _}` here would mean `fun` rolled the transaction back. Nothing in
    # a probe arm does, so a mismatch raises rather than arming the arm with
    # `nil` — which would be a fixture that measures nothing and looks like a
    # measurement.
    case Tenancy.with_account(Repo, account_id, fun) do
      {:ok, value} -> value
      {:error, reason} -> raise("with_account rolled back: #{inspect(reason)}")
    end
  end

  # THE POINT OF THE FILE: run `fun`, and report what it returned, what the rows
  # say afterwards, and **what it logged**. The log is captured rather than
  # eyeballed because "nothing in the log" is half the finding, and a claim
  # about the absence of output is only worth printing if the capture sits in the
  # same breath as the number it is attached to.
  defp measure(prefix, fun) do
    ExUnit.start(autorun: false)

    {result, log} =
      # `with_log/2`, NOT `capture_log/2`. On Elixir 1.20 `capture_log/2`
      # returns the log string alone and `with_log/2` is the one that returns
      # `{result, log}` — a `capture_log/2` destructured as a pair raises
      # `MatchError` on the log itself, which is how this file spent its first
      # run producing empty numbers for every field.
      ExUnit.CaptureLog.with_log([level: :info], fn ->
        try do
          {:returned, fun.()}
        rescue
          error -> {:raised, Exception.format(:error, error, __STACKTRACE__)}
        catch
          kind, reason -> {:caught, inspect({kind, reason})}
        end
      end)

    {shape, value} = result

    say("#{prefix}_CALL=#{shape}")
    say("#{prefix}_RETURN=#{inspect(value)}")
    say("#{prefix}_DELIVERY_ROWS=#{count("webhook_deliveries")}")
    say("#{prefix}_DELIVERY_ROWS_SUCCEEDED=#{count_where("webhook_deliveries", "status = 'succeeded'")}")
    say("#{prefix}_DELIVERY_ROWS_EXHAUSTED=#{count_where("webhook_deliveries", "status = 'exhausted'")}")
    say("#{prefix}_LOG_LINES=#{count_lines(log)}")
    say("#{prefix}_LOG=#{one_line(log)}")
  end

  defp count_lines(""), do: 0
  defp count_lines(log), do: log |> String.split("\n", trim: true) |> length()

  # Newlines and quotes would break the line-oriented shell harness that reads
  # this output, and the log here is only ever read by a human.
  defp one_line(log), do: log |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 400)

  defp job(worker) do
    %Oban.Job{
      id: 1,
      worker: to_string(worker),
      queue: to_string(worker.__opts__()[:queue]),
      priority: 0,
      args: %{}
    }
  end

  # Raw counts, deliberately: `webhook_deliveries` carries no `account_id` and no
  # policy, so this number is the same whoever is asking — which is what makes it
  # a usable witness for a read the asker cannot see. Asking through
  # `webhook_endpoints` would be asking the question under test.
  defp count(table), do: scalar("select count(*) from #{table}")

  defp count_where(table, clause), do: scalar("select count(*) from #{table} where #{clause}")

  defp undispatched_events,
    do: scalar("select count(*) from outbox_events where webhooks_dispatched_at is null")

  defp scalar(sql) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, [])
    value
  end

  defp current_role do
    scalar(
      "select current_user || ' rolsuper=' || r.rolsuper || ' rolbypassrls=' || r.rolbypassrls from pg_roles r where r.rolname = current_user"
    )
  end

  defp say(line), do: IO.puts("PROBE " <> line)
end

CourierQueueProbe.Driver.run(System.argv())