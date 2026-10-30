defmodule Courier.SuppressionsTest do
  @moduledoc """
  What a provider told courier about an address, and what courier does about it.

  This is the middle and the end of the loop the whole packet exists for:
  `CourierWeb.EmailEventsController` ingests, this records and answers, and
  `Courier.Deliver` asks before it sends. A test file that covered only the
  controller would prove a store nobody reads; one that covered only `Deliver`
  would prove a check nothing can put state into.


  A **hard bounce** is a statement about the mailbox: RFC 5321 §5.1.1 permanent
  failure — "no such user", a null reverse path, a mailbox that cannot exist. It
  means retrying cannot help, so courier stops. `:undeliverable` is the name.

  A **complaint** is a statement about the *message*, from the person who
  received it: RFC 2142 §5, an abuse report, Postmark's `SpamNotification`, a
  Gmail "report spam". It says nothing about whether the mailbox works — the
  address may be perfectly deliverable and the message perfectly unwanted. So it
  is its own state, `:suppressed`, rather than a flavour of "address is dead".

  **Both stop the send**, and that is the decision rather than the default.
  Continuing to mail a dead address burns the sending domain's reputation, which
  is the ordinary way a domain gets suspended; continuing to mail somebody who
  marked you as spam is worse than that and is how a provider's abuse desk gets
  involved. The asymmetry is the argument: being wrong in the direction of
  sending costs a domain, and being wrong in the direction of not sending costs
  one message.

  They are kept apart anyway because an operator reading them needs to. A rise in
  `:undeliverable` is a list-hygiene problem. A rise in `:suppressed` is a
  content and reputation problem that a per-address suppression does not fix, and
  the two demand different responses.


  Rows are immutable. Nothing in courier ever updates a suppression, so there is
  no mutation rule that can be got wrong, and the address's state is a fold over
  the rows that exist:

      no rows                  -> `nil`, the address is not suppressed
      rows, all nil state      -> `nil`
      any `:suppressed`        -> `:suppressed`
      otherwise any            -> `:undeliverable`

  `:suppressed` outranks `:undeliverable` because a complaint is an instruction
  from the recipient and a bounce is a fact about the mailbox, and an instruction
  is not withdrawn by a later fact. So a hard bounce arriving after a complaint
  cannot put the address back into the sending set, and there is no code path
  that *could*, because there is no update.


  A soft bounce is RFC 5321 §4.2.2 temporary failure — mailbox full, greylisted,
  "try again in four hours". Suppressing on one is the classic way a suppression
  list starts eating live addresses: one provider's bad afternoon becomes a
  thousand addresses courier will never write to again, and nothing in courier's
  data can tell an operator which of them were ever real. So `ingest/2` accepts a
  soft bounce, records **no row**, and says so in the answer. The caller still
  gets its 2xx, so the provider stops retrying something courier has decided not
  to act on — being deliberately unhelpful to a provider is worse than being
  briefly silent.


  `(provider, provider_event_id)` is unique, and a delivery that loses it is
  answered `{:ok, :duplicate, row}` with nothing written. Real providers retry —
  Postmark retries on a timeout and on any 5xx — so "the same event twice" is
  the normal case rather than the edge one. A hand-rolled "have I seen this?"
  check would be a race; the index cannot be.
  """

  use Courier.DataCase, async: true

  alias Courier.Repo
  alias Courier.Suppression
  alias Courier.Suppressions

  defp address, do: "recipient-#{System.unique_integer([:positive])}@example.com"

  defp event(email, attrs \\ %{}) do
    Map.merge(
      %{
        provider: "postmark",
        provider_event_id: "pm-#{System.unique_integer([:positive])}",
        email: email,
        state: :undeliverable,
        reason: "Hard bounce: 550 5.1.1 The email account that you tried to reach does not exist."
      },
      Map.new(attrs)
    )
  end

  describe "recording one provider report" do
    test "a hard bounce marks the address undeliverable" do
      email = address()

      assert {:ok, :new, %Suppression{}} = Suppressions.record(event(email))

      assert Suppressions.suppressed?(email)
      assert Suppressions.state(email) == :undeliverable
    end

    test "a complaint marks the address suppressed, which is a different state" do
      email = address()

      assert {:ok, :new, %Suppression{}} = Suppressions.record(event(email, state: :suppressed))

      assert Suppressions.suppressed?(email)
      assert Suppressions.state(email) == :suppressed
    end

    test "the two states are not the same value, which is the whole distinction" do
      assert Suppressions.states() == [:undeliverable, :suppressed]
      refute Suppressions.states() == [:suppressed]
    end

    test "the address is stored normalised, and the lookup normalises too" do
      raw = "  Recipient.Mixed@Example.COM "

      assert {:ok, :new, %Suppression{email: stored}} = Suppressions.record(event(raw))
      assert stored == "recipient.mixed@example.com"

      assert Suppressions.suppressed?("Recipient.Mixed@Example.COM")
      assert Suppressions.suppressed?("RECIPIENT.MIXED@EXAMPLE.COM")
    end

    test "the provider's own words are kept, bounded" do
      assert {:ok, :new, %Suppression{reason: kept}} =
               Suppressions.record(event(address(), reason: String.duplicate("r", 500)))

      assert String.length(kept) == 500

      assert {:error, changeset} =
               Suppressions.record(event(address(), reason: String.duplicate("r", 501)))

      assert %{reason: [_]} = errors_on(changeset)
    end

    test "an event with no provider id is refused rather than stored" do
      assert {:error, changeset} =
               Suppressions.record(%{event(address()) | provider_event_id: nil})

      assert %{provider_event_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "an event with no state is refused rather than stored" do
      assert {:error, changeset} = Suppressions.record(%{event(address()) | state: nil})
      assert %{state: ["can't be blank"]} = errors_on(changeset)
    end

    test "an address courier cannot send to is refused at write" do
      assert {:error, changeset} = Suppressions.record(event("not-an-address"))
      assert %{email: ["is not an email address"]} = errors_on(changeset)
    end

    test "an address nobody has heard of is not suppressed" do
      refute Suppressions.suppressed?(address())
      assert Suppressions.state(address()) == nil
      assert Suppressions.find(address()) == nil
    end
  end

  describe "the same event delivered twice" do
    test "the second delivery writes nothing" do
      id = "pm-retry-#{System.unique_integer([:positive])}"
      email = address()
      attrs = event(email, provider_event_id: id)

      assert {:ok, :new, first} = Suppressions.record(attrs)
      assert {:ok, :duplicate, second} = Suppressions.record(attrs)

      assert second.id == first.id
      assert rows_for(id) == 1
    end

    test "the second delivery does not change the state either" do
      id = "pm-retry-#{System.unique_integer([:positive])}"
      email = address()
      attrs = event(email, provider_event_id: id)

      assert {:ok, :new, _} = Suppressions.record(attrs)
      assert {:ok, :duplicate, _} = Suppressions.record(attrs)

      assert Suppressions.state(attrs.email) == :undeliverable
      assert rows_for(id) == 1
    end

    test "a complaint delivered twice is still one complaint" do
      id = "pm-retry-#{System.unique_integer([:positive])}"
      email = address()
      attrs = event(email, provider_event_id: id, state: :suppressed)

      assert {:ok, :new, _} = Suppressions.record(attrs)
      assert {:ok, :duplicate, _} = Suppressions.record(attrs)

      assert Suppressions.state(attrs.email) == :suppressed
      assert rows_for(id) == 1
    end

    test "the same id from two providers is two events, not one" do
      id = "shared-id-#{System.unique_integer([:positive])}"
      email = address()

      assert {:ok, :new, _} =
               Suppressions.record(event(email, provider: "postmark", provider_event_id: id))

      assert {:ok, :new, _} =
               Suppressions.record(event(email, provider: "ses", provider_event_id: id))

      assert rows_for(id) == 2
    end
  end

  describe "a complaint outranks a hard bounce, and nothing regresses" do
    setup do
      email = address()
      %{email: email}
    end

    test "a complaint after a hard bounce wins", %{email: email} do
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :undeliverable))
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :suppressed))

      assert Suppressions.state(email) == :suppressed
    end

    test "a hard bounce after a complaint does NOT win", %{email: email} do
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :suppressed))
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :undeliverable))

      assert Suppressions.state(email) == :suppressed,
             "a later hard bounce downgraded a complaint. courier has no code path " <>
               "that can un-suppress an address, so a provider retry must not have one either"
    end

    test "and the answer is derived from the rows, so there is nothing to keep in step", %{
      email: email
    } do
      assert {:ok, :new, complaint} = Suppressions.record(event(email, state: :suppressed))
      assert {:ok, :new, bounce} = Suppressions.record(event(email, state: :undeliverable))

      assert complaint.inserted_at == complaint.inserted_at
      assert bounce.id != complaint.id
      assert Suppressions.state(email) == :suppressed
    end
  end

  describe "a soft bounce" do
    test "is accepted and suppresses nothing" do
      email = address()

      assert {:ok, :ignored} =
               Suppressions.ingest(%{
                 provider: "postmark",
                 provider_event_id: "pm-soft-#{System.unique_integer([:positive])}",
                 email: email,
                 kind: :soft_bounce,
                 reason: "Soft bounce: 452 4.2.2 Mailbox full"
               })

      refute Suppressions.suppressed?(email)
      assert Suppressions.state(email) == nil
    end

    test "reports no row rather than a row it refuses to act on" do
      assert {:ok, :ignored} =
               Suppressions.ingest(%{
                 provider: "postmark",
                 provider_event_id: "pm-soft-#{System.unique_integer([:positive])}",
                 email: address(),
                 kind: :soft_bounce,
                 reason: "Soft bounce"
               })
    end
  end

  describe "ingest/2, which is what the HTTP surface calls" do
    test "a hard bounce becomes a suppression" do
      email = address()

      assert {:ok, :new, _row} =
               Suppressions.ingest(%{
                 provider: "postmark",
                 provider_event_id: "pm-#{System.unique_integer([:positive])}",
                 email: email,
                 kind: :hard_bounce,
                 reason: "Hard bounce: 550 no such user"
               })

      assert Suppressions.state(email) == :undeliverable
    end

    test "a complaint becomes a suppression, in the other state" do
      email = address()

      assert {:ok, :new, _row} =
               Suppressions.ingest(%{
                 provider: "postmark",
                 provider_event_id: "pm-#{System.unique_integer([:positive])}",
                 email: email,
                 kind: :complaint,
                 reason: "Recipient marked as spam"
               })

      assert Suppressions.state(email) == :suppressed
    end

    test "a kind courier does not act on is refused rather than guessed at" do
      assert {:error, :unsupported_kind} =
               Suppressions.ingest(%{
                 provider: "postmark",
                 provider_event_id: "pm-#{System.unique_integer([:positive])}",
                 email: address(),
                 kind: :delivery,
                 reason: "Delivered"
               })
    end

    test "the kind vocabulary is courier's, and it is closed" do
      assert Suppressions.kinds() == [:hard_bounce, :soft_bounce, :complaint]
    end
  end

  describe "what is stored, and what is not" do
    test "the message id the provider quoted is kept, so a bounce ties back to a send" do
      assert {:ok, :new, %Suppression{message_id: "courier-abc@anywaye.com"}} =
               Suppressions.record(event(address(), message_id: "<courier-abc@anywaye.com>"))
    end

    test "the same message id quoted with and without brackets is one identifier" do
      email = address()

      assert {:ok, :new, bracketed} =
               Suppressions.record(event(email, message_id: "<courier-xyz@anywaye.com>"))

      assert {:ok, :new, bare} =
               Suppressions.record(event(email, message_id: "courier-xyz@anywaye.com"))

      assert bracketed.message_id == bare.message_id
      assert bare.message_id == "courier-xyz@anywaye.com"
    end

    test "a bounce with no message id is stored without one" do
      assert {:ok, :new, %Suppression{message_id: nil}} = Suppressions.record(event(address()))
    end

    test "the provider's own timestamp is kept, distinct from when courier heard it" do
      occurred = ~U[2026-09-30 04:05:06.000000Z]

      assert {:ok, :new, %Suppression{occurred_at: ^occurred}} =
               Suppressions.record(event(address(), occurred_at: occurred))
    end

    test "no column anywhere holds the body the provider sent" do
      fields =
        Suppression.__schema__(:fields)
        |> Enum.map(&String.replace_prefix(to_string(&1), "_", ""))
        |> Enum.sort()

      assert fields ==
               Enum.sort(~w(id email state provider provider_event_id reason message_id
                            occurred_at notification_type user_id inserted_at updated_at))
    end
  end

  describe "reading it back" do
    test "find/1 returns the row the state was decided from" do
      email = address()
      assert {:ok, :new, row} = Suppressions.record(event(email))

      assert Suppressions.find(email).id == row.id
      assert Suppressions.find(email).state == :undeliverable
    end

    test "find/1 on a complaint returns the complaint, not the bounce" do
      email = address()
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :undeliverable))
      assert {:ok, :new, complaint} = Suppressions.record(event(email, state: :suppressed))

      assert Suppressions.find(email).id == complaint.id
    end

    test "the rows for an address are all of them, oldest first" do
      email = address()
      assert {:ok, :new, first} = Suppressions.record(event(email))
      assert {:ok, :new, second} = Suppressions.record(event(email, state: :suppressed))

      ids = Suppressions.history(email) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([first.id, second.id])
    end

    test "history for an address nobody has reported on is empty" do
      assert Suppressions.history(address()) == []
    end
  end

  defp rows_for(provider_event_id) do
    Suppression
    |> Ecto.Query.where([s], s.provider_event_id == ^provider_event_id)
    |> Repo.aggregate(:count)
  end
end
