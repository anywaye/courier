defmodule CourierWeb.Plugs.ForceSSLTest do
  @moduledoc """
  `force_ssl` is ON in genuine prod and OFF everywhere else, on a runtime
  opt-in — because the launch compose network talks courier-to-courier over
  plain HTTP, and the compile-time `force_ssl` in `config/prod.exs` 307'd every
  `POST /v1/messages` on a non-localhost peer (verify, reset and invitation
  mail all RED in the site loop-proof).

  ## The signal

  `COURIER_FORCE_SSL`, read at boot by `config/runtime.exs` into
  `Application.get_env(:courier, :force_ssl_enabled)`. Set to `true` (or `1`)
  in genuine prod; absent everywhere else — local compose, the launch tier, CI
  — serves plain HTTP. No hostname allowlist: that list is what kept rotting.

  ## Why a plug and not `force_ssl:` in `config/prod.exs`

  `force_ssl` is COMPILE-time endpoint configuration (Phoenix.Endpoint docs:
  compile-time config "may be set on config/dev.exs, config/prod.exs and so on,
  but has no effect on config/runtime.exs"). A release bakes whatever prod.exs
  said; no env var read at boot can switch it. So prod.exs says nothing and
  `CourierWeb.Plugs.ForceSSL` enforces the redirect per request, gated on the
  runtime flag.

  ## The probes stay exempt regardless

  `/healthz` and `/readyz` answer plain HTTP in every environment — an
  orchestrator that gets a redirect reads courier as dead.

  ## WHY `async: false`, WITH A REASON

  These tests toggle `Application.get_env(:courier, :force_ssl_enabled)`,
  which the whole VM shares. Each restores the previous value in an
  `on_exit`, but two such tests running concurrently would still observe each
  other's flag.
  """

  use ExUnit.Case, async: false

  alias CourierWeb.Plugs.ForceSSL

  @flag_key :force_ssl_enabled

  setup do
    previous = Application.get_env(:courier, @flag_key)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(:undefined), do: Application.delete_env(:courier, @flag_key)
  defp restore(value), do: Application.put_env(:courier, @flag_key, value)

  defp peer_conn(method, path) do
    # `Plug.Test.conn/3` builds a plain-HTTP conn from a non-localhost peer
    # (`www.example.com`): exactly the shape the launch compose network has,
    # and the shape the old compile-time `force_ssl` redirected.
    Plug.Test.conn(method, path, "")
  end

  describe "the compile-time redirect is gone" do
    test "config/prod.exs sets no force_ssl — the release must not redirect on its own" do
      config = Config.Reader.read!("config/prod.exs", env: :prod)

      assert config[:courier][CourierWeb.Endpoint][:force_ssl] == nil,
             "config/prod.exs still sets force_ssl, so a release redirects " <>
               "plain-HTTP peers to https with no signal set — the 307 that " <>
               "killed every mail step in the loop-proof"
    end

    test "config/runtime.exs reads the COURIER_FORCE_SSL signal" do
      # Paired with the `enabled?/0` tests below: a signal nothing reads is a
      # comment, and a flag nothing sets is one too.
      assert File.read!("config/runtime.exs") =~ "COURIER_FORCE_SSL",
             "config/runtime.exs reads no COURIER_FORCE_SSL, so nothing maps " <>
               "the deployer's opt-in onto the flag this plug enforces"
    end
  end

  describe "enabled?/0" do
    test "is false when the flag is unset — plain HTTP is the default" do
      Application.delete_env(:courier, @flag_key)

      refute ForceSSL.enabled?(),
             "force_ssl must default to OFF: everything without the explicit " <>
               "signal — compose, launch tier, CI — serves plain HTTP"
    end

    test "is true when the flag is set — genuine prod opts in" do
      Application.put_env(:courier, @flag_key, true)

      assert ForceSSL.enabled?()
    end
  end

  describe "the plug with the signal absent" do
    test "a plain-HTTP POST /v1/messages from a non-localhost peer is NOT redirected" do
      # THE RED PROOF, before the fix: with compile-time `force_ssl` this same
      # conn shape is answered 307 -> https -> 405, and all three mails fail.
      Application.delete_env(:courier, @flag_key)

      conn = peer_conn(:post, "/v1/messages") |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted, "expected the request to pass through with no signal set"
      assert conn.status == nil
      assert Plug.Conn.get_resp_header(conn, "location") == []
    end
  end

  describe "the plug with the signal present" do
    test "a plain-HTTP POST /v1/messages from a non-localhost peer IS redirected to https" do
      Application.put_env(:courier, @flag_key, true)

      conn = peer_conn(:post, "/v1/messages") |> ForceSSL.call(ForceSSL.init([]))

      assert conn.halted
      assert conn.status == 307
      [location] = Plug.Conn.get_resp_header(conn, "location")

      assert location =~ ~r/^https:\/\//,
             "expected an https redirect, got #{inspect(location)}"
    end

    test "the probes are exempt — /healthz answers plain HTTP with the signal present" do
      Application.put_env(:courier, @flag_key, true)

      conn = peer_conn(:get, "/healthz") |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted, "/healthz must answer plain HTTP even in genuine prod"
      assert Plug.Conn.get_resp_header(conn, "location") == []
    end

    test "the probes are exempt — /readyz answers plain HTTP with the signal present" do
      Application.put_env(:courier, @flag_key, true)

      conn = peer_conn(:get, "/readyz") |> ForceSSL.call(ForceSSL.init([]))

      refute conn.halted, "/readyz must answer plain HTTP even in genuine prod"
      assert Plug.Conn.get_resp_header(conn, "location") == []
    end
  end

  describe "the endpoint wiring" do
    test "CourierWeb.Endpoint runs the plug — an unenforced flag enforces nothing" do
      # Read off the endpoint's own source rather than a list kept here, for
      # the same reason the pipeline order is read off router.ex elsewhere: a
      # list kept here can agree with an endpoint that does not have the plug.
      source = File.read!(Path.join(__DIR__, "../../../lib/courier_web/endpoint.ex"))

      assert source =~ "CourierWeb.Plugs.ForceSSL",
             "CourierWeb.Endpoint does not run CourierWeb.Plugs.ForceSSL, so " <>
               "the flag is read and never enforced"
    end
  end
end
