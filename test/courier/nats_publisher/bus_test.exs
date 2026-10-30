defmodule Courier.NatsPublisherBusTest do
  @moduledoc """
  THE PROOF THIS PACKET EXISTS FOR: an unpublished `outbox_events` row reaches
  the broker, on the subject named by its event type, and is marked published
  from the broker's own acknowledgement.

  The proof is a real one, not an inspection. `Courier.TestSupport.NatsServer`
  listens on a kernel-assigned loopback port and speaks the NATS protocol — the
  `INFO` greeting gnat waits for, `PING`/`PONG`, and the JetStream publish ack a
  stream answers a publish with. `Courier.NatsPublisher.Bus` publishes through a
  real `Gnat` connection over a real socket, so what is asserted is on the wire:

      a row was written, and a message arrived at this port, on this subject,
      carrying this envelope — and the row's `published_at` was set only because
      the broker said so.

  A test asserting the publisher was CALLED proves nothing about delivery, which
  is why the assertions below are about the bytes the broker received.


  Three reasons, and each is a property of the VM rather than of this test:

    * application env is VM-global, so `:nats` and `:nats_publisher` are put and
      restored around the run;
    * `Courier.Nats` is a NAMED process (`name: Courier.Nats`), so two copies in
      one VM is a clash;
    * the publisher it ends up configured with is not the suite's stand-in.


  That a real broker creates the `anywaye` stream, or that `courier.>` matches.
  kit owns that (`templates/compose/docker-compose.yml:540` and
  `templates/substrate/install.sh:1365`), and the subject this test asserts is
  the one this server answers for. What IS proved is that courier publishes on
  the event's own type, prefixed with its own name, and marks the row from the
  ack. The stream half was measured in brk-2R against a real
  `nats:2.10.24-alpine` broker — the stream created by kit's verbatim
  `nats stream add anywaye --subjects "identity.>,billing.>,courier.>,muse.>,
  darkroom.>" ...` accepted a real publish on `courier.email.delivered` and
  stored the envelope at seq 1 — recorded in
  `REPORT-courier-brk2-outbox-publisher`'s stream section, reproducible with
  `evidence/brk2-broker-proof.exs`.
  """

  use Courier.DataCase, async: false

  use Oban.Testing, repo: Courier.Repo

  alias Courier.Deliver
  alias Courier.Nats
  alias Courier.NatsPublisher.Bus
  alias Courier.OutboxEvent
  alias Courier.Workers.ProcessOutboxWorker
  alias Courier.TestSupport.NatsServer

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp welcome_payload do
    %{
      user_id: @user_id,
      email: "kaka@example.com",
      name: "Kaka",
      url: "https://anywaye.com/verify?token=abc123"
    }
  end

  defp delivered_row! do
    {:ok, result} = Deliver.welcome(welcome_payload())
    Repo.get!(OutboxEvent, result.event_id)
  end

  setup do
    server = start_supervised!(NatsServer)

    port = NatsServer.port(server)

    original_nats = Application.get_env(:courier, :nats)
    original_publisher = Application.get_env(:courier, :nats_publisher)

    Application.put_env(:courier, :nats, url: "nats://127.0.0.1:#{port}")
    Application.put_env(:courier, :nats_publisher, Bus)

    on_exit(fn ->
      Application.put_env(:courier, :nats, original_nats)
      Application.put_env(:courier, :nats_publisher, original_publisher)
    end)

    {:ok, server: server}
  end

  describe "an unpublished row, against a real broker" do
    test "reaches the bus on the subject named by its event type", ctx do
      row = delivered_row!()

      start_supervised!({Nats, []})
      assert {:ok, _connection} = Nats.connection()

      assert {:ok, _} = perform_job(ProcessOutboxWorker, %{})

      assert [%{subject: subject, payload: payload}] = NatsServer.published(ctx.server)

      assert subject == "courier.email.delivered"

      envelope = Jason.decode!(payload)
      assert envelope["id"] == row.id
      assert envelope["type"] == "courier.email.delivered"
      assert envelope["source"] == "courier"
      assert envelope["specversion"] == "1.0"
      assert envelope["subject"] == row.subject
      assert envelope["time"] == DateTime.to_iso8601(row.occurred_at)

      assert String.starts_with?(subject, "courier.")

      reloaded = Repo.get!(OutboxEvent, row.id)
      assert reloaded.published_at
      assert reloaded.last_error == nil
      assert reloaded.attempt_count == 0
    end

    test "a batch is published oldest first, each row on its own subject", ctx do
      first = delivered_row!()
      second = delivered_row!()

      start_supervised!({Nats, []})
      assert {:ok, _} = perform_job(ProcessOutboxWorker, %{})

      assert NatsServer.subjects(ctx.server) == [
               "courier.email.delivered",
               "courier.email.delivered"
             ]

      assert Enum.map(NatsServer.published(ctx.server), &Jason.decode!(&1.payload)["id"]) == [
               first.id,
               second.id
             ]
    end

    test "the published bytes are the sent bytes", ctx do
      row = delivered_row!()

      start_supervised!({Nats, []})
      assert {:ok, _} = perform_job(ProcessOutboxWorker, %{})

      [%{payload: payload}] = NatsServer.published(ctx.server)
      assert payload == Jason.encode!(OutboxEvent.envelope(row))
    end
  end

  describe "when the broker refuses" do
    setup ctx do
      :ok =
        NatsServer.refuse_next(
          ctx.server,
          ~s({"type":"io.nats.jetstream.api.v1.publish_ack_response",) <>
            ~s("error":{"code":404,"err_code":10059,"description":) <>
            ~s("stream not found for subject: courier.email.delivered"}})
        )

      :ok
    end

    test "the row is not marked published and the refusal is recorded", ctx do
      row = delivered_row!()

      start_supervised!({Nats, []})

      assert {:error, %{published: 0, failed: 1, reason: reason}} =
               perform_job(ProcessOutboxWorker, %{})

      assert reason ==
               ~s(stream_refused 404: "stream not found for subject: ) <>
                 ~s(courier.email.delivered")

      assert [%{subject: subject}] = NatsServer.published(ctx.server)
      assert subject == "courier.email.delivered"

      reloaded = Repo.get!(OutboxEvent, row.id)
      assert is_nil(reloaded.published_at)
      assert reloaded.attempt_count == 1

      assert reloaded.last_error ==
               ~s(stream_refused 404: "stream not found for subject: ) <>
                 ~s(courier.email.delivered")
    end
  end
end
