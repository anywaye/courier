defmodule Courier.EventsTest do
  @moduledoc """
  The envelope is core's contract, not courier's: `anywaye/core`'s
  `schemas/event-envelope.schema.json` is where these rules live, and core's
  suite is what ultimately validates courier's output against it.

  This file restates the schema's constraints as assertions, so that drift shows
  up in courier's own suite instead of in core's. The patterns are transcribed
  from that schema — they are the contract, not courier's opinion of it. A new
  event type is not something courier gets to invent quietly: registering one is
  a checklist in core's docs/event-naming.md, and the catalog test below is the
  reminder that the list of types courier may emit is shorter than the list of
  types one could imagine.

  ## The payload schemas, which are four files and one more per type

  Each event's `data` has a schema in **core**, at
  `schemas/events/<service>/<entity>/<action>.schema.json` — the event type with
  the dots turned into directory separators. They live in core rather than here
  because a payload schema is a promise to *other* services, and a publisher that
  owns its own contract is describing something its consumers never read. So the
  four courier payload schemas are transcribed at the top of this file as
  `@bounce_payload_fields`, `@suppression_payload_fields`, `@notification_type`,
  `@message_id` and `@reasons`, each with the path it came from, and the
  builders are asserted against those transcriptions rather than against
  courier's own idea of a payload.

  Three of the four carry the same four fields — `courier.email.queued`,
  `.delivered`, `.bounced` and `.complained` are identical in shape — and
  `courier.notification.suppressed` is the one that is not, because it has no
  `message_id` (nothing was rendered, so there is no notification to be about)
  and its subject is the recipient rather than the notification. That difference
  is core's D8, in core's `anywaye/notes/decisions.md`, and a builder that got it wrong would
  be a publisher of an event no consumer could join.

  ## A builder is a shape, not an emission

  Four of the catalogued types have builders here and `courier.email.queued` does
  not. That is the honest split and it is asserted below rather than left to a
  reader of the moduledoc: a builder exists because courier can produce the four
  facts, and something that *publishes* it is a separate decision this module
  does not make.
  """

  use ExUnit.Case, async: true

  alias Courier.Events
  alias Courier.Mailers

  # schemas/event-envelope.schema.json: $defs.eventType
  @event_type ~r/^[a-z][a-z0-9]*(_[a-z0-9]+)*(\.[a-z][a-z0-9]*(_[a-z0-9]+)*){1,2}$/

  # schemas/event-envelope.schema.json: $defs.serviceName
  @service_name ~r/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/

  # schemas/event-envelope.schema.json: properties.subject
  @subject ~r{^[A-Za-z0-9][A-Za-z0-9._:@/-]*$}

  # schemas/event-envelope.schema.json: properties.subject.minLength/maxLength.
  # Not asserted as a pattern because `1` is not a pattern; the envelope carries
  # `minLength: 1` and a builder that accepted an empty subject would build an
  # envelope the schema refuses, so the two live here together.
  @subject_max 200

  @subject_id "courier-6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # A bare uuid, which is what identity hands out and what core's D7 says every
  # courier payload keys its recipient on. Distinct from `@subject_id` on purpose:
  # the two id shapes are the difference between `courier.email.delivered`'s
  # subject and `courier.notification.suppressed`'s, and a fixture that used one
  # string for both would not notice a builder that used the wrong one.
  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # schemas/events/courier/email/{queued,delivered,bounced,complained}.schema.json:
  # `required`. All four schemas are identical in shape, which is why one
  # transcription covers them.
  #
  # **Sorted, and that is not cosmetic.** `required` is a list in the schema and
  # the payload is an object, and a JSON object's key order is not a thing any
  # validator reads — so the assertions below `Enum.sort/1` both sides, and a
  # transcription left in the schema's own order would compare a set against a
  # sequence and fail on nothing. The set is the contract.
  @bounce_payload_fields ~w(email message_id notification_type user_id)

  # schemas/events/courier/email/*.schema.json: properties.notification_type.enum
  @notification_type ~w(welcome password_reset team_invitation)

  # schemas/events/courier/email/*.schema.json: properties.message_id.pattern
  @message_id ~r/^courier-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  # schemas/events/courier/notification/suppressed.schema.json: `required`. No
  # `message_id` here, and that is the whole difference from the four above.
  @suppression_payload_fields ~w(email notification_type reason user_id)

  # schemas/events/courier/notification/suppressed.schema.json:
  # properties.reason.enum
  @reasons ~w(preference_off address_suppressed rate_limited)

  # The payload `Courier.Deliver` builds for a send, transcribed from
  # schemas/events/courier/email/delivered.schema.json. It is also, field for
  # field, what `bounced` and `complained` carry about the same send — which is
  # what lets a consumer join a bounce arriving days later to the send that
  # caused it.
  @data %{
    "message_id" => @subject_id,
    "user_id" => @user_id,
    "notification_type" => "welcome",
    "email" => "kaka@example.com"
  }

  # The payload for a skipped send, transcribed from
  # schemas/events/courier/notification/suppressed.schema.json.
  @suppressed_data %{
    "user_id" => @user_id,
    "notification_type" => "welcome",
    "email" => "kaka@example.com",
    "reason" => "preference_off"
  }

  # The four builders, for the argument contract every one of them shares.
  @builders [:delivered, :bounced, :complained, :suppressed]

  describe "types/0" do
    test "the catalog is exactly the events in courier's anywaye.yml" do
      # anywaye.yml `exposes.events` and core's docs/event-naming.md catalog are
      # asserted to agree by core's own suite. If `Courier.Events` gains a type,
      # one of those two needs the same row in the same commit.
      assert Events.types() == manifest_events()
    end

    test "every builder names a type courier is allowed to publish" do
      for builder <- @builders do
        assert apply(Events, builder, [[subject: @subject_id, data: %{}]])["type"] in Events.types(),
               "#{builder}/1 builds an event of a type that is not in the catalog"
      end
    end

    test "the catalogued type with no builder is queued, because there is no queue" do
      # courier's send path is synchronous and documented as such: the provider is
      # dialled inside the request, in the transaction that writes the
      # `courier.email.delivered` row. `courier.email.queued` exists to make a
      # queue backlog visible, and there is no backlog to see — so there is no
      # moment at which courier could honestly emit it. Asserting the gap by name
      # rather than leaving it implicit is the point: the day courier grows a queue
      # this test is the thing that has to be argued with, instead of a builder
      # appearing nobody had looked for.
      built =
        Enum.map(@builders, &apply(Events, &1, [[subject: @subject_id, data: %{}]])["type"])

      assert Events.types() -- built == ["courier.email.queued"]
    end
  end

  describe "delivered/1" do
    test "names a type courier is allowed to publish" do
      envelope = Events.delivered(subject: @subject_id, data: %{})

      assert envelope["type"] == "courier.email.delivered"
      assert envelope["type"] == Events.delivered_type()
      assert envelope["type"] in Events.types()
    end

    test "carries every required attribute and nothing else" do
      # `additionalProperties: false` in the schema: an extra attribute is a
      # validation failure, not an extension point. `specversion` is one of the
      # seven — the schema's `required` list — and the next test says so; it is
      # spelled out here because the point of this test is the closed set, and a
      # closed set that quietly omits a required member is not closed.
      envelope = Events.delivered(subject: @subject_id, data: %{})

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(data id source specversion subject time type)
    end

    test "pins the dialect version" do
      assert Events.delivered(subject: @subject_id, data: %{})["specversion"] == "1.0"
    end

    test "the id is a uuid, unique per emission" do
      one = Events.delivered(subject: @subject_id, data: %{})
      two = Events.delivered(subject: @subject_id, data: %{})

      assert {:ok, _uuid} = Ecto.UUID.cast(one["id"])
      refute one["id"] == two["id"]
    end

    test "the source is courier, which is `name` in courier's anywaye.yml" do
      assert Events.delivered(subject: @subject_id, data: %{})["source"] == "courier"
    end

    test "the time is RFC3339 in UTC, to the second" do
      assert %{"time" => time} = Events.delivered(subject: @subject_id, data: %{})

      assert String.ends_with?(time, "Z")

      # The third element is the parsed utc_offset (`0`), which `from_iso8601/1`
      # has returned alongside the DateTime since Elixir 1.4.
      assert {:ok, %DateTime{time_zone: "Etc/UTC", microsecond: {0, 0}}, 0} =
               DateTime.from_iso8601(time)
    end

    test "the subject is the entity the event is about, and matches the schema's pattern" do
      assert %{"subject" => subject} = Events.delivered(subject: @subject_id, data: %{})

      assert subject =~ @subject
      assert String.length(subject) <= @subject_max
    end

    test "the data is the publisher's payload, untouched" do
      assert Events.delivered(subject: @subject_id, data: @data)["data"] == @data
    end

    test "the payload is exactly the four fields core's schema requires" do
      # schemas/events/courier/email/delivered.schema.json, `required` plus
      # `additionalProperties: false`. A payload carrying a fifth key is an
      # envelope no consumer's generated validator accepts, and this file's own
      # fixture is where that would be caught first.
      assert @data |> Map.keys() |> Enum.sort() == @bounce_payload_fields

      assert Events.delivered(subject: @subject_id, data: @data)["data"]
             |> Map.keys()
             |> Enum.sort() ==
               @bounce_payload_fields
    end

    test "carries the subject it was given rather than the payload's message_id" do
      # properties.message_id says "Always equal to the envelope's `subject`", and
      # the builder is handed both halves rather than deriving one from the other.
      # That is deliberate: the builder is a shape and the pairing is the caller's
      # obligation, since `Courier.Deliver` mints both in the same breath.
      #
      # So this asserts the builder does not quietly ENFORCE the pairing either. A
      # builder that rewrote the subject from the payload would be deciding which
      # entity an event is about on its author's behalf, and core's D8 is the record
      # of what happens when that choice is made in the wrong file: for
      # `courier.notification.suppressed` the subject is the recipient, and no
      # payload field could have said so. Passing a second, different subject is
      # how that mutation gets caught.
      other = "courier-" <> Ecto.UUID.generate()
      envelope = Events.delivered(subject: other, data: @data)

      assert envelope["subject"] == other
      assert envelope["subject"] != @data["message_id"]
    end
  end

  describe "bounced/1" do
    test "names a type courier is allowed to publish" do
      envelope = Events.bounced(subject: @subject_id, data: %{})

      assert envelope["type"] == "courier.email.bounced"
      assert envelope["type"] == Events.bounced_type()
      assert envelope["type"] in Events.types()
    end

    test "carries every required attribute and nothing else" do
      envelope = Events.bounced(subject: @subject_id, data: %{})

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(data id source specversion subject time type)
    end

    test "pins the dialect version" do
      assert Events.bounced(subject: @subject_id, data: %{})["specversion"] == "1.0"
    end

    test "the id is a uuid, unique per emission" do
      one = Events.bounced(subject: @subject_id, data: @data)
      two = Events.bounced(subject: @subject_id, data: @data)

      assert {:ok, _uuid} = Ecto.UUID.cast(one["id"])
      refute one["id"] == two["id"]
    end

    test "the source is courier, which is `name` in courier's anywaye.yml" do
      assert Events.bounced(subject: @subject_id, data: %{})["source"] == "courier"
    end

    test "the time is RFC3339 in UTC, to the second" do
      assert %{"time" => time} = Events.bounced(subject: @subject_id, data: %{})

      assert {:ok, %DateTime{time_zone: "Etc/UTC", microsecond: {0, 0}}, 0} =
               DateTime.from_iso8601(time)
    end

    test "the subject is the notification that bounced" do
      # The bounce arrives from the provider quoting the RFC 5322 `Message-ID`
      # header `Courier.Deliver` set, so this subject is the message id and not
      # the address: suppressing an address needs the address, and the payload
      # carries it. A subject here that were the address would make the event
      # uncorrelatable with the `courier.email.delivered` row about the same send.
      assert %{"subject" => subject} = Events.bounced(subject: @subject_id, data: @data)

      assert subject =~ @message_id
    end

    test "the data is the publisher's payload, untouched" do
      assert Events.bounced(subject: @subject_id, data: @data)["data"] == @data
    end

    test "the payload is exactly the four fields core's schema requires" do
      # schemas/events/courier/email/bounced.schema.json, which is field for field
      # the same four `delivered` carries — and no provider diagnostic, because no
      # publisher emits one. That absence is core's decision written into core's
      # schema, not a gap in courier: a bounce code is a field nobody sends, and a
      # schema naming a field nobody emits is a contract that lies green.
      assert @data |> Map.keys() |> Enum.sort() == @bounce_payload_fields

      assert Events.bounced(subject: @subject_id, data: @data)["data"]
             |> Map.keys()
             |> Enum.sort() ==
               @bounce_payload_fields
    end

    test "carries the subject it was given rather than the payload's message_id" do
      # The same argument as `delivered/1`'s: the builder is handed both halves and
      # does not reconcile them. A bounce that rewrote its subject out of the
      # payload would still correlate correctly here — there is only one sane
      # candidate — which is exactly why the pass-through has to be asserted
      # deliberately rather than left to the fact that it happens to be harmless
      # today. `suppressed/1` is where it stops being harmless.
      other = "courier-" <> Ecto.UUID.generate()
      envelope = Events.bounced(subject: other, data: @data)

      assert envelope["subject"] == other
      assert envelope["subject"] != @data["message_id"]
    end
  end

  describe "complained/1" do
    test "names a type courier is allowed to publish" do
      envelope = Events.complained(subject: @subject_id, data: %{})

      assert envelope["type"] == "courier.email.complained"
      assert envelope["type"] == Events.complained_type()
      assert envelope["type"] in Events.types()
    end

    test "carries every required attribute and nothing else" do
      envelope = Events.complained(subject: @subject_id, data: %{})

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(data id source specversion subject time type)
    end

    test "pins the dialect version" do
      assert Events.complained(subject: @subject_id, data: %{})["specversion"] == "1.0"
    end

    test "the id is a uuid, unique per emission" do
      one = Events.complained(subject: @subject_id, data: @data)
      two = Events.complained(subject: @subject_id, data: @data)

      assert {:ok, _uuid} = Ecto.UUID.cast(one["id"])
      refute one["id"] == two["id"]
    end

    test "the source is courier, which is `name` in courier's anywaye.yml" do
      assert Events.complained(subject: @subject_id, data: %{})["source"] == "courier"
    end

    test "the time is RFC3339 in UTC, to the second" do
      assert %{"time" => time} = Events.complained(subject: @subject_id, data: %{})

      assert {:ok, %DateTime{time_zone: "Etc/UTC", microsecond: {0, 0}}, 0} =
               DateTime.from_iso8601(time)
    end

    test "the subject is the notification that was complained about" do
      assert %{"subject" => subject} = Events.complained(subject: @subject_id, data: @data)

      assert subject =~ @message_id
    end

    test "the data is the publisher's payload, untouched" do
      assert Events.complained(subject: @subject_id, data: @data)["data"] == @data
    end

    test "the payload is exactly the four fields core's schema requires" do
      # schemas/events/courier/email/complained.schema.json, field for field the
      # same four. `notification_type` is here for the same reason the bounce's is:
      # a complaint suppresses the address for every type, so what the type is
      # tells a consumer what the user objected to rather than what to stop sending.
      assert @data |> Map.keys() |> Enum.sort() == @bounce_payload_fields

      assert Events.complained(subject: @subject_id, data: @data)["data"]
             |> Map.keys()
             |> Enum.sort() == @bounce_payload_fields
    end

    test "carries the subject it was given rather than the payload's message_id" do
      other = "courier-" <> Ecto.UUID.generate()
      envelope = Events.complained(subject: other, data: @data)

      assert envelope["subject"] == other
      assert envelope["subject"] != @data["message_id"]
    end
  end

  describe "suppressed/1" do
    test "names a type courier is allowed to publish" do
      envelope = Events.suppressed(subject: @user_id, data: %{})

      assert envelope["type"] == "courier.notification.suppressed"
      assert envelope["type"] == Events.suppressed_type()
      assert envelope["type"] in Events.types()
    end

    test "carries every required attribute and nothing else" do
      envelope = Events.suppressed(subject: @user_id, data: %{})

      assert envelope |> Map.keys() |> Enum.sort() ==
               ~w(data id source specversion subject time type)
    end

    test "pins the dialect version" do
      assert Events.suppressed(subject: @user_id, data: %{})["specversion"] == "1.0"
    end

    test "the id is a uuid, unique per emission" do
      one = Events.suppressed(subject: @user_id, data: @suppressed_data)
      two = Events.suppressed(subject: @user_id, data: @suppressed_data)

      assert {:ok, _uuid} = Ecto.UUID.cast(one["id"])
      refute one["id"] == two["id"]
    end

    test "the source is courier, which is `name` in courier's anywaye.yml" do
      assert Events.suppressed(subject: @user_id, data: %{})["source"] == "courier"
    end

    test "the time is RFC3339 in UTC, to the second" do
      assert %{"time" => time} = Events.suppressed(subject: @user_id, data: %{})

      assert {:ok, %DateTime{time_zone: "Etc/UTC", microsecond: {0, 0}}, 0} =
               DateTime.from_iso8601(time)
    end

    test "the subject is the user, not the notification" do
      # The one place courier's four types disagree about their subject, and the
      # reason this builder does not look like the other three. Nothing was
      # rendered, nothing was addressed and nothing left, so there is no message
      # to name; core's catalog calls the subject "the recipient", and core's D8
      # settles that the recipient is the **user id** rather than the address —
      # an address is mutable and `subject` is the per-entity ordering key. So the
      # subject here is a bare uuid, and it is the envelope's subject that must be
      # a user id rather than one of courier's own `courier-` ids.
      assert %{"subject" => subject} = Events.suppressed(subject: @user_id, data: %{})

      assert subject =~ @subject
      refute subject =~ ~r/^courier-/
      assert {:ok, _uuid} = Ecto.UUID.cast(subject)
    end

    test "the data is the publisher's payload, untouched" do
      assert Events.suppressed(subject: @user_id, data: @suppressed_data)["data"] ==
               @suppressed_data
    end

    test "the payload is exactly the four fields core's schema requires" do
      # schemas/events/courier/notification/suppressed.schema.json: `required` is
      # user_id, notification_type, email, reason — and there is no `message_id`,
      # because nothing was rendered. A payload that carried one would fail
      # `additionalProperties: false`, so this asserts the absence as well as the
      # set: an event naming a notification that was never sent is the whole lie
      # this type exists to avoid.
      assert @suppressed_data |> Map.keys() |> Enum.sort() == @suppression_payload_fields
      refute Map.has_key?(@suppressed_data, "message_id")

      assert Events.suppressed(subject: @user_id, data: @suppressed_data)["data"]
             |> Map.keys()
             |> Enum.sort() == @suppression_payload_fields
    end

    test "carries the subject it was given rather than the payload's user_id" do
      # The one place the pass-through is load-bearing rather than tidy. This
      # payload has no `message_id` to default to, so a builder that derived the
      # subject from the payload would have to pick between `user_id` and `email` —
      # and it would pick by guessing, in the one file where D8's answer (the user
      # id) is a decision rather than a derivation.
      other = Ecto.UUID.generate()
      envelope = Events.suppressed(subject: other, data: @suppressed_data)

      assert envelope["subject"] == other
      assert envelope["subject"] != @suppressed_data["user_id"]
    end
  end

  # The argument contract, which is `Courier.Deliver`'s to rely on: a builder with
  # no subject raises rather than emitting an envelope whose `subject` is null,
  # because core's schema requires the attribute and a consumer that receives one
  # anyway has been handed something no schema in the fleet will validate. Written
  # once and instantiated per builder so a failure names the builder rather than
  # "one of four".
  for builder <- @builders do
    test "#{builder}/1 refuses to build an event with no subject" do
      assert_raise KeyError, fn -> apply(Events, unquote(builder), [[data: %{}]]) end
    end

    test "#{builder}/1 refuses anything that is not a keyword list" do
      error =
        assert_raise FunctionClauseError, fn -> apply(Events, unquote(builder), [%{}]) end

      # Asserting only the class is not enough, and the reason is specific:
      # `Keyword.fetch!/2` raises a `FunctionClauseError` of its own on a map, so
      # a builder that had lost its `when is_list(opts)` guard would still answer
      # this assertion and the guard — the only thing telling a caller it passed
      # the wrong shape instead of the right one — would have become untested.
      # Naming the module and the arity is what pins the refusal to the guard.
      assert error.module == Events
      assert error.function == unquote(builder)
      assert error.arity == 1
    end
  end

  describe "core's payload schemas, transcribed" do
    test "the notification types courier can put in a payload, and the ones core's enum does not yet hold" do
      # properties.notification_type.enum in all four of courier's payload schemas.
      # `Courier.Mailers` is where the messages are named, and every payload
      # courier emits takes its `notification_type` from there.
      #
      # COURIER'S CATALOG IS NOW EIGHT; CORE'S ENUM IS THREE. The fourth,
      # `account_security`, was added by the sessions-revoked consumer
      # (`Courier.Consumers.SessionsRevoked`), the two email-change notices by
      # the email-change packet, `receipt` by the payment consumer
      # (`Courier.Consumers.PaymentSucceeded`, the mail for a settled payment),
      # and `payment_failed` by its sibling (`Courier.Consumers.PaymentFailed`,
      # the warning for an attempt that did not go through); core's four payload
      # schemas still freeze `notification_type` to the three names below. core
      # is not this repository's to change, so the divergence is REPORTED rather
      # than applied: `REPORT-courier-consumer-sessionsrevoked-01` for the
      # first three, `REPORT-courier-consumer-paymentreceipt-01` for the
      # fourth, and `REPORT-courier-consumer-paymentfailed-01` for this one.
      # This assertion pins the known divergence — a NINTH type still fails it —
      # rather than asserting an agreement that no longer holds. The day core's
      # enum grows the missing names, the `++ [...]` comes out and the two
      # lists are equal again.
      assert Mailers.types() ==
               @notification_type ++
                 [
                   "account_security",
                   "email_change_current",
                   "email_change_new",
                   "receipt",
                   "payment_failed"
                 ]
    end

    test "the message ids courier mints are the shape core's pattern requires" do
      # properties.message_id.pattern. `Courier.Deliver` builds
      # `"courier-" <> Ecto.UUID.generate()`; the transcription is the same
      # expression, so this is the assertion that the prefix and the generator have
      # not drifted apart from the contract four payload schemas depend on.
      assert "courier-" <> Ecto.UUID.generate() =~ @message_id
    end

    test "the reasons a suppression can carry are exactly core's enum" do
      # properties.reason.enum in suppressed.schema.json. The two courier can
      # reach are `preference_off` (the user turned the type off) and
      # `address_suppressed` (a previous bounce or complaint); `rate_limited` has
      # no producer in courier at all, because the send path has no rate limiter.
      # The enum is core's and is not courier's to narrow — so the gap is named
      # here rather than papered over with a two-value list.
      assert Events.reasons() == @reasons
      assert Map.has_key?(@suppressed_data, "reason")
      assert @suppressed_data["reason"] in Events.reasons()
    end
  end

  describe "conformance" do
    test "the envelope a real delivery produces satisfies every schema constraint" do
      envelope = Events.delivered(subject: @subject_id, data: @data)

      assert envelope["specversion"] == "1.0"
      assert envelope["type"] =~ @event_type
      assert envelope["source"] =~ @service_name
      assert envelope["subject"] =~ @subject
      assert {:ok, _uuid} = Ecto.UUID.cast(envelope["id"])
      assert {:ok, _time, _offset} = DateTime.from_iso8601(envelope["time"])
      assert is_map(envelope["data"])
    end

    test "every builder's envelope satisfies every envelope-schema constraint" do
      # One test for the four, because this is the one property that belongs to
      # `Courier.Events.envelope/1` rather than to any builder: the type is the
      # only attribute that differs, and each builder's own block asserts which
      # type it is. `source` is checked against the event type's first segment as
      # well as the `serviceName` pattern, because core's schema says the two must
      # be equal and a pattern cannot say that.
      for builder <- @builders do
        envelope =
          apply(Events, builder, [
            [subject: subject_for(builder), data: data_for(builder)]
          ])

        assert envelope["specversion"] == "1.0"
        assert envelope["type"] =~ @event_type
        assert envelope["source"] =~ @service_name
        assert envelope["source"] == envelope["type"] |> String.split(".") |> hd()
        assert envelope["subject"] =~ @subject
        assert {:ok, _uuid} = Ecto.UUID.cast(envelope["id"])
        assert {:ok, _time, _offset} = DateTime.from_iso8601(envelope["time"])
        assert is_map(envelope["data"])
      end
    end
  end

  # The subject each builder is given its own fixture for: three name the
  # notification, one names the user, and the whole point of D8 is that a builder
  # cannot be handed either and still be right.
  defp subject_for(:suppressed), do: @user_id
  defp subject_for(_builder), do: @subject_id

  defp data_for(:suppressed), do: @suppressed_data
  defp data_for(_builder), do: @data

  # anywaye.yml is the service's own statement of what it publishes, and
  # `Courier.Events` is the same list in Elixir. Parsing YAML is not worth a
  # dependency to check a list of five plain strings, so this reads the block
  # directly: the `events:` key at two spaces, its list items at four.
  defp manifest_events do
    lines = File.read!(Path.join(File.cwd!(), "anywaye.yml")) |> String.split("\n")

    case Enum.find_index(lines, &(&1 =~ ~r/^\s{2}events:/)) do
      nil ->
        flunk(
          "anywaye.yml no longer declares `exposes.events`; `Courier.Events` cannot be checked against it"
        )

      index ->
        lines
        |> Enum.drop(index + 1)
        |> Enum.take_while(&(&1 =~ ~r/^\s{4}- /))
        |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("- ") |> String.trim()))
    end
  end
end
