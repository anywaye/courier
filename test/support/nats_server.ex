defmodule Courier.TestSupport.NatsServer do
  @moduledoc """
  A real NATS broker, as much of one as a publish needs, on a kernel-assigned
  loopback port.

  This is the SMTP server's job again (`test/support/smtp_server.ex`): courier's
  proof that a send reaches a provider is a real conversation over a real socket,
  and the proof that an outbox row reaches the bus is the same shape. What is
  under test is `Courier.NatsPublisher.Bus` and a real `Gnat` connection talking
  a real protocol — so what stands in for the broker has to speak it back.

  It implements exactly the ops the publish path uses, and nothing else:

    * `INFO` on connect, because gnat's `Gnat.Handshake.perform_handshake/2`
      waits one second for it and then sends `CONNECT`;
    * `PING` → `PONG`, which is the only thing a connected server must answer;
    * `SUB` — accepted and unanswered, as a real broker does;
    * `PUB <subject> [reply-to] <bytes>` — recorded, and answered with the
      JetStream publish ack when the message carries a reply-to.


  Because that ack is the whole argument of the packet. `published_at` is set
  from the publisher's answer, and this server answers with the body the broker
  really sends:

      {"type":"io.nats.jetstream.api.v1.publish_ack_response",
       "stream":"anywaye","seq":1,"duplicate":false}

  A refusal is answered with the same envelope shape carrying `error`, so the
  `Broker refuses the publish` test is driving the publisher against the bytes a
  broker in that state sends rather than against a symbol this suite invented.


  It is not a JetStream implementation. No stream is checked, no retention is
  enforced and no message is stored: `published/1` is the store. A second
  connection is refused rather than queued, because gnat's connection is started
  once per test and a second one means a test is leaking a process.

  The whole thing is a test support module and it is not reachable from the
  application: nothing in `lib/` names it.
  """

  use GenServer

  require Logger

  @ack_body ~s({"type":"io.nats.jetstream.api.v1.publish_ack_response",) <>
              ~s("stream":"anywaye","seq":1,"duplicate":false})

  @doc """
  Starts the broker on a kernel-assigned loopback port.

  Options:

    * `:ack` — the body answered to a publish that carries a reply-to. Defaults
      to a JetStream publish ack; a test that needs the broker to refuse passes
      its own.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @doc "Stops the broker, which closes every connection it accepted."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc "The port the broker is listening on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc """
  Every publish the broker received, oldest first, as
  `%{subject: subject, reply_to: reply_to | nil, payload: payload}`.
  """
  @spec published(GenServer.server()) :: [map()]
  def published(server), do: GenServer.call(server, :published)

  @doc "The subjects published to, in order."
  @spec subjects(GenServer.server()) :: [String.t()]
  def subjects(server), do: Enum.map(published(server), & &1.subject)

  @doc """
  Every live subscription on this broker, as `%{sid: sid, subject: subject}`,
  oldest first.

  The consumer packet's assertion is on this: the subscriber subscribes to the
  **prefix** (`identity.>`), and a subscription to four exact types would be
  the failure the moduledoc describes.
  """
  @spec subscriptions(GenServer.server()) :: [map()]
  def subscriptions(server), do: GenServer.call(server, :subscriptions)

  @doc "Whether anything was published to `subject`."
  @spec published?(GenServer.server(), String.t()) :: boolean()
  def published?(server, subject), do: Enum.any?(published(server), &(&1.subject == subject))

  @doc """
  Answers the broker to refuse the next publish.

  A test that needs a refusal passes `ack:` at start; this is for the case where
  the decision is made after the connection is up.
  """
  @spec refuse_next(GenServer.server(), String.t()) :: :ok
  def refuse_next(server, body) do
    GenServer.cast(server, {:refuse_next, body})
  end

  @impl GenServer
  def init(opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        backlog: 4,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    send(self(), :accept)

    {:ok,
     %{
       listen: listen,
       port: port,
       socket: nil,
       buffer: "",
       published: [],
       subscriptions: [],
       ack: Keyword.get(opts, :ack, @ack_body),
       refusal: nil
     }}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:published, _from, state), do: {:reply, state.published, state}
  def handle_call(:subscriptions, _from, state), do: {:reply, state.subscriptions, state}

  @impl GenServer
  def handle_cast({:refuse_next, body}, state), do: {:noreply, %{state | refusal: body}}

  @impl GenServer
  def handle_info(:accept, %{listen: listen} = state) do
    case :gen_tcp.accept(listen, 0) do
      {:ok, socket} ->
        {:noreply, connect(socket, state)}

      {:error, :timeout} ->
        Process.send_after(self(), :accept, 10)
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    {publishes, state} = parse(state.buffer <> data, state)

    for publish <- publishes do
      send(self(), {:publish_ack, publish})
    end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:noreply, %{state | socket: nil, buffer: ""}}
  end

  def handle_info({:tcp_error, _socket, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp connect(socket, state) do
    :inet.setopts(socket, active: :once)

    :ok =
      :gen_tcp.send(
        socket,
        ~s(INFO {"server_id":"courier-test-nats","server_name":"courier-test",) <>
          ~s("version":"2.10.24","host":"127.0.0.1","port":
          ~s("headers":true,"max_payload":1048576,"proto":1,"client_id":1}) <> "\r\n"
      )

    %{state | socket: socket, buffer: ""}
  end

  defp parse(buffer, state), do: parse(buffer, [], state)

  defp parse("", publishes, state), do: {Enum.reverse(publishes), state}

  defp parse(buffer, publishes, state) do
    case String.split(buffer, "\r\n", parts: 2) do
      [_incomplete] ->
        {Enum.reverse(publishes), %{state | buffer: buffer}}

      [line, rest] ->
        case handle_op(line, rest, state) do
          {:ok, remainder, state} ->
            parse(remainder, publishes, state)

          {:ok, remainder, publish, state} ->
            parse(remainder, [publish | publishes], state)

          :incomplete ->
            {Enum.reverse(publishes), %{state | buffer: buffer}}
        end
    end
  end

  defp handle_op("PING", rest, state) do
    :ok = :gen_tcp.send(state.socket, "PONG\r\n")
    {:ok, rest, state}
  end

  defp handle_op("PONG", rest, state), do: {:ok, rest, state}
  defp handle_op("+OK", rest, state), do: {:ok, rest, state}
  defp handle_op("-ERR" <> _err, rest, state), do: {:ok, rest, state}

  defp handle_op("CONNECT" <> _connect, rest, state), do: {:ok, rest, state}

  defp handle_op("SUB " <> sub, rest, state) do
    case String.split(sub, " ") do
      [subject, sid] ->
        {sid, ""} = Integer.parse(sid)
        subscriptions = state.subscriptions ++ [%{sid: sid, subject: subject}]

        {:ok, rest, %{state | subscriptions: subscriptions}}

      _ ->
        Logger.warning("nats server: unreadable SUB op #{inspect(sub)}")
        {:ok, rest, state}
    end
  end

  defp handle_op("UNSUB" <> _unsub, rest, state), do: {:ok, rest, state}

  defp handle_op("PUB " <> args, rest, state) do
    case String.split(args, " ") do
      [subject, reply_to, size] when reply_to != "" ->
        publish(subject, reply_to, size, rest, state)

      [subject, size] ->
        publish(subject, nil, size, rest, state)

      _ ->
        Logger.warning("nats server: unreadable PUB op #{inspect(args)}")
        {:ok, rest, state}
    end
  end

  defp handle_op(other, rest, state) do
    Logger.debug("nats server: ignoring op #{inspect(other)}")
    {:ok, rest, state}
  end

  defp publish(subject, reply_to, size, rest, state) do
    case Integer.parse(size) do
      {size, ""} ->
        case rest do
          <<payload::binary-size(^size), remainder::binary>> ->
            remainder = String.replace_prefix(remainder, "\r\n", "")
            publish = %{subject: subject, reply_to: reply_to, payload: payload}
            state = %{state | published: state.published ++ [publish]}

            if reply_to, do: send_ack(state, reply_to, state.refusal || state.ack)
            state = deliver(state, subject, payload)

            {:ok, remainder, publish, state}

          _ ->
            :incomplete
        end

      :error ->
        Logger.warning("nats server: unreadable PUB size #{inspect(size)}")
        {:ok, rest, state}
    end
  end

  defp send_ack(state, reply_to, body) do
    :ok = :gen_tcp.send(state.socket, "MSG #{reply_to} 0 #{byte_size(body)}\r\n#{body}\r\n")
  end

  defp deliver(state, subject, payload) do
    for sub <- state.subscriptions, matches?(sub.subject, subject) do
      sid = sub.sid

      :ok =
        :gen_tcp.send(
          state.socket,
          "MSG #{subject} #{sid} #{byte_size(payload)}\r\n#{payload}\r\n"
        )
    end

    state
  end

  defp matches?(subscribed, subject) do
    match_tokens(String.split(subscribed, "."), String.split(subject, "."))
  end

  defp match_tokens([">"], [_ | _]), do: true
  defp match_tokens([">"], []), do: false
  defp match_tokens(["*" | rest_sub], [_ | rest_topics]), do: match_tokens(rest_sub, rest_topics)

  defp match_tokens([sub | rest_sub], [topic | rest_topics]),
    do: sub == topic and match_tokens(rest_sub, rest_topics)

  defp match_tokens([], []), do: true
  defp match_tokens(_sub, _topics), do: false
end
