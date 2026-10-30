defmodule Courier.TestSupport.SentryTestClient do
  @moduledoc """
  A `Sentry.HTTPClient` that hands the envelope to the test instead of a socket.


  The brief requires a **failing-if-broken** test that no secret reaches a stored
  error, and the only version of that test worth having runs the *real* SDK: real
  `Sentry.Event` construction, real `before_send`, real envelope framing, real
  bytes. Asserting on `Courier.ErrorReporting.Filter` in isolation would prove
  the filter works on a struct the test built by hand, which is the same shape of
  claim as asserting a redaction function works on a map the test wrote: it never
  touches the code that decides what goes into the event in the first place.

  So the boundary of the test is the **transport**, which is the last thing before
  the wire. Everything above it is the SDK's own code, running as it runs in
  production. What is replaced is only the socket.

  And it is a *substitution*, not a mock: this module implements
  `Sentry.HTTPClient` exactly as the behaviour asks, returns a real Sentry
  response body so the SDK's own success path runs, and records the endpoint, the
  headers and the bytes. A test that stubbed the SDK's return value could not
  assert on the bytes, which is the whole assertion.


  `sentry`'s default client is `Sentry.FinchClient`, which needs `finch` — a
  package this repository does not have and this packet is not adding. Naming a
  client here is the SDK's supported seam for exactly that situation, and it is
  why this file is forty lines instead of a Gemfile line.


  The tests configure `COURIER_ERROR_REPORTING_DSN`-shaped DSNs pointing at
  `http://public@relay.test/1`. A DSN pointed at a real third party is the
  misconfiguration `Courier.ErrorReporting.Filter` exists to survive, and a test
  that cannot demonstrate the surviving case cannot claim it.
  """

  @behaviour Sentry.HTTPClient

  @impl Sentry.HTTPClient
  def post(url, headers, body) do
    case :persistent_term.get({__MODULE__, :target}, nil) do
      pid when is_pid(pid) -> send(pid, {:sentry_envelope, url, headers, body})
      _absent -> :ok
    end

    {:ok, 200, [], ~s({"id":"00000000000000000000000000000000"})}
  end

  @doc "Where envelopes are delivered. `:persistent_term` because the SDK has nowhere to pass it."
  def deliver_to(pid), do: :persistent_term.put({__MODULE__, :target}, pid)

  @doc "Stop delivering. Called from `on_exit` so a finished test leaves nothing behind."
  def stop_delivering, do: :persistent_term.erase({__MODULE__, :target})
end
