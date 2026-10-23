defmodule Courier.Consumers.Subject do
  @moduledoc """
  The NATS subject an event is delivered on, which is **the event's type**, with
  no mapping table between them.

  This is a one-line module and it is not one line of logic — it is a one-line
  module because the rule it exists to hold is a rule the code cannot show. Core
  fixes it in `Courier.Events` for the publishing side already ("the `type` is
  the subject, with no mapping table between them"), and `Courier.Workers.
  ProcessOutboxWorker` publishes on `event.type` for the same reason. This is
  the consuming half, so the two halves cannot drift.

  **Why it takes an atom as well as a string.** A subscription's delivery is
  whatever the subscriber's callback was handed, and a type read from a job's
  args or a config map is an atom in half the paths and a string in the other
  half. `to_string/1` on the way in means the registry — which is keyed by the
  strings in `anywaye.yml` — has exactly one key shape, and a type arriving as an
  atom is not silently unhandled.
  """

  @doc """
  The subject `type` is delivered on, which is `type`.
  """
  @spec for(String.t() | atom()) :: String.t()
  def for(type), do: to_string(type)
end
