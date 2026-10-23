# THE EVIDENCE RUN for brk-2R's stream question.
#
# The manager's finding was, verbatim:
#
#     stream_refused 404: "stream not found for subject: courier.email.delivered"
#
# and the packet asks which of three things was true: the stream was created
# before the subject list kit now defines, courier publishes a subject the
# stream does not cover, or the broker had a different stream. This script
# settles it against a REAL broker with kit's OWN stream-definition command,
# driven through the real `Courier.Nats` connection and the real
# `Courier.NatsPublisher.Bus` — real gnat, real socket, real publish ack.
#
# It is NOT part of the suite: it needs a broker at `NATS_URL`, which the gate
# has no contract to provide. Run it by hand:
#
#   # 1. a bare broker with JetStream and NO stream — reproduces the finding
#   docker run -d --rm --name brk2-nats -p 14222:4222 nats:2.10.24-alpine -js
#   NATS_URL=nats://127.0.0.1:14222 mise exec -- mix run evidence/brk2-broker-proof.exs
#
#   # 2. create the stream with kit's verbatim argv (install.sh step 10 and
#   #    compose's nats-stream-init are the same command)
#   docker run --rm natsio/nats-box:0.20.0 nats --server nats://host.docker.internal:14222 \
#     stream add anywaye --subjects "identity.>,billing.>,courier.>,muse.>,darkroom.>" \
#     --storage file --retention limits --max-age 7d --discard old --replicas 1 --defaults
#
#   # 3. the same publish again — this is the assertion the packet is for
#   NATS_URL=nats://127.0.0.1:14222 mise exec -- mix run evidence/brk2-broker-proof.exs
#   docker run --rm natsio/nats-box:0.20.0 nats --server nats://host.docker.internal:14222 \
#     stream info anywaye
#
# Exit 0 means the broker acknowledged the publish; the answer is printed.

url = System.get_env("NATS_URL") || raise "NATS_URL must name the broker"

Application.put_env(:courier, :nats, url: url)
Application.put_env(:courier, :nats_publisher, Courier.NatsPublisher.Bus)

# `Courier.Nats` is a supervised child whenever `NATS_URL` is set —
# `config/runtime.exs` puts it in the tree — so this is a no-op when the
# application already started one, and the connection below is the live one
# either way.
_ = Courier.Nats.start_link([])
{:ok, _connection} = Courier.Nats.connection()

# An envelope courier itself would publish: the same shape
# `Courier.OutboxEvent.envelope/1` builds, for the one event type with a
# producer today. The type is what becomes the NATS subject — no mapping
# table, core's rule — so it is the only field the stream question is about.
envelope =
  Courier.Events.envelope(%{
    id: Ecto.UUID.bingenerate() |> Ecto.UUID.cast!(),
    type: "courier.email.delivered",
    source: "courier",
    subject: Ecto.UUID.bingenerate() |> Ecto.UUID.cast!(),
    time: DateTime.utc_now(),
    data: %{
      "user_id" => Ecto.UUID.bingenerate() |> Ecto.UUID.cast!(),
      "email" => "kaka@example.com",
      "name" => "Kaka",
      "url" => "https://anywaye.com/verify?token=abc123"
    }
  })

IO.puts("subject:  #{envelope["type"]}")
IO.puts("publish:  #{inspect(Courier.NatsPublisher.Bus.publish(envelope))}")
