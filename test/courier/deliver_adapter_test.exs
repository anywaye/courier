defmodule Courier.DeliverAdapterTest do
  @moduledoc """
  What happens when the mail provider says no.

  `async: false` because this module swaps `config :courier, Courier.Mailer`'s
  adapter, and application env is VM-global: for the length of this module any
  other test in the suite that delivers mail would deliver it through the
  failing adapter instead of the Test adapter. `on_exit` restores it before the
  next test starts.

  The provider-refused case belongs here rather than in `Courier.DeliverTest`
  because only a swapped adapter exercises the real Swoosh path — the Test
  adapter cannot fail.
  """

  use Courier.DataCase, async: false

  alias Courier.Deliver
  alias Courier.OutboxEvent

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @payload %{
    user_id: @user_id,
    email: "kaka@example.com",
    name: "Kaka",
    url: "https://anywaye.com/verify?token=abc123"
  }

  setup do
    original = Application.get_env(:courier, Courier.Mailer)

    on_exit(fn -> Application.put_env(:courier, Courier.Mailer, original) end)

    Application.put_env(:courier, Courier.Mailer, adapter: Courier.TestSupport.FailingAdapter)

    :ok
  end

  test "the reason comes back to the caller" do
    assert {:error, {:delivery_failed, :provider_unavailable}} = Deliver.welcome(@payload)
  end

  test "no event is recorded for a send that did not happen" do
    # The outbox row and the provider call share a transaction. If the provider
    # refuses, the transaction rolls back and there is nothing claiming a mail
    # went out.
    assert {:error, {:delivery_failed, :provider_unavailable}} = Deliver.welcome(@payload)

    assert Repo.all(OutboxEvent) == []
  end
end
