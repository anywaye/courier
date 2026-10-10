defmodule Courier.NatsPublisher.Unconfigured do
  @moduledoc """
  The publisher a courier with no `NATS_URL` publishes through, which is a
  refusal rather than a stand-in.

  `Courier.NatsPublisher.Noop` answers `:ok` and hands the envelope to the
  calling process. That is right where it is configured — `config/test.exs`, and
  nowhere else. `config/runtime.exs` puts **this** module in the application env
  when `NATS_URL` is unset, and the difference between the two is the whole
  point:

  | | answer | effect on the row |
  | --- | --- | --- |
  | `Noop` | `:ok` | marked `published_at`, and the event went nowhere |
  | `Unconfigured` | `{:error, :nats_url_not_set}` | `last_error` records why, `published_at` stays `nil` |

  identity states the argument in `internal/outbox/publisher.go` and courier
  matches it rather than re-deriving it:

      What it is NOT is the shipped publisher. Wiring it into the running service
      would mark every event published and drain the outbox into nowhere, which
      is worse than the honest accumulation an unconfigured broker produces: the
      rows are the promise, and a promise this process keeps by discarding is
      not a promise.

  So the unconfigured shape is: **no connection process**
  (`Courier.Nats.supervised_child/0` answers `:ignored`), **no relay of its own
  started**, and rows accumulating in `outbox_events` until a broker is
  configured and courier restarts. Every row keeps its `attempt_count` bounded by
  the relay's cap, so an outbox nobody drains is eventually visible as a stuck
  row rather than an infinite retry loop.

  The reason this module exists at all — rather than configuring nothing and
  letting `Courier.NatsPublisher.impl/0` fall through to its `Noop` default —
  is that the default is the *test* double. A publisher whose default is the
  test double is a deployment that drains the outbox into nowhere the first
  time somebody forgets a config key, which is the identical failure wearing a
  different hat.
  """

  @behaviour Courier.NatsPublisher

  @impl Courier.NatsPublisher
  @spec publish(Courier.NatsPublisher.envelope()) :: {:error, :nats_url_not_set}
  def publish(_envelope), do: {:error, :nats_url_not_set}
end
