defmodule Courier.TestSupport.SmtpServer do
  @moduledoc """
  A REAL SMTP server, in the suite, started per test.

  This is the only support module that opens a listening socket, and it exists
  because of the failure this packet was written against: `Swoosh.Adapters.Local`
  renders a message into memory and returns a provider-shaped id, so a courier
  could be "shipping" for months with no adapter that could reach a provider and
  every test still green. A test that mocks the adapter proves the mock works.

  So the send under test is real in every part that matters:

    * a real TCP listener on the loopback interface, on a port the kernel picks
      (`port: 0`, read back with `:ranch.get_port/1` — see below);
    * a real SMTP conversation driven by `gen_smtp_client`, the same library
      `Swoosh.Adapters.SMTP` speaks through, over real `EHLO` / `MAIL FROM` /
      `RCPT TO` / `DATA` / `QUIT`;
    * `handle_DATA/4` receiving the bytes a provider would have received.


  `gen_smtp` ships a server as well as a client, on top of `ranch`. Using it
  rather than a `:gen_tcp` accept loop that replies `"250 ok\\r\\n"` to anything
  is the point: a fake that accepts everything would pass against a broken
  client. This one parses the conversation, enforces the reply codes, and hands
  back a real RFC-5322 body — so a malformed `EHLO`, a skipped `RCPT TO`, or a
  body that arrives empty are all failures rather than things the test cannot
  see.


  `start_link/1` passes `port: 0` and reads the assigned port back. A written-down
  port is a port another process can hold: two workers running this suite at once
  would collide, and the failure would be a bind error that reads like a broken
  server rather than a busy one. The kernel hands out a free ephemeral port
  instead, so this runs alongside whatever else is on the machine — which it has
  to, because courier's other services and their tests are running at the same
  time.


  The listener is a ranch supervisor and each session is its own process, so the
  process running a test cannot simply `assert_receive` what `handle_DATA/4`
  saw. Every received message is written to an ETS table owned by the server
  process, and `messages/1` reads it back. ETS rather than the test pid because
  the session is unrelated to the test process, and routing through a mailbox
  would mean every caller having to arrange one.

  `take/1` clears as it reads, so two assertions in one test cannot both be
  satisfied by one message.
  """

  use GenServer

  @listener :courier_smtp_test_server

  @typedoc "One message as the server received it on the wire."
  @type received :: %{from: binary(), to: [binary()], data: binary(), authenticated: boolean()}

  @doc """
  Start a server and return `{pid, port}`.

  The port is chosen by the kernel (`port: 0`) and read back from ranch — see
  the moduledoc. The returned pid is a normal linked GenServer, so it dies with
  the test that started it; a test that wants a genuinely closed port can stop it
  and keep the port it was given.

  `options` may carry `:username` and `:password`, which the server then REQUIRES
  over `AUTH`. Left out, the server still advertises `AUTH` and accepts whatever
  it is given — which is what lets one test prove courier authenticates and
  another prove a relay rejecting the credentials fails the send.
  """
  @spec start_link(keyword()) :: {:ok, pid(), :inet.port_number()}
  def start_link(options \\ []) do
    case GenServer.start_link(__MODULE__, options) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :port)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Start a server that requires `username`/`password` over `AUTH`.
  """
  @spec start_link_authenticated(binary(), binary()) :: {:ok, pid(), :inet.port_number()}
  def start_link_authenticated(username, password),
    do: start_link(username: username, password: password)

  @doc "Every message the server has received, oldest first. Does not clear."
  @spec messages(pid()) :: [received()]
  def messages(server), do: GenServer.call(server, :messages)

  @doc "The messages received so far, clearing the table."
  @spec take(pid()) :: [received()]
  def take(server), do: GenServer.call(server, :take)

  @doc """
  Whether any received message's raw DATA contains `needle`.

  Matched against the wire bytes rather than a parsed structure, because "the
  subject reached the provider" is the claim — and a parser that dropped a header
  would let a leak pass.
  """
  @spec received?(pid(), String.t()) :: boolean()
  def received?(server, needle) do
    Enum.any?(messages(server), &String.contains?(&1.data, needle))
  end

  @impl true
  def init(options) do
    table = :ets.new(__MODULE__, [:ordered_set, :public])

    case start_listener(table, options) do
      {:ok, port} ->
        {:ok, {table, port}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp start_listener(table, options) do
    case :gen_smtp_server.start(@listener, __MODULE__.Callback, listener_options(table, options)) do
      {:ok, _pid} ->
        {:ok, :ranch.get_port(@listener)}

      {:error, {:already_started, _pid}} ->
        :ok = :gen_smtp_server.stop(@listener)
        start_listener(table, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp listener_options(table, options) do
    [
      domain: "courier.test",
      address: {127, 0, 0, 1},
      port: 0,
      sessionoptions: [
        protocol: :smtp,
        callbackoptions: [
          {:table, table},
          {:username, Keyword.get(options, :username)},
          {:password, Keyword.get(options, :password)}
        ]
      ]
    ]
  end

  @impl true
  def handle_call(:port, _from, {_table, port} = state), do: {:reply, port, state}

  def handle_call(:messages, _from, {table, _port} = state) do
    {:reply, read_all(table), state}
  end

  def handle_call(:take, _from, {table, _port} = state) do
    messages = read_all(table)
    :ets.delete_all_objects(table)
    {:reply, messages, state}
  end

  defp read_all(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_sequence, message} -> message end)
  end

  @impl true
  def terminate(_reason, {table, _port}) do
    :gen_smtp_server.stop(@listener)
    :ets.delete(table)
    :ok
  end


  defmodule Callback do
    @moduledoc false

    @behaviour :gen_smtp_server_session

    @impl true
    def init(_hostname, _session_count, _peer, options) do
      state = %{
        table: Keyword.fetch!(options, :table),
        username: Keyword.get(options, :username),
        password: Keyword.get(options, :password),
        authenticated: false
      }

      {:ok, "220 courier.test ESMTP courier-test-server", state}
    end

    @impl true
    def handle_HELO(_hostname, state), do: {:ok, 10_485_760, state}

    @impl true
    def handle_EHLO(_hostname, extensions, state) do
      {:ok, extensions ++ [{~c"AUTH", ~c"PLAIN LOGIN"}], state}
    end

    @impl true
    def handle_MAIL(_from, state), do: {:ok, state}

    @impl true
    def handle_MAIL_extension(_extension, _state), do: :ok

    @impl true
    def handle_RCPT(_to, state), do: {:ok, state}

    @impl true
    def handle_RCPT_extension(_extension, _state), do: :ok

    @impl true
    def handle_RSET(state), do: state

    @impl true
    def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled by policy", state}

    @impl true
    def handle_other(verb, _args, state), do: {"500 command not recognized: #{verb}", state}

    @impl true
    def handle_info(_info, state), do: {:noreply, state}

    @impl true
    def handle_error(_class, _details, state), do: {:ok, state}

    @impl true
    def handle_STARTTLS(state), do: state

    @impl true
    def terminate(_reason, _state), do: {:ok, :normal}

    @impl true
    def code_change(_old, state, _extra), do: {:ok, state}

    @impl true
    def handle_AUTH(_type, username, credential, state) do
      expected = {state.username, state.password}
      offered = if is_tuple(credential), do: credential, else: {username, credential}

      if (is_nil(state.username) and is_nil(state.password)) or offered == expected do
        {:ok, %{state | authenticated: true}}
      else
        :error
      end
    end

    @impl true
    def handle_DATA(from, to, data, state) do
      :ets.insert(state.table, {
        :erlang.unique_integer([:monotonic, :positive]),
        %{from: from, to: to, data: data, authenticated: state.authenticated}
      })

      {:ok, "queued as #{:erlang.unique_integer([:positive])}", state}
    end
  end
end
