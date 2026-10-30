defmodule Courier.InboundConfigTest do
  @moduledoc """
  The inbound signing secret: how it is stored, and the shape assertions that
  stand in for a boot this suite does not perform.


  Both of these were wrong at least once while this surface was being built, and
  neither is visible in a config file:

    * `config :courier, :inbound_secrets, resend: "…"` — the keyword shorthand —
      stores a **keyword list**. `Application.get_env/2` hands that back looking
      nothing like the map the lookup reads, and the symptom is a `BadMapError` on
      the request path of a route whose entire vocabulary is a 400, a 401, a 422
      and a 500 and never a crash.
    * an **atom** key does not match a **string** lookup, because the lookup key
      comes from the request's path. That one is a 500 on every delivery, naming
      a missing variable, while the variable is set and correct.

  Both are the same class of error as the `COURIER_SECRET_BOX_KEY` one this
  repository already refuses: a required value with a shape nothing checks, where
  a deployment that got it wrong boots cleanly and then fails every request.
  `config/runtime.exs` refuses to boot without the variable, and this file holds
  it to the two shapes that would pass that refusal and still not work.


  `config/runtime.exs` is not evaluated in the test environment — it is guarded by
  `config_env() == :prod` and running it would need a `DATABASE_URL` and a
  `SECRET_KEY_BASE` as well. The **release** job in `ci/ci.yml`
  asserts the refusal for real, alongside the one for `COURIER_SECRET_BOX_KEY`,
  because that is the only place a production `runtime.exs` is ever evaluated.
  """

  use ExUnit.Case, async: true

  alias Courier.InboundConfig
  alias Courier.TestSupport.FakeResend

  @key :inbound_secrets

  describe "the stored value" do
    test "is a map, and a keyword list would be a BadMapError on the request path" do
      stored = Application.get_env(:courier, @key)

      assert is_map(stored),
             "config/test.exs stores :inbound_secrets as #{inspect(stored)}. The keyword " <>
               "shorthand `resend: \"…\"` is a keyword LIST, and `Courier.InboundConfig` " <>
               "reads a map — so every inbound request would raise rather than answer."
    end

    test "is keyed by STRING, because the lookup key is the request's path" do
      stored = Application.get_env(:courier, @key)

      assert Map.has_key?(stored, "resend"),
             "the key must be the string \"resend\": the route's path segment is what " <>
               "looks the secret up, and an atom key would never match it — a 500 on " <>
               "every delivery naming a variable that is set."

      refute Map.has_key?(stored, :resend),
             "an atom key is present as well. It is dead configuration: nothing reads it, " <>
               "so it looks configured and is not."
    end

    test "carries a Svix secret, with the prefix `Courier.Inbound.Signature` requires" do
      assert "whsec_" <> _ = InboundConfig.secret("resend")
    end
  end

  describe "the test secret" do
    test "is the one `Courier.TestSupport.FakeResend` signs with" do
      assert InboundConfig.secret("resend") == FakeResend.secret()
    end

    test "and the positive suite would notice if they stopped matching" do
      assert FakeResend.signed(FakeResend.bounce()) |> elem(1) |> Map.values() |> Enum.any?()
      assert FakeResend.other_secret() != FakeResend.secret()
    end
  end

  describe "the lookup" do
    test "answers nil for a provider courier holds no secret for" do
      assert InboundConfig.secret("postmark") == nil
    end

    test "answers nil for no provider at all" do
      assert InboundConfig.secret(nil) == nil
    end

    test "accepts an atom as well as a string" do
      assert InboundConfig.secret(:resend) == FakeResend.secret()
    end
  end

  describe "configured_providers/0" do
    test "names the provider and never the secret" do
      assert InboundConfig.configured_providers() == ["resend"]
      refute inspect(InboundConfig.configured_providers()) =~ "whsec_"
    end
  end
end
