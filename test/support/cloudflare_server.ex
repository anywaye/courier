defmodule Courier.TestSupport.CloudflareServer do
  @moduledoc """
  A REAL HTTP server that speaks the Cloudflare Email Sending API, in the suite.

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


  The adapter's reason to exist is that a provider REFUSING the send is
  surfaced as `{:error, _}` rather than vanishing. A server that always
  answers success cannot prove that. So the status and body are set per test
  with `set_response/3`, and every refusal shape Cloudflare documents —
  `400` invalid, `401` unauthorized, `403` forbidden, `429` throttled, `500`
  internal — is a response the test can ask for. The 2xx failure channel
  (`permanent_bounces`, `suppressed_recipients`, `success: false`) is the
  critical one: it arrives under a 2xx and must still be an error.


  The request is handled by a Plug process unrelated to the test process, so
  the test cannot `assert_receive` what it saw. Every request is written to an
  ETS table owned by this server, and `requests/1` / `take/1` read it back —
  the same shape `SmtpServer` uses. `take/1` clears as it reads, so two
  assertions in one test cannot both be satisfied by one request.

  The response configuration lives in a SECOND table, so `take/1` clearing
  the requests cannot discard what the server is meant to answer.


  Both tables are created in `init/1` against THIS process, unnamed. An ETS
  name is a VM-wide registration, so a named table here made the harness
  collide with itself: a server is linked to the test process that started it,
  the link is severed ASYNCHRONOUSLY when that test exits, and a second test
  that starts a server in that window called `:ets.new(:named_table)` on a name
  that already existed and died with `ArgumentError`. Measured on the whole
  suite with `--seed 218080` under load — `a provider that refuses the send is
  surfaced` failed at `init/1`, in a test whose own file starts no server at
  all. The name was the defect; the test order was only the trigger. So the
  table descriptor is held in this server's STATE, `requests/1` and `take/1`
  read it back through the process, and the Plug is handed it in its options —
  no name to collide on, however many servers are alive at once, and the
  response table is per-server too (it used to be shared, so one server's
  `set_response/3` silently changed another's answer).
  """

  use GenServer

  @requests_label :courier_cloudflare_requests
  @response_label :courier_cloudflare_response

  @default_body ~s({"success":true,"errors":[],"messages":[],"result":{"delivered":["test@example.com"],"permanent_bounces":[],"queued":[],"suppressed_recipients":[]}})

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
  def set_response(server, status, body),
    do: GenServer.call(server, {:set_response, status, body})

  @impl true
  def init(options) do
    requests = :ets.new(@requests_label, [:public, :ordered_set])
    response = :ets.new(@response_label, [:public])

    :ets.insert(response, {:response, 200, @default_body})

    port = Keyword.get(options, :port, 0)

    case Bandit.start_link(
           scheme: :http,
           port: port,
           ip: {127, 0, 0, 1},
           plug: {__MODULE__.Plug, [table: requests, response_table: response]},
           startup_log: false
         ) do
      {:ok, pid} ->
        {:ok, {_address, bound_port}} = ThousandIsland.listener_info(pid)
        {:ok, %{pid: pid, port: bound_port, requests: requests, response: response}}

      {:error, reason} ->
        :ets.delete(requests)
        :ets.delete(response)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, %{port: port} = state), do: {:reply, port, state}

  def handle_call(:requests, _from, state), do: {:reply, read_all(state.requests), state}

  def handle_call(:take, _from, state) do
    all = read_all(state.requests)
    :ets.delete_all_objects(state.requests)
    {:reply, all, state}
  end

  def handle_call({:set_response, status, body}, _from, state) do
    :ets.insert(state.response, {:response, status, body})
    {:reply, :ok, state}
  end

  defp read_all(requests) do
    requests
    |> :ets.tab2list()
    |> Enum.map(fn {_sequence, request} -> request end)
  end

  @impl true
  def terminate(_reason, %{requests: requests, response: response}) do
    :ets.delete(requests)
    :ets.delete(response)
    :ok
  end


  defmodule Plug do
    @moduledoc false

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

      {status, response_body} =
        cond do
          contains_email_key?(body) ->
            {400,
             ~s({"success":false,"errors":[{"code":10001,"message":"email.sending.error.invalid_request_schema"}],"messages":[],"result":null})}

          has_message_id_header?(body) ->
            {400,
             ~s({"success":false,"errors":[{"code":10202,"message":"email.sending.error.email.invalid"}],"result":null})}

          true ->
            [{:response, s, b}] = :ets.lookup(opts[:response_table], :response)
            {s, b}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, response_body)
    end

    defp contains_email_key?(body) do
      case Jason.decode(body) do
        {:ok, decoded} when is_map(decoded) ->
          Enum.any?(["from", "to", "cc", "bcc", "reply_to"], fn field ->
            case Map.get(decoded, field) do
              nil -> false
              value -> address_value_has_email_key?(value)
            end
          end)

        _ ->
          false
      end
    end

    defp address_value_has_email_key?(value) when is_map(value), do: Map.has_key?(value, "email")

    defp address_value_has_email_key?(value) when is_list(value),
      do: Enum.any?(value, &address_value_has_email_key?/1)

    defp address_value_has_email_key?(_), do: false

    defp has_message_id_header?(body) do
      case Jason.decode(body) do
        {:ok, %{"headers" => headers}} when is_map(headers) ->
          Enum.any?(Map.keys(headers), &(String.downcase(&1) == "message-id"))

        _ ->
          false
      end
    end
  end
end
