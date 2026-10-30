defmodule Courier.TestSupport.FailingSink do
  @moduledoc """
  A `Courier.ErrorRelay.Sink` that fails in **both** of the ways a real one can,
  because they fail differently and the relay has to survive each.

    * `raise/1` — the bug. An exception out of the HTTP client, a bad TLS
      certificate, a `Req` call that raises rather than returning. This is the
      one that would take the relay down if the forwarding were not wrapped.
    * `{:error, reason}` — the ordinary case. A 503 from GlitchTip, a DNS
      failure, a refused connection. Nothing is exceptional about it and it must
      not be logged as though it were.

  Both are counted in the same `sink_failures` stat, deliberately: the counter is
  a health signal for the error path, and a health signal that distinguishes
  "GlitchTip said no" from "our own client has a bug" is a second counter
  somebody has to remember to look at. The distinction is in the log line's
  level, not in the metric's shape.
  """

  @behaviour Courier.ErrorRelay.Sink

  @impl Courier.ErrorRelay.Sink
  def forward(_envelope, opts) do
    notify(opts)
    fail(opts)
  end

  defp notify(opts) do
    case Keyword.get(opts, :sink_target) do
      pid when is_pid(pid) -> send(pid, {:sink_attempted, mode(opts)})
      _absent -> :ok
    end
  end

  defp fail(opts) do
    case mode(opts) do
      :raise -> raise "the sink is unreachable"
      :error -> {:error, :econnrefused}
    end
  end

  defp mode(opts), do: Keyword.get(opts, :sink_mode, :raise)
end
