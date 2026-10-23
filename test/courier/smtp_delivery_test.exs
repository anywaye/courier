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

  ## Why the whole conversation is driven rather than stubbed

  Each test below configures the adapter and calls `Courier.Mailers.deliver/2` —
  the same two lines production runs. A test that built a `%Swoosh.Email{}` by
  hand and handed it to `Mailer.deliver/1` would prove the adapter works while
  saying nothing about whether courier composes a message it can actually send,
  and the two have been broken independently in this repository.
  """

  # `async: false`, and the reason is the application environment rather than the
  # network: these tests replace `config :courier, Courier.Mailer`, which the
  # whole VM shares, so two of them running at once would deliver through each
  # other's adapter. Same rule as the other `*ConfigTest` files in this suite.
  use ExUnit.Case, async: false

  alias Courier.Mailers
  alias Courier.TestSupport.SmtpServer

  setup do
    # The suite's default is `Swoosh.Adapters.Test`, and it has to be restored.
    # `on_exit` runs after the test even when it fails, so a test that dies
    # mid-way cannot leave SMTP configured for the files that run next.
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

      # Not `assert_receive` and not a sleep: the table is written inside
      # `handle_DATA/4`, which has already returned by the time `deliver/2`
      # answers, because the 250 comes after the insert.
      assert [message] = SmtpServer.take(server)

      # The envelope courier built: `config :courier, :mailing`'s from address
      # and the address the platform handed in.
      assert message.from == "no-reply@anywaye.com"
      assert message.to == ["roundtrip@example.com"]

      # The subject is courier's, from the `:mailing` configuration, rendered
      # through the template — so this is also the assertion that the subject
      # templates still resolve.
      assert message.data =~ "Subject: Welcome to Anywaye"

      # The body is the rendered template, not an empty multipart. A message
      # that "arrives" with a subject line and no body is still useless, and
      # would pass an assertion about the envelope alone.
      assert message.data =~ "Round Trip"

      # The MIME structure, so the text alternative is real rather than declared.
      assert message.data =~ "multipart/alternative"

      # A Message-ID header, so a bounce quoting this message can be tied to a
      # row. Swoosh generates one per send; the courier-prefixed id that ties a
      # bounce to `outbox_events.subject` is added by `Courier.Deliver.tag/2`,
      # which is not on this path — asserting it here would be asserting a
      # function this test does not call. `Courier.DeliverTest` covers that half.
      assert message.data =~ ~r/Message-ID: <[^>]+>/
    end

    test "the adapter authenticates with the credentials it was configured with" do
      # The server REQUIRES these and refuses anything else, so a message that
      # arrives has proved the username and password travelled out of courier's
      # configuration, through the adapter and through `gen_smtp_client`, into a
      # real AUTH exchange — not around them.
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
      # The inverse of the test above, and the reason it exists. `auth: :always`
      # with the wrong password must NOT come back `{:ok, _}` — the Local adapter
      # returned a provider-shaped id for every send it was ever given, which is
      # the entire class of bug this packet is about.
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

      # The refusal really is at the relay: nothing arrived, so this is not a
      # send that reported failure after a message was already accepted.
      assert SmtpServer.messages(server) == []
    end
  end

  describe "an unreachable provider fails loudly" do
    test "a relay that is not listening is an error, not a provider-shaped id" do
      # Bind a listener, take its port, then stop it — so the port is genuinely
      # free and known to be one courier can reach, which a hard-coded closed
      # port is not (it could be held by something else on a busy machine).
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
      # `.invalid` is reserved by RFC 2606 precisely so it can never resolve, so
      # this is a guaranteed NXDOMAIN rather than a name that might one day be
      # registered by somebody.
      #
      # `no_mx_lookups: true` because without it courier asks DNS for the MX
      # records of the relay domain — which is the right production behaviour for
      # a domain and a DNS call this suite has no business making.
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
      # `Swoosh.Adapters.SMTP` declares `required_config: [:relay]` and Swoosh
      # validates it by RAISING an `ArgumentError` — it does not return
      # `{:error, _}`. Asserted as written rather than as one might expect,
      # because it is the honest contract: a half-configured adapter is a
      # deployment fault, and courier's own refusal (see `Courier.MailerAdapter`)
      # is what stops it reaching this point at all.
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

  # An adapter aimed at the loopback test server.
  #
  # `no_mx_lookups: true` and `tls: :never` both matter and neither is a
  # convenience. Without the first, `gen_smtp` asks DNS for MX records of
  # "127.0.0.1" before connecting — a real resolver call per send. Without the
  # second, `gen_smtp`'s default is `tls: :if_available`, which is correct
  # against a real relay and would negotiate STARTTLS against a plaintext test
  # server that does not offer it.
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
