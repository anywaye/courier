defmodule Courier.Webhooks.UrlGuardTest do
  @moduledoc """
  courier signs HTTP requests to a URL a *customer* chose. That makes every
  webhook endpoint an SSRF primitive: whoever can create an endpoint can point
  courier at anything courier can reach — the cloud metadata service, a database
  on a private network, an admin port on the host. Standard Webhooks calls this
  out at §Server side request forgery and says the protection is "to prevent the
  webhooks from calling into internal networks and services".

  Every target in this file is a real address class, asserted one at a time,
  because a table that says "SSRF: blocked" proves nothing about *which*
  addresses are blocked.

  The rule courier enforces, in order, is: **scheme, then host, then the address
  the host resolves to.** The third step is the one that matters, because the
  attack is a public name that answers with a private address. A guard that only
  looked at the URL string would pass every case below except the resolver
  tests, and would be trivially defeated by them.
  """

  use ExUnit.Case, async: true

  alias Courier.TestSupport.TestDns
  alias Courier.Webhooks.UrlGuard

  @resolver {__MODULE__.Resolver, :canned}

  defp check(url), do: UrlGuard.validate(url, @resolver)

  defp resolves_to(url, ips), do: UrlGuard.validate(url, {TestDns, {:canned, ips}})

  describe "schemes" do
    test "accepts https" do
      assert {:ok, _target} = check("https://hooks.example.com/events")
    end

    test "accepts http" do
      assert {:ok, _target} = check("http://hooks.example.com/events")
    end

    test "rejects file" do
      assert {:error, :blocked_scheme} == check("file:///etc/passwd")
    end

    test "rejects ftp" do
      assert {:error, :blocked_scheme} == check("ftp://hooks.example.com/x")
    end

    test "rejects gopher" do
      assert {:error, :blocked_scheme} == check("gopher://hooks.example.com/x")
    end

    test "rejects data" do
      assert {:error, :blocked_scheme} == check("data:text/plain,hello")
    end

    test "rejects javascript" do
      assert {:error, :blocked_scheme} == check("javascript:alert(1)")
    end

    test "rejects a url with no scheme at all" do
      assert {:error, :blocked_scheme} == check("//hooks.example.com/x")
    end

    test "rejects a bare host, which is not a url courier can send to" do
      assert {:error, :blocked_scheme} == check("hooks.example.com/events")
    end
  end

  describe "malformed urls" do
    test "rejects a url with no host" do
      assert {:error, :missing_host} == check("https:///events")
    end

    test "rejects the empty string" do
      assert {:error, :blocked_scheme} == check("")
    end

    test "rejects a host that is only whitespace" do
      assert {:error, :missing_host} == check("https://   /x")
    end
  end

  describe "literal addresses" do
    test "accepts a public ipv4" do
      assert {:ok, _target} = check("https://8.8.8.8/hooks")
    end

    test "accepts a public ipv6" do
      assert {:ok, _target} = check("https://[2606:2800:220:1:248:1893:25c8:1946]/hooks")
    end

    test "rejects loopback ipv4" do
      assert {:error, :blocked_address} == check("http://127.0.0.1/hooks")
    end

    test "rejects loopback ipv4 with a port" do
      assert {:error, :blocked_address} == check("http://127.0.0.1:6379/hooks")
    end

    test "rejects loopback ipv6" do
      assert {:error, :blocked_address} == check("http://[::1]/hooks")
    end

    test "rejects the whole 127.0.0.0/8, not just 127.0.0.1" do
      for host <- ~w(127.0.0.1 127.0.0.53 127.1.2.3 127.255.255.254) do
        assert {:error, :blocked_address} == check("http://#{host}/x"),
               "#{host} must be refused"
      end
    end

    test "rejects the unspecified address, which means this host" do
      assert {:error, :blocked_address} == check("http://0.0.0.0/x")
    end

    test "rejects link-local 169.254.0.0/16, where the cloud metadata service lives" do
      for host <- ~w(169.254.169.254 169.254.0.1 169.254.255.254) do
        assert {:error, :blocked_address} == check("http://#{host}/latest/meta-data/"),
               "#{host} must be refused"
      end
    end

    test "rejects link-local ipv6" do
      assert {:error, :blocked_address} == check("http://[fe80::1]/x")
    end

    test "rejects the private range 10.0.0.0/8" do
      for host <- ~w(10.0.0.1 10.255.255.254 10.1.2.3) do
        assert {:error, :blocked_address} == check("http://#{host}/x"), "#{host} must be refused"
      end
    end

    test "rejects 172.16.0.0/12, the whole private range and not just part of it" do
      for host <- ~w(172.16.0.1 172.20.10.1 172.31.255.254 172.31.255.255) do
        assert {:error, :blocked_address} == check("http://#{host}/x"), "#{host} must be refused"
      end
    end

    test "accepts 172.15 and 172.32, which are public and outside the private range" do
      for host <- ~w(172.15.0.1 172.32.0.1 172.1.2.3) do
        assert {:ok, _target} = check("http://#{host}/x"),
               "#{host} is public and must be allowed"
      end
    end

    test "rejects 192.168.0.0/16" do
      for host <- ~w(192.168.0.1 192.168.1.1 192.168.255.254) do
        assert {:error, :blocked_address} == check("http://#{host}/x"), "#{host} must be refused"
      end
    end

    test "rejects the unique-local ipv6 range fc00::/7" do
      assert {:error, :blocked_address} == check("http://[fd00::1]/x")
      assert {:error, :blocked_address} == check("http://[fc00::1]/x")
    end

    test "rejects an ipv4-mapped ipv6 address that points at a private ipv4" do
      assert {:error, :blocked_address} == check("http://[::ffff:127.0.0.1]/x")
      assert {:error, :blocked_address} == check("http://[::ffff:10.0.0.1]/x")
    end

    test "rejects the ipv4-compatible and unspecified ipv6 forms" do
      assert {:error, :blocked_address} == check("http://[::]/x")
    end

    test "rejects an address with a scope id, which is the same address plus a device" do
      assert {:error, :blocked_address} == check("http://[fe80::1%25eth0]/x")
    end
  end

  describe "hostnames" do
    test "rejects localhost by name" do
      assert {:error, :blocked_host} == check("http://localhost/hooks")
    end

    test "rejects localhost on a port" do
      assert {:error, :blocked_host} == check("http://localhost:4000/hooks")
    end

    test "rejects any name under localhost" do
      assert {:error, :blocked_host} == check("http://api.localhost/hooks")
    end

    test "rejects the .local mDNS suffix, which resolves on the local network" do
      assert {:error, :blocked_host} == check("http://printer.local/hooks")
    end

    test "rejects localhost with a trailing dot, which is the same name to DNS" do
      assert {:error, :blocked_host} == check("http://localhost./hooks")
    end

    test "rejects the mDNS suffix with a trailing dot too" do
      assert {:error, :blocked_host} == check("http://printer.local./hooks")
    end

    test "strips the trailing dot before resolving, so the address is found" do
      assert {:ok, target} = UrlGuard.validate("https://hooks.example.com./x", @resolver)

      assert target.host_header == "hooks.example.com."
      assert target.host == "8.8.8.8"
    end

    test "rejects a loopback name hidden behind userinfo" do
      assert {:error, :blocked_address} == check("https://hooks.example.com@127.0.0.1/x")
    end

    test "rejects a metadata address hidden behind userinfo" do
      assert {:error, :blocked_address} == check("https://hooks.example.com@169.254.169.254/x")
    end

    test "dials the host after the @, and says so in the Host header" do
      assert {:ok, target} = UrlGuard.validate("https://hooks.example.com@8.8.8.8/x", @resolver)

      assert target.host == "8.8.8.8"
      assert target.host_header == "8.8.8.8"
    end

    test "ignores a port when reading the host" do
      assert {:ok, target} = UrlGuard.validate("https://hooks.example.com:8443/x", @resolver)

      assert target.host_header == "hooks.example.com"
      assert target.port == 8443
    end

    test "reads a bracketed ipv6 literal whole, not as its first four characters" do
      assert {:error, :blocked_address} == check("http://[fe80::1]/x")
      assert {:error, :blocked_address} == check("http://[::1]:8080/x")
    end

    test "accepts a public ipv6 literal, which is not read as a truncated ipv4" do
      assert {:ok, target} = check("https://[2606:2800:220:1:248:1893:25c8:1946]/hooks")

      assert target.host == "2606:2800:220:1:248:1893:25c8:1946"
      assert target.host_header == "2606:2800:220:1:248:1893:25c8:1946"
    end

    test "accepts an ordinary public name" do
      assert {:ok, _target} = check("https://hooks.example.com/events")
    end

    test "accepts a name that merely contains a blocked word" do
      assert {:ok, _target} = check("https://localhost.example.com/hooks")
      assert {:ok, _target} = check("https://my-localhost-mirror.example.com/hooks")
      assert {:ok, _target} = check("https://notlocalhost.example.com/hooks")
    end
  end

  describe "resolution" do
    test "accepts a public name that resolves to a public address" do
      assert {:ok, _target} = resolves_to("https://hooks.example.com/x", ["8.8.8.8"])
    end

    test "rejects a public name that resolves to loopback" do
      assert {:error, :blocked_address} ==
               resolves_to("https://evil.example.com/x", ["127.0.0.1"])
    end

    test "rejects a public name that resolves to the metadata service" do
      assert {:error, :blocked_address} ==
               resolves_to("https://evil.example.com/x", ["169.254.169.254"])
    end

    test "rejects a public name that resolves to a private address" do
      assert {:error, :blocked_address} ==
               resolves_to("https://evil.example.com/x", ["10.0.0.5"])
    end

    test "rejects a name whose answers are mixed, when any one of them is private" do
      assert {:error, :blocked_address} ==
               resolves_to("https://rebind.example.com/x", ["8.8.8.8", "127.0.0.1"])
    end

    test "accepts a name with several public answers" do
      assert {:ok, _target} =
               resolves_to("https://hooks.example.com/x", ["8.8.8.8", "2606:2800::1"])
    end

    test "rejects a name that does not resolve" do
      assert {:error, :dns_failure} ==
               UrlGuard.validate("https://nope.example.com/x", {TestDns, {:canned, :nxdomain}})
    end

    test "rejects a name whose resolver timed out" do
      assert {:error, :dns_failure} ==
               UrlGuard.validate("https://slow.example.com/x", {TestDns, {:canned, :timeout}})
    end

    test "rejects a name that resolves to nothing at all" do
      assert {:error, :dns_failure} == resolves_to("https://empty.example.com/x", [])
    end

    test "rejects an answer that is not an address at all" do
      assert {:error, :dns_failure} == resolves_to("https://weird.example.com/x", ["not-an-ip"])
    end

    test "refuses rather than falling back when one answer in a list is unreadable" do
      assert {:error, :dns_failure} ==
               resolves_to("https://weird.example.com/x", ["not-an-ip", "127.0.0.1"])
    end
  end

  describe "the address courier actually connects to" do
    test "is the resolved address, not the name" do
      assert {:ok, target} =
               UrlGuard.validate(
                 "https://hooks.example.com/hooks",
                 {TestDns, {:canned, ["8.8.8.8"]}}
               )

      assert target.host == "8.8.8.8"
      assert target.host_header == "hooks.example.com"
      assert target.scheme == "https"
      assert target.path == "/hooks"
    end

    test "keeps the port the customer asked for" do
      assert {:ok, target} =
               UrlGuard.validate(
                 "https://hooks.example.com:8443/hooks",
                 {TestDns, {:canned, ["8.8.8.8"]}}
               )

      assert target.port == 8443
    end

    test "defaults the port to the scheme's" do
      assert {:ok, %{port: 443}} =
               UrlGuard.validate("https://hooks.example.com/x", {TestDns, {:canned, ["8.8.8.8"]}})

      assert {:ok, %{port: 80}} =
               UrlGuard.validate("http://hooks.example.com/x", {TestDns, {:canned, ["8.8.8.8"]}})
    end

    test "keeps the host header the name, not the address, because that is what the customer serves" do
      assert {:ok, target} =
               UrlGuard.validate("https://hooks.example.com/x", {TestDns, {:canned, ["8.8.8.8"]}})

      assert target.host_header == "hooks.example.com"
    end

    test "keeps the path and the query the customer registered" do
      assert {:ok, target} =
               UrlGuard.validate(
                 "https://hooks.example.com/hooks?tenant=acme",
                 {TestDns, {:canned, ["8.8.8.8"]}}
               )

      assert target.path == "/hooks?tenant=acme"
    end

    test "a literal address is its own target, with no resolution and no host header of a name" do
      assert {:ok, target} = UrlGuard.validate("https://8.8.8.8/hooks", @resolver)

      assert target.host == "8.8.8.8"
      assert target.host_header == "8.8.8.8"
    end
  end

  describe "the url that was checked" do
    test "is the one returned, so a caller cannot send somewhere else than it validated" do
      assert {:ok, target} =
               UrlGuard.validate(
                 "https://hooks.example.com/hooks",
                 {TestDns, {:canned, ["8.8.8.8"]}}
               )

      assert target.url == "https://hooks.example.com/hooks"
    end
  end

  defmodule Resolver do
    @moduledoc false
    @behaviour Courier.Webhooks.Dns

    @impl Courier.Webhooks.Dns
    def resolve(:canned), do: {:ok, ["8.8.8.8"]}
  end
end
