defmodule Courier.TestSupport.MailChannelsServer do
  @moduledoc """
  A REAL HTTP server that speaks the MailChannels send API, in the suite.

  This is the HTTP sibling of `Courier.TestSupport.SmtpServer`, and it exists
  for the same reason: the failure the Cloudflare adapter work was written
  against is invisible to a test that stops one layer short. A mock provider
  proves the mock works; a courier whose adapter could not reach anything
  looked exactly like a courier that worked. So the send under test is real
  in every part that matters:

    * a real HTTP listener on the loopback interface, on a port the kernel
      picks (`port: 0`, read back with `ThousandIsland.listener_info/1`);
    * a real `POST` parsed by a real Plug pipeline under Bandit, the same
      server Phoenix itself runs on;
    * the real `Courier.Adapters.CloudflareEmail` posting through the real
      `Swoosh.ApiClient.Req` client.

  ## Why the response is configurable

  The adapter's reason to exist is that a provider REFUSING the send is
  surfaced as `{:error, _}` rather than vanishing. A server that always
  answers `202` cannot prove that. So the status and body are set per test
  with `set_response/3`, and every refusal shape MailChannels documents —
  `400` malformed, `403` unauthorized, `500` transient — is a response the
  test can ask for.

  ## How a test reads what arrived

  The request is handled by a Plug process unrelated to the test process, so
  the test cannot `assert_receive` what it saw. Every request is written to an
  ETS table owned by this server, and `requests/1` / `take/1` read it back —
  the same shape `SmtpServer` uses. `take/1` clears as it reads, so two
  assertions in one test cannot both be satisfied by one request.

  The response configuration lives in a SECOND table, so `take/1` clearing
  the requests cannot discard what the server is meant to answer.
  """

  use GenServer

  @requests_table :courier_mailchannels_requests
  @response_table :courier_mailchannels_response

  @typedoc "One request as the server received it on the wire."
  @type received :: %{
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @doc """
  Start a server and return `{pid, port}`.

  The port is chosen by the kernel (`port: 0`) and read back from
  ThousandIsland — see the moduledoc. The returned pid is a normal linked
  GenServer, so it dies with the test that started it.
  """
  @spec start_link(keyword()) :: {:ok, pid(), :inet.port_number()} | {:error, term()}
  def start_link(options \\ []) do
    case GenServer.start_link(__MODULE__, options) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :port)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The port the server is listening on."
  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Every request the server has received, oldest first. Does not clear."
  @spec requests(pid()) :: [received()]
  def requests(server), do: GenServer.call(server, :requests)

  @doc "The requests received so far, clearing the table."
  @spec take(pid()) :: [received()]
  def take(server), do: GenServer.call(server, :take)

  @doc """
  Set the status and body the server answers every request with.

  The body is a binary and is sent as `application/json`. A test sets this
  before the send it is about to make, so the adapter sees the refusal it is
  meant to surface.
  """
  @spec set_response(pid(), pos_integer(), String.t()) :: :ok
  def set_response(server, status, body), do: GenServer.call(server, {:set_response, status, body})

  @impl true
  def init(options) do
    :ets.new(@requests_table, [:named_table, :public, :ordered_set])
    :ets.new(@response_table, [:named_table, :public])

    :ets.insert(@response_table, {:response, 202, ~s({"request_id":"test-request","results":[]})})

    port = Keyword.get(options, :port, 0)

    case Bandit.start_link(
           scheme: :http,
           port: port,
           ip: {127, 0, 0, 1},
           plug: {__MODULE__.Plug, [table: @requests_table, response_table: @response_table]},
           startup_log: :debug
         ) do
      {:ok, pid} ->
        {:ok, {_address, bound_port}} = ThousandIsland.listener_info(pid)
        {:ok, %{pid: pid, port: bound_port}}

      {:error, reason} ->
        :ets.delete(@requests_table)
        :ets.delete(@response_table)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, %{port: port} = state), do: {:reply, port, state}

  def handle_call(:requests, _from, state), do: {:reply, read_all(), state}

  def handle_call(:take, _from, state) do
    all = read_all()
    :ets.delete_all_objects(@requests_table)
    {:reply, all, state}
  end

  def handle_call({:set_response, status, body}, _from, state) do
    :ets.insert(@response_table, {:response, status, body})
    {:reply, :ok, state}
  end

  defp read_all do
    @requests_table
    |> :ets.tab2list()
    |> Enum.map(fn {_sequence, request} -> request end)
  end

  @impl true
  def terminate(_reason, _state) do
    :ets.delete(@requests_table)
    :ets.delete(@response_table)
    :ok
  end

  # --------------------------------------------------------------------------
  # The Plug pipeline.
  #
  # One function: read the body, record the request, answer with whatever the
  # test configured. It is deliberately not a router — every path is the
  # send endpoint as far as this server is concerned, and a test that posts
  # to the wrong path is a test whose adapter is misconfigured.
  # --------------------------------------------------------------------------

  defmodule Plug do
    @moduledoc false

    # `Elixir.Plug.Conn`, not `Plug.Conn`: inside this nested module the name
    # `Plug` resolves to `Courier.TestSupport.MailChannelsServer.Plug` itself,
    # so a bare `import Plug.Conn` looks for a submodule of the test server
    # and fails to compile. The `Elixir.` prefix forces the top-level lookup.
    import Elixir.Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      :ets.insert(opts[:table], {
        :erlang.unique_integer([:monotonic, :positive]),
        %{
          method: conn.method,
          path: conn.request_path,
          headers: conn.req_headers,
          body: body
        }
      })

      [{:response, status, response_body}] = :ets.lookup(opts[:response_table], :response)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, response_body)
    end
  end
end
