defmodule Courier.Principal.Introspection.DocumentTest do
  @moduledoc """
  What courier makes of identity's answer, with no network, no database and no
  endpoint in the way.

  This is the module that decides three things the packet called judgement calls,
  and each of them is settled by a table rather than by a paragraph:

    * **whether the token is usable** — and it is *one* answer for every reason
      it is not, because identity already collapsed them and a resolver that
      re-expands them re-creates the oracle identity's own moduledoc is about;
    * **where the account comes from** — `account_id` and nothing else, with no
      `sub` fallback anywhere, asserted here behaviourally *and* on the source;
    * **what courier does with the scope claims** — both names, and a decision
      about what to do when one is missing and when the shape is unreadable.

  ## Why a separate module exists at all

  Because the alternative is a parsing function inside the module that opens a
  socket, and then "an inactive token is a 401" is a claim about a `Req` call
  that has to be dialled, stubbed and re-stubbed to test. Splitting the two means
  every rule below is a table over a literal, and the resolver's own tests are
  left with the one question they are actually about: does courier turn this
  answer into this status.
  """

  use ExUnit.Case, async: true

  alias Courier.Principal
  alias Courier.Principal.Introspection.Document

  @account "ab000000-0000-0000-0000-0000000000c1"

  # identity's own example writes `sub: ab000000-0000-0000-0000-0000000000u1`,
  # and `u` is not a hex digit — so the string in identity's own document is not a
  # uuid any implementation could cast. It is copied here as the other hex
  # position so the fixture is a value identity can actually emit, and the
  # difference is worth recording rather than quietly correcting: a fixture
  # transcribed from a provider's documentation is only as good as the
  # documentation's own examples, and this one would have made the subject read as
  # `nil` for a reason that had nothing to do with courier.
  @subject "ab000000-0000-0000-0000-000000000001"

  # identity's own worked example, copied from the `active` example in
  # `identity/openapi/v1.yaml` under `/v1/introspections`. Every field of it,
  # because a fixture written from memory is indistinguishable from a correct one
  # until the provider's real bytes arrive — and by then it is in production rows.
  @live %{
    "active" => true,
    "sub" => @subject,
    "account_id" => @account,
    "scopes" => "accounts:read accounts:write",
    "scope" => "accounts:read accounts:write",
    "jti" => "ab000000-0000-0000-0000-0000000000a1",
    "name" => "ci-deploy",
    "role" => "owner",
    "iat" => 1_788_168_000,
    "exp" => 1_790_760_000
  }

  describe "a live token" do
    test "becomes a principal on the account it names" do
      assert {:ok, %Principal{account_id: @account} = principal} = Document.from(@live)

      assert principal.account_id == @account
    end

    test "and the subject is the user, not the account" do
      # Two different ids in one document, and they have to stay two different
      # things: `sub` is the user the token names and `account_id` is the tenancy
      # boundary. Reading one as the other is the bug this whole packet is
      # arranged around, so the assertion is that they do not collide.
      assert {:ok, principal} = Document.from(@live)

      assert principal.subject == @subject
      assert principal.subject != principal.account_id
    end

    test "and the scopes are parsed from `scopes`" do
      assert {:ok, %Principal{scopes: scopes}} = Document.from(@live)

      assert "accounts:read" in scopes
      assert "accounts:write" in scopes
    end

    test "a document with only `scope` parses the same way, and that is the whole point" do
      # identity emits BOTH names, byte for byte, because the fleet has not
      # agreed on one (MD7, open in the manager's DECISIONS.md): core's
      # conventions require `scopes` and gateway's verifier reads `scope`. So the
      # day one of them is removed, courier must not be the service that breaks.
      #
      # The claim is asserted in both directions on purpose: reading `scope` alone
      # would pass the first half, and reading `scopes` alone would pass the
      # second. A resolver that reads one name is a resolver waiting for MD7.
      only_singular = Map.delete(@live, "scopes")

      assert {:ok, %Principal{scopes: from_singular}} = Document.from(only_singular)
      assert {:ok, %Principal{scopes: from_plural} = _plural} = Document.from(@live)

      assert from_singular == from_plural
    end

    test "and a document carrying both names reads as the union, not as one of them" do
      # They are byte-identical today, so the union and either one alone agree.
      # This test says what happens the day they are NOT identical: a scope under
      # either name counts. A union that dropped a half would mean a scope
      # identity believes it issued stops authorising the moment the other name
      # goes away.
      divergent = Map.merge(@live, %{"scopes" => "accounts:read", "scope" => "audit_log:read"})

      assert {:ok, %Principal{scopes: scopes}} = Document.from(divergent)

      assert Enum.sort(scopes) == ["accounts:read", "audit_log:read"]
    end
  end

  describe "an unusable token is one answer, whatever the reason" do
    # identity answers `200 {"active": false}` for unknown, revoked, expired, and
    # for a token whose owner has been removed from the account — four situations
    # a resolver could tell apart and must not. So the four documents courier
    # could plausibly see are asserted to be the SAME answer here, and the fact
    # that identity collapses them upstream is not something courier re-decides.
    test "inactive, and the four reasons a token cannot be used" do
      for {name, document} <- [
            {"inactive", %{"active" => false}},
            # What a revoked or expired token looks like to a reader: the claims
            # are still there and only the flag changed.
            {"revoked", Map.put(@live, "active", false)},
            {"expired", Map.merge(%{"active" => false}, %{"exp" => 1_788_168_000})},
            {"orphaned", %{"active" => false, "sub" => @subject}},
            {"no account", %{"active" => false, "scopes" => "accounts:read"}}
          ] do
        assert Document.from(document) == :error,
               "#{name} did not produce the one answer an unusable token gets"
      end
    end

    test "and a document that does not SAY a token is active has not said it is unusable" do
      # The other half of the split, and it is the one that is easy to get wrong.
      # `{"active": false}` is identity answering "no", so it is a 401. A document
      # with no `active` at all is identity not answering, so it is a 503 — and
      # collapsing the two would turn a contract change in a dependency into a
      # stream of "your token is invalid" reports from customers holding tokens
      # that are fine.
      for document <- [%{}, %{"account_id" => @account}, %{"active" => nil}] do
        assert {:error, :unreadable} = Document.from(document),
               "#{inspect(document)} was read as a refusal"
      end
    end
  end

  describe "`account_id` is the only tenancy key, and `sub` is never one" do
    test "an active document with no account is inactive" do
      # identity's own rule: `account_id` is required, there is no `sub`
      # fallback, and a token with no account "cannot be used against any
      # account and is answered `{\"active\": false}`". A document courier is
      # handed that has `sub` and no `account_id` is therefore a caller courier
      # cannot place, and the answer is the refusal.
      no_account = Map.delete(@live, "account_id")

      assert Document.from(no_account) == :error
    end

    test "a document whose only key is `sub` is refused rather than resolved against it" do
      sub_only = %{"active" => true, "sub" => @subject, "scopes" => "accounts:read"}

      assert Document.from(sub_only) == :error,
             "a token with no account_id was accepted on the strength of its `sub`. " <>
               "`sub` is a USER; using it as the tenancy key would hand a service " <>
               "credential one tenant's data on a bug in one service"
    end

    test "an `account_id` courier cannot parse is a contract courier does not understand" do
      # Deliberately NOT the same answer as "no account at all". identity says a
      # token with no account is inactive, so its absence is an ANSWER and courier
      # reports it as a 401. A present-but-malformed `account_id` is not an
      # answer at all: identity broke its own contract, and the loud refusal
      # (`{:error, :unreadable}`, which the resolver turns into a 503) is what
      # stops courier from quietly logging somebody in as the account
      # "not-a-uuid".
      for bad <- ["not-a-uuid", "", 42, nil, %{}, ["ab000000-0000-0000-0000-0000000000c1"]] do
        document = Map.put(@live, "account_id", bad)

        assert {:error, :unreadable} = Document.from(document),
               "#{inspect(bad)} as an account_id did not produce the loud refusal"
      end
    end

    test "a non-string `account_id` is unreadable, not inactive" do
      # The distinction from the case above is deliberate and is asserted here
      # separately: absent means identity said "no", and a wrong TYPE means
      # identity said something courier cannot read. Only the first is a 401.
      assert {:error, :unreadable} = Document.from(%{"active" => true, "account_id" => 42})
    end
  end

  describe "the scopes decision, made on purpose" do
    test "a document with NEITHER claim name is authenticated on tenancy alone" do
      # THE DECISION, stated rather than defaulted. RFC 7662 makes the scope
      # claim optional, identity's `IntrospectionResponse` requires only
      # `active`, and `InactiveClaims()` carries neither name. So "no scope claim
      # at all" is a shape courier must accept rather than refuse: refusing it
      # would mean inventing a requirement identity does not state.
      #
      # AND THE COST IS REAL, so it is written down here rather than discovered:
      # if identity ever stopped emitting both, every caller would still
      # authenticate on `account_id` alone and nothing would say so. That is the
      # packet that has to revisit this, and the test below is what makes the
      # current behaviour a decision a reader can find rather than an accident.
      no_scopes = @live |> Map.delete("scopes") |> Map.delete("scope")

      assert {:ok, %Principal{account_id: @account, scopes: []}} = Document.from(no_scopes)
    end

    test "an empty or whitespace scope claim is an empty set, not a refusal" do
      for empty <- ["", " ", "  \t "] do
        document = @live |> Map.delete("scopes") |> Map.put("scope", empty)

        assert {:ok, %Principal{scopes: []}} = Document.from(document)
      end
    end

    test "scopes are split on whitespace, because a space-separated string is the contract" do
      document = Map.put(@live, "scopes", "  accounts:read   accounts:write  ")

      assert {:ok, %Principal{scopes: scopes}} = Document.from(document)

      assert Enum.sort(scopes) == ["accounts:read", "accounts:write"]
    end

    test "a scope claim that is not a STRING is refused rather than read as nothing" do
      # The load-bearing half of the both-names rule. identity's own document says
      # the value is a string and not an array because "gateway's verifier refuses a
      # non-string claim" — so an array is a shape that exists in the wild, on
      # whichever side of MD7 loses the argument.
      #
      # Reading it as an empty set is the silent version of this bug: a token
      # holding `["webhooks:write"]` would authenticate and appear to hold no
      # scopes, which is the one reading nobody can debug later. courier refuses
      # the document instead — loudly, as a contract courier cannot read.
      for bad <- [["accounts:read"], %{"scope" => "accounts:read"}, 1, true] do
        document = @live |> Map.delete("scopes") |> Map.put("scope", bad)

        assert {:error, :unreadable} = Document.from(document),
               "#{inspect(bad)} as a scope claim was not refused"
      end
    end
  end

  describe "a body courier cannot read at all" do
    test "is loud, not an inactive token" do
      # Every one of these is identity not answering the question courier asked.
      # Mapping them onto `:error` would tell a caller with a perfectly good
      # token that their token is bad — the one lie this boundary cannot tell.
      for body <- [
            "",
            "not json",
            "[]",
            "[{\"active\": true}]",
            "null",
            "42",
            ~s("active"),
            ~s({"active": "true"}),
            ~s({"active": null})
          ] do
        assert {:error, :unreadable} = Document.from(body),
               "#{inspect(body)} was read as something courier can act on"
      end
    end

    test "the bytes and the decoded map are the same question" do
      assert {:ok, %Principal{account_id: @account}} =
               Document.from(Jason.encode!(@live))

      assert {:error, :unreadable} = Document.from(Jason.encode!(%{"active" => "true"}))
    end
  end
end
