defmodule Courier.TestSupport.Clock do
  @moduledoc """
  A monotonic millisecond clock a test can move, and the only reason
  `Courier.ErrorRelay`'s throttle is testable without waiting.


  A token bucket's behaviour lives in the *shape* of its refill schedule — one
  token per `60_000 / per_minute` milliseconds, capped at `burst` — and a wall
  clock can only demonstrate that by living through it. Asserting "sixty seconds
  later there is one more token" by sleeping sixty seconds is a test that takes
  a minute, and it is the reason a schedule like this gets asserted only by
  "time passed, something happened", which is not the claim.

  So `Courier.ErrorRelay` takes `now: (() -> integer)`. In the application tree
  it is `System.monotonic_time(:millisecond)`, read once per event; here it is
  this process.


  A named `Agent`, so two tests moving the clock at once would make every refill
  assertion depend on the interleaving. `Courier.ErrorRelayTest` is
  `async: false` and says why in its own moduledoc. Each test starts its own via
  `start_supervised!/1`, so the name is released when the test ends and no test
  sees another's clock.
  """

  use Agent

  @doc "Start at zero. A test that needs a non-zero start advances to it."
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> 0 end, name: __MODULE__)
  end

  @doc "The current time, in the relay's units: integer milliseconds."
  def now, do: Agent.get(__MODULE__, & &1)

  @doc "Move the clock forward. There is no `set/1`: every test here moves time, none invents it."
  def advance(milliseconds), do: Agent.update(__MODULE__, &(&1 + milliseconds))
end
