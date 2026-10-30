defmodule Courier.StartupNotices do
  @moduledoc """
  The operator-facing notices `config/runtime.exs` composes, emitted once the
  logger can actually carry them.


  `config/runtime.exs` finished with a `Logger.info/1` on the resolved mail
  adapter and a `Logger.warning/1` when no inbound provider is configured. Both
  look right and neither reaches a release's log: **the release's boot script
  evaluates `config/runtime.exs` before the `:logger` application is up**, so
  the call has no handler to go to and the line is dropped with no error, no
  warning and no clue. Measured on two live boxes:

      kubectl logs | grep -c 'mailer:\|inbound:'   ->  0   (fresh install, 32 lines)
      kubectl logs | grep -c 'mailer:\|inbound:'   ->  0   (a box up for days, 544 lines)

  On the same boxes the running node's own state was correct — `adapter:
  Courier.Adapters.CloudflareEmail` and `inbound_secrets: %{}` — so this is a
  visibility defect rather than a configuration one. It is the trap the next
  reader will walk into: a `Logger.*` call in that file reads as a startup line
  and is a write to nothing.


  Because the failure is about WHEN `config/runtime.exs` is evaluated relative
  to the logger, no arrangement of `Logger.*` inside it can work. So the notice
  is **composed** there — where the environment and the resolved adapter are
  already in hand — and carried in application env to `log_startup/0`, which
  `Courier.Application.start/2` calls. `:logger` is named in `mix.exs`'s
  `extra_applications`, so it is up before courier's own supervisor starts, and
  a call from `courier start` reaches it.

  That is this repository's existing idiom rather than a second one: `Courier.
  Nats.log_startup/0` and `Courier.Telemetry.log_startup/0` are called from the
  same place, for the same reason, and carry the same comment.


  The mailer notice is `Courier.MailerAdapter.describe/1`'s output, which names
  the relay and whether auth is on and never the username or password; the
  inbound notice names which provider is configured and never the secret. Both
  rules are held where the notice is composed (`Courier.ReleaseMigrateConfigTest`)
  and where the descriptions are rendered (`Courier.MailerAdapterCredentialsTest`).
  """

  require Logger

  @doc """
  Emits every composed notice once, at the level it was composed with.

  Reads `:startup_notices` — a list of `{Logger.level(), String.t()}` built by
  `config/runtime.exs` — and is a no-op when there is none, which is the state in
  `:test` and `:dev`: only `:prod` composes them.

  A call from `Courier.Application.start/2` is the one caller. It writes to the
  log the operator reads, which `config/runtime.exs` cannot.
  """
  @spec log_startup() :: :ok
  def log_startup do
    :courier
    |> Application.get_env(:startup_notices)
    |> List.wrap()
    |> Enum.each(fn {level, message} -> Logger.log(level, message) end)

    :ok
  end
end
