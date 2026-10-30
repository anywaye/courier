defmodule Courier.TestSupport.IntrospectionTransport do
  @moduledoc """
  A `Courier.Principal.Introspection.Transport` that answers from a table.

  Configured as courier's introspection transport in `config/test.exs`, so the
  resolver's tests are assertions about courier's decision and not about a
  socket: what courier sends, what it does with each answer, and what it refuses.

  test in a fresh process. A test that stubs nothing therefore reads "no request
  was made" rather than inheriting an earlier test's answer — which is the way a
  table of recorded requests quietly becomes a table of the previous test's
  requests. A shared ETS table would need an `on_exit` and would reintroduce the
  problem it was meant to solve.


  `requests/0` returns every request the resolver has made **in this process**.
  Process-local rather than an ETS table on purpose: the resolver is called on the
  process that serves the request, the resolver's tests are `async: true`, and a
  shared table would make one test's request the next test's evidence.
  """

  @behaviour Courier.Principal.Introspection.Transport

  @requests :"$introspection_requests"

  defmodule Request do
    @moduledoc """
    One request the resolver made, with the headers as a list of pairs.

    A list of pairs rather than a map because the assertion worth making is on
    ORDER and DUPLICATION: that courier sends exactly one `authorization`, and
    that the one it sends is its own. A map would collapse two same-named headers
    into one and pass an assertion about a request that carried two.
    """
    @enforce_keys [:method, :url, :headers, :body]
    defstruct [:method, :url, :headers, :body]
  end

  @doc """
  Answer every request with `status` and `body`.

  `body` is encoded when it is not a binary, so a test writes a map and the
  transport sends the bytes identity would send.
  """
  def stub(status, body) do
    Process.put(key(), {:answer, status, encode(body)})
  end

  @doc "Answer every request with a dial failure carrying `reason`."
  def fail(reason) do
    Process.put(key(), {:failure, reason})
  end

  @doc "The requests made so far, oldest first."
  @spec requests() :: [Request.t()]
  def requests do
    Process.get(@requests, []) |> Enum.reverse()
  end

  @impl Courier.Principal.Introspection.Transport
  def post(url, headers, body) do
    Process.put(@requests, [
      %Request{method: "POST", url: url, headers: headers, body: body}
      | Process.get(@requests, [])
    ])

    case Process.get(key()) do
      {:answer, status, response} -> {:ok, status, response}
      {:failure, reason} -> {:error, reason}
      nil -> {:error, :unstubbed}
    end
  end

  @doc false
  defp key, do: :"$introspection_answer"

  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: Jason.encode!(body)
end
