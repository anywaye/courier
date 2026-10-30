defmodule Courier.SmtpDeliveryTest do
  @moduledoc """
  The SMTP adapter is really wired: a message crosses a real socket.

  Every other test in this repository asserts about courier. This one asserts
  about courier *and a provider*, because the failure it exists to prevent is
  invisible to a test that stops one layer short. `Swoosh.Adapters.Local` returns
  a provider-shaped id out of memory and `Swoosh.Adapters.Test` hands the message
  to the process that sent it — neither opens a socket — so a courier whose
  adapter could not reach anything looked exactly like a courier that worked.

  So: a real `gen_smtp` server on a real ephemeral loopback port
  (`Courier.TestSupport.SmtpServer`), the real `Swoosh.Adapters.SMTP`, the real
  `gen_smtp_client` conversation underneath it, and assertions about the bytes
  that arrived. Nothing here is mocked, and nothing here would pass with the
  Local adapter configured.


  Each test below configures the adapter and calls `Courier.Mailers.deliver/2` —
  the same two lines production runs. A test that built a `%Swoosh.Email{}` by
  hand and handed it to `Mailer.deliver/1` would prove the adapter works while
  saying nothing about whether courier composes a message it can actually send,
  and the two have been broken independently in this repository.
  """

  use ExUnit.Case, async: false

  alias Courier.Mailers
  alias Courier.TestSupport.SmtpServer

  setup do
    previous = Application.get_env(:courier, Courier.Mailer)
    on_exit(fn -> Application.put_env(:courier, Courier.Mailer, previous) end)
    :ok
  end

  describe "a send crosses a real socket" do
    test "the message the provider received is the message courier composed" do
      {:ok, server, port} = SmtpServer.start_link()
      put_adapter(local_relay(port))

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_roundtrip",
                 email: "roundtrip@example.com",
                 name: "Round Trip"
               })

      assert [message] = SmtpServer.take(server)

      assert message.from == "no-reply@anywaye.com"
      assert message.to == ["roundtrip@example.com"]

      assert message.data =~ "Subject: Welcome to Anywaye"

      assert message.data =~ "Round Trip"

      assert message.data =~ "multipart/alternative"

      assert message.data =~ ~r/Message-ID: <[^>]+>/
    end

    test "the adapter authenticates with the credentials it was configured with" do
      {:ok, server, port} = SmtpServer.start_link_authenticated("apikey", "test-smtp-password")

      put_adapter(
        local_relay(port) ++ [auth: :always, username: "apikey", password: "test-smtp-password"]
      )

      assert {:ok, _receipt} =
               deliver(:welcome, %{
                 user_id: "usr_auth",
                 email: "auth@example.com",
                 name: "Authenticated"
               })

      assert [message] = SmtpServer.take(server)
      assert message.authenticated
    end

    test "a relay that rejects the credentials fails the send, loudly" do
      {:ok, server, port} = SmtpServer.start_link_authenticated("apikey", "the-right-one")

      put_adapter(
        local_relay(port) ++ [auth: :always, username: "apikey", password: "the-wrong-one"]
      )

      assert {:error, _reason} =
               deliver(:welcome, %{
                 user_id: "usr_rejected",
                 email: "rejected@example.com",
                 name: "Rejected"
               })

      assert SmtpServer.messages(server) == []
    end
  end

  describe "an unreachable provider fails loudly" do
    test "a relay that is not listening is an error, not a provider-shaped id" do
      {:ok, server, port} = SmtpServer.start_link()
      :ok = GenServer.stop(server)
      put_adapter(local_relay(port))

      assert {:error, _reason} =
               deliver(:welcome, %{
                 user_id: "usr_unreachable",
                 email: "unreachable@example.com",
                 name: "Unreachable"
               })
    end

    test "a relay hostname that does not resolve is an error" do
      put_adapter(
        adapter: Swoosh.Adapters.SMTP,
        relay: "no-such-relay.invalid",
        port: 587,
        no_mx_lookups: true,
        tls: :never,
        auth: :never
      )

      assert {:error, _reason} =
               deliver(:welcome, %{
                 user_id: "usr_nxdomain",
                 email: "nxdomain@example.com",
                 name: "No Such Relay"
               })
    end

    test "an adapter missing its relay raises rather than reporting a send" do
      put_adapter(adapter: Swoosh.Adapters.SMTP)

      assert_raise ArgumentError, ~r/relay/, fn ->
        deliver(:welcome, %{
          user_id: "usr_no_relay",
          email: "no-relay@example.com",
          name: "No Relay"
        })
      end
    end
  end

  defp local_relay(port) do
    [
      adapter: Swoosh.Adapters.SMTP,
      relay: "127.0.0.1",
      port: port,
      no_mx_lookups: true,
      tls: :never,
      auth: :never
    ]
  end

  defp put_adapter(config), do: Application.put_env(:courier, Courier.Mailer, config)

  defp deliver(type, payload), do: Mailers.deliver(type, payload)
end
