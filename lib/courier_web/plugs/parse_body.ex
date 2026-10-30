defmodule CourierWeb.Plugs.ParseBody do
  @moduledoc """
  `Plug.Parsers`, with courier's answer for a body it cannot parse.

  The only reason this is a module of its own: a body that is not JSON raises
  before the router runs, so the `:api` pipeline is too late to catch it, and the
  default answer would be Phoenix's own rather than the problem+json every other
  error in courier uses. 400 is right, and is core's status convention for
  exactly this: malformed syntax the client could not have known.

  The parser options stay in the endpoint, where the generated application had
  them, and are passed straight through — this plug translates one exception,
  changes nothing else, and **leaves the body of a signed inbound webhook alone**
  so the bytes a signature covers are the bytes that arrive. The detail it reports
  is deliberately short: the parser's own message quotes the body, and a
  repository that is public should not put a request body into a response.
  """

  import Plug.Conn

  alias CourierWeb.Problem
  alias CourierWeb.Router

  def init(opts), do: Plug.Parsers.init(opts)

  def call(conn, opts) do
    if Router.signed_body?(conn.request_path) do
      conn
    else
      Plug.Parsers.call(conn, opts)
    end
  rescue
    _error in Plug.Parsers.ParseError ->
      conn
      |> Problem.send(400, :bad_request, "The request body is not valid JSON.")
      |> halt()
  end
end
