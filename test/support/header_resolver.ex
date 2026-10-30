defmodule Courier.TestSupport.HeaderResolver do
  @moduledoc """
  A `Courier.Principal.Resolver` that reads the account from a request header.

  It is a stand-in for the JWT verifier identity's packet will provide, and it is
  only ever the configured resolver in test (`config/test.exs`). In any other
  configuration `Courier.Principal.Reject` answers instead, so a courier that has
  not been told about this module cannot be authenticated by one.

  What it deliberately does *not* do is check a signature. A header a caller sets
  is a claim, not a proof, and the tests that use this are about the authorization
  matrix — which account may do what to which endpoint — not about proving who the
  caller is. Those are separate questions and this answers the first one.
  """

  @behaviour Courier.Principal.Resolver

  @impl Courier.Principal.Resolver
  def resolve(conn) do
    case conn |> Plug.Conn.get_req_header(CourierWeb.Plugs.Principal.account_header()) do
      [account_id] -> build(account_id)
      _missing_or_ambiguous -> :error
    end
  end

  defp build(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, uuid} -> {:ok, %Courier.Principal{account_id: uuid, subject: "test"}}
      :error -> :error
    end
  end
end
