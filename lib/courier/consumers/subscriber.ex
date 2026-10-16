defmodule Courier.Consumers.Subscriber do
  @moduledoc """
  The subscription: the process that turns an `identity.>` DELIVERY into a
  `consumed_events` row, which is the half of the consumer that had never been
  written.

  Until this packet courier had the consumer's brain and no senses.
  `Courier.Consumers` claims, dispatches and marks; `ConsumeEventsWorker`
  sweeps on a timer; three handlers are registered against three identity
  types — and **nothing connected any of it to the bus.** `wiring_test.exs`
  asserted the absence as a decision with a reason ("a subscriber needs a
  broker, and courier has no NATS client"). The broker client landed in the
  outbox packet (`Courier.Nats`, `Courier.NatsPublisher.Bus`), so this is the
  wiring that packet's report promised and the reason is now the opposite one:
  the client exists, and a consumer whose delivery half is unwritten is a
  service that publishes into a bus nobody reads, which is the state this
  whole broker build exists to remove.

  ## WHAT THE PROCESS DOES, IN ONE SENTENCE

  Hold a subscription to the **`identity.>` subject prefix**, and for every
  message delivered, hand the envelope to `Courier.Consumers.record/1` — the
  function whose primary key IS the dedupe — and log, loudly, anything that
  cannot be recorded.

  ## WHY THE PREFIX AND NOT THE SUBSCRIBED TYPES

  `cafaye.yml`'s `consumes:` names four `identity.*` types and the registry
  has four handlers, but the subscription is to `identity.>` — the prefix,
  with the NATS wildcard. The alternative, one SUB per subscribed type, is
  the same guarantee today and a silent failure tomorrow: identity's fifth
  event type arrives, the registry gains its handler when somebody opens this
  file, and until then a SUB-per-type consumer **drops the event on the floor
  while every wire is correct.** A prefix subscription records it, the loop
  reports it as `skipped` (not this consumer's business, left claimable for
  the `consumes:` entry added later), and the manifest and the registry are
  the only two places a subscription is decided. Core's rule 6 is still
  enforced — the registry is a closed set held to `cafaye.yml` in both
  directions — but the floor of the bus is one prefix, not four exact
  subjects.

  ## WHY THE PROCESS DOES NOT HANDLE, ONLY RECORDS

  `record/1` writes the row IN THE SAME PROCESS that owns the subscription,
  and the handler runs from the sweep. Two consequences, both load-bearing:

    * **A crash mid-effect is recoverable.** The row is durable before the
      effect is owed; the handler's success is what marks it
      (`Consumers.mark_handled/1`), and a handler that failed leaves
      `consumed_at` NULL for the next pass. Consuming and THEN marking —
      acking the broker from inside the handler — would record "handled" for
      a handler that then failed, and the next pass would skip a mail nobody
      was sent. The relay marks when the BROKER acknowledges; this marks when
      the EFFECT is done. That is the whole reason `consumed_events` is three
      columns and not one flag.
    * **A handler that raises cannot take the stream down.** The subscriber's
      callback runs in the process that owns the subscription, and an
      uncaught raise there kills the subscription for every subsequent
      message. `Courier.Consumers.safe_apply/2` wraps the handler for
      exactly this reason; recording from here keeps that boundary where it
      already is.

  This process owns no business logic beyond "decode and record": routing is
  the registry's job, and a subscriber with a handler dispatch in it is the
  two halves tangled together.

  ## WHY IT ASKS THE CONNECTION PROCESS RATHER THAN OWNING A SOCKET

  `Courier.Nats` is the one connection the application holds: it dials, it
  retries on a fixed interval, it survives a broker outage without taking the
  application down, and its startup line says which half of the bus courier
  has. A subscriber that opened its own second connection would duplicate
  all of that. So this process asks `Courier.Nats.connection()` and
  subscribes on what it is handed — gnat delivers the messages to the pid
  that asked, which is this one — and re-asks on a timer, because
  **reconnecting the broker re-establishes the connection and LOSES every
  subscription on it.** A subscriber that subscribed once and never again
  would go silently deaf after the broker's first blip, which is precisely
  the "quietly stopped working" state this repository keeps refusing.

  ## WHAT A REFUSAL LOOKS LIKE

  Nothing is swallowed. `record/1` answers `{:error, :already_consumed}` for
  a redelivery — ordinary operation under at-least-once, logged at debug and
  counted nowhere — and `{:error, :unreadable_envelope}` or a changeset for
  something courier cannot key, which is a **warning** naming the topic and
  the envelope id and not one byte of the payload. The redaction boundary is
  the consumer's half of `Courier.Observability`'s: the bus carries other
  services' data, and a log line quoting a delivered payload is the leak the
  span allowlist exists to prevent, reached with a log statement instead of a
  span attribute.

  A broker that is dark is not a log storm either: the subscription is
  re-attempted on a timer, the "no connection yet" state is logged once, and
  nothing crashes.
  """

  use GenServer

  require Logger

  alias Courier.Consumers
  alias Courier.Nats

  # THE SUBJECTS, DERIVED FROM THE CONSUMERS MAP AND NEVER HARDCODED.
  #
  # It was one constant — `"identity.>"` — while every consumer courier had was
  # an identity event, and that was true until `billing.payment.succeeded`
  # arrived: the receipt consumer was added to `config :courier, :consumers`,
  # every test of the CONSUMER passed, and the subscription still asked the
  # broker for `identity.>` alone. Measured on the launch stack (2026-10-16):
  # courier logged "subscribed to identity.>", billing published a settled
  # payment onto the bus, and the receipt landed in no mailbox — the registered
  # consumer was dead wire, green tests and all. A registration that does not
  # move the subscription is a message nobody receives, so the subscription is
  # read off the same map the router reads.
  #
  # One prefix per SERVICE, not one per type: a subscription to a concrete type
  # would be a subscription to a servant, and a service that gains a fifth
  # event should not need courier redeployed before it can be heard.
  @spec subjects() :: [String.t()]
  def subjects do
    Consumers.subscribed()
    |> Enum.map(fn type -> type |> String.split(".") |> hd() end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&(&1 <> ".>"))
  end

  # How often the subscription is (re-)attempted. Fixed rather than growing,
  # on the same terms as `Courier.Nats`'s own reconnect interval: the bus
  # coming back is not an event to back away from, and one SUB every two
  # seconds is nothing against a broker nobody is watching. It is also what
  # re-subscribes after the broker's own reconnect, which loses subscriptions
  # on the connection.
  @subscribe_interval 2_000

  @doc """
  The child this module puts in the application's supervision tree, or nothing.

  A **list**, on the same terms and for the same reason as
  `Courier.Nats.supervised_child/0`: Elixir's supervisor takes a bare atom as
  a module name, so the no-broker shape has to be an empty entry rather than a
  branch that has to remember not to add one. A courier with no `NATS_URL`
  holds no socket, starts no retry loop and subscribes nowhere.
  """
  @spec supervised_child() :: [Supervisor.child_spec()]
  def supervised_child do
    if Nats.enabled?(), do: [child_spec([])], else: []
  end

  @doc "Starts the subscriber, which is a supervised child or nothing."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :subscribe)
    {:ok, %{connection: nil, sids: [], logged_disconnected: false}}
  end

  @impl GenServer
  def handle_info(:subscribe, state) do
    Process.send_after(self(), :subscribe, @subscribe_interval)

    case Nats.connection() do
      {:ok, connection} -> subscribe(connection, state)
      {:error, :not_connected} -> dark(state)
    end
  end

  # The delivery, and the only thing done with it. `topic` is the event's
  # type — core's "the type is the subject, with no mapping table" rule on the
  # consuming side — and `body` is the envelope as it arrived. The record is
  # `Courier.Consumers.record/1`, which keys on the envelope's own id and
  # whose primary key IS the dedupe, so a second delivery of the same event is
  # refused here by the database and not by anything this module decides.
  @impl GenServer
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    _ = record(topic, body)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp subscribe(connection, state) do
    if state.connection == connection and state.sids != [] do
      # Already subscribed on this connection. The timer keeps running — the
      # broker's next reconnect hands us a new pid and that is the signal to
      # subscribe again.
      {:noreply, state}
    else
      # EVERY subject, or none: a half-subscribed subscriber is the defect this
      # function's history records (a second service's events arriving while
      # the subscription still named the first), so one refused SUB rolls the
      # whole attempt back to "no connection" and the timer tries the set
      # again. The broker's reconnect loses every subscription on the
      # connection, so the set is what re-arms — not one of them.
      case Enum.reduce_while(subjects(), {:ok, []}, &subscribe_one(connection, &1, &2)) do
        {:ok, sids} ->
          if state.connection != connection do
            Logger.info("bus: subscribed to #{Enum.join(subjects(), ", ")}")
          end

          {:noreply, %{state | connection: connection, sids: sids, logged_disconnected: false}}

        {:error, reason, subject} ->
          # A refused SUB is a warning, not a crash: the retry timer is armed
          # either way and this process surviving is what lets it succeed
          # later.
          Logger.warning(
            "bus: the broker refused the subscription to #{subject} (#{inspect(reason)}); " <>
              "it will be attempted again"
          )

          {:noreply, %{state | connection: nil, sids: []}}
      end
    end
  end

  defp subscribe_one(connection, subject, {:ok, sids}) do
    case Gnat.sub(connection, self(), subject, []) do
      {:ok, sid} -> {:cont, {:ok, [sid | sids]}}
      {:error, reason} -> {:halt, {:error, reason, subject}}
    end
  end

  # No broker. Logged ONCE, because "the bus is dark" is a fact an operator
  # needs once, not forty times a minute, and a log storm during an outage is
  # the outage with more lines. The retry timer is armed in `handle_info/2`
  # before this branch, so nothing here has to remember it.
  defp dark(state) do
    unless state.logged_disconnected do
      Logger.warning(
        "bus: no connection to #{Nats.url() || "the broker"}; " <>
          "#{Enum.join(subjects(), ", ")} deliveries cannot be received until one is established"
      )
    end

    {:noreply, %{state | connection: nil, sids: [], logged_disconnected: true}}
  end

  # The envelope, decoded and recorded — or a NAMED refusal with nothing from
  # the payload in it.
  #
  # `Jason.decode/1` first, because the bytes on the wire are what the
  # publisher signed and courier records exactly what it received; a payload
  # that is not JSON is a fact about the bus that no handler can act on and
  # is recorded as one (`{:error, :unreadable_envelope}` from `record/1`
  # covers a decoded-but-keyless shape; this arm covers bytes that are not a
  # JSON object at all).
  defp record(topic, body) do
    body
    |> decode()
    |> case do
      {:ok, envelope} -> Consumers.record(envelope)
      {:error, reason} -> {:error, {:undecodable_envelope, reason}}
    end
    |> case do
      {:ok, _event} ->
        :ok

      {:error, :already_consumed} ->
        # At-least-once, answering. Debug, because a redelivery is the bus
        # working and a warning on every one would train an operator to
        # ignore this line.
        Logger.debug("bus: a redelivered #{topic} event was deduped by its id")
        :ok

      {:error, reason} ->
        # LOUD, AND WITHOUT THE PAYLOAD. The topic and the reason are what an
        # operator can act on; the envelope's `data` is another service's
        # message content and does not go into a log line. This is the
        # consumer's half of the redaction boundary.
        Logger.warning("bus: could not record a #{topic} delivery: #{describe(reason)}")

        :ok
    end
  end

  # The reason, SHAPED so it cannot carry the payload.
  #
  # This is the whole of the boundary on this side, and it is a function
  # rather than a convention because the obvious version leaks: a
  # `Jason.DecodeError` holds the bytes it could not parse in `data`, so
  # `inspect/1` on it prints the message content into the log — measured,
  # with a payload this suite planted and the assertion above catching it. An
  # `Ecto.Changeset` carries the rejected VALUE in `errors`, so only the field
  # NAMES are named.
  defp describe({:undecodable_envelope, _reason}), do: "the bytes were not a JSON object"

  defp describe(:unreadable_envelope),
    do: "the envelope has no id, type, source or time to key it under"

  defp describe(%Ecto.Changeset{} = changeset) do
    "the envelope failed its changeset on #{inspect(Keyword.keys(changeset.errors))}"
  end

  defp describe(other), do: inspect(other)

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, envelope} when is_map(envelope) -> {:ok, envelope}
      {:ok, _not_an_object} -> {:error, :not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(_body), do: {:error, :not_a_binary}
end
