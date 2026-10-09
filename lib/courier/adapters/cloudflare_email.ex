defmodule Courier.Adapters.CloudflareEmail do
  @moduledoc """
  courier's Cloudflare Email adapter, and the provider it actually speaks to.

  Cloudflare Email Routing is receive-only — it routes inbound mail to your
  address and has no send API. The sending half of a Cloudflare Email
  connection is the **MailChannels transactional API**, which is what this
  adapter posts to. The two are one product from the customer's side: they
  authorize a domain once (the `_mailchannels` TXT record and the SPF
  `include:relay.mailchannels.net` — see W3-P5) and then send through
  MailChannels. So "the Cloudflare Email adapter" is not a port of a
  provider-specific SDK; it is the MailChannels contract, named for the
  product the customer bought.

  ## The contract, and where it comes from

  `POST https://api.mailchannels.net/tx/v1/send`, `X-Api-Key` header, JSON
  body. The payload is MailChannels' own shape — `personalizations` /
  `from` / `subject` / `content` — documented at
  <https://docs.mailchannels.com/email-api/curl/quickstart> and pinned by
  the OpenAPI schema at
  <https://docs.mailchannels.com/api-reference/send/send-an-email>. The
  response is `202` with a `SendResults` body (`request_id` plus a
  per-personalization `message_id`), or a non-2xx with an `ErrorResponse`
  body (`{"errors": [...]}`).

  ## The failure this adapter exists to surface

  The brief's first failure mode is a provider path that swallows delivery
  failures: jumpstart's Cloudflare-ish route left `raise_delivery_errors` at
  its `false` default, so mail vanished with no error. This adapter's answer
  is structural rather than a flag: **every non-2xx is `{:error, {code,
  body}}`**, and a transport error is `{:error, reason}`. There is no code
  path that returns `{:ok, _}` for a mail the provider did not accept, and
  `test/courier/cloudflare_delivery_test.exs` proves it against a real HTTP
  server that refuses the send — the test that would have caught the silent
  default.

  ## Why a courier-owned adapter module

  Swoosh ships no MailChannels adapter, and the rule in this repository is
  that a dependency is not added without approval. So the adapter is
  courier's own, in the same shape as `Swoosh.Adapters.Postmark`: it posts
  through `Swoosh.ApiClient.post/4`, which `config/runtime.exs` turns on
  from the provider table (`Courier.MailerAdapter.api_client/1`) rather than
  from a second variable an operator could forget.

  ## Configuration

      COURIER_MAIL_ADAPTER=cloudflare
      COURIER_CLOUDFLARE_API_KEY=...      required; the MailChannels API key

  `base_url` is read from the adapter config and defaults to the production
  endpoint. It exists so a test can point the adapter at a listener it
  controls — the same seam `Swoosh.Adapters.Postmark` has — and is not a
  variable an operator sets.
  """

  use Swoosh.Adapter, required_config: [:api_key]

  alias Swoosh.Email

  @base_url "https://api.mailchannels.net/tx/v1"
  @api_endpoint "/send"

  @doc """
  Delivers one email through the MailChannels send API.

  Returns `{:ok, %{id: request_id}}` on a 2xx, where `request_id` is the
  provider's own identifier for the request (present in every webhook it
  later sends). Returns `{:error, {code, body}}` on a non-2xx — the status
  and the provider's error body, decoded when it is JSON — and
  `{:error, reason}` when the request itself fails (refused, timed out,
  unresolvable).

  The non-2xx branch is the one that matters. MailChannels answers `400` for
  a malformed payload, `403` for a missing/invalid key or an unauthorized
  sending domain, `413` for an over-large message, and `500`/`502` for
  transient failures. All of them are delivery failures the caller must be
  told about, and none of them is `{:ok, _}`.
  """
  @spec deliver(Email.t(), keyword()) ::
          {:ok, %{id: String.t() | nil}} | {:error, {pos_integer(), term()} | term()}
  def deliver(%Email{} = email, config \\ []) do
    headers = prepare_headers(config)
    body = email |> prepare_body() |> Swoosh.json_library().encode!()
    url = [base_url(config), @api_endpoint]

    case Swoosh.ApiClient.post(url, headers, body, email) do
      {:ok, code, _headers, body} when code >= 200 and code <= 399 ->
        {:ok, %{id: extract_id(body)}}

      {:ok, code, _headers, body} ->
        case Swoosh.json_library().decode(body) do
          {:ok, error} -> {:error, {code, error}}
          {:error, _} -> {:error, {code, body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delivers each email in its own request, collecting the receipts.

  MailChannels accepts multiple `personalizations` in one call, but each
  Swoosh email is a complete message with its own sender, subject and body,
  and folding them into one request would mean deciding which fields are
  per-recipient overrides and which are shared — a decision this adapter
  does not get to make on the caller's behalf. So each email is posted
  separately, the first failure stops the run, and the result is `{:ok,
  [receipt]}` or `{:error, reason}`. courier sends one message per
  `Courier.Mailers.deliver/2` call and never invokes this; it is here
  because the behaviour declares it and a caller that reaches it should get
  the same failure-surfacing contract as `deliver/2`.
  """
  @spec deliver_many([Email.t()], keyword()) ::
          {:ok, [%{id: String.t() | nil}]} | {:error, term()}
  def deliver_many(emails, config \\ []) do
    results =
      Enum.reduce_while(emails, {:ok, []}, fn email, {:ok, acc} ->
        case deliver(email, config) do
          {:ok, receipt} -> {:cont, {:ok, [receipt | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_url(config), do: config[:base_url] || @base_url

  # `X-Api-Key` is MailChannels' authentication, and it is the whole secret —
  # the same class of credential as a Postmark server token. The User-Agent
  # is added by `Swoosh.ApiClient.Req` itself, so it is not repeated here.
  defp prepare_headers(config) do
    [
      {"X-Api-Key", config[:api_key]},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  # The MailChannels payload. `personalizations` carries the recipients (the
  # only required field inside it); `from`, `subject` and `content` are the
  # root-level message. The shape is the provider's, not a generic one — a
  # second provider with a different vocabulary would be a different
  # adapter, not a branch here.
  defp prepare_body(email) do
    %{}
    |> prepare_from(email)
    |> prepare_to(email)
    |> prepare_subject(email)
    |> prepare_content(email)
    |> prepare_cc(email)
    |> prepare_bcc(email)
    |> prepare_reply_to(email)
    |> prepare_attachments(email)
    |> prepare_custom_headers(email)
  end

  defp prepare_from(body, %{from: from}), do: Map.put(body, "from", address(from))

  defp prepare_to(body, %{to: to}),
    do: Map.put(body, "personalizations", [%{"to" => addresses(to)}])

  defp prepare_cc(body, %{cc: []}), do: body
  defp prepare_cc(body, %{cc: cc}), do: put_in_personalization(body, "cc", addresses(cc))

  defp prepare_bcc(body, %{bcc: []}), do: body
  defp prepare_bcc(body, %{bcc: bcc}), do: put_in_personalization(body, "bcc", addresses(bcc))

  # `cc`/`bcc` live inside each personalization in MailChannels' shape, so
  # they are merged into the one `to` entry `prepare_to/2` created rather
  # than appended as a second personalization.
  defp put_in_personalization(body, key, recipients) do
    update_in(body, ["personalizations", Access.at(0)], fn personalization ->
      Map.put(personalization, key, recipients)
    end)
  end

  defp prepare_subject(body, %{subject: ""}), do: body
  defp prepare_subject(body, %{subject: subject}), do: Map.put(body, "subject", subject)

  # `content` is an array of `{type, value}` parts. Both a text and an HTML
  # body are always present in a courier message (see `Courier.Mailers`), so
  # the array has two entries; a body that is nil is omitted rather than
  # sent as an empty part.
  defp prepare_content(body, %{text_body: nil, html_body: nil}), do: body

  defp prepare_content(body, email) do
    content =
      []
      |> maybe_add_content("text/plain", email.text_body)
      |> maybe_add_content("text/html", email.html_body)

    Map.put(body, "content", content)
  end

  defp maybe_add_content(acc, _type, nil), do: acc
  defp maybe_add_content(acc, _type, ""), do: acc
  defp maybe_add_content(acc, type, value), do: acc ++ [%{"type" => type, "value" => value}]

  defp prepare_reply_to(body, %{reply_to: nil}), do: body

  defp prepare_reply_to(body, %{reply_to: reply_to}),
    do: Map.put(body, "reply_to", address(reply_to))

  defp prepare_attachments(body, %{attachments: []}), do: body

  defp prepare_attachments(body, %{attachments: attachments}) do
    Map.put(body, "attachments", Enum.map(attachments, &prepare_attachment/1))
  end

  defp prepare_attachment(attachment) do
    attachment_data = %{
      "filename" => attachment.filename,
      "type" => attachment.content_type,
      "content" => Swoosh.Attachment.get_content(attachment, :base64)
    }

    case attachment.type do
      :attachment -> attachment_data
      :inline -> Map.put(attachment_data, "content_id", attachment.cid)
    end
  end

  defp prepare_custom_headers(body, %{headers: headers}) when map_size(headers) == 0, do: body

  defp prepare_custom_headers(body, %{headers: headers}) do
    Map.put(body, "headers", headers)
  end

  # MailChannels' `EmailAddress` is `{email, name}` — the same shape
  # `render_recipient/1` produces for the wire, minus the display-name
  # quoting. A recipient with no name is the bare address.
  defp address(nil), do: %{"email" => ""}
  defp address({nil, email}), do: %{"email" => email}
  defp address({"", email}), do: %{"email" => email}
  defp address({name, email}), do: %{"email" => email, "name" => name}

  defp addresses(recipients) when is_list(recipients),
    do: Enum.map(recipients, &address/1)

  defp addresses(recipient), do: [address(recipient)]

  # The `request_id` is the provider's identifier for the whole request and
  # is what its later webhooks reference. A `200` dry-run answer carries no
  # `request_id` (it returns the rendered message instead), so the id is
  # `nil` there — the send was accepted, and there is nothing to reference.
  defp extract_id(body) do
    case Swoosh.json_library().decode(body) do
      {:ok, %{"request_id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end
end
