defmodule Courier.ErrorRelay.Sink.Noop do
  @moduledoc """
  A sink that discards, for a deployment that has a relay and nowhere to send.


  The alternative to this sink is refusing to start. That is the right answer
  for `COURIER_SECRET_BOX_KEY`, where a default would be a key in version
  control — but it is the wrong answer here, for a different reason: **the relay
  is not a security control, it is an observability control.** A courier that
  will not boot because its error store is unreachable has turned a missing
  integration into an outage, and the thing the operator wanted — to know when
  things break — is the thing that broke.

  So a deployment with no `COURIER_ERROR_SINK_DSN` gets this sink, the relay
  runs, the counters in `Courier.ErrorRelay.stats/1` move, and an operator
  watching `forwarded` sees it climbing with nothing arriving anywhere. That is a
  diagnosable state. A process that refused to boot is not.


  Nothing ships with it configured. It is the default a `dev` or `test`
  deployment gets, and it is the sink to configure in a self-hosting customer's
  stack if they have decided not to run GlitchTip at all — in which case the SDKs
  can be pointed at the relay, the redaction boundary still applies, and the
  envelopes go nowhere. That is a worse product than a working store and a
  **better** one than an unredacted path straight to Sentry, which is the
  alternative this packet exists to remove.
  """

  @behaviour Courier.ErrorRelay.Sink

  @impl Courier.ErrorRelay.Sink
  def forward(_envelope, _opts), do: :ok
end
