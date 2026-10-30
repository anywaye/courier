defmodule Courier.Health do
  @moduledoc """
  Liveness and readiness for courier.

  Liveness is answered by the web layer alone (`GET /healthz`); it says the VM
  is up and the endpoint can dispatch. Readiness (`GET /readyz`) says the
  service can actually do work, which right now means the database answers a
  query.

  Delivery in courier is at-least-once (PLAN.md §3), so a readiness check that
  raises would take out the whole endpoint rather than the one request. Every
  failure mode — repo not started, pool gone, connection refused, auth
  rejected, timeout — is folded into an error tuple here, once.

  How long a failure takes, measured in the release image against
  `postgres:17`: with the repo not running, `ready?/1` raises and returns
  immediately. With a database that went away underneath a running pool, the
  answer waits for the pool to give up — about 4.4s, from DBConnection's queue
  backpressure, not from the query `timeout` below. `:queue_target` and
  `:queue_interval` are pool state rather than per-call options, so a probe
  cannot shorten that without reconfiguring every query in the service. The
  verdict is right either way: an orchestrator whose probe times out reads
  courier as not ready, which is what it is. Leave the pool alone.
  """

  require Logger

  @query "SELECT 1"
  @query_timeout_ms 2_000

  @doc """
  Checks that `repo` answers a trivial query.

  Returns `:ok`, or `{:error, reason}` with the reason logged and never raised.
  The database is a dependency courier cannot work without, so a failed check
  must be visible in the logs even when the HTTP response stays terse.
  """
  @spec ready?(module()) :: :ok | {:error, term()}
  def ready?(repo \\ Courier.Repo) do
    case Ecto.Adapters.SQL.query(repo, @query, [], timeout: @query_timeout_ms) do
      {:ok, _result} -> :ok
      {:error, reason} -> error(reason)
    end
  rescue
    exception -> error(exception)
  catch
    kind, reason -> error({kind, reason})
  end

  defp error(reason) do
    Logger.warning("courier readiness check failed: #{inspect(reason)}")
    {:error, reason}
  end
end
