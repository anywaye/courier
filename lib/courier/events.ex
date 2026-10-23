defmodule Courier.Events do
  @moduledoc """
  The event envelope courier emits, and the catalog of the types it may emit.

  The envelope is core's contract, not courier's:
  `anywaye/core`'s `schemas/event-envelope.schema.json` is where the rules live,
  and `Courier.EventsTest` restates them here so drift shows up in courier's own
  suite instead of in core's.

  Each event's `data` is core's contract too, one schema per type at
  `schemas/events/<service>/<entity>/<action>.schema.json`. Every builder below
  names the schema it was written against, because the payload is a promise to
  the *other* services on the bus and a publisher that owns its own payload shape
  is describing something none of them read.

  The catalog is the short list. `types/0` must agree, entry for entry, with
  `exposes.events` in this repository's `anywaye.yml` — the test says so — and
  both are courier's row in `core/docs/event-naming.md`. Registering a new type
  is a checklist in core, not a quiet addition here.

  Every type is **three** segments: `<service>.<entity>.<action>`, so
  `courier.email.delivered` and not `email.delivered`. courier-01/02 shipped the
  two-segment spelling, which core's frozen `eventType` grammar and
  `caf contract lint` both reject — core records the same drift in
  `docs/event-naming.md` §courier. The prefix is the service name, which is also
  the envelope's `source` and the manifest's `name`, so a type says who emitted
  it without a lookup.

  ## A builder is a shape, not an emission

  Four of the five catalogued types have a builder here and `courier.email.queued`
  does not. The two statements are different on purpose, because collapsing them
  is the lie this module used to be in the shape of:

    * `courier.email.delivered` has a builder **and** a caller. `Courier.Deliver`
      writes the row in the transaction that sent the mail.
    * `courier.email.bounced` and `courier.email.complained` have builders and no
      caller, because courier has no inbound surface to learn a bounce or a
      complaint from. A builder that fabricates the moment a bounce happened would
      be worse than no builder: it would publish an event about a message nobody
      reported, which is the same class of lie as a catalog entry with nothing
      behind it.
    * `courier.notification.suppressed` has a builder and its first caller as of
      the one-click unsubscribe, which writes the row in the same transaction as
      the preference it belongs to. **It is still not called for a refused
      send**, and that is the sentence in `Courier.Deliver` this packet did NOT
      change: `POST /unsubscribe/:token` is not a send courier turned down, it is
      a standing answer that changed, and the type's schema is built for exactly
      that — the subject is the user, there is no `message_id`, and the `reason` is
      `preference_off`. Whether courier writes an outbox row for the *other* two
      refusals — `{:error, :suppressed}` and `{:error, {:suppressed_address,
      _}}` out of `Courier.Deliver`, which happen today and which `POST
      /v1/messages` already answers — is still open, and the argument is still
      `Courier.Deliver`'s to make. A builder that had quietly overridden that
      promise would be deciding policy in the one file whose job is shapes.

  `courier.email.queued` has no builder because courier has no queue. The send path
  is synchronous and documented as such — the provider is dialled inside the
  request — and that type exists to make a *backlog* visible. With no backlog
  there is no moment at which courier could honestly emit it, and an acceptance
  event with no queue behind it would be a queue-depth metric reading zero for
  structural reasons.
  """

  @specversion "1.0"
  @source "courier"
  @delivered "courier.email.delivered"
  @bounced "courier.email.bounced"
  @complained "courier.email.complained"
  @suppressed "courier.notification.suppressed"

  @types ~w(
    courier.email.queued
    courier.email.delivered
    courier.email.bounced
    courier.email.complained
    courier.notification.suppressed
  )

  # schemas/events/courier/notification/suppressed.schema.json:
  # properties.reason.enum. Transcribed from core rather than invented here,
  # because a caller writing the refusal's reason should be picking from a set
  # somebody else published rather than spelling a string and hoping. It is a
  # superset of what courier can produce today and that is deliberate: `reason` is
  # core's enum, and narrowing it here would make a `rate_limited` refusal
  # unpublishable rather than unimplemented. Which of the three courier can reach
  # is `Courier.Deliver`'s to say — `:suppressed` is a user declining,
  # `{:suppressed_address, _}` is a previous bounce or complaint, and
  # `rate_limited` has no producer because the send path has no rate limiter.
  @reasons ~w(preference_off address_suppressed rate_limited)

  @doc """
  Every event type courier is allowed to publish, in the order `anywaye.yml`
  declares them.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  The type of the event courier records for a send — and, by core's rule, the
  NATS subject the row is published on: the `type` is the subject, with no
  mapping table between them.
  """
  @spec delivered_type() :: String.t()
  def delivered_type, do: @delivered

  @doc """
  The `email.delivered` envelope for one send.

  `subject` is the message the send is about — courier's own message id, not the
  user, so two sends to one person are two events about two entities. `data` is
  the send's own fields and nothing else: this envelope goes to every subscriber
  on the bus, and a verification token or an invitation id in there would be a
  credential leak into a fan-out.

  `time` is RFC3339 in UTC to the second: the envelope's timestamp, and a
  consumer that orders by it should not have to care about sub-second precision
  courier never promised.
  """
  @spec delivered(keyword()) :: map()
  def delivered(opts) when is_list(opts) do
    envelope(%{
      id: Ecto.UUID.generate(),
      type: @delivered,
      source: @source,
      subject: Keyword.fetch!(opts, :subject),
      time: DateTime.truncate(DateTime.utc_now(), :second),
      data: Keyword.get(opts, :data, %{})
    })
  end

  @doc """
  The type of the `courier.email.bounced` event, on the same terms as
  `delivered_type/0`: the type is the NATS subject.
  """
  @spec bounced_type() :: String.t()
  def bounced_type, do: @bounced

  @doc """
  The `email.bounced` envelope for one message that hard-bounced.

  `subject` is the notification that failed — courier's own message id, and the
  one the send wrote into the RFC 5322 `Message-ID` header, so the bounce that
  arrives days later joins to the send that caused it. `data` is that send's own
  four fields, `message_id` / `user_id` / `notification_type` / `email`, exactly
  as `core/schemas/events/courier/email/bounced.schema.json` requires.

  **No provider diagnostic**, and that is core's schema rather than a gap in
  courier: the file says so in its own description, because no publisher emits a
  bounce code. It arrives with the receiver, and when one does, the field is a
  patch to core's schema and not a key in this map — an `additionalProperties:
  false` payload rejects the extra field rather than ignoring it.

  **This builder does not say what courier did about the bounce.** The
  suppression that follows is a separate fact, written by `Courier.Suppressions`
  and never exposed through a route. A subscriber gets the failure here and reads
  the consequence by attempting the next send, which is the honest order: the
  event is about the message, and the list is about the mailbox.
  """
  @spec bounced(keyword()) :: map()
  def bounced(opts) when is_list(opts) do
    envelope(%{
      id: Ecto.UUID.generate(),
      type: @bounced,
      source: @source,
      subject: Keyword.fetch!(opts, :subject),
      time: DateTime.truncate(DateTime.utc_now(), :second),
      data: Keyword.get(opts, :data, %{})
    })
  end

  @doc """
  The type of the `courier.email.complained` event, on the same terms as
  `delivered_type/0`.
  """
  @spec complained_type() :: String.t()
  def complained_type, do: @complained

  @doc """
  The `email.complained` envelope for one message the recipient reported as spam.

  Field for field the same payload as `bounced/1` — core specifies both against
  `message_id`, `user_id`, `notification_type` and `email` — and the subject is
  the notification again, because the `Message-ID` the complaint quotes is the
  same header and the same id.

  **The two are kept apart even though their payloads are identical**, and the
  reason is that they are different facts with different consequences and different
  readers. A bounce is a fact about a *mailbox*: RFC 5321 §5.1.1 permanent
  failure, and the operator's response is list hygiene. A complaint is an
  instruction from a *person*: RFC 2142 §5, a "report spam", and the operator's
  response is a content and sender-reputation problem that no per-address
  suppression fixes. Publishing both as one type would leave a consumer unable to
  tell which it is looking at, and `Courier.Suppressions` keeps the two states
  distinct for exactly that reason.

  `notification_type` is here for the same reason it is on the bounce: a
  complaint suppresses the address for every type immediately, so what the type
  is tells a consumer what the user objected to rather than what to stop sending.
  """
  @spec complained(keyword()) :: map()
  def complained(opts) when is_list(opts) do
    envelope(%{
      id: Ecto.UUID.generate(),
      type: @complained,
      source: @source,
      subject: Keyword.fetch!(opts, :subject),
      time: DateTime.truncate(DateTime.utc_now(), :second),
      data: Keyword.get(opts, :data, %{})
    })
  end

  @doc """
  The type of the `courier.notification.suppressed` event, on the same terms as
  `delivered_type/0`.
  """
  @spec suppressed_type() :: String.t()
  def suppressed_type, do: @suppressed

  @doc """
  Every value `courier.notification.suppressed`'s `reason` can carry, transcribed
  from `core/schemas/events/courier/notification/suppressed.schema.json`.

  Core's enum, not a narrower one: courier can reach two of the three today
  (`preference_off`, `address_suppressed`) and `rate_limited` has no producer,
  but the payload schema belongs to core and a fourth value is not courier's to
  publish and not courier's to remove. `Courier.EventsTest` asserts this list
  against that transcription, so the two cannot drift apart quietly.
  """
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc """
  The `notification.suppressed` envelope for one send courier refused.

  **The subject is the user id and not the notification, and that is the one thing
  about this envelope the other three do not do.** Nothing was rendered, nothing
  was addressed and nothing left, so there is no message to name; and core's
  catalog calls this type's subject "the recipient", which core's D8
  (`anywaye/notes/decisions.md`) settles as the **user id** rather than the address — an address
  is mutable and `subject` is the per-entity ordering key, so a correlation key
  that the recipient can change is a key that moves under a consumer.

  So `subject` here is a bare uuid from identity, and `data` is
  `user_id` / `notification_type` / `email` / `reason` — **no `message_id`**, which
  is not an omission courier made but the schema itself: there was no message.
  `data.email` is here so a consumer can join on whichever the manager picks
  without re-reading anybody's data.

  ## Its one caller, and what it is not

  `Courier.Unsubscribes` calls this from the one-click endpoint, in the same
  transaction as the `notification_preferences` row that turns the type off. The
  mapping is the one the enum was drawn for: `reason: "preference_off"`, because
  the user turned the type off — a `preference_off` that no send attempted.

  That is also why this is **not** the send path's refusal. `{:error, :suppressed}`
  and `{:error, {:suppressed_address, _}}` out of `Courier.Deliver` would map to
  `preference_off` and `address_suppressed` respectively, and which of them to
  publish is still `Courier.Deliver`'s call: its moduledoc promises "no mail, no
  event, no record of a send that did not happen" and this packet did not touch
  that sentence, because a send courier refused and an answer a user changed are
  two different facts and a consumer that cannot tell them apart has been handed
  a lie.
  """
  @spec suppressed(keyword()) :: map()
  def suppressed(opts) when is_list(opts) do
    envelope(%{
      id: Ecto.UUID.generate(),
      type: @suppressed,
      source: @source,
      subject: Keyword.fetch!(opts, :subject),
      time: DateTime.truncate(DateTime.utc_now(), :second),
      data: Keyword.get(opts, :data, %{})
    })
  end

  @doc """
  The envelope for an emission whose attributes are already known.

  One definition of the seven attributes, so the row `Courier.OutboxEvent`
  records and the message `Courier.Workers.ProcessOutboxWorker` publishes are the
  same shape by construction rather than by two modules agreeing.
  `additionalProperties: false` in core's schema: an extra attribute is a
  validation failure, not an extension point.
  """
  @spec envelope(map()) :: map()
  def envelope(%{id: id, type: type, source: source, subject: subject, time: time, data: data}) do
    %{
      "specversion" => @specversion,
      "id" => id,
      "type" => type,
      "source" => source,
      "subject" => subject,
      "time" => DateTime.to_iso8601(time),
      "data" => data
    }
  end
end
