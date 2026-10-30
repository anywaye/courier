defmodule Courier.NatsPublisherTest do
  @moduledoc """
  The relay publishes through a behaviour, not through Gnat, so this packet can
  be tested end to end without a broker, and the NATS packet can be added later
  without touching the worker.

  `Courier.NatsPublisher.Noop` is the stand-in: it hands each envelope to the
  process that published it, which is what makes "the relay published this" an
  assertion rather than a hope.
  """

  use ExUnit.Case, async: true

  alias Courier.NatsPublisher

  @envelope %{
    "specversion" => "1.0",
    "id" => "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061",
    "type" => "email.delivered",
    "source" => "courier",
    "subject" => "courier-1a2b",
    "time" => "2026-09-30T04:19:00Z",
    "data" => %{"message_id" => "courier-1a2b"}
  }

  test "the stand-in reports success" do
    assert :ok == NatsPublisher.Noop.publish(@envelope)
  end

  test "the stand-in hands the envelope back to the process that published it" do
    :ok = NatsPublisher.Noop.publish(@envelope)

    assert_received {:nats_published, @envelope}
  end

  test "the stand-in declares the behaviour, so Gnat is a config change and not a rewrite" do
    behaviours =
      NatsPublisher.Noop.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert NatsPublisher in behaviours
  end
end

defmodule Courier.NatsPublisherConfigTest do
  @moduledoc """
  Which publisher the relay talks to is configuration.

  `async: false` because these cases change application env, which the whole VM
  shares. `on_exit` puts it back before the next test starts.
  """

  use ExUnit.Case, async: false

  alias Courier.NatsPublisher

  setup do
    original = Application.get_env(:courier, :nats_publisher)

    on_exit(fn -> Application.put_env(:courier, :nats_publisher, original) end)

    :ok
  end

  test "the relay publishes through the configured publisher" do
    assert NatsPublisher.impl() == NatsPublisher.Noop
  end

  test "an unconfigured publisher is the stand-in rather than a crash mid-relay" do
    Application.delete_env(:courier, :nats_publisher)

    assert NatsPublisher.impl() == NatsPublisher.Noop
  end

  test "a configured publisher is the one used" do
    Application.put_env(:courier, :nats_publisher, Courier.TestSupport.RefusingPublisher)

    assert NatsPublisher.impl() == Courier.TestSupport.RefusingPublisher
  end
end
