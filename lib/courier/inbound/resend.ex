defmodule Courier.Inbound.Resend do
  @moduledoc """
  Resend's deliverability reports, in courier's vocabulary.

  The first provider implementation of `Courier.Inbound`, and the one that
  matters for a specific reason: **Resend signs its webhooks with Svix**, and
  Svix is the scheme Standard Webhooks was standardised from. So the provider
  courier already talks to for OUTBOUND delivery is the provider that speaks the
  scheme courier already implements for OUTBOUND webhooks, and
  `Courier.Inbound.Signature` verifies it with the same base string.


  It is a translator and nothing else. It reads one provider's JSON and produces
  the event maps `Courier.Suppressions.ingest/1` already accepts, with the kind
  expressed in courier's words rather than Resend's. It does not verify anything
  (that is `Courier.Inbound.Signature`, and it runs first), it does not write
  anything (that is `Suppressions.ingest/1`), and it does not decide HTTP status
  (that is worker C's route).

  The mapping honours `Courier.Suppression`'s stated rationale rather than
  inventing a parallel vocabulary: "a Postmark `HardBounce` and an SES
  `Permanent` are both `:undeliverable` here, because the question courier asks
  is not 'what did Postmark call it' but 'can this mailbox receive mail'."
  Resend's `bounce.type` is the same shape of word, so the table is:

  | Resend `bounce.type` | courier kind | what courier does |
  | -------------------- | ------------ | ----------------- |
  | `Permanent`          | `:hard_bounce` | records `:undeliverable`, stops sending |
  | `Transient`          | `:soft_bounce` | records nothing |
  | `Temporary`          | `:soft_bounce` | records nothing |
  | `Undetermined`       | `:soft_bounce` | records nothing |

  Plus two event types that are not bounces at all:

  | Resend `type`      | courier kind | why |
  | ------------------ | ------------ | --- |
  | `email.complained` | `:complaint` | an abuse report; `Courier.Suppressions` makes it outrank a bounce |
  | `email.delivery_delayed` | `:soft_bounce` | "couldn't be delivered due to a temporary issue" — RFC 5321 §4.2.2 |

  Everything else is `{:ok, []}` or an error, and both of those are decisions
  rather than omissions. `test/courier/inbound/resend_test.exs` states each one
  with the documentation it came from.


    * **An event courier cannot classify is refused, not defaulted.** An unknown
      `type` is `{:error, :unsupported_event}` and an unknown `bounce.type` is
      `{:error, {:unknown_bounce_type, value}}`. `Courier.Suppressions` is
      explicit: "Storing an unclassifiable event as 'not suppressed' would be a
      decision courier could not defend." A provider that adds a bounce type
      should be VISIBLE in courier's logs, not quietly recorded as nothing.
    * **A known value meaning "we don't know" is the safe direction.**
      `Undetermined` is a real documented value and courier treats it as soft,
      because being told there was a bounce is not being told the mailbox is
      gone. Distinguishing "the provider says it does not know" from "courier
      does not recognise what the provider said" is the whole difference between
      a decision and a guess.
    * **The idempotency key is `email_id` AND the recipient.** Resend's `to` is
      "Array of impacted recipient email addresses" and a broadcast has one
      `email_id` for all of them, so `email_id` alone would let four of five
      bounces be recorded as duplicates of the first — four live mailboxes
      courier goes on mailing forever.
    * **Nothing is stored that courier does not act on.** The subject, the
      sender, the tags and the broadcast id are read out of the payload and
      dropped. `Courier.Suppression` says a `payload` column "would be a copy of
      somebody's inbox held for no operational reason", and every field carried
      forward is one `Courier.Observability` would have to keep out of a span.
  """

  @behaviour Courier.Inbound

  alias Courier.Suppressions

  @provider "resend"

  @complained "email.complained"
  @delivery_delayed "email.delivery_delayed"
  @bounced "email.bounced"

  @bounce_types %{
    "Permanent" => :hard_bounce,
    "Transient" => :soft_bounce,
    "Temporary" => :soft_bounce,
    "Undetermined" => :soft_bounce
  }

  @uninteresting_events MapSet.new([
                          "email.delivered",
                          "email.sent",
                          "email.scheduled",
                          "email.opened",
                          "email.clicked",
                          "email.failed",
                          "email.received",
                          "suppression.added",
                          "suppression.removed",
                          "domain.created",
                          "domain.updated",
                          "domain.deleted",
                          "contact.created",
                          "contact.updated",
                          "contact.deleted",
                          "contact.topics.updated",
                          "topic.created",
                          "topic.updated",
                          "topic.deleted",
                          "inbox.created",
                          "inbox.updated",
                          "inbox.deleted",
                          "inbox.thread.created",
                          "inbox.thread.folder.updated",
                          "inbox.thread.assigned",
                          "inbox.thread.unassigned",
                          "inbox.thread.labels.updated",
                          "inbox.email.received",
                          "inbox.email.sent",
                          "inbox.draft.created",
                          "inbox.draft.updated",
                          "inbox.draft.sent",
                          "inbox.draft.deleted"
                        ])

  @doc """
  The value that goes in `email_suppressions.provider`, and half of the unique
  index `(provider, provider_event_id)`.
  """
  @impl Courier.Inbound
  def provider, do: @provider

  @doc """
  Parses one Resend webhook body into zero or more `Courier.Suppressions` events.

  Takes the RAW body as a binary, not a decoded map, and the reason is not
  fussiness: the caller has to hand `Courier.Inbound.Signature.verify/4` the same
  bytes, and spec §Signature scheme names parse-then-re-serialize as "a very
  common failure mode" of verification. A parser that took a map would invite a
  route that parsed first and verified a re-encoding, which verifies nothing.

  `{:ok, []}` means "understood, and courier has no opinion on this event".
  `{:ok, events}` means one or more reports, one per recipient, each ready for
  `Courier.Suppressions.ingest/1`. An error means the payload could not be read
  or not be classified, and the reason says which.
  """
  @impl Courier.Inbound
  def parse(body) when is_binary(body) do
    with {:ok, envelope} <- decode(body),
         {:ok, type} <- string_field(envelope, :type),
         {:ok, data} <- object_field(envelope, :data),
         do: classify(type, envelope, data)
  end

  @impl Courier.Inbound
  def parse(_not_a_binary), do: {:error, :invalid_body}

  defp classify(@bounced, envelope, data) do
    with {:ok, bounce} <- object_field(data, :bounce),
         {:ok, bounce_type} <- string_field(bounce, :type),
         {:ok, kind} <- bounce_kind(bounce_type),
         {:ok, email_id} <- string_field(data, :email_id),
         {:ok, recipients} <- recipients(data),
         do: build(@bounced, kind, envelope, data, bounce, recipients, email_id)
  end

  defp classify(@complained, envelope, data) do
    with {:ok, email_id} <- string_field(data, :email_id),
         {:ok, recipients} <- recipients(data),
         do: build(@complained, :complaint, envelope, data, nil, recipients, email_id)
  end

  defp classify(@delivery_delayed, envelope, data) do
    with {:ok, email_id} <- string_field(data, :email_id),
         {:ok, recipients} <- recipients(data),
         do: build(@delivery_delayed, :soft_bounce, envelope, data, nil, recipients, email_id)
  end

  defp classify(type, _envelope, _data) do
    if MapSet.member?(@uninteresting_events, type),
      do: {:ok, []},
      else: {:error, :unsupported_event}
  end

  defp bounce_kind(type) do
    case Map.fetch(@bounce_types, type) do
      {:ok, kind} ->
        {:ok, kind}

      :error ->
        {:error, {:unknown_bounce_type, type}}
    end
  end

  defp build(type, kind, envelope, data, bounce, recipients, email_id) do
    with {:ok, message_id} <- optional_string(data, :message_id) do
      {:ok, Enum.map(recipients, &event(&1, type, kind, envelope, bounce, email_id, message_id))}
    end
  end

  defp event(email, type, kind, envelope, bounce, email_id, message_id) do
    %{
      provider: @provider,
      provider_event_id: event_id(type, email_id, email),
      email: email,
      kind: kind,
      reason: reason(bounce),
      message_id: message_id,
      occurred_at: occurred_at(envelope)
    }
  end

  defp event_id(type, email_id, email) do
    "#{type}/#{email_id}:#{Suppressions.normalize(email)}"
  end

  defp reason(nil), do: nil

  defp reason(bounce) do
    [
      Map.get(bounce, "type"),
      Map.get(bounce, "subType"),
      bounce |> diagnostic() |> Kernel.||(Map.get(bounce, "message"))
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(": ")
  end

  defp diagnostic(bounce) do
    case bounce |> Map.get("diagnosticCode") |> List.wrap() |> Enum.filter(&is_binary/1) do
      [] -> nil
      codes -> Enum.join(codes, " | ")
    end
  end

  defp occurred_at(envelope) do
    with value when is_binary(value) <- Map.get(envelope, "created_at"),
         {:ok, instant, _offset} <- DateTime.from_iso8601(value) do
      instant
    else
      _absent_or_unparseable -> nil
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _not_an_object} -> {:error, :invalid_payload}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp object_field(payload, field) do
    case Map.fetch(payload, Atom.to_string(field)) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      {:ok, _wrong_type} ->
        {:error, {:invalid_field, field}}

      :error ->
        {:error, {:missing_field, field}}
    end
  end

  defp string_field(payload, field) do
    case Map.fetch(payload, Atom.to_string(field)) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _wrong_type} -> {:error, {:invalid_field, field}}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp optional_string(payload, field) do
    case Map.fetch(payload, Atom.to_string(field)) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      :error -> {:ok, nil}
      {:ok, _wrong_type} -> {:error, {:invalid_field, field}}
    end
  end

  defp recipients(data) do
    case Map.fetch(data, "to") do
      {:ok, list} when is_list(list) -> validate_recipients(list)
      {:ok, _not_a_list} -> {:error, {:invalid_field, :to}}
      :error -> {:error, {:missing_field, :to}}
    end
  end

  defp validate_recipients([]), do: {:error, {:missing_field, :to}}

  defp validate_recipients(list) do
    case Enum.find(list, &(not valid_recipient?(&1))) do
      nil -> {:ok, list}
      bad -> {:error, {:invalid_recipient, bad}}
    end
  end

  defp valid_recipient?(address) when is_binary(address) do
    Regex.match?(~r/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/, address)
  end

  defp valid_recipient?(_other), do: false
end
