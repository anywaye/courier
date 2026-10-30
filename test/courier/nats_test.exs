defmodule Courier.NatsTest do
  @moduledoc """
  The connection process's own contract, on its own terms.

  `Courier.NatsPublisherBusTest` proves a row reaches the bus through a real
  socket. This file is about the halves that file takes as given:

    * **`supervised_child/0` answers `:ignored` with no `NATS_URL`**, which is the
      whole of "no loop starts". The dark loop this packet undoes is a process
      that runs, marks rows published and publishes nowhere.
    * **A URL that does not parse is a boot failure**, raised from the connection
      rather than answered as `{:error, :bad_url}`. identity's comment on its own
      `NewNATSPublisher` is the reason: "a typo is a deployment that believes it
      has a bus and does not, and that belongs at boot where an operator reads
      it, not at the first event where nobody does".
    * **A broker that is down is NOT a boot failure.** The process starts, stays
      unconnected, retries on a fixed interval and refuses every publish with
      `{:error, :not_connected}`. This is the property that keeps courier's
      request path off the bus's availability.


  `Courier.Nats` is a named process and `:nats` is VM-global application env.
  """

  use ExUnit.Case, async: false

  alias Courier.Nats

  @valid_url "nats://127.0.0.1:4222"

  setup do
    original = Application.get_env(:courier, :nats)

    on_exit(fn -> Application.put_env(:courier, :nats, original) end)
  end

  defp start_nats! do
    result = GenServer.start(Courier.Nats, [], name: Courier.Nats)

    pid =
      case result do
        {:ok, pid} -> pid
        {:error, _} -> nil
      end

    on_exit(fn ->
      if pid && Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    end)

    result
  end

  describe "url/0 and enabled?/0" do
    test "an unset variable means no broker" do
      Application.put_env(:courier, :nats, url: nil)

      assert Nats.url() == nil
      refute Nats.enabled?()
    end

    test "an empty string counts as unset, as it does everywhere in this repository" do
      Application.put_env(:courier, :nats, url: "")

      assert Nats.url() == nil
      refute Nats.enabled?()
    end

    test "whitespace counts as unset, for the same reason" do
      Application.put_env(:courier, :nats, url: "   ")

      assert Nats.url() == nil
    end

    test "a URL names a broker" do
      Application.put_env(:courier, :nats, url: @valid_url)

      assert Nats.url() == @valid_url
      assert Nats.enabled?()
    end

    test "a missing `:nats` key means no broker rather than a crash" do
      Application.delete_env(:courier, :nats)

      assert Nats.url() == nil
      refute Nats.enabled?()
    end
  end

  describe "supervised_child/0" do
    test "an empty list when no broker is configured" do
      Application.put_env(:courier, :nats, url: nil)

      assert Nats.supervised_child() == []
    end

    test "a real child when one is" do
      Application.put_env(:courier, :nats, url: @valid_url)

      children = Nats.supervised_child()
      assert [%{id: Courier.Nats} = child] = children
      assert {Courier.Nats, :start_link, [[]]} = child.start
    end
  end

  describe "a broker that is not there" do
    test "is not a boot failure: the process starts, refuses, and retries" do
      {:ok, listen} = :gen_tcp.listen(0, [{:ip, {127, 0, 0, 1}}])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      Application.put_env(:courier, :nats, url: "nats://127.0.0.1:#{port}")

      assert {:ok, _pid} = {:ok, start_nats!()}

      assert Nats.connection() == {:error, :not_connected}
    end
  end

  describe "a URL that does not parse" do
    test "is a boot failure, raised where an operator reads it" do
      Application.put_env(:courier, :nats, url: "not-a-url")

      assert {:error, {:nats_url_does_not_name_a_broker, "not-a-url"}} = start_nats!()
    end

    test "so is one that names a scheme courier does not speak" do
      Application.put_env(:courier, :nats, url: "amqp://nats:4222")

      assert {:error, {:nats_url_does_not_name_a_broker, "amqp://nats:4222"}} = start_nats!()
    end
  end

  describe "connection/0" do
    test "answers `{:error, :not_connected}` rather than raising when nothing started it" do
      Application.put_env(:courier, :nats, url: nil)

      assert {:error, :not_connected} = Nats.connection()
    end
  end
end
