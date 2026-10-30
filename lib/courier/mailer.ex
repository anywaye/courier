defmodule Courier.Mailer do
  @moduledoc """
  courier's Swoosh mailer.

  It is a thin wrapper on purpose: the adapter is configuration
  (`config :courier, Courier.Mailer, adapter: ...`), so choosing a provider is a
  deploy-time decision and not a code change. `Courier.Mailers` composes the
  messages; this module is the only place that hands one to a provider.


  `Courier.MailerAdapter`. It reads `COURIER_MAIL_ADAPTER` and the
  `COURIER_SMTP_*` variables from `config/runtime.exs`, and it REFUSES rather
  than defaulting: an unset adapter, or one that cannot deliver, stops the boot.

  This module used to carry a comment saying no provider adapter shipped, and
  that dev and prod were both `Swoosh.Adapters.Local`. That was the defect, and
  it was invisible from here — `Local` renders into memory and returns a
  provider-shaped id, so a courier with no way to reach a provider accepted every
  send it was ever given. The module itself needed no change to stop being the
  problem; the configuration around it did.


  `swoosh` declares `gen_smtp` as an OPTIONAL dependency and `Swoosh.Adapters.SMTP`
  declares it as a required one. Naming `swoosh` alone compiles a courier whose
  only shipped adapter is the silent one — which is precisely the state this
  module's old comment described, and which no amount of configuration could
  have fixed.
  """

  use Swoosh.Mailer, otp_app: :courier
end
