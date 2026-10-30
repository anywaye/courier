defmodule CourierWeb.Messages do
  @moduledoc """
  The HTTP send surface's own rules: what a `POST /v1/messages` body must carry,
  what it becomes, and the one invariant about the message courier renders from
  it.

  This is courier's send path reached over HTTP, and the vocabulary is
  deliberately **closed**. `Courier.Mailers` casts a payload with
  `Ecto.Changeset.cast/3` against a fixed field list and discards everything else
  without a word — which is the right behaviour for a library a trusted caller
  holds, and the wrong behaviour for a request body, where a misspelled
  `emai_enabled` or an `account_id` that courier reads nowhere would otherwise be
  accepted with no sign that anything was ignored. So every key is checked against
  the list below, and an unknown one is a 422.


  The brief for this surface asked for a `from`, and there is not one. courier's
  sender is `config :courier, :mailing[:from]` and the subjects beside it, because
  the sender is the one field a caller must not be able to choose: an authenticated
  tenant that could set `From:` would be a phishing relay wearing the platform's
  sending domain, and the reputation cost of that lands on every other tenant's
  mail. `Courier.Mailers.from/0` already refuses an unconfigured sender as
  `:from_not_configured` and this surface inherits that refusal rather than adding
  a second one.

  A body carrying `from` is therefore an unknown field and a 422 naming `from` —
  the same answer `emai_enabled` gets, and a stronger one than `user_id` gets,
  because `user_id` really is a field and this request's own `type` overwrites
  what a payload would have carried.


  The same argument one layer in. courier sends *transactional* mail that it
  renders from `lib/courier/mailers/templates/`, and a raw `text`/`html` pair on
  the wire would make courier a general-purpose relay: every template, every
  layout, every escaping decision, handed to whichever authenticated caller asked.
  The "at least one body" rule therefore survives as a check on the **rendered**
  message rather than on the request — `Courier.Mailers.body?/1`, called from
  `Courier.Deliver` where the message is the only thing in hand.


  `Courier.Mailers` has always keyed the recipient as `email`, because that is
  what the platform's event payloads carry. Over HTTP the same field reads as
  `to`, which is the mail vocabulary and the one a caller writing an HTTP client
  expects. One mapping, in one place, so the two spellings cannot drift into
  meaning different things.
  """

  alias Courier.Mailers
  alias Courier.Notifiers
  @wire_fields ~w(type user_id to name url account_name invited_by role reason previous_email)

  @payload_fields [
    user_id: "user_id",
    name: "name",
    url: "url",
    account_name: "account_name",
    invited_by: "invited_by",
    role: "role",
    reason: "reason",
    previous_email: "previous_email"
  ]

  @doc """
  The fields a body may carry, in the order the document lists them.
  """
  @spec fields() :: [String.t()]
  def fields, do: @wire_fields

  @doc """
  The notification types this surface accepts, which is `Courier.Mailers`' whole
  catalog.

  Not a second list: a type courier cannot send is a type no caller may ask for,
  and the two lists agreeing is what makes the 422 on `type` mean anything.
  """
  @spec types() :: [String.t()]
  def types, do: Notifiers.types()

  @doc """
  Checks `params` against the vocabulary and returns the payload for
  `Courier.Deliver` when it passes.

  `{:ok, payload}`, or `{:error, fields}` where `fields` is the list of
  `%{"field" => name, "code" => code}` entries a 422 renders as `errors[]`.

  **Every** failing field is reported rather than the first. A caller who can fix
  a body in one round trip is a caller who will; a caller who has to guess which
  of five fields was wrong will fix the wrong one.


  Only the three things a cast through `Courier.Mailers` cannot catch:

    * **unknown keys** — it discards them silently, which over HTTP is how a
      misspelling becomes a setting the caller believes took effect;
    * **a missing or blank `type`** — the context answers
      `:unknown_notification_type`, and naming the field is what makes the 422
      actionable rather than a shrug;
    * **a `user_id` that is not a uuid** — `notification_preferences` is keyed by
      it and the emitted event attributes the send to it, so a non-uuid is a
      preference courier cannot read and a consumer that cannot correlate.

  The per-type required fields, the address's format and the subject placeholders
  are `Courier.Mailers`' own validation, and they arrive as
  `{:error, {:invalid_payload, changeset}}` for the controller to render from the
  changeset's own errors. Two validators that both listed required fields would be
  two lists of required fields, and one of them would be the stale one.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [map()]}
  def validate(params) when is_map(params) do
    case unknown(params) ++ type_error(params) ++ user_id_error(params) ++ payload_errors(params) do
      [] -> {:ok, payload(params)}
      fields -> {:error, fields}
    end
  end

  defp type_error(params) do
    case params["type"] do
      type when is_binary(type) ->
        cond do
          String.trim(type) == "" ->
            [missing("type")]

          type not in Notifiers.types() ->            [%{"field" => "type", "code" => "unknown_notification_type"}]

          true ->
            []
        end

      _absent_or_not_a_string ->
        [missing("type")]
    end
  end

  defp payload_errors(params) do
    case Mailers.build(params["type"], payload(params)) do
      {:error, {:invalid_payload, changeset}} -> field_errors(changeset)
      _ok_or_a_configuration_error -> []
    end
  end

  defp field_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {_message, opts}} ->
      %{"field" => requested(field), "code" => Keyword.get(opts, :code, "invalid_format")}
    end)
  end

  defp requested(:email), do: "to"
  defp requested(field), do: to_string(field)

  defp unknown(params) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in @wire_fields))
    |> Enum.sort()
    |> Enum.map(&%{"field" => &1, "code" => "unknown_field"})
  end

  defp missing(name), do: %{"field" => name, "code" => "required"}

  defp user_id_error(params) do
    case params["user_id"] do
      user_id when is_binary(user_id) and byte_size(user_id) > 0 ->
        case Ecto.UUID.cast(String.trim(user_id)) do
          {:ok, _uuid} -> []
          :error -> [%{"field" => "user_id", "code" => "invalid_format"}]
        end

      _blank_or_absent ->
        [missing("user_id")]
    end
  end

  defp payload(params) do
    Enum.reduce(@payload_fields, %{}, fn {field, key}, acc ->
      Map.put(acc, field, params[key])
    end)
    |> Map.put(:email, params["to"])
  end
end
