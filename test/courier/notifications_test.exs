defmodule Courier.NotificationsTest do
  @moduledoc """
  `notification_events` and `notifications`: what courier can now remember about
  what a person was told.


  It proves the **shape of the record**: one event addressed to one recipient,
  both rows carrying the account, `seen` and `read` being different facts, and
  both marks being idempotent.

  **It does not prove the account boundary, and it cannot.** Every assertion here
  would be green with `protect_table` never called: the queries carry
  `account_id` in Elixir, so an absent policy changes nothing they can see. The
  proof that the two tables are protected — and the proof that the *owner* is
  filtered, which is the half `FORCE ROW LEVEL SECURITY` buys and no login-role
  denial can detect — is `test/courier/notifications_boundary_test.exs`, which
  reads the catalog and makes the refusals with the identity the database holds.

  The split is deliberate and it is the same split `test/courier/tenancy_test.exs`
  makes. A file that asserted both would be a file whose "cross-account reads
  nothing" assertion reads as though it were about the query.
  """

  use Courier.DataCase, async: true

  alias Courier.Notification
  alias Courier.NotificationEvent
  alias Courier.Notifications

  @account_id "d1e2f3a4-5b60-4718-8a9b-0c1d2e3f4a51"
  @other_account_id "e2f3a4b5-6c70-4829-9bac-1d2e3f4a5b62"

  @moduletag account: @account_id

  @recipient {"user", "9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"}
  @other_recipient {"user", "0a1b2c3d-4e5f-4061-8172-8394a5b6c7d8"}

  defp record!(overrides \\ []) do
    attrs =
      Keyword.merge(
        [
          type: "comment",
          recipient: @recipient,
          params: %{"actor" => "Dana"},
          record_type: "Comment",
          record_id: "7f6e5d4c-3b2a-4190-8765-4d3c2b1a0987"
        ],
        overrides
      )

    {:ok, result} = Notifications.record(@account_id, attrs)
    result
  end

  defp notify!(overrides \\ []) do
    %{notifications: [notification | _]} = record!(overrides)
    notification
  end

  describe "record/2" do
    test "writes an event and a notification, both carrying the account" do
      %{event: event, notifications: [notification]} = record!()

      assert event.id
      assert event.type == "comment"
      assert event.params == %{"actor" => "Dana"}
      assert event.record_type == "Comment"
      assert event.record_id == "7f6e5d4c-3b2a-4190-8765-4d3c2b1a0987"
      assert event.account_id == @account_id

      assert notification.id
      assert notification.notification_event_id == event.id
      assert notification.recipient_type == "user"
      assert notification.recipient_id == "9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a"
      assert notification.account_id == @account_id
    end

    test "a fresh notification is neither seen nor read" do
      notification = notify!()

      assert notification.seen_at == nil
      assert notification.read_at == nil
      refute Notification.read?(notification)
      refute Notification.seen?(notification)
    end

    test "params default to an empty bag rather than NULL" do
      assert %{event: event} = record!(params: %{})
      assert event.params == %{}

      assert {:error, {:event, changeset}} =
               Notifications.record(@account_id,
                 type: "comment",
                 recipient: @recipient,
                 params: nil
               )

      assert %{params: ["can't be blank"]} = errors_on(changeset)
    end

    test "an event with no record at all is allowed, and is the common case" do
      %{event: event} = record!(record_type: nil, record_id: nil)

      assert event.record_type == nil
      assert event.record_id == nil
    end

    test "a keyword list and a map are the same call" do
      {:ok, from_list} =
        Notifications.record(@account_id,
          type: "welcome",
          recipient: @recipient
        )

      {:ok, from_map} =
        Notifications.record(@account_id, %{type: "welcome", recipient: @recipient})

      assert from_list.event.type == from_map.event.type

      assert [a] = from_list.notifications
      assert [c] = from_map.notifications
      assert a.recipient_id == c.recipient_id
      assert a.recipient_type == c.recipient_type
    end
  end

  describe "record/2 refusals" do
    test "no recipient at all, and it says so on the RECIPIENTS" do
      assert {:error, {:recipients, changeset}} =
               Notifications.record(@account_id, type: "comment")

      assert %{recipients: ["is required: a non-empty list of {type, id} pairs"]} =
               errors_on(changeset)
    end

    test "a recipient with a blank id is refused, and NOT NULL would not have" do
      assert {:error, {:recipients, changeset}} =
               Notifications.record(@account_id, type: "comment", recipient: {"user", ""})

      assert Map.has_key?(errors_on(changeset), :recipients)
    end

    test "a recipient that is not a pair is refused" do
      assert {:error, {:recipients, _changeset}} =
               Notifications.record(@account_id, type: "comment", recipient: "9f8e7d6c")
    end

    test "ONE BAD ENTRY IN A LIST REFUSES THE CALL, and it says so once" do
      assert {:error, {:recipients, changeset}} =
               Notifications.record(@account_id,
                 type: "comment",
                 recipients: [@recipient, {"user", ""}]
               )

      assert Map.keys(errors_on(changeset)) == [:recipients]
    end

    test "a type courier does not record, and the error names the EVENT stage" do
      assert {:error, {:event, changeset}} =
               Notifications.record(@account_id, type: "carrier_pigeon", recipient: @recipient)

      assert %{type: ["is not a notification type"]} = errors_on(changeset)
    end

    test "no type at all" do
      assert {:error, {:event, changeset}} =
               Notifications.record(@account_id, recipient: @recipient)

      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "half a record reference is refused, in both directions" do
      assert {:error, {:event, by_type}} =
               Notifications.record(@account_id,
                 type: "comment",
                 recipient: @recipient,
                 record_type: "Comment",
                 record_id: nil
               )

      assert %{record_id: ["is required when record_type is given"]} = errors_on(by_type)

      assert {:error, {:event, by_id}} =
               Notifications.record(@account_id,
                 type: "comment",
                 recipient: @recipient,
                 record_type: nil,
                 record_id: "7f6e5d4c-3b2a-4190-8765-4d3c2b1a0987"
               )

      assert %{record_type: ["is required when record_id is given"]} = errors_on(by_id)
    end

    test "a refused event writes NOTHING — the transaction rolls back" do
      assert {:error, {:event, _changeset}} =
               Notifications.record(@account_id, type: "carrier_pigeon", recipient: @recipient)

      assert Repo.aggregate(
               from(e in NotificationEvent, where: e.type == "carrier_pigeon"),
               :count
             ) ==
               0
    end
  end

  describe "one event, several recipients" do
    test "N rows, one event, and each addressed to the person named" do
      {:ok, result} =
        Notifications.record(@account_id,
          type: "assignment",
          recipients: [@recipient, @other_recipient]
        )

      assert length(result.notifications) == 2
      assert length(Enum.uniq(Enum.map(result.notifications, & &1.notification_event_id))) == 1

      assert length(Notifications.list(@account_id, @recipient)) == 1
      assert length(Notifications.list(@account_id, @other_recipient)) == 1
      assert Notifications.unread_count(@account_id, @recipient) == 1
      assert Notifications.unread_count(@account_id, @other_recipient) == 1
    end

    test "THE SAME PERSON NAMED TWICE IS ONE ROW, AND BOTH ENTRIES ARE THE STORED ROW" do
      {:ok, result} =
        Notifications.record(@account_id,
          type: "comment",
          recipients: [@recipient, @recipient]
        )

      assert [first, second] = result.notifications
      assert first.id == second.id
      assert first.seen_at == second.seen_at
      assert length(Notifications.list(@account_id, @recipient)) == 1
    end

    test "a refusal on the SECOND recipient rolls the first one back too" do
      good = @recipient
      bad = {"user", String.duplicate("a", 300)}

      assert {:error, {:notification, changeset}} =
               Notifications.record(@account_id, type: "comment", recipients: [good, bad])

      assert %{recipient_id: ["should be at most 255 character(s)"]} = errors_on(changeset)

      assert Repo.aggregate(from(n in Notification), :count) == 0
      assert Repo.aggregate(from(e in NotificationEvent, where: e.type == "comment"), :count) == 0
    end

    test "an EMPTY list is refused, because an event with no notification is the bug" do
      assert {:error, {:recipients, changeset}} =
               Notifications.record(@account_id, type: "comment", recipients: [])

      assert %{recipients: ["is required: a non-empty list of {type, id} pairs"]} =
               errors_on(changeset)
    end

    test ":recipient and :recipients together are the LIST, and the singular is dropped" do
      {:ok, result} =
        Notifications.record(@account_id,
          type: "comment",
          recipient: @recipient,
          recipients: [@recipient, @other_recipient]
        )

      assert length(result.notifications) == 2
    end
  end

  describe "list/3" do
    setup do
      %{one: notify!(), two: notify!(), three: notify!()}
    end

    test "newest first", %{one: one, two: two, three: three} do
      assert ids(@recipient) == [three.id, two.id, one.id]
    end

    test "another recipient sees nothing" do
      assert Notifications.list(@account_id, @other_recipient) == []
    end

    test "another ACCOUNT sees nothing, even for the same recipient id", %{one: one} do
      assert one.id in ids(@recipient)

      assert Notifications.list(@other_account_id, @recipient) == []
    end

    test "unread: true filters out what has been read", %{one: one, two: two, three: three} do
      assert {:ok, _} = Notifications.mark_read(@account_id, @recipient, one.id)

      assert ids(@recipient, unread: true) == [three.id, two.id]
      assert one.id not in ids(@recipient, unread: true)
    end

    test "seen and not read is still unread", %{two: two} do
      assert {:ok, marked} = Notifications.mark_seen(@account_id, @recipient, two.id)

      assert marked.seen_at
      assert marked.read_at == nil
      assert two.id in ids(@recipient, unread: true)
    end

    test ":after pages backwards, strictly, without repeating the boundary row",
         %{one: one, two: two, three: three} do
      assert ids(@recipient, after: three.inserted_at) == [two.id, one.id]
      assert ids(@recipient, after: one.inserted_at) == []
    end

    test ":after with something that is not a DateTime is no cursor at all", %{one: one} do
      assert one.id in ids(@recipient, after: "yesterday")
      assert one.id in ids(@recipient, after: nil)
    end

    test "the event is not loaded unless asked for" do
      assert [_, _, _] = Notifications.list(@account_id, @recipient)

      assert [%Notification{event: %Ecto.Association.NotLoaded{}} | _] =
               Notifications.list(@account_id, @recipient)

      assert [%Notification{event: %NotificationEvent{type: "comment"}} | _] =
               Notifications.list(@account_id, @recipient, preload_event: true)
    end
  end

  describe "list/3 and the page size" do
    test "defaults to 25, honours a smaller limit, and caps at 100" do
      for _ <- 1..130, do: record!()

      assert length(Notifications.list(@account_id, @recipient)) == 25
      assert length(Notifications.list(@account_id, @recipient, limit: 3)) == 3
      assert length(Notifications.list(@account_id, @recipient, limit: 130)) == 100
    end

    test "a limit that is not a positive integer is the default, not an error" do
      for _ <- 1..30, do: record!()

      assert length(Notifications.list(@account_id, @recipient, limit: 0)) == 25
      assert length(Notifications.list(@account_id, @recipient, limit: -3)) == 25
      assert length(Notifications.list(@account_id, @recipient, limit: "ten")) == 25
    end
  end

  describe "unread_count/2" do
    test "counts what has not been read and nothing that has" do
      one = notify!()
      two = notify!()
      notify!()
      assert Notifications.unread_count(@account_id, @recipient) == 3

      assert {:ok, _} = Notifications.mark_read(@account_id, @recipient, one.id)
      assert Notifications.unread_count(@account_id, @recipient) == 2

      assert {:ok, _} = Notifications.mark_seen(@account_id, @recipient, two.id)
      assert Notifications.unread_count(@account_id, @recipient) == 2
    end

    test "is zero for a recipient who has never been told anything" do
      assert Notifications.unread_count(@account_id, @other_recipient) == 0
    end

    test "another account's inbox is not this account's count" do
      record!()

      assert Notifications.unread_count(@other_account_id, @recipient) == 0
    end
  end

  describe "mark_seen/3" do
    test "stamps seen_at and leaves read_at alone" do
      one = notify!()
      assert {:ok, marked} = Notifications.mark_seen(@account_id, @recipient, one.id)

      assert marked.seen_at
      assert marked.read_at == nil
      assert Notification.seen?(marked)
      refute Notification.read?(marked)
    end

    test "a second call keeps the FIRST timestamp" do
      one = notify!()

      assert {:ok, first} = Notifications.mark_seen(@account_id, @recipient, one.id)
      assert {:ok, second} = Notifications.mark_seen(@account_id, @recipient, one.id)

      assert second.seen_at == first.seen_at
    end

    test "a notification in another account is not found" do
      one = notify!()

      assert Notifications.mark_seen(@other_account_id, @recipient, one.id) ==
               {:error, :not_found}
    end

    test "one recipient cannot mark another recipient's notification" do
      one = notify!()

      assert Notifications.mark_seen(@account_id, @other_recipient, one.id) ==
               {:error, :not_found}
    end

    test "an id that is not a uuid is not found, and does not raise" do
      assert Notifications.mark_seen(@account_id, @recipient, "not-a-uuid") ==
               {:error, :not_found}
    end

    test "an id nobody has is not found" do
      assert Notifications.mark_seen(@account_id, @recipient, Ecto.UUID.generate()) ==
               {:error, :not_found}
    end
  end

  describe "mark_read/3" do
    test "stamps BOTH, which is what the database constraint requires" do
      one = notify!()
      assert {:ok, marked} = Notifications.mark_read(@account_id, @recipient, one.id)

      assert marked.read_at
      assert marked.seen_at
      assert Notification.read?(marked)
      assert Notification.seen?(marked)
    end

    test "a second call keeps the first timestamps" do
      one = notify!()

      assert {:ok, first} = Notifications.mark_read(@account_id, @recipient, one.id)
      assert {:ok, second} = Notifications.mark_read(@account_id, @recipient, one.id)

      assert second.read_at == first.read_at
      assert second.seen_at == first.seen_at
    end

    test "it does NOT clear a seen_at that was already set" do
      one = notify!()

      assert {:ok, seen} = Notifications.mark_seen(@account_id, @recipient, one.id)
      assert {:ok, read} = Notifications.mark_read(@account_id, @recipient, one.id)

      assert read.seen_at == seen.seen_at
      assert Notifications.unread_count(@account_id, @recipient) == 0
    end

    test "another account's notification is not found" do
      one = notify!()

      assert Notifications.mark_read(@other_account_id, @recipient, one.id) ==
               {:error, :not_found}
    end
  end

  describe "get/3" do
    test "returns the notification when it belongs to this account and recipient" do
      one = notify!()

      assert %Notification{id: id} = Notifications.get(@account_id, @recipient, one.id)
      assert id == one.id
    end

    test "nil rather than an error, for a row the caller cannot see" do
      one = notify!()

      assert Notifications.get(@other_account_id, @recipient, one.id) == nil
      assert Notifications.get(@account_id, @other_recipient, one.id) == nil
      assert Notifications.get(@account_id, @recipient, "not-a-uuid") == nil
    end
  end

  describe "types/0" do
    test "is the closed vocabulary, and every one of them can be recorded" do
      assert "welcome" in Notifications.types()
      assert "comment" in Notifications.types()

      for type <- Notifications.types() do
        assert {:ok, %{event: event}} =
                 Notifications.record(@account_id, type: type, recipient: @recipient)

        assert event.type == type
      end
    end

    test "it is NOT Courier.Mailers.types/0 and NOT Courier.Events.types/0" do
      assert Notifications.types() != Courier.Mailers.types()
      assert Notifications.types() != Courier.Events.types()
    end
  end

  defp ids(recipient, opts \\ []) do
    @account_id
    |> Notifications.list(recipient, opts)
    |> Enum.map(& &1.id)
  end
end
