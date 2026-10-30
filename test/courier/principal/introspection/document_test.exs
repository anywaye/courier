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

  @subject "ab000000-0000-0000-0000-000000000001"

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
      only_singular = Map.delete(@live, "scopes")

      assert {:ok, %Principal{scopes: from_singular}} = Document.from(only_singular)
      assert {:ok, %Principal{scopes: from_plural} = _plural} = Document.from(@live)

      assert from_singular == from_plural
    end

    test "and a document carrying both names reads as the union, not as one of them" do
      divergent = Map.merge(@live, %{"scopes" => "accounts:read", "scope" => "audit_log:read"})

      assert {:ok, %Principal{scopes: scopes}} = Document.from(divergent)

      assert Enum.sort(scopes) == ["accounts:read", "audit_log:read"]
    end
  end

  describe "an unusable token is one answer, whatever the reason" do
    test "inactive, and the four reasons a token cannot be used" do
      for {name, document} <- [
            {"inactive", %{"active" => false}},
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
      for document <- [%{}, %{"account_id" => @account}, %{"active" => nil}] do
        assert {:error, :unreadable} = Document.from(document),
               "#{inspect(document)} was read as a refusal"
      end
    end
  end

  describe "`account_id` is the only tenancy key, and `sub` is never one" do
    test "an active document with no account is inactive" do
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
      for bad <- ["not-a-uuid", "", 42, nil, %{}, ["ab000000-0000-0000-0000-0000000000c1"]] do
        document = Map.put(@live, "account_id", bad)

        assert {:error, :unreadable} = Document.from(document),
               "#{inspect(bad)} as an account_id did not produce the loud refusal"
      end
    end

    test "a non-string `account_id` is unreadable, not inactive" do
      assert {:error, :unreadable} = Document.from(%{"active" => true, "account_id" => 42})
    end
  end

  describe "the scopes decision, made on purpose" do
    test "a document with NEITHER claim name is authenticated on tenancy alone" do
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
      for bad <- [["accounts:read"], %{"scope" => "accounts:read"}, 1, true] do
        document = @live |> Map.delete("scopes") |> Map.put("scope", bad)

        assert {:error, :unreadable} = Document.from(document),
               "#{inspect(bad)} as a scope claim was not refused"
      end
    end
  end

  describe "a body courier cannot read at all" do
    test "is loud, not an inactive token" do
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
