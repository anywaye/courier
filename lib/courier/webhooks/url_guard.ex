defmodule Courier.Webhooks.UrlGuard do
  @moduledoc """
  The check every webhook URL passes before courier will sign a request to it.

  courier holds a signing secret and will HMAC a request to any URL an account
  registers. That is an SSRF machine: whoever can create an endpoint can reach
  anything courier can reach, with courier's network position and courier's
  credentials on the wire. Standard Webhooks §Server side request forgery names
  the same risk and says the protection is "to prevent the webhooks from calling
  into internal networks and services".

  ## What is refused, and why each one is a target

  | refused | why it matters |
  | ------- | -------------- |
  | `file:`, `ftp:`, `gopher:`, `data:`, `javascript:` and no scheme at all | not HTTP; a client that follows one of these is reading courier's filesystem or talking a protocol nobody expected |
  | loopback `127.0.0.0/8`, `::1`, `0.0.0.0`, `::` | courier's own process, and every sidecar, admin port and debug server sharing the host |
  | link-local `169.254.0.0/16`, `fe80::/10` | the cloud instance metadata service. It answers on `169.254.169.254` and hands out credentials for everything else in the account |
  | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7` | the service network: databases, caches, internal APIs, and the other anywaye services |
  | `::ffff:0:0/96` mapped onto any of the above | the same addresses wearing an IPv6 costume |
  | `localhost` and `*.localhost`, `*.local` | names that resolve to loopback by rule, before any DNS answer is involved |

  `172.16.0.0/12` is the whole range, `172.15` and `172.32` included on the
  outside: a guard that refused "172." wholesale would be turning away real
  customers' hosts, and the tests say so.

  ## The part that actually stops the attack

  The string is not the target, the *resolved address* is. So `validate/2`
  resolves the host and refuses the URL when **any** answer is blocked — a name
  that answers with one public and one private address is the DNS-rebinding
  shape, and a guard that inspected only the first answer would wave it through.

  And the value it returns is that resolved address, which the sender dials
  directly with the original name as the `Host` header. That closes the gap
  between "the address I checked" and "the address I connected to": if the guard
  returned the hostname for the sender to re-resolve, the check would be
  decorative and a second lookup would do whatever the attacker wanted. The
  sender therefore has no way to connect somewhere the guard did not approve,
  and a `Host` header of the resolved address would break every virtual host
  this would otherwise work against.

  This is a guard, not a network boundary. Spec §Server side request forgery
  recommends running the webhook workers in their own subnet as well; that is
  deployment, not this module, and courier's Dockerfile is the place for it.
  """

  # For unpacking the last 32 bits of an IPv4-mapped IPv6 address into the four
  # octets the IPv4 rules are written in.
  import Bitwise, only: [>>>: 2, &&&: 2]

  @default_port %{"https" => 443, "http" => 80}
  @allowed_schemes ["https", "http"]

  @typedoc """
  Where to connect, and what to put in the `Host` header.

  `host` is an address courier has already checked. `host_header` is the name
  the customer registered, because that is the virtual host their server answers
  on. `url` is the URL the guard was given, kept for the record and for the
  signature's sake — never for re-resolution.
  """
  @type target :: %{
          url: String.t(),
          scheme: String.t(),
          host: String.t(),
          host_header: String.t(),
          port: pos_integer(),
          path: String.t()
        }

  @doc """
  Checks `url` and returns where to send the request, or why not.

  `resolver` is anything implementing `Courier.Webhooks.Dns.resolve/1`: a module,
  or `{module, argument}` to hand a fake the answers it should give. It is a
  required argument rather than a default so that no caller can accidentally
  validate a customer's URL by string-matching it alone.

  Returns:

    * `{:ok, target}` — the address to dial, already checked
    * `{:error, :blocked_scheme}` — not an http(s) URL
    * `{:error, :missing_host}` — nothing to connect to
    * `{:error, :blocked_host}` — a name that is internal by rule (`localhost`)
    * `{:error, :blocked_address}` — the URL, or everything it resolves to, is
      internal
    * `{:error, :dns_failure}` — the name does not resolve, so there is nothing
      safe to connect to
  """
  @spec validate(String.t(), module() | {module(), term()}) :: {:ok, target()} | {:error, atom()}
  def validate(url, resolver) when is_binary(url) do
    with {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri),
         {:ok, host} <- fetch_host(uri),
         :ok <- check_host(host) do
      check_addresses(url, uri, host, resolver)
    end
  end

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} = uri when scheme in [nil, ""] ->
        # A url with no scheme is not something courier can send a signed HTTP
        # request to, and defaulting it to https would be guessing on the
        # caller's behalf.
        _ = uri
        {:error, :blocked_scheme}

      %URI{} = uri ->
        {:ok, uri}
    end
  rescue
    _error -> {:error, :blocked_scheme}
  end

  defp check_scheme(%URI{scheme: scheme}) do
    if scheme in @allowed_schemes, do: :ok, else: {:error, :blocked_scheme}
  end

  # `URI.parse/1` cannot be trusted with the host of an *untrusted* URL here.
  # For `http://[fe80::1%25eth0]/x` it answers `"fe80"` — it stops at the `[` and
  # hands back the first four characters of an IPv6 literal as if they were the
  # whole name. A guard built on that would check `fe80` (which is not an address
  # at all) and then dial the rest, so the authority is read here instead: strip
  # the userinfo, take what is left up to the path, and unbracket it.
  defp fetch_host(%URI{authority: authority}) when is_binary(authority) do
    authority
    |> authority_host()
    |> case do
      "" -> {:error, :missing_host}
      host -> check_zone(host)
    end
  end

  defp fetch_host(_uri), do: {:error, :missing_host}

  # `authority` is everything up to the path, query or fragment, and it may carry
  # userinfo and a port. Neither can change which address courier connects to, and
  # both are things a customer can and does write, so both are removed by
  # splitting rather than by pattern-matching a shape we would rather it had.
  #
  # Userinfo first: `https://expected.example.com@evil.example.com/x` is a
  # request to `evil.example.com`, and reading the host as anything before the
  # `@` is how a URL validator is made to check one host and dial another.
  defp authority_host(authority) do
    authority
    |> String.split(["/", "?", "#"], parts: 2)
    |> List.first()
    |> strip_userinfo()
    |> strip_brackets()
    |> strip_port()
    |> String.trim()
  end

  defp strip_userinfo(authority) do
    case String.split(authority, "@", parts: 2) do
      [_userinfo, rest] -> rest
      [authority] -> authority
    end
  end

  # `[::1]:8080` and `[::1]`. An unbracketed IPv6 literal cannot appear in an
  # authority at all — the brackets are what make the colons unambiguous — so
  # anything that is not bracketed is a name with an optional port.
  defp strip_brackets("[" <> _prefix_and_rest = authority) do
    case String.split(authority, "]", parts: 2) do
      ["[" <> inner, _after] -> inner
      _unterminated -> authority
    end
  end

  defp strip_brackets(authority), do: authority

  # The port is removed only when what follows the colon is *entirely* a number.
  # `Integer.parse("2800:220:1")` answers `{:ok, 2800}` with a remainder, and
  # treating that tuple as "numeric" splits an unbracketed IPv6 literal at its
  # first colon: `2606:2800:…` would be read as host `2606`, which parses as the
  # IPv4 address `0.0.10.46` — private, and refused for the wrong reason.
  defp strip_port(authority) do
    case String.split(authority, ":", parts: 2) do
      [host, port] -> if numeric?(port), do: host, else: authority
      [host] -> host
    end
  end

  defp numeric?(port) do
    case Integer.parse(port) do
      {_value, ""} -> true
      _partial_or_not_a_number -> false
    end
  end

  # A zone id (`fe80::1%25eth0`) names a link-local address *on a device*. There
  # is no legitimate webhook on one, and decoding it to check the address would be
  # more machinery than the answer is worth, so it is refused here.
  defp check_zone(host) do
    if String.contains?(host, "%") do
      {:error, :blocked_address}
    else
      {:ok, host}
    end
  end

  # Names that are internal before any DNS answer exists. `localhost` resolves to
  # loopback by rule on every resolver there is, and `.local` is the mDNS suffix
  # that resolves on the local network rather than in DNS.
  #
  # The comparison strips a trailing dot, because `example.com.` and
  # `example.com` are the same name to DNS and a string comparison that ignored
  # the dot would treat them as different — which is how a guard ends up with a
  # one-character bypass.
  defp check_host(host) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")

    blocked? =
      normalized == "localhost" or
        String.ends_with?(normalized, ".localhost") or
        String.ends_with?(normalized, ".local")

    if blocked?, do: {:error, :blocked_host}, else: :ok
  end

  # A literal address is checked directly and never resolved, so a URL with an IP
  # in it cannot be laundered through a resolver.
  defp check_addresses(url, uri, host, resolver) do
    case address_of(host) do
      {:ok, address} ->
        if blocked_address?(address) do
          {:error, :blocked_address}
        else
          {:ok, target(url, uri, host, address)}
        end

      :error ->
        case resolve(host, resolver) do
          {:ok, []} -> {:error, :dns_failure}
          {:ok, answers} -> check_answers(url, uri, host, answers)
          {:error, _reason} -> {:error, :dns_failure}
        end
    end
  end

  defp check_answers(url, uri, host, answers) do
    parsed = Enum.map(answers, &parse_answer/1)

    cond do
      Enum.any?(parsed, &match?(:error, &1)) ->
        {:error, :dns_failure}

      Enum.any?(parsed, fn {:ok, address} -> blocked_address?(address) end) ->
        {:error, :blocked_address}

      true ->
        # The first answer that passed, as text, is what the sender dials. Any
        # address in the list would do — the point is that it is one this
        # function has already refused to sign towards.
        [{:ok, address} | _rest] = parsed
        {:ok, target(url, uri, host, address)}
    end
  end

  # A bare module gets the host; a `{module, argument}` pair gets the argument,
  # which is how a test hands a fake the table of answers it should return
  # without giving the fake a second callback to implement.
  defp resolve(_host, {module, argument}), do: module.resolve(argument)
  defp resolve(host, module) when is_atom(module), do: module.resolve(host)

  # `host` is the name the customer registered and `address` is where it points.
  # The two are kept apart on purpose: the connection is made to the address, the
  # request names the host, because that is the virtual host the customer serves.
  defp target(url, uri, host, address) do
    %{
      url: url,
      scheme: uri.scheme,
      host: address_text(address),
      host_header: host,
      port: uri.port || Map.fetch!(@default_port, uri.scheme),
      # The path *and* query, because `URI.parse/1` keeps them apart and a
      # customer who registered `https://hooks.example.com/hooks?tenant=acme`
      # would otherwise get every delivery signed for a path courier silently
      # truncated to `/hooks`.
      path: path_with_query(uri)
    }
  end

  # The address goes back to text on the way out. The sender builds a URL and a
  # `Host` header from it, and a value that is a string in one branch and a tuple
  # in the other is a value some future caller interpolates as `{:ipv4, 8, 8,
  # 8, 8}`.
  defp address_text(address) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string()
  end

  defp address_text(address) when is_binary(address), do: address

  defp path_with_query(%URI{path: nil, query: nil}), do: "/"
  defp path_with_query(%URI{query: nil} = uri), do: uri.path || "/"

  defp path_with_query(%URI{path: path, query: query}) do
    if(path in [nil, ""], do: "/", else: path) <> "?" <> query
  end

  defp parse_answer(answer) do
    case :inet.parse_address(String.to_charlist(answer)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp address_of(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Whether `address` — an `:inet` address tuple or a textual one — is one courier
  will not connect to.

  Public so the sender can re-check the address it is about to dial, which is
  what makes the check a property of the connection rather than of the URL.
  """
  @spec blocked_address?(term()) :: boolean()
  def blocked_address?(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(String.trim(address))) do
      {:ok, parsed} -> blocked_address?(parsed)
      {:error, _reason} -> true
    end
  end

  # `:inet.parse_address/1` answers a bare `{a, b, c, d}` for IPv4 and a bare
  # eight-word list for IPv6 — not the `{:ipv4, ...}` / `{:ipv6, ...}` tuples
  # `:inet.getaddrs/2` answers, which is the shape a careless port of this
  # pattern from a Stack Overflow answer gets wrong, and gets wrong in the one
  # direction that blocks every public address.
  def blocked_address?({a, b, c, d})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and a < 256 and
             b < 256 and c < 256 and d < 256 do
    blocked_ipv4?(a, b, c, d)
  end

  def blocked_address?(words) when is_list(words) do
    blocked_ipv6?(words)
  end

  # `:inet.parse_address/1` answers IPv6 as an eight-word *tuple*, while
  # `getaddrs/2` and the network types in an Erlang literal answer it as a list.
  # Both shapes reach this function — one from a literal in a URL, one from a
  # resolver — so both are handled. The eight-word tuple has to be matched
  # *before* the four-word IPv4 one, or `2606:2800:220:1:…` is read as the IPv4
  # address `2606.2800.220.1` and refused for being in a range it is not in.
  def blocked_address?(words) when is_tuple(words) and tuple_size(words) == 8 do
    words |> Tuple.to_list() |> blocked_ipv6?()
  end

  # An address courier does not recognise is refused rather than allowed: the
  # cost of refusing an exotic address is one failed webhook, and the cost of
  # allowing one is a network boundary with a hole in it.
  def blocked_address?(_other), do: true

  # Every range below is a network, not an address: 10.1.2.3 and 10.255.0.1 are
  # both inside 10.0.0.0/8, so the test covers the edges rather than one example.
  defp blocked_ipv4?(0, _b, _c, _d), do: true
  defp blocked_ipv4?(10, _b, _c, _d), do: true
  defp blocked_ipv4?(127, _b, _c, _d), do: true
  # Shared address space, 100.64.0.0/10 (RFC 6598). Written as guards rather
  # than a `64..127` pattern because this whole block is guard clauses.
  defp blocked_ipv4?(100, second, _c, _d) when second >= 64 and second <= 127, do: true
  defp blocked_ipv4?(169, 254, _c, _d), do: true
  defp blocked_ipv4?(172, second, _c, _d) when second >= 16 and second <= 31, do: true
  defp blocked_ipv4?(192, 168, _c, _d), do: true
  defp blocked_ipv4?(192, 0, 0, _d), do: true
  defp blocked_ipv4?(192, 0, 2, _d), do: true
  defp blocked_ipv4?(198, second, _c, _d) when second >= 18 and second <= 19, do: true
  defp blocked_ipv4?(198, 51, 100, _d), do: true
  defp blocked_ipv4?(203, 0, 113, _d), do: true
  # Multicast and reserved, 224.0.0.0/4 and 240.0.0.0/4. A webhook cannot be
  # delivered to either, and allowing them would be a way to fan courier's
  # traffic out across a network.
  defp blocked_ipv4?(octet, _b, _c, _d) when octet >= 224, do: true
  defp blocked_ipv4?(_a, _b, _c, _d), do: false

  # :: — the unspecified address, which on a host means "this machine".
  defp blocked_ipv6?([0, 0, 0, 0, 0, 0, 0, 0]), do: true
  # ::1 — loopback.
  defp blocked_ipv6?([0, 0, 0, 0, 0, 0, 0, 1]), do: true
  # ::ffff:0:0/96 — an IPv4 address in IPv6 clothing. The last 32 bits are the
  # address, so they are unpacked into four octets and asked the same question as
  # an IPv4 one. Getting the unpacking wrong here is how `::ffff:127.0.0.1`
  # slips through a guard that blocks `127.0.0.1`.
  #
  # A *public* mapped address (`::ffff:8.8.8.8`) answers `false`, which is what
  # makes the `::ffff:0:0/96` clause a filter rather than a blanket refusal.
  defp blocked_ipv6?([0, 0, 0, 0, 0, 0xFFFF, high, low]) do
    blocked_ipv4?(high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF)
  end

  # ::/8 beyond the two above, which is all of `::`-and-up.
  defp blocked_ipv6?([0, 0, 0, 0, 0, 0, 0, _word]), do: true
  # The deprecated site-local range fec0::/10, kept out for the same reason as
  # everything else: it was never a public range either.
  defp blocked_ipv6?([0xFEC0, 0xFEFF | _rest]), do: true
  # fc00::/7 unique-local and fe80::/10 link-local, tested on the first word.
  defp blocked_ipv6?([word | _rest]) when word >= 0xFC00 and word <= 0xFDFF, do: true
  defp blocked_ipv6?([word | _rest]) when word >= 0xFE80 and word <= 0xFEBF, do: true
  # Multicast ff00::/8.
  defp blocked_ipv6?([word | _rest]) when word >= 0xFF00, do: true
  defp blocked_ipv6?(_words), do: false
end
