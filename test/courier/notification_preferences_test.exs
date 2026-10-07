defmodule Courier.NotificationPreferencesTest do
  @moduledoc """
  Notification preferences are courier's one piece of per-user state, and the
  only thing standing between a user and mail they asked not to receive. The
  cases that matter are the boring ones: what a user who has never touched this
  endpoint sees, whether turning something off sticks, and whether turning
  something on for one type quietly turns it on for another.

  The last block is the one this surface grew when it stopped being
  unauthenticated: a row records the **account** entitled to it, so
  `list/2` and `update/3` answer `{:error, :not_found}` for an account that does
  not own the user rather than another account's answer.
  """

  use Courier.DataCase, async: true

  alias Courier.NotificationPreferences

  @one "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @two "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

  # Tenancy keys, not credentials. Minted per test the way courier-15 minted
  # accounts for its row-counting tests: a claim about what this account stored
  # must not be a claim about every row in the table.
  @account "1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d"
  @other_account "2b3c4d5e-6f7a-4b9c-8d1e-2f3a4b5c6d7e"

  # The four types `Courier.Mailers` can send. `account_security` is the fourth,
  # added by the sessions-revoked consumer — and it is in this list because
  # `NotificationPreferences.types/0` delegates to `Mailers.types/0`: a type
  # courier can send is a type a user can be asked about. The core enum gap
  # (the delivered-event schema still freezes three) is reported, not hidden
  # here: `REPORT-courier-consumer-sessionsrevoked-01.md`.
  @types ~w(welcome password_reset team_invitation account_security)

  # THE ACCOUNT THIS FILE WRITES AS. `notification_preferences` is protected, so
  # an INSERT with no identity set is refused `42501`. See `Courier.DataCase`.
  @moduletag account: @account

  defp types_of(preferences), do: Enum.map(preferences, & &1.notification_type)

  defp stored(user_id, type, account_id \\ @account) do
    assert {:ok, preferences} = NotificationPreferences.list(account_id, user_id)

    Enum.find(preferences, &(&1.notification_type == type))
  end

  describe "list/2" do
    test "returns every notification type, on, for a user courier has never seen" do
      assert {:ok, preferences} = NotificationPreferences.list(@account, @one)

      assert types_of(preferences) == @types
      assert Enum.all?(preferences, &(&1.email_enabled and &1.push_enabled))
    end

    test "returns the stored values where there are stored values" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      found = stored(@one, "welcome")

      assert found.email_enabled == false
      assert found.push_enabled == true
    end

    test "never shows another user's rows" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      assert {:ok, preferences} = NotificationPreferences.list(@account, @two)
      assert Enum.all?(preferences, & &1.email_enabled)
    end

    test "always returns the same types in the same order" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("team_invitation", false)]
        })

      assert types_of(stored_all(@one)) == @types
      assert types_of(stored_all(@one)) == types_of(stored_all(@one))
    end
  end

  describe "update/3" do
    test "turns one channel off for one type and leaves everything else on" do
      assert {:ok, preferences} =
               NotificationPreferences.update(@account, @one, %{
                 "preferences" => [pref("password_reset", false)]
               })

      assert types_of(preferences) == @types

      by_type = Map.new(preferences, &{&1.notification_type, &1})
      assert by_type["password_reset"].email_enabled == false
      assert by_type["password_reset"].push_enabled == true
      assert by_type["welcome"].email_enabled == true
      assert by_type["team_invitation"].email_enabled == true
    end

    test "turns email back on" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      {:ok, preferences} =
        NotificationPreferences.update(@account, @one, %{"preferences" => [pref("welcome", true)]})

      assert %{email_enabled: true} = Enum.find(preferences, &(&1.notification_type == "welcome"))
    end

    test "push is stored even though nothing sends push yet" do
      {:ok, preferences} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [%{"notification_type" => "welcome", "push_enabled" => false}]
        })

      assert %{push_enabled: false} = Enum.find(preferences, &(&1.notification_type == "welcome"))
    end

    test "an entry that names no channel leaves the stored value alone" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [%{"notification_type" => "welcome"}]
        })

      assert %{notification_type: "welcome", email_enabled: false} = stored(@one, "welcome")
    end

    test "applying the same update twice is the same state" do
      params = %{"preferences" => [pref("team_invitation", false)]}

      assert {:ok, first} = NotificationPreferences.update(@account, @one, params)
      assert {:ok, second} = NotificationPreferences.update(@account, @one, params)
      assert first == second
    end

    test "one row per user and type, however many times it is applied" do
      for _ <- 1..3 do
        {:ok, _} =
          NotificationPreferences.update(@account, @one, %{
            "preferences" => [pref("welcome", false)]
          })
      end

      assert Enum.count(stored_all(@one), &(&1.email_enabled == false)) == 1
    end

    test "rejects a type courier does not send" do
      assert {:error, changeset} =
               NotificationPreferences.update(@account, @one, %{
                 "preferences" => [
                   %{"notification_type" => "weekly_digest", "email_enabled" => false}
                 ]
               })

      assert %{notification_type: ["is not a notification type"]} = errors_on(changeset)
    end

    test "rejects a channel courier does not have" do
      assert {:error, changeset} =
               NotificationPreferences.update(@account, @one, %{
                 "preferences" => [%{"notification_type" => "welcome", "sms_enabled" => false}]
               })

      assert error_on?(changeset, "sms_enabled")
    end

    test "rejects an entry naming the account, which is not an entry field" do
      # Not silently ignored. `account_id` is not part of a preference entry at
      # all, so a body carrying one is a key courier does not have — the same
      # answer as `sms_enabled` above, and deliberately not the same answer as
      # `user_id`, which *is* an entry field that the path overwrites.
      assert {:error, changeset} =
               NotificationPreferences.update(@account, @one, %{
                 "preferences" => [
                   %{"notification_type" => "welcome", "account_id" => @other_account}
                 ]
               })

      assert error_on?(changeset, "account_id")
    end

    test "rejects a body that is not a list of preferences" do
      assert {:error, changeset} =
               NotificationPreferences.update(@account, @one, %{"preferences" => %{}})

      assert error_on?(changeset, "preferences")

      assert {:error, changeset} = NotificationPreferences.update(@account, @one, %{})
      assert error_on?(changeset, "preferences")
    end

    test "rejects an entry with no notification type" do
      assert {:error, changeset} =
               NotificationPreferences.update(@account, @one, %{
                 "preferences" => [%{"email_enabled" => false}]
               })

      assert %{notification_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "changes nothing when any entry in the batch is rejected" do
      params = %{
        "preferences" => [pref("welcome", false), %{"notification_type" => "nope"}]
      }

      assert {:error, _changeset} = NotificationPreferences.update(@account, @one, params)

      assert Enum.all?(stored_all(@one), & &1.email_enabled)
    end
  end

  describe "another account" do
    test "cannot read a user whose preferences exist and are not theirs" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      assert NotificationPreferences.list(@other_account, @one) == {:error, :not_found}
    end

    test "cannot write one either, and writes nothing" do
      # The owner's write comes first: recording the account that owns a user is
      # what the *first* `PUT` for that user does, because courier cannot look a
      # user up and ask which account it belongs to.
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      assert {:error, :not_found} =
               NotificationPreferences.update(@other_account, @one, %{
                 "preferences" => [%{"notification_type" => "welcome", "push_enabled" => false}]
               })

      # The refusal alone would pass with a context that stored the batch and then
      # reported the refusal, so the row is read afterwards by its owner.
      found = stored(@one, "welcome")
      assert found.email_enabled == false
      assert found.push_enabled == true
    end

    test "gets the defaults for a user nobody has written anything for" do
      # The distinction is the whole point of the 404 being narrow: a user with no
      # rows is courier's normal case, because courier does not own users and
      # cannot tell an account's user from one that does not exist.
      assert {:ok, preferences} = NotificationPreferences.list(@other_account, @one)
      assert Enum.all?(preferences, &(&1.email_enabled and &1.push_enabled))
    end

    test "an account that owns a user may still write as many times as it likes" do
      # A 404 must be a statement about tenancy, not a one-shot claim: the owning
      # account is the one that can keep answering for the user.
      for _ <- 1..3 do
        assert {:ok, _} =
                 NotificationPreferences.update(@account, @one, %{
                   "preferences" => [pref("welcome", false)]
                 })
      end

      assert stored(@one, "welcome").email_enabled == false
    end
  end

  describe "enabled?/3" do
    test "email is on for a user who has never been here" do
      assert NotificationPreferences.enabled?(@one, "welcome", :email)
    end

    test "email is off once the user turns it off" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      refute NotificationPreferences.enabled?(@one, "welcome", :email)
    end

    test "turning one type off does not silence another" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      assert NotificationPreferences.enabled?(@one, "password_reset", :email)
    end

    test "one user's choice does not silence another user" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      assert NotificationPreferences.enabled?(@two, "welcome", :email)
    end

    test "a type courier does not send is never enabled" do
      refute NotificationPreferences.enabled?(@one, "weekly_digest", :email)
    end

    test "push is a stored answer, not a delivery decision courier can act on" do
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [%{"notification_type" => "welcome", "push_enabled" => false}]
        })

      refute NotificationPreferences.enabled?(@one, "welcome", :push)
    end

    test "the answer is the user's, and the delivery path is not a tenancy question" do
      # `enabled?/3` takes no account and deliberately does not: `Courier.Deliver`
      # is asked about a *user*, a user id is a global uuid from identity, and
      # there is exactly one row per (user, type) so there is nothing to choose
      # between. Adding an account here would have meant inventing an account for
      # a payload that does not carry one, and the row an account owns is the
      # user's answer either way.
      {:ok, _} =
        NotificationPreferences.update(@account, @one, %{
          "preferences" => [pref("welcome", false)]
        })

      refute NotificationPreferences.enabled?(@one, "welcome", :email)
    end
  end

  defp pref(type, email_enabled),
    do: %{"notification_type" => type, "email_enabled" => email_enabled}

  # Every preference the owning account can see for a user, so an assertion is
  # about what this account stored rather than about what it happened to be sent.
  defp stored_all(user_id), do: elem(NotificationPreferences.list(@account, user_id), 1)

  # An error on a field courier does not have a column for is keyed by the string
  # the request used, so `Keyword.keys/1` — which raises on a string key — cannot
  # be used to look at them. Making those keys atoms would mean `String.to_atom/1`
  # on a request body, which grows the atom table without bound.
  defp error_on?(changeset, field) do
    Enum.any?(changeset.errors, fn {key, _error} -> key == field end)
  end
end
