defmodule Courier.NotificationsTest do
  @moduledoc """
  `notification_events` and `notifications`: what courier can now remember about
  what a person was told.

  ## WHAT THIS FILE PROVES, AND WHAT IT DELIBERATELY DOES NOT

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

  # Both tables are protected, so a write with no identity is refused `42501`.
  # See `Courier.DataCase` for the measurement behind the suite running as
  # `courier_app` at all.
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

  # The first (and, with one recipient, only) notification out of a `record/2`.
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
      # The link is the whole two-table shape: a notification is not a copy of
      # the event, it is the event addressed somewhere.
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

      # **OMITTED IS NOT THE SAME AS NIL**, and the difference is a decision
      # rather than an accident. Omitting `:params` takes the schema's
      # `default: %{}` and the column is `null: false`, so a bag is always
      # stored and a consumer never has to handle `nil`. Passing `params: nil`
      # casts an explicit `nil` OVER the default and `validate_required` refuses
      # it — which is right: a caller that wrote `params: nil` has said
      # something, and courier should not quietly decide it meant "empty".
      assert {:error, {:event, changeset}} =
               Notifications.record(@account_id,
                 type: "comment",
                 recipient: @recipient,
                 params: nil
               )

      assert %{params: ["can't be blank"]} = errors_on(changeset)
    end

    test "an event with no record at all is allowed, and is the common case" do
      # "Your trial ends tomorrow" has no row behind it. Half a reference is a
      # reference nobody can resolve, so BOTH columns or NEITHER.
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
      # The database's `NOT NULL` refuses the *absence* of a recipient and says
      # nothing about the presence of an empty one — `{"user", ""}` satisfies a
      # `NOT NULL` column perfectly well, and would be an inbox entry addressed
      # to nobody.
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
      # **This is the assertion the moduledoc's transaction claim rests on.**
      # `Repo.transaction/1` whose function RETURNS `{:error, …}` COMMITS; only a
      # rollback or a raise fails it. So a `with` that returned the error would
      # leave the event row behind with no notification — the "fan-out that has
      # not happened" state this module exists to make impossible.
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

      # The second person's inbox has one row and the first person's has one row,
      # which is the entire reason there are two tables rather than one.
      assert length(Notifications.list(@account_id, @recipient)) == 1
      assert length(Notifications.list(@account_id, @other_recipient)) == 1
      assert Notifications.unread_count(@account_id, @recipient) == 1
      assert Notifications.unread_count(@account_id, @other_recipient) == 1
    end

    test "THE SAME PERSON NAMED TWICE IS ONE ROW, AND BOTH ENTRIES ARE THE STORED ROW" do
      # **THIS IS THE ASSERTION THE UNIQUE INDEX EXISTS FOR**, and it was
      # unreachable through a single-recipient `record/2`: every call minted a new
      # `notification_event_id`, so
      # `notifications_one_per_recipient_index` could never fire and the
      # `on_conflict: :nothing` branch was dead code. A constraint that cannot be
      # violated is not a constraint.
      #
      # It is also the wrong-looking answer: two entries for one person is a
      # caller that built a list badly, and an unread count that is one too high
      # is the kind of bug nobody reports.
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
      # Partial fan-out is the failure this design exists to prevent: three of
      # five people told is not a state anybody can render.
      good = @recipient
      bad = {"user", String.duplicate("a", 300)}

      assert {:error, {:notification, changeset}} =
               Notifications.record(@account_id, type: "comment", recipients: [good, bad])

      assert %{recipient_id: ["should be at most 255 character(s)"]} = errors_on(changeset)

      # Neither the notification NOR the event it would have pointed at.
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
      # Three in a known order, and every assertion below reads them back
      # newest-first, so the order they are created in and the order the list
      # answers in are opposites.
      %{one: notify!(), two: notify!(), three: notify!()}
    end

    test "newest first", %{one: one, two: two, three: three} do
      assert ids(@recipient) == [three.id, two.id, one.id]
    end

    test "another recipient sees nothing" do
      assert Notifications.list(@account_id, @other_recipient) == []
    end

    test "another ACCOUNT sees nothing, even for the same recipient id", %{one: one} do
      # The same person addressed by another account is a different inbox. That is
      # the reason `account_id` is on both tables rather than derived from the
      # event, and it is why the predicate leads with it.
      assert one.id in ids(@recipient)

      assert Notifications.list(@other_account_id, @recipient) == []
    end

    test "unread: true filters out what has been read", %{one: one, two: two, three: three} do
      assert {:ok, _} = Notifications.mark_read(@account_id, @recipient, one.id)

      # Exactly the rows with no `read_at` — which is `two` and `three` and NOT
      # "everything but the first".
      assert ids(@recipient, unread: true) == [three.id, two.id]
      assert one.id not in ids(@recipient, unread: true)
    end

    test "seen and not read is still unread", %{two: two} do
      assert {:ok, marked} = Notifications.mark_seen(@account_id, @recipient, two.id)

      assert marked.seen_at
      assert marked.read_at == nil
      # The distinction the two columns exist for, and the reason the filter is on
      # `read_at` rather than on "has been touched".
      assert two.id in ids(@recipient, unread: true)
    end

    test ":after pages backwards, strictly, without repeating the boundary row",
         %{one: one, two: two, three: three} do
      # STRICT `<` and not `<=`, and the difference is the whole of the cursor: a
      # boundary that repeats its row hands a client two copies of one
      # notification and no way to tell which is which.
      assert ids(@recipient, after: three.inserted_at) == [two.id, one.id]
      assert ids(@recipient, after: one.inserted_at) == []
    end

    test ":after with something that is not a DateTime is no cursor at all", %{one: one} do
      # A query parameter that arrived as the wrong shape is not a page and is not
      # an error — it is a first page, which is the answer a caller can render.
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
      # Exercised against the real query rather than by asserting a constant, so
      # the cap is a property of `list/3` and not of a number in a comment. 130
      # rows, because a cap of 100 cannot be told from a default of 100 by
      # anything under the ceiling.
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

      # Seen is not read, and the badge does not move for it.
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

      # "When did they first see it" is a fact. A call that moved it would be
      # answering a different question with the same function.
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
      # Opening something is a stronger statement than seeing it, and a deep link
      # can open a notification that was never in a list — so `read_at` with no
      # `seen_at` is a row `notifications_read_implies_seen_check` refuses.
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
      # An unread filter that resets on every page load is a count nobody can act
      # on, so neither mark ever clears the other.
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
      # Three lists, three questions: what courier tells a person inside the
      # product, what it sends as mail, and what it puts on the bus for other
      # services. Folding this one into either of the others would make every
      # in-app event a bus event, and `cafaye.yml`'s `exposes.events` is a
      # contract with core's frozen payload schemas.
      assert Notifications.types() != Courier.Mailers.types()
      assert Notifications.types() != Courier.Events.types()
    end
  end

  # The ids, and nothing else. Every list assertion in this file is about WHICH
  # rows came back and in WHAT order, so asserting on ids keeps a change to a
  # column out of a test about ordering.
  defp ids(recipient, opts \\ []) do
    @account_id
    |> Notifications.list(recipient, opts)
    |> Enum.map(& &1.id)
  end
end
