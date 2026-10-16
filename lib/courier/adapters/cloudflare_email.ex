defmodule Courier.Adapters.CloudflareEmail do
  @moduledoc """
  courier's Cloudflare Email adapter — the Cloudflare Email Sending REST API.

  Cloudflare Email Routing is receive-only; the sending half is the
  **Cloudflare Email Sending** API, a first-party REST endpoint under
  `api.cloudflare.com`. The adapter posts to it, and the credential is the
  same Cloudflare API token an operator already creates in the dashboard that
  owns the DNS — scoped to "Email Sending: Edit", revocable, no second vendor.
  That is the whole point of calling the adapter `cloudflare`.

  ## The contract, and where it comes from

  `POST https://api.cloudflare.com/client/v4/accounts/{account_id}/email/sending/send`,
  `Authorization: Bearer <token>`, JSON body. Published at
  <https://developers.cloudflare.com/email-service/api/send-emails/rest-api/>
  and the OpenAPI at
  <https://developers.cloudflare.com/api/resources/email_sending/methods/send/>.
  The recipients shape (cc/bcc/named) is at
  <https://developers.cloudflare.com/email-service/examples/email-sending/recipients/>.
  Read off those pages rather than remembered:

    * required body fields: `to`, `from`, `subject`, plus at least one of
      `html` / `text`
    * `to` / `from` / `cc` / `bcc` each accept a bare address string or
      `{address, name}` — the shape `recipient/1` builds (REST API; the Workers binding uses `{email, name}` and is the wrong shape here)
    * `headers` is `additionalProperties: string` — a JSON object, same as the
      previous MailChannels contract, and NOT an array of pairs. The provider
      OWNS `Message-ID` (it refuses a caller-supplied one with `400 / 10202` and
      returns its own as `result.message_id`), so the adapter never forwards it;
      see `@provider_owned_headers`. `List-Unsubscribe` and
      `List-Unsubscribe-Post` do travel through here.
    * `attachments` are `{content (base64), filename, type, disposition}` —
      the shape `prepare_attachment/1` builds
    * responses: `2xx` with `{"success": true, "result": {delivered,
      permanent_bounces, queued, suppressed_recipients, message_id}}` on
      success (`message_id` is the provider-assigned id the receipt carries);
      `4xx`/`5xx` with `{"success": false, "errors": [...]}` on failure
    * total message size (attachments included) must not exceed 5 MiB

  **A 2xx is not always a success.** See below.

  ## The failure this adapter exists to surface

  The brief's first failure mode is a provider path that swallows delivery
  failures: jumpstart's Cloudflare-ish route left `raise_delivery_errors` at
  its `false` default, so mail vanished with no error. This adapter's answer
  is structural rather than a flag: **every non-2xx is `{:error, {code,
  body}}`**, a transport error is `{:error, reason}`, and a 2xx that names a
  recipient under `permanent_bounces` or `suppressed_recipients` — or carries
  `success: false` — is also `{:error, _}`. There is no code path that
  returns `{:ok, _}` for a mail the provider did not accept.

  The same class of trap the previous MailChannels adapter handled for a 202
  carrying `status: "failed"`, translated: `result.permanent_bounces` and
  `result.suppressed_recipients` are the failure channel, and they arrive
  under a 2xx. A courier outbox row for mail that was permanently refused is
  the silent failure this whole adapter exists to prevent — do not let it back
  in. `test/courier/cloudflare_delivery_test.exs` drives each of those 2xx
  shapes against a real HTTP server that answers them.

  ## Why a courier-owned adapter module

  Swoosh ships no Cloudflare adapter, and the rule in this repository is
  that a dependency is not added without approval. So the adapter is
  courier's own, in the same shape as `Swoosh.Adapters.Postmark`: it posts
  through `Swoosh.ApiClient.post/4`, which `config/runtime.exs` turns on
  from the provider table (`Courier.MailerAdapter.api_client/1`) rather than
  from a second variable an operator could forget.

  ## Configuration

      COURIER_MAIL_ADAPTER=cloudflare
      COURIER_CLOUDFLARE_API_KEY=...      required; the Cloudflare API token
      COURIER_CF_ACCOUNT_ID=...           required; the Cloudflare account id
                                          that owns the sending domain

  `base_url` is read from the adapter config and defaults to the production
  API host. It exists so a test can point the adapter at a listener it
  controls — the same seam `Swoosh.Adapters.Postmark` has — and is not a
  variable an operator sets.
  """

  use Swoosh.Adapter, required_config: [:api_key, :account_id]

  alias Swoosh.Email

  @base_url "https://api.cloudflare.com/client/v4"

  # THE PROVIDER OWNS `Message-ID`, AND THIS LIST IS WHY COURIER NEVER SENDS IT.
  #
  # Cloudflare Email Sending refuses a caller-supplied `Message-ID` — in EITHER
  # case — with `400` and exactly
  # `{"success":false,"errors":[{"code":10202,"message":"email.sending.error.email.invalid"}],"result":null}`
  # (measured live on cafaye.com, 2026-10-16). It assigns a Message-ID itself and
  # returns it as `result.message_id` on every 2xx — that is what `accepted/2`
  # now reports as the receipt id, and it is the id the provider's own bounce and
  # delivery reports quote.
  #
  # `Courier.Deliver`'s `tag/2` attaches `message-id`
  # (`<courier-<uuid>@cafaye.com>`) to EVERY message it sends, so forwarding this
  # one header was the difference between a delivery and a refusal of the whole
  # message. It must never be forwarded again.
  #
  # This is a targeted drop of a header the provider OWNS, NOT an allow-list.
  # `headers` is `additionalProperties: string` and Cloudflare accepts real
  # headers — `List-Unsubscribe` and `List-Unsubscribe-Post` travel through it
  # for RFC 8058 compliance — so refusing everything not on a list would break
  # the moment Cloudflare adds a header. Only the provider-owned ones are ours to
  # remove.
  @provider_owned_headers ["message-id"]

  @doc """
  Delivers one email through the Cloudflare Email Sending API.

  Returns `{:ok, %{id: provider_message_id}}` on a 2xx whose `result` carries no
  `permanent_bounces` or `suppressed_recipients` and whose `success` is not
  `false`. `provider_message_id` is the provider's own `result.message_id` —
  Cloudflare assigns it and refuses a caller-supplied one, so it is the id the
  provider's reports quote — and is `nil` only when a 2xx body carries none.
  Returns `{:error, {code, body}}` on a non-2xx or a `success: false`
  envelope, and `{:error, reason}` when the request itself fails (refused,
  timed out, unresolvable).

  The non-2xx branch is the one that matters. Cloudflare answers `400` for a
  malformed payload, `401` for a bad token, `403` for a token that lacks
  permission or a zone not entitled to send, `429` for throttling, and
  `500`/`503` for transient failures. All of them are delivery failures the
  caller must be told about, and none of them is `{:ok, _}`.

  ## The 2xx that is not a success

  A 2xx answers "your request was accepted", and the body then carries the
  per-recipient verdict. Cloudflare's `result` is `{delivered,
  permanent_bounces, queued, suppressed_recipients}`, so **a 2xx CAN contain a
  recipient that was refused** — the request was well-formed and the provider
  refused one address inside it. Returning `{:ok, _}` there would be the
  silent default wearing a 2xx: courier would write an outbox row and publish
  `courier.email.delivered` for a mail that was not sent. So a 2xx whose
  `result` carries any `permanent_bounces` or `suppressed_recipients`, or
  whose envelope has `success: false`, is `{:error, {code, body}}`.

  A `queued` recipient is NOT a failure — the provider accepted the message
  for later delivery, which is the same promise a `delivered` recipient got
  one step further along.
  """
  @spec deliver(Email.t(), keyword()) ::
          {:ok, %{id: String.t() | nil}} | {:error, {pos_integer(), term()} | term()}
  def deliver(%Email{} = email, config \\ []) do
    headers = prepare_headers(config)
    body = email |> prepare_body() |> Swoosh.json_library().encode!()
    url = [base_url(config), "/accounts/", config[:account_id], "/email/sending/send"]

    case Swoosh.ApiClient.post(url, headers, body, email) do
      {:ok, code, _headers, body} when code >= 200 and code <= 399 ->
        accepted(code, body)

      {:ok, code, _headers, body} ->
        case Swoosh.json_library().decode(body) do
          {:ok, decoded} -> {:error, {code, decoded}}
          {:error, _} -> {:error, {code, body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delivers each email in its own request, collecting the receipts.

  Each Swoosh email is a complete message with its own sender, subject and
  body, so each is posted separately. The first failure stops the run.
  courier sends one message per `Courier.Mailers.deliver/2` call and never
  invokes this; it is here because the behaviour declares it and a caller
  that reaches it should get the same failure-surfacing contract as
  `deliver/2`.
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

  defp prepare_headers(config) do
    [
      {"Authorization", "Bearer #{config[:api_key]}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  defp prepare_body(email) do
    %{}
    |> prepare_from(email)
    |> prepare_to(email)
    |> prepare_cc(email)
    |> prepare_bcc(email)
    |> prepare_subject(email)
    |> prepare_content(email)
    |> prepare_attachments(email)
    |> prepare_custom_headers(email)
  end

  defp prepare_from(body, %{from: from}), do: Map.put(body, "from", recipient(from))

  defp prepare_to(body, %{to: to}) do
    case to do
      [] -> body
      [single] -> Map.put(body, "to", recipient(single))
      list when is_list(list) -> Map.put(body, "to", Enum.map(list, &recipient/1))
      single -> Map.put(body, "to", recipient(single))
    end
  end

  defp prepare_cc(body, %{cc: []}), do: body
  defp prepare_cc(body, %{cc: nil}), do: body

  defp prepare_cc(body, %{cc: cc}) do
    value =
      case cc do
        [single] -> recipient(single)
        list when is_list(list) -> Enum.map(list, &recipient/1)
        single -> recipient(single)
      end

    Map.put(body, "cc", value)
  end

  defp prepare_bcc(body, %{bcc: []}), do: body
  defp prepare_bcc(body, %{bcc: nil}), do: body

  defp prepare_bcc(body, %{bcc: bcc}) do
    value =
      case bcc do
        [single] -> recipient(single)
        list when is_list(list) -> Enum.map(list, &recipient/1)
        single -> recipient(single)
      end

    Map.put(body, "bcc", value)
  end

  defp prepare_subject(body, %{subject: ""}), do: body
  defp prepare_subject(body, %{subject: subject}), do: Map.put(body, "subject", subject)

  defp prepare_content(body, %{text_body: nil, html_body: nil}), do: body

  defp prepare_content(body, email) do
    body
    |> maybe_put("text", email.text_body)
    |> maybe_put("html", email.html_body)
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, _key, ""), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp prepare_attachments(body, %{attachments: []}), do: body

  defp prepare_attachments(body, %{attachments: attachments}) do
    Map.put(body, "attachments", Enum.map(attachments, &prepare_attachment/1))
  end

  defp prepare_attachment(attachment) do
    base = %{
      "content" => Swoosh.Attachment.get_content(attachment, :base64),
      "filename" => attachment.filename,
      "type" => attachment.content_type
    }

    case attachment.type do
      :inline -> Map.put(base, "disposition", "inline")
      _ -> Map.put(base, "disposition", "attachment")
    end
  end

  defp prepare_custom_headers(body, %{headers: headers}) when map_size(headers) == 0, do: body

  defp prepare_custom_headers(body, %{headers: headers}) do
    case drop_provider_owned_headers(headers) do
      cleaned when map_size(cleaned) == 0 -> body
      cleaned -> Map.put(body, "headers", cleaned)
    end
  end

  # Case-insensitive because the provider refuses `Message-ID` and `message-id`
  # alike, and `Swoosh.Email.header/3` stores the key exactly as the caller wrote
  # it. See `@provider_owned_headers` for why only these are dropped.
  defp drop_provider_owned_headers(headers) do
    Map.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) in @provider_owned_headers
    end)
  end

  defp recipient(nil), do: ""
  defp recipient({nil, email}), do: email
  defp recipient({"", email}), do: email
  defp recipient({name, email}), do: %{"address" => email, "name" => name}
  defp recipient(email) when is_binary(email), do: email

  defp accepted(code, body) do
    case Swoosh.json_library().decode(body) do
      {:error, _} ->
        {:ok, %{id: nil}}

      {:ok, decoded} when is_map(decoded) ->
        cond do
          decoded["success"] == false ->
            {:error, {code, decoded}}

          true ->
            result = decoded["result"] || %{}
            bounces = result["permanent_bounces"] || []
            suppressed = result["suppressed_recipients"] || []

            if bounces != [] or suppressed != [] do
              {:error, {code, decoded}}
            else
              # The provider's own Message-ID, assigned because it refuses a
              # caller-supplied one. It is what the provider's bounce and
              # delivery reports quote, so it is the receipt id courier must
              # carry rather than a nil it can correlate nothing against.
              {:ok, %{id: result["message_id"]}}
            end
        end

      {:ok, _other} ->
        {:ok, %{id: nil}}
    end
  end
end
