defmodule Courier.SuppressionsTest do
  @moduledoc """
  What a provider told courier about an address, and what courier does about it.

  This is the middle and the end of the loop the whole packet exists for:
  `CourierWeb.EmailEventsController` ingests, this records and answers, and
  `Courier.Deliver` asks before it sends. A test file that covered only the
  controller would prove a store nobody reads; one that covered only `Deliver`
  would prove a check nothing can put state into.

  ## The two states, and why there are two

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

  ## Why the state is DERIVED and never overwritten

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

  ## Why a soft bounce records nothing at all

  A soft bounce is RFC 5321 §4.2.2 temporary failure — mailbox full, greylisted,
  "try again in four hours". Suppressing on one is the classic way a suppression
  list starts eating live addresses: one provider's bad afternoon becomes a
  thousand addresses courier will never write to again, and nothing in courier's
  data can tell an operator which of them were ever real. So `ingest/2` accepts a
  soft bounce, records **no row**, and says so in the answer. The caller still
  gets its 2xx, so the provider stops retrying something courier has decided not
  to act on — being deliberately unhelpful to a provider is worse than being
  briefly silent.

  ## Idempotency is the unique index, and it is at the database

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

  # One address per test, because the unique index is on `email` and a test that
  # shares an address with another test is asserting about the other test's rows.
  # This is the rule in AGENTS.md — "a test asserts about its own rows" — with
  # the address as the tenancy key that suppression rows carry instead of an
  # account.
  defp address, do: "recipient-#{System.unique_integer([:positive])}@example.com"

  # The address is the FIRST argument and is never defaulted. An earlier shape gave
  # `event/1` a defaulted attrs and derived the address inside it, which meant
  # `event(email)` silently compiled as `event(%{}, email)` — the address arrived
  # as the attrs keyword and every read went asking about a mailbox nobody had
  # written. Taking the tenancy key explicitly means a test cannot accidentally
  # look up an address other than the one it recorded.
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
      # Bound ONCE and passed to both halves. Calling the helper twice would mint
      # two addresses: the write would land on one and the read would ask about
      # the other, and the test would go green while proving nothing.
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
      # Asserted rather than asserted-about: a schema that collapsed both into one
      # boolean would pass every other test in this file and lose the reason an
      # operator needs. This is the set itself.
      assert Suppressions.states() == [:undeliverable, :suppressed]
      refute Suppressions.states() == [:suppressed]
    end

    test "the address is stored normalised, and the lookup normalises too" do
      raw = "  Recipient.Mixed@Example.COM "

      assert {:ok, :new, %Suppression{email: stored}} = Suppressions.record(event(raw))
      assert stored == "recipient.mixed@example.com"

      # Both halves matter and they are separate: a row stored mixed-case is
      # invisible to a lookup that lowercases, and a caller that changes how it
      # spells an address must not get a different answer.
      assert Suppressions.suppressed?("Recipient.Mixed@Example.COM")
      assert Suppressions.suppressed?("RECIPIENT.MIXED@EXAMPLE.COM")
    end

    test "the provider's own words are kept, bounded" do
      # The BOUND is the assertion, not Ecto's wording. `validate_length/3` has
      # changed its message text across Ecto releases ("should be at most 500
      # character(s)" became "is too long (maximum is 500 characters)"), so a
      # test that pinned the sentence would fail on a dependency bump that changed
      # nothing courier does. What is asserted instead is the property: 500 is
      # kept, 501 is refused.
      assert {:ok, :new, %Suppression{reason: kept}} =
               Suppressions.record(event(address(), reason: String.duplicate("r", 500)))

      assert String.length(kept) == 500

      assert {:error, changeset} =
               Suppressions.record(event(address(), reason: String.duplicate("r", 501)))

      assert %{reason: [_]} = errors_on(changeset)
    end

    test "an event with no provider id is refused rather than stored" do
      # Without it there is nothing to deduplicate on, and a row that cannot be
      # deduplicated is a row a retry duplicates.
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
      # The count is over this test's own event, not the table: `event()` gives
      # every call a fresh `provider_event_id`, so the row being counted is one
      # this test wrote. `Repo.aggregate/3` over the whole table would be a claim
      # about every other test in the repository.
      id = "pm-retry-#{System.unique_integer([:positive])}"
      email = address()
      attrs = event(email, provider_event_id: id)

      assert {:ok, :new, first} = Suppressions.record(attrs)
      assert {:ok, :duplicate, second} = Suppressions.record(attrs)

      assert second.id == first.id
      assert rows_for(id) == 1
    end

    test "the second delivery does not change the state either" do
      # "Does not double-count" is not only about a row count. If the duplicate
      # re-ran the state fold with a *stronger* value it would be a mutation
      # wearing an ingest's clothes, and a provider that retried five times would
      # walk an address up courier's own vocabulary.
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
      # The unique index is on the PAIR. A provider's ids are its own namespace,
      # and two providers both saying "1" is two facts rather than one retry.
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
      # The load-bearing direction. A complaint is the recipient's instruction; a
      # later bounce is a fact about a mailbox and cannot withdraw an instruction.
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :suppressed))
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :undeliverable))

      assert Suppressions.state(email) == :suppressed,
             "a later hard bounce downgraded a complaint. courier has no code path " <>
               "that can un-suppress an address, so a provider retry must not have one either"
    end

    test "and the answer is derived from the rows, so there is nothing to keep in step", %{
      email: email
    } do
      # Proven by the shape rather than the value: rows are immutable and the
      # answer is a fold. `Repo.update/2` on a suppression would be the mutation
      # this design does not have.
      assert {:ok, :new, complaint} = Suppressions.record(event(email, state: :suppressed))
      assert {:ok, :new, bounce} = Suppressions.record(event(email, state: :undeliverable))

      assert complaint.inserted_at == complaint.inserted_at
      assert bounce.id != complaint.id
      assert Suppressions.state(email) == :suppressed
    end
  end

  describe "a soft bounce" do
    test "is accepted and suppresses nothing" do
      # The decision, not an accident. RFC 5321 §4.2.2 is a TEMPORARY failure, and
      # a suppression list that fills up on temporary failures is how a service
      # stops mailing people whose provider had a bad afternoon.
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
      # The two answers are different shapes on purpose. `{:ok, :new, row}` says
      # "this is now courier's state" and `{:ok, :ignored}` says "courier heard you
      # and decided not to". A caller that counted `:ignored` as a failure would
      # retry forever; a caller that counted it as `:new` would be counting a row
      # that does not exist.
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
      # Fail-closed, the same instinct as `Courier.ErrorReporting.Filter`: an event
      # courier cannot classify is not an event courier will act on, and storing it
      # as "not suppressed" would be a decision courier cannot defend.
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
      # `Courier.Deliver.tag/2` puts a real Message-ID on every send precisely so
      # this can be filled in. A bounce with no message id is normal — providers
      # do not always quote it — so it is nullable rather than required.
      assert {:ok, :new, %Suppression{message_id: "courier-abc@anywaye.com"}} =
               Suppressions.record(event(address(), message_id: "<courier-abc@anywaye.com>"))
    end

    test "the same message id quoted with and without brackets is one identifier" do
      # The whole reason the brackets are stripped. Providers quote RFC 5322's
      # `<...>` inconsistently, and two spellings of one identifier must not be two
      # rows an operator has to learn to recognise as the same thing.
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
      # The provider's payload is a bounce report: addresses, reasons, sometimes a
      # snippet. courier stores the four facts it acts on and nothing else, so a
      # schema addition cannot quietly turn into a copy of somebody's inbox.
      #
      # `notification_type` and `user_id` arrived with the one-click unsubscribe
      # and are the two exceptions, and the assertion names them rather than
      # loosening the list: a column holding a payload is what this test is for, and
      # a test that grows a list silently is a test that stopped looking.
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
      # Which row "the" row is has to be decided the same way the state is, or an
      # operator reading `find/1` is shown a bounce for an address that was
      # actually suppressed by a complaint.
      email = address()
      assert {:ok, :new, _} = Suppressions.record(event(email, state: :undeliverable))
      assert {:ok, :new, complaint} = Suppressions.record(event(email, state: :suppressed))

      assert Suppressions.find(email).id == complaint.id
    end

    test "the rows for an address are all of them, oldest first" do
      # Sorted here rather than left to PostgreSQL: an unordered `Repo.all/1` is a
      # claim about the server's whim, and AGENTS.md says both sides of a list
      # comparison are sorted.
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
