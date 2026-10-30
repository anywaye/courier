defmodule Courier.TestSupport.CloudflareServerTest do
  @moduledoc """
  The harness holds two servers at once, because no table it creates has a
  global name.

  This file exists for ONE measured failure. On the whole suite with
  `--seed 218080`, `Courier.CloudflareDeliveryTest`'s "a provider that refuses
  the send is surfaced, not swallowed" died inside
  `CloudflareServer.init/1` with `ArgumentError: table name already exists` —
  in a test whose own file starts no server at all, so the failure was the
  harness's rather than the test's. The old `init/1` created
  `:courier_cloudflare_requests` and `:courier_cloudflare_response` as NAMED
  tables, and an ETS name is a VM-wide registration: a server is linked to the
  test process that started it, that link is severed ASYNCHRONOUSLY when the
  test exits, and a second server created inside that window called
  `:ets.new(:named_table)` on a name that already existed. The name was the
  defect; the test order was only the trigger.

  Both tests below fail against the old harness and neither is a race:

    * two servers alive at once collide by construction — the second
      `start_link/1` raised immediately — and the RESPONSE table was global
      too, so one server's `set_response/3` silently changed the other's answer
      (asserted here over real HTTP requests, not over the table);
    * neither server registers a name in the VM, so there is nothing for a
      third one to collide with. This one is asserted on the MECHANISM because
      that is the claim: a change that puts `:named_table` back goes red
      regardless of scheduling, which is more than a seed can promise.

  "A leaked server cannot take down a later test" needs no test of its own: a
  leaked server IS a server that is still alive.
  """
  use ExUnit.Case, async: false

  alias Courier.TestSupport.CloudflareServer

  test "two servers run at once, each answering with its own configured response" do
    {:ok, first, first_port} = CloudflareServer.start_link()
    {:ok, second, second_port} = CloudflareServer.start_link()

    :ok = CloudflareServer.set_response(first, 401, ~s({"refused":"first"}))
    :ok = CloudflareServer.set_response(second, 200, ~s({"accepted":"second"}))

    assert post(first_port, "/accounts/first/email/sending/send").status == 401
    assert post(second_port, "/accounts/second/email/sending/send").status == 200

    assert [first_request] = CloudflareServer.take(first)
    assert [second_request] = CloudflareServer.take(second)

    assert first_request.path == "/accounts/first/email/sending/send"
    assert second_request.path == "/accounts/second/email/sending/send"
  end

  test "a live server registers no global ETS name" do
    {:ok, _server, _port} = CloudflareServer.start_link()

    assert :ets.whereis(:courier_cloudflare_requests) == :undefined
    assert :ets.whereis(:courier_cloudflare_response) == :undefined
  end

  defp post(port, path) do
    Req.post!("http://127.0.0.1:#{port}#{path}",
      body: ~s({"to":{"address":"x@example.com","name":"X"}}),
      decode_body: false
    )
  end
end
