defmodule Courier.SendingDomains.Dns.SystemTest do
  @moduledoc """
  The seam is `Courier.SendingDomains.Dns` as a behaviour and
  `Courier.TestSupport.SendingDomainDns` as the double. This file is the other
  side: the shipped `Courier.SendingDomains.Dns.System` (`:inet_res`) itself.

  The untested half is the parsing of `:inet_res`'s record shapes — the
  `
  (list of charlists) and the normalisation the module does on top (lowercase,
  trailing-dot-free). That parsing is what would silently mis-verify a domain
  if it were wrong, so that is the subject.

  It must not depend on the network, so every assertion builds its answer from
  controlled inputs: either a hand-built `dns_rr` list fed to
  `parse_records/2`, or a stubbed `:inet_res` module injected via
  `Application.get_env(:courier, :sending_domain_inet_res)` for the `mx/1` /
  `txt/1` paths. No socket, no resolver, no timeout.
  """

  use ExUnit.Case, async: true

  alias Courier.SendingDomains.Dns.System

  defp rr(data) do
    {:dns_rr, ~c"example.com", :mx, :in, 0, 0, data, :undefined, :undefined, false}
  end

  defp rr_txt(data) do
    {:dns_rr, ~c"example.com", :txt, :in, 0, 0, data, :undefined, :undefined, false}
  end

  describe "parse_records/2 for :mx" do
    test "maps {preference, exchange} and normalises the exchange" do
      answers = [
        rr({5, ~c"mail.example.com"}),
        rr({10, ~c"MAIL.EXAMPLE.COM."}),
        rr({20, ~c"Route1.MX.Cloudflare.NET."})
      ]

      assert System.parse_records(answers, :mx) == [
               {5, "mail.example.com"},
               {10, "mail.example.com"},
               {20, "route1.mx.cloudflare.net"}
             ]
    end

    test "lowercases and trims trailing dot per record" do
      assert System.parse_records([rr({1, ~c"EXAMPLE.COM."})], :mx) == [{1, "example.com"}]
      assert System.parse_records([rr({1, ~c"example.com"})], :mx) == [{1, "example.com"}]
      assert System.parse_records([rr({1, ~c"EXAMPLE.COM"})], :mx) == [{1, "example.com"}]
    end

    test "preserves preference ordering as returned" do
      answers = [
        rr({30, ~c"c.example.com"}),
        rr({10, ~c"a.example.com"}),
        rr({20, ~c"b.example.com"})
      ]

      assert System.parse_records(answers, :mx) == [
               {30, "c.example.com"},
               {10, "a.example.com"},
               {20, "b.example.com"}
             ]
    end

    test "empty answer list is []" do
      assert System.parse_records([], :mx) == []
    end
  end

  describe "parse_records/2 for :txt" do
    test "flattens each record's charlist list into strings" do
      answers = [
        rr_txt([~c"v=spf1 include:_spf.mail.cloudflare.net ~all"]),
        rr_txt([~c"v=DKIM1; k=rsa; p=abc", ~c"second-string"])
      ]

      assert System.parse_records(answers, :txt) == [
               "v=spf1 include:_spf.mail.cloudflare.net ~all",
               "v=DKIM1; k=rsa; p=abc",
               "second-string"
             ]
    end

    test "empty answer list is []" do
      assert System.parse_records([], :txt) == []
    end

    test "single TXT record with multiple strings" do
      answers = [rr_txt([~c"hello", ~c"world"])]
      assert System.parse_records(answers, :txt) == ["hello", "world"]
    end
  end

  describe "mx/1 and txt/1 via stubbed resolver (no network)" do
    defmodule StubOk do
      def resolve(~c"mx.example.com", :in, :mx) do
        answers = [
          {:dns_rr, ~c"mx.example.com", :mx, :in, 0, 3600, {5, ~c"route1.mx.cloudflare.net."},
           :undefined, :undefined, false},
          {:dns_rr, ~c"mx.example.com", :mx, :in, 0, 3600, {10, ~c"ROUTE2.MX.CLOUDFLARE.NET"},
           :undefined, :undefined, false}
        ]

        {:ok, {{:dns_rec, :header}, :header2, :query, answers, [], []}}
      end

      def resolve(~c"txt.example.com", :in, :txt) do
        answers = [
          {:dns_rr, ~c"txt.example.com", :txt, :in, 0, 3600,
           [~c"v=spf1 include:_spf.mail.cloudflare.net ~all"], :undefined, :undefined, false}
        ]

        {:ok, {{:dns_rec, :header}, :header2, :query, answers, [], []}}
      end

      def resolve(~c"empty.example.com", :in, _type) do
        {:ok, {{:dns_rec, :header}, :header2, :query, [], [], []}}
      end

      def resolve(_name, :in, _type), do: {:error, :nxdomain}
    end

    defmodule StubError do
      def resolve(_name, :in, _type), do: {:error, :nxdomain}
    end

    setup do
      previous = Application.get_env(:courier, :sending_domain_inet_res)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:courier, :sending_domain_inet_res)
        else
          Application.put_env(:courier, :sending_domain_inet_res, previous)
        end
      end)

      :ok
    end

    test "mx/1 returns normalised records from stubbed :inet_res" do
      Application.put_env(:courier, :sending_domain_inet_res, StubOk)
      assert {:ok, records} = System.mx("mx.example.com")
      assert records == [{5, "route1.mx.cloudflare.net"}, {10, "route2.mx.cloudflare.net"}]
    end

    test "txt/1 returns strings from stubbed :inet_res" do
      Application.put_env(:courier, :sending_domain_inet_res, StubOk)
      assert {:ok, records} = System.txt("txt.example.com")
      assert records == ["v=spf1 include:_spf.mail.cloudflare.net ~all"]
    end

    test "empty answer is {:ok, []} not an error" do
      Application.put_env(:courier, :sending_domain_inet_res, StubOk)
      assert {:ok, []} = System.mx("empty.example.com")
      assert {:ok, []} = System.txt("empty.example.com")
    end

    test "lookup failure is {:error, reason}" do
      Application.put_env(:courier, :sending_domain_inet_res, StubError)
      assert {:error, :nxdomain} = System.mx("missing.example.com")
      assert {:error, :nxdomain} = System.txt("missing.example.com")
    end

    test "trims trailing dot from domain before querying" do
      Application.put_env(:courier, :sending_domain_inet_res, StubOk)
      assert {:ok, _} = System.mx("mx.example.com.")
      assert {:ok, _} = System.txt("txt.example.com.")
    end
  end
end
