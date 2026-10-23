defmodule Courier.OutboxEnqueueConfigTest do
  @moduledoc """
  The enqueue and the ROLLBACK it shares a transaction with, which needs a mail
  adapter that refuses.

  `Courier.Outbox.insert/1` inserts the row and the relay job in the caller's
  transaction. That is the whole reason the window in which a committed row has
  nothing waiting to publish it is empty rather than small, and it is a claim
  about a transaction unwinding — so the case that unwinds one belongs here,
  where the adapter can be swapped.

  `async: false` because this module replaces `config :courier, Courier.Mailer`'s
  adapter, and application env is VM-global: for the length of this module any
  other test that delivers mail would deliver it through the refusing adapter.
  `on_exit` restores it before the next test starts. This is the same reason
  `Courier.DeliverAdapterTest` owns the swap, and the two never run at once.

  ## Why "no job" is the answer and not "no row, job left behind"

  A job that outlived the row it names is a relay that will claim nothing and
  report success: the event is on no bus and no table says so. So the assertion
  is the pair — no row AND no job — and a test that only asserted "no row" would
  pass with a stray job in the queue, which is the half of the failure that is
  invisible.
  """

  use Courier.DataCase, async: false

  use Oban.Testing, repo: Courier.Repo

  alias Courier.Deliver
  alias Courier.OutboxEvent
  alias Courier.Workers.ProcessOutboxWorker

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  setup do
    original = Application.get_env(:courier, Courier.Mailer)

    on_exit(fn -> Application.put_env(:courier, Courier.Mailer, original) end)

    Application.put_env(:courier, Courier.Mailer, adapter: Courier.TestSupport.FailingAdapter)

    :ok
  end

  test "a send that rolled back leaves no row and no job" do
    assert {:error, {:delivery_failed, :provider_unavailable}} =
             Deliver.welcome(%{
               user_id: @user_id,
               email: "kaka@example.com",
               name: "Kaka",
               url: "https://anywaye.com/verify?token=abc123"
             })

    assert Repo.all(OutboxEvent) == []
    assert all_enqueued(worker: ProcessOutboxWorker) == []
  end

  test "and the next send does enqueue, so the pair is not vacuously empty" do
    # A negative assertion with no positive beside it passes when the enqueue
    # never worked at all, which is the state this repository was in. So: the
    # same call with an adapter that accepts leaves exactly one job.
    Application.put_env(:courier, Courier.Mailer, adapter: Swoosh.Adapters.Test)

    assert {:ok, %{event_id: event_id}} =
             Deliver.welcome(%{
               user_id: @user_id,
               email: "kaka@example.com",
               name: "Kaka",
               url: "https://anywaye.com/verify?token=abc123"
             })

    assert [job] = all_enqueued(worker: ProcessOutboxWorker)
    assert job.args == %{"event_id" => event_id}
    assert Repo.get!(OutboxEvent, event_id)
  end
end
