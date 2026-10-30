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


  Four of the catalogued types have builders here and `courier.email.queued` does
  not. That is the honest split and it is asserted below rather than left to a
  reader of the moduledoc: a builder exists because courier can produce the four
  facts, and something that *publishes* it is a separate decision this module
  does not make.
  """

  use ExUnit.Case, async: true

  alias Courier.Events
  alias Courier.Mailers

  @event_type ~r/^[a-z][a-z0-9]*(_[a-z0-9]+)*(\.[a-z][a-z0-9]*(_[a-z0-9]+)*){1,2}$/

  @service_name ~r/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/

  @subject ~r{^[A-Za-z0-9][A-Za-z0-9._:@/-]*$}

  @subject_max 200

  @subject_id "courier-6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @bounce_payload_fields ~w(email message_id notification_type user_id)

  @notification_type ~w(welcome password_reset team_invitation)

  @message_id ~r/^courier-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @suppression_payload_fields ~w(email notification_type reason user_id)

  @reasons ~w(preference_off address_suppressed rate_limited)

  @data %{
    "message_id" => @subject_id,
    "user_id" => @user_id,
    "notification_type" => "welcome",
    "email" => "kaka@example.com"
  }

  @suppressed_data %{
    "user_id" => @user_id,
    "notification_type" => "welcome",
    "email" => "kaka@example.com",
    "reason" => "preference_off"
  }

  @builders [:delivered, :bounced, :complained, :suppressed]

  describe "types/0" do
    test "the catalog is exactly the events in courier's anywaye.yml" do
      assert Events.types() == manifest_events()
    end

    test "every builder names a type courier is allowed to publish" do
      for builder <- @builders do
        assert apply(Events, builder, [[subject: @subject_id, data: %{}]])["type"] in Events.types(),
               "#{builder}/1 builds an event of a type that is not in the catalog"
      end
    end

    test "the catalogued type with no builder is queued, because there is no queue" do
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
      assert @data |> Map.keys() |> Enum.sort() == @bounce_payload_fields

      assert Events.delivered(subject: @subject_id, data: @data)["data"]
             |> Map.keys()
             |> Enum.sort() ==
               @bounce_payload_fields
    end

    test "carries the subject it was given rather than the payload's message_id" do
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
      assert %{"subject" => subject} = Events.bounced(subject: @subject_id, data: @data)

      assert subject =~ @message_id
    end

    test "the data is the publisher's payload, untouched" do
      assert Events.bounced(subject: @subject_id, data: @data)["data"] == @data
    end

    test "the payload is exactly the four fields core's schema requires" do
      assert @data |> Map.keys() |> Enum.sort() == @bounce_payload_fields

      assert Events.bounced(subject: @subject_id, data: @data)["data"]
             |> Map.keys()
             |> Enum.sort() ==
               @bounce_payload_fields
    end

    test "carries the subject it was given rather than the payload's message_id" do
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
      assert @suppressed_data |> Map.keys() |> Enum.sort() == @suppression_payload_fields
      refute Map.has_key?(@suppressed_data, "message_id")

      assert Events.suppressed(subject: @user_id, data: @suppressed_data)["data"]
             |> Map.keys()
             |> Enum.sort() == @suppression_payload_fields
    end

    test "carries the subject it was given rather than the payload's user_id" do
      other = Ecto.UUID.generate()
      envelope = Events.suppressed(subject: other, data: @suppressed_data)

      assert envelope["subject"] == other
      assert envelope["subject"] != @suppressed_data["user_id"]
    end
  end

  for builder <- @builders do
    test "#{builder}/1 refuses to build an event with no subject" do
      assert_raise KeyError, fn -> apply(Events, unquote(builder), [[data: %{}]]) end
    end

    test "#{builder}/1 refuses anything that is not a keyword list" do
      error =
        assert_raise FunctionClauseError, fn -> apply(Events, unquote(builder), [%{}]) end

      assert error.module == Events
      assert error.function == unquote(builder)
      assert error.arity == 1
    end
  end

  describe "core's payload schemas, transcribed" do
    test "the notification types courier can put in a payload, and the ones core's enum does not yet hold" do
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
      assert "courier-" <> Ecto.UUID.generate() =~ @message_id
    end

    test "the reasons a suppression can carry are exactly core's enum" do
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

  defp subject_for(:suppressed), do: @user_id
  defp subject_for(_builder), do: @subject_id

  defp data_for(:suppressed), do: @suppressed_data
  defp data_for(_builder), do: @data

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
