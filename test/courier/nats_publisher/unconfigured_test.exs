defmodule Courier.NatsPublisher.UnconfiguredTest do
  @moduledoc """
  The other half of the packet's two outcomes, and it is the half that is a
  refusal rather than a feature.

  With no `NATS_URL`, courier holds no connection, and nothing is marked
  published. `Courier.NatsPublisher.Unconfigured` answers
  `{:error, :nats_url_not_set}` and the relay records it in `last_error`, so:

    * `published_at` stays `nil` — the row is still unpublished and still
      claimable, so a broker configured later drains it;
    * `Courier.Nats.supervised_child/0` answers `:ignored`, so the no-broker
      shape is one entry the supervisor does not start rather than a branch
      somewhere that has to remember not to.

  ## Why this is a test about rows rather than about configuration

  Because "no loop started and no row is marked" is a claim about two things, and
  the second of them is a database assertion. A test that read
  `Application.get_env(:courier, :nats_publisher)` and found
  `Courier.NatsPublisher.Unconfigured` would prove the configuration and nothing
  about what happens to an outbox row when nobody configured a broker — which is
  the thing that would go wrong. So this file creates a real row through
  `Courier.Deliver`, performs the real relay, and reads the row back.

  What is deliberately NOT asserted here is that `Courier.NatsPublisher.Noop` is
  never wired in. `config/test.exs` configures it, and that is correct: it is the
  suite's stand-in. The shape this file holds is the one
  `config/runtime.exs` builds for every non-test environment — the Bus when
  `NATS_URL` is set, this module when it is not — and `Courier.NatsTest` asserts
  the branch that follows from the variable.

  ## `async: false`

  Application env is VM-global and `Courier.Nats` is a named process.
  """

  use Courier.DataCase, async: false

  use Oban.Testing, repo: Courier.Repo

  alias Courier.Deliver
  alias Courier.Nats
  alias Courier.NatsPublisher.Unconfigured
  alias Courier.OutboxEvent
  alias Courier.Workers.ProcessOutboxWorker

  @user_id "9f2a1b8c-3d4e-4f5a-8b6c-7d8e9f0a1b2c"

  defp delivered_row! do
    {:ok, result} =
      Deliver.welcome(%{
        user_id: @user_id,
        email: "kaka@example.com",
        name: "Kaka",
        url: "https://anywaye.com/verify?token=abc123"
      })

    Repo.get!(OutboxEvent, result.event_id)
  end

  setup do
    original_url = Application.get_env(:courier, :nats)
    original_publisher = Application.get_env(:courier, :nats_publisher)

    Application.put_env(:courier, :nats, url: nil)
    Application.put_env(:courier, :nats_publisher, Unconfigured)

    on_exit(fn ->
      Application.put_env(:courier, :nats, original_url)
      Application.put_env(:courier, :nats_publisher, original_publisher)
    end)

    :ok
  end

  describe "the publisher" do
    test "refuses rather than acknowledging" do
      # The one assertion that cannot be made about Noop: it answers :ok.
      assert Unconfigured.publish(%{"type" => "courier.email.delivered"}) ==
               {:error, :nats_url_not_set}
    end
  end

  describe "with no broker configured" do
    test "no connection is started, and the tree says so" do
      # No loop. Not "a loop that does nothing" — no process at all.
      assert Courier.Nats.supervised_child() == []
      assert is_nil(Process.whereis(Courier.Nats))
      assert Nats.connection() == {:error, :not_connected}
    end

    test "no row is marked published, and the row still exists" do
      row = delivered_row!()

      assert {:error, %{published: 0, failed: 1, reason: :nats_url_not_set}} =
               perform_job(ProcessOutboxWorker, %{})

      reloaded = Repo.get!(OutboxEvent, row.id)

      assert is_nil(reloaded.published_at)
      assert reloaded.attempt_count == 1
      assert reloaded.last_error == "nats_url_not_set"
    end

    test "the row is still there to be published when a broker appears" do
      row = delivered_row!()

      # Two passes, which is what an outbox with no broker does: claim, refuse,
      # leave the row claimable. The row is neither dropped nor marked.
      assert {:error, %{failed: 1}} = perform_job(ProcessOutboxWorker, %{})
      assert {:error, %{failed: 1}} = perform_job(ProcessOutboxWorker, %{})

      reloaded = Repo.get!(OutboxEvent, row.id)
      assert is_nil(reloaded.published_at)
      assert reloaded.attempt_count == 2
      assert Enum.count(Repo.all(OutboxEvent), fn e -> e.id == row.id end) == 1
    end
  end

  describe "the configuration that decides between the two halves" do
    test "no config file wires the suite's stand-in outside config/test.exs" do
      # The one thing that cannot happen outside the suite: the Noop answering
      # :ok. `config/test.exs` configures it and is the only file allowed to;
      # "the test double is the default" is how a deployment drains its outbox
      # into nowhere the first time somebody forgets a key.
      for path <- Path.wildcard("config/*.exs") do
        # Comments stripped before the search. `config/runtime.exs` names the Noop
        # in prose — "what the unset case deliberately does NOT do" — and a scan
        # that counted comments would fail on the sentence explaining the
        # refusal. A scan that only looked at assigned lines is the check that
        # bites.
        statements =
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
          |> Enum.join("\n")

        if statements =~ "Courier.NatsPublisher.Noop" and not String.ends_with?(path, "test.exs") do
          flunk("#{path} configures Courier.NatsPublisher.Noop")
        end
      end
    end

    test "runtime.exs names both halves of the NATS_URL condition" do
      source = File.read!("config/runtime.exs")

      # The publisher that publishes, the publisher that refuses, and the guard
      # that keeps both out of the suite. Three names, one condition.
      assert source =~ "Courier.NatsPublisher.Bus"
      assert source =~ "Courier.NatsPublisher.Unconfigured"
      assert source =~ "config_env() != :test"
    end
  end
end
