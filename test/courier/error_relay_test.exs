defmodule Courier.ErrorRelayTest do
  @moduledoc """
  Volume control on the error path, and the guarantee that the error path cannot
  take the main path down with it.


  Sentry **does not sample errors, by design**. The SDK's `sample_rate` applies
  to transactions; an exception is reported every time it happens. That is the
  right default for an error store — you cannot sample the one crash that
  mattered — and it means a bug in a hot loop becomes one notification per
  iteration, which is not an error store any more, it is a denial of service
  with a UI.

  So there are two controls and they are deliberately at two different places,
  because two controls of the same kind is one control:

    * **per service**, in `Courier.ErrorReporting` and its two siblings: a
      client-side limiter, so a hot loop does not build ten thousand envelopes.
    * **here**, in the relay: a fingerprint-keyed token bucket, so even a service
      whose own limiter is misconfigured, or missing, or a version behind,
      cannot fill the store.

  The relay's throttle is the one that makes the brief's promise true — "one bug
  in a hot loop does not become ten thousand identical notifications" — because
  it holds no matter what the three SDKs do.


  A counter with a reset is a rate limit with a cliff: at the boundary it either
  lets a burst through or it does not. A bucket refills continuously, so the
  first event of a bug always gets through — which is the one that matters,
  because it is the one that says *the bug is still happening* — and a continuing
  bug produces one event per refill interval rather than a wall.


  `Courier.TestSupport.Clock` is a **named** process, and the refill assertions
  move its clock. Two of these tests advancing one clock concurrently would make
  every refill assertion depend on the interleaving, so the file is
  `async: false`. That is the reason the house rules ask for — a test that
  coordinates through a suite-shared process has to say so — and not a shrug. It
  costs about thirty milliseconds; every other file in the no-database tier stays
  `async: true`.


  A throttle tested by waiting is a throttle tested by the wall clock, and it is
  a test that takes as long as the window it is proving. `now` is a function the
  relay takes at init, so the refill is asserted by moving the clock rather than
  by living through it. That is also the only way to assert the *shape* of the
  schedule rather than that time passed.

  The harder half is the wait, and this file used to get it wrong in the way the
  house rules name: a bounded spin. `eventually/3` polled two hundred times and
  gave up, and two hundred `:sys.get_state/1` round trips are **not** a duration
  — they are a count, so they are a proxy for one, and the proxy is only as good
  as the machine it ran on. Measured on the same code on the same test, two
  hundred iterations took between 0.6 ms and 2.2 ms of wall clock, while the
  thing being waited for arrived between 0.4 ms and 36 ms later. Whichever was
  bigger won, and the result was a test that failed about one run in three.

  So there are three ways to wait here and each is chosen because of **who
  writes the fact being asserted**:

    * **the relay writes it** (`received`, `forwarded`, `throttled`, `malformed`,
      `unclassified`, `undeclared`) — `:sys.get_state(relay)`, which `sync/1`
      already is. One round trip, no loop, and it is a *barrier* rather than a
      wait: the cast the test made is ahead of the system message in the relay's
      mailbox, so the counter is written before the reply comes back.

    * **the sender writes it** (`queue_full`) — `sync/1`, which asks the sender
      second, because the sender can only count a drop after the relay has cast
      the envelope to it and `:sys.get_state(relay)` is what proves that.

    * **the sender's drain writes it** (`sink_failures`) — neither of the above
      is enough, because the drain is a `Task` and the counter is written after
      the sink has returned. Here `await_drain/1` waits for the drain **process to
      exit**, which it cannot do before every counter in the batch is written. It
      is `Process.monitor/1` plus an `assert_receive` on the `:DOWN`, and it is a
      barrier for the same reason the other two are: the observation is causally
      after the write, not merely later than it.

  And what the sink *receives* is waited for by message too — `forwarded/1` says
  how many envelopes it is expecting and blocks on each — for the same reason
  `error_relay_endpoint_test.exs` uses `assert_receive {:relayed, body}`: a
  window that waits for silence has to be longer than the slowest drain that can
  possibly happen, and the slowest drain is bounded by nothing but the machine.
  A test that passes because nothing had arrived *yet* is a test measuring the
  scheduler.

  Each `assert_receive` still carries a timeout, and it is a **failure deadline,
  not a budget**: no assertion's truth depends on it being generous, because each
  one waits for a message a specific process must send. Measured, the slowest
  drain observed while fixing this file was 36 ms on a machine at load average
  60 across 8 cores; `@wait` is 2 s, so the deadline is never the binding
  constraint. Before the fix it *was* the binding constraint, which is the
  difference between this paragraph and the one it replaced.
  """

  use ExUnit.Case, async: false

  alias Courier.ErrorRelay
  alias Courier.ErrorRelay.Sink
  alias Courier.TestSupport.Clock
  alias Courier.TestSupport.FailingSink
  alias Courier.TestSupport.RecordingSink

  @burst 3
  @per_minute 60
  @capacity 64
  @canary "CANARY-4f19b2c7-do-not-store-me"
  @bearer "Bearer abcdefghijklmnopqrstuvwxyz012345"

  @wait 2_000

  setup do
    start_supervised!({Clock, []})
    :ok
  end

  defp start_relay(opts \\ []) do
    name = :"relay_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ErrorRelay,
       Keyword.merge(
         [
           name: name,
           sink: RecordingSink,
           sink_target: self(),
           now: &Clock.now/0,
           burst: @burst,
           per_minute: @per_minute,
           capacity: @capacity,
           queue_size: 16
         ],
         opts
       )}
    )

    name
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => "6f5d4c3b2a184e8f9c071b2d3e4f5061",
        "timestamp" => "2026-10-01T12:00:00Z",
        "platform" => "elixir",
        "level" => "error",
        "release" => "9f2c1ab",
        "environment" => "production",
        "transaction" => "courier.email.deliver",
        "tags" => %{"error.type" => "internal_error", "service.name" => "courier"},
        "exception" => %{
          "values" => [
            %{
              "type" => "RuntimeError",
              "module" => "Elixir.Courier.Deliver",
              "stacktrace" => %{
                "frames" => [
                  %{
                    "filename" => "lib/courier/deliver.ex",
                    "function" => "deliver/3",
                    "lineno" => 42,
                    "in_app" => true,
                    "module" => "Elixir.Courier.Deliver"
                  }
                ]
              }
            }
          ]
        }
      },
      overrides
    )
  end

  defp as_item(event), do: %{"type" => "event", "payload" => event}

  defp forwarded(expected) when expected > 0 do
    Enum.map(1..expected, fn _ ->
      assert_receive {:relayed, envelope}, @wait
      envelope
    end)
  end

  defp sync(relay) do
    :sys.get_state(relay)
    :sys.get_state(ErrorRelay.sender_name(relay))
    :ok
  end

  defp await_drain(relay) do
    :sys.get_state(ErrorRelay.sender_name(relay))

    relay
    |> ErrorRelay.tasks_name()
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @wait
    end)
  end

  describe "a hot loop becomes a bounded number of notifications" do
    test "ten thousand occurrences of one bug forward three and count the rest" do
      relay = start_relay()

      for _ <- 1..10_000, do: ErrorRelay.ingest(relay, [as_item(event())])
      sync(relay)

      assert %{forwarded: 3, throttled: 9_997} = ErrorRelay.stats(relay)
      assert 3 == length(forwarded(3))
    end

    test "a different bug has its own bucket" do
      relay = start_relay()

      for _ <- 1..@burst, do: ErrorRelay.ingest(relay, [as_item(event())])
      assert @burst == length(forwarded(@burst))

      ErrorRelay.ingest(relay, [as_item(event(%{"transaction" => "courier.webhook.send"}))])
      assert 1 == length(forwarded(1))
    end

    test "the bucket refills, so a bug that is still happening keeps being reported" do
      relay = start_relay()

      for _ <- 1..@burst, do: ErrorRelay.ingest(relay, [as_item(event())])
      assert @burst == length(forwarded(@burst))

      ErrorRelay.ingest(relay, [as_item(event())])
      sync(relay)
      assert @burst == ErrorRelay.stats(relay).forwarded

      Clock.advance(999)
      ErrorRelay.ingest(relay, [as_item(event())])
      sync(relay)
      assert @burst == ErrorRelay.stats(relay).forwarded

      Clock.advance(1)
      ErrorRelay.ingest(relay, [as_item(event())])
      assert 1 == length(forwarded(1))
    end

    test "a very long idle period refills to `burst` and no further" do
      relay = start_relay()

      for _ <- 1..@burst, do: ErrorRelay.ingest(relay, [as_item(event())])
      assert @burst == length(forwarded(@burst))

      Clock.advance(60 * 60 * 1000)
      for _ <- 1..(@burst * 3), do: ErrorRelay.ingest(relay, [as_item(event())])
      sync(relay)

      assert %{forwarded: 6, throttled: 6} = ErrorRelay.stats(relay)
      assert @burst == length(forwarded(@burst))
    end
  end

  describe "it cannot crash-loop" do
    test "the fingerprint table is bounded, whatever arrives" do
      relay = start_relay()

      for n <- 1..(@capacity * 3) do
        ErrorRelay.ingest(relay, [as_item(event(%{"transaction" => "courier.op#{n}"}))])
      end

      sync(relay)

      assert :ets.info(relay, :size) <= @capacity
    end

    test "a relay whose sink raises is still alive and still counting" do
      relay = start_relay(sink: FailingSink)

      assert :ok == ErrorRelay.ingest(relay, [as_item(event())])
      assert Process.alive?(Process.whereis(relay))

      assert_receive {:sink_attempted, :raise}, @wait

      await_drain(relay)
      assert 1 == ErrorRelay.stats(relay).sink_failures
      assert Process.alive?(Process.whereis(relay))

      ErrorRelay.ingest(relay, [as_item(event(%{"transaction" => "courier.webhook.send"}))])
      assert_receive {:sink_attempted, :raise}, @wait

      await_drain(relay)
      assert 2 == ErrorRelay.stats(relay).sink_failures
    end

    test "a sink that returns an error tuple is counted, not raised" do
      relay = start_relay(sink: FailingSink, sink_mode: :error)

      ErrorRelay.ingest(relay, [as_item(event())])

      assert_receive {:sink_attempted, :error}, @wait

      await_drain(relay)
      assert 1 == ErrorRelay.stats(relay).sink_failures
    end
  end

  describe "it never blocks the caller" do
    test "ingest/2 returns when the queue is full and nothing is draining" do
      relay = start_relay(queue_size: 0)

      assert :ok == ErrorRelay.ingest(relay, [as_item(event())])

      sync(relay)
      assert 1 == ErrorRelay.stats(relay).queue_full

      assert Process.alive?(Process.whereis(relay))
    end

    test "an event nobody can read is dropped with a reason, and the relay lives" do
      relay = start_relay()

      assert :ok ==
               ErrorRelay.ingest(relay, [
                 as_item("not an event at all")
               ])

      assert :ok ==
               ErrorRelay.ingest(relay, [
                 as_item(event(%{"tags" => %{"service.name" => "courier"}}))
               ])

      sync(relay)

      assert %{malformed: 1, unclassified: 1, forwarded: 0} = ErrorRelay.stats(relay)
      assert Process.alive?(Process.whereis(relay))
    end
  end

  describe "what the sink receives" do
    test "a Sentry envelope containing only what survived" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [as_item(event())])

      assert [envelope] = forwarded(1)
      assert {:ok, [%{"type" => "event", "payload" => payload}]} = Sink.parse_envelope(envelope)
      assert {:ok, decoded} = Jason.decode(payload)
      assert "courier" == decoded["tags"]["service.name"]
    end

    test "two events in one envelope arrive as two items in one envelope" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [
        as_item(event()),
        as_item(event(%{"transaction" => "courier.webhook.send"}))
      ])

      assert [envelope] = forwarded(1)
      assert {:ok, items} = Sink.parse_envelope(envelope)
      assert 2 == length(items)
    end

    test "a non-event item — a session, a transaction — is not forwarded" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [
        %{"type" => "session", "payload" => %{"status" => "ok"}},
        %{"type" => "event", "payload" => event()},
        %{"type" => "transaction", "payload" => %{"spans" => [%{"description" => "a secret"}]}}
      ])

      assert [envelope] = forwarded(1)
      assert {:ok, [%{"type" => "event"}]} = Sink.parse_envelope(envelope)
      refute envelope =~ "a secret"
    end
  end

  describe "the end-to-end boundary, asserted on the bytes that would be stored" do
    test "a secret the SDK put in `extra` and in a header is gone" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [
        as_item(
          event(%{
            "extra" => %{"prompt" => @canary},
            "request" => %{"headers" => %{"Authorization" => @bearer}}
          })
        )
      ])

      assert [envelope] = forwarded(1)
      refute envelope =~ @canary
      refute envelope =~ @bearer
    end

    test "the exception message is gone, and the class survives" do
      relay = start_relay()

      ErrorRelay.ingest(relay, [
        as_item(
          event(%{
            "exception" => %{
              "values" => [%{"type" => "RuntimeError", "value" => "boom: #{@canary}"}]
            }
          })
        )
      ])

      assert [envelope] = forwarded(1)
      refute envelope =~ @canary
      assert envelope =~ "RuntimeError"
    end
  end

  describe "the fingerprint is the relay's, not the caller's" do
    test "a caller that changes its Sentry fingerprint every event cannot defeat the throttle" do
      relay = start_relay()

      for n <- 1..5 do
        ErrorRelay.ingest(
          relay,
          [
            as_item(
              event(%{
                "event_id" => "event-#{n}",
                "timestamp" => "2026-10-01T12:0#{n}:00Z",
                "fingerprint" => ["a-different-group-every-time"]
              })
            )
          ]
        )
      end

      sync(relay)

      assert %{forwarded: 3, throttled: 2} = ErrorRelay.stats(relay)
      assert @burst == length(forwarded(@burst))
    end
  end
end
