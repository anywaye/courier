defmodule Courier.ErrorRelay.Sink do
  @moduledoc """
  Where a redacted envelope goes, and how one is framed.


  A sink takes **bytes** and returns `:ok | {:error, reason}`. It does not know
  about redaction, about fingerprints, or about the throttle, and it cannot
  redact: the whole claim of this packet is that the redaction happens in
  `Courier.ErrorRelay.Policy` at one chokepoint, and a sink that could reach an
  unredacted event would make that claim a matter of which implementation is
  configured.

  Three implementations ship:

    * `Courier.ErrorRelay.Sink.Req` — POSTs to GlitchTip. The shipped one.
    * `Courier.ErrorRelay.Sink.Noop` — discards. What a deployment with no
      sink DSN gets, so "the relay is on and there is nowhere to send" is a
      configuration that runs and says so rather than a boot failure.
    * `Courier.TestSupport.RecordingSink` — hands the bytes to a test.


  A Sentry envelope is newline-delimited: one JSON **header** object, then a
  sequence of items, each an item-header JSON object on its own line followed by
  exactly `length` bytes of payload. It is not a JSON document and it is not
  `multipart/form-data`; a relay that treated it as either would parse
  something.

  The relay **rebuilds** the envelope rather than editing bytes in place, for
  three reasons that all come from the same place:

    1. The payload of an `event` item has to be decoded, redacted and re-encoded.
    2. Items that are not events — `session`, `transaction` — are dropped, and
       dropping an item from a length-prefixed stream means re-writing every
       subsequent length.
    3. The header's `dsn` is **replaced with the sink's DSN**. The DSN an SDK
       holds is the relay's, and the relay is not GlitchTip; forwarding it would
       either confuse the store or, in a configuration where a service is
       pointed straight at GlitchTip, mean a service's DSN is a GlitchTip
       credential. Rewriting it here is what makes "the SDKs only ever know the
       relay" true at the byte level.

  Every function here refuses rather than raises, for the reason that recurs
  through this module: the input is bytes off a socket that courier did not
  write, and a crash in the error path is the failure this packet exists to
  prevent.
  """

  @typedoc "A Sentry envelope item: its item-header plus the raw payload bytes."
  @type item :: %{optional(String.t()) => term()}

  @doc "Ship one envelope. `:ok`, or `{:error, reason}`. Never raises."
  @callback forward(binary(), keyword()) :: :ok | {:error, term()}

  @doc """
  Parse a Sentry envelope into its items.

  `{:ok, [%{"type" => ..., "payload" => binary}, ...]}` or
  `{:error, reason}`. The payload is returned as **bytes** rather than decoded,
  because an item's payload type is the item's business: an `event` item is JSON
  and a `attachment` item is not, and a reader that decoded everything would
  reject an envelope for containing an attachment.
  """
  @spec parse_envelope(binary()) :: {:ok, [item()]} | {:error, term()}
  def parse_envelope(binary) when is_binary(binary) do
    with {:ok, _header, rest} <- take_line(binary),
         {:ok, items} <- take_items(rest, []) do
      {:ok, Enum.reverse(items)}
    end
  end

  def parse_envelope(_other), do: {:error, :not_bytes}

  @doc """
  Build a Sentry envelope from items, with `dsn` as the header's DSN.

  `items` are `[%{"type" => binary, "payload" => binary}]` — **already-redacted
  payload bytes**. There is no path through this function that takes an
  unredacted event, and that is the point: the framing layer cannot be the thing
  that forgot.
  """
  @spec build_envelope([item()], String.t() | nil) :: {:ok, binary()} | {:error, term()}
  def build_envelope(items, dsn \\ nil)

  def build_envelope(items, dsn) when is_list(items) do
    header =
      %{
        "event_id" => fresh_event_id(),
        "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> to_iso8601()
      }
      |> maybe_put_dsn(dsn)

    with {:ok, header_json} <- encode(header) do
      body =
        Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
          with {:ok, payload} <- payload_bytes(item),
               {:ok, item_json} <-
                 encode(%{"type" => item["type"], "length" => byte_size(payload)}) do
            {:cont, {:ok, [item_json, "\n", payload, "\n" | acc]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      with {:ok, parts} <- body, do: {:ok, IO.iodata_to_binary([header_json, "\n" | parts])}
    end
  end

  def build_envelope(_other, _dsn), do: {:error, :not_a_list}


  defp maybe_put_dsn(header, nil), do: header

  defp maybe_put_dsn(header, dsn), do: Map.put(header, "dsn", dsn)

  defp fresh_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp payload_bytes(%{"payload" => payload}) when is_binary(payload), do: {:ok, payload}

  defp payload_bytes(%{"payload" => payload}) when is_map(payload) or is_list(payload) do
    encode(payload)
  end

  defp payload_bytes(_other), do: {:error, :no_payload}

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, :unencodable}
    end
  end

  defp to_iso8601(datetime), do: DateTime.to_iso8601(datetime)


  defp take_items(binary, acc) do
    case take_line(binary) do
      {:ok, "", _rest} ->
        {:ok, acc}

      {:ok, line, rest} ->
        with {:ok, header} <- decode(line),
             {:ok, payload, rest} <- take_payload(header, rest) do
          take_items(rest, [Map.put(header, "payload", payload) | acc])
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp take_payload(%{"length" => declared} = _header, rest)
       when is_integer(declared) and declared >= 0 do
    if byte_size(rest) >= declared + 1 do
      case :binary.at(rest, declared) do
        ?\n ->
          tail = :binary.part(rest, declared + 1, byte_size(rest) - declared - 1)
          {:ok, :binary.part(rest, 0, declared), tail}

        _not_a_newline ->
          {:error, :misframed}
      end
    else
      if byte_size(rest) == declared do
        {:ok, rest, ""}
      else
        {:error, :truncated}
      end
    end
  end

  defp take_payload(_header, rest) do
    case :binary.split(rest, "\n") do
      [payload, tail] -> {:ok, payload, tail}
      [_payload] -> {:ok, rest, ""}
    end
  end

  defp take_line(binary) do
    case :binary.split(binary, "\n") do
      [line, rest] -> {:ok, line, rest}
      [_line] -> {:ok, binary, ""}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, term} when is_map(term) -> {:ok, term}
      _other -> {:error, :undecodable_item_header}
    end
  end
end
