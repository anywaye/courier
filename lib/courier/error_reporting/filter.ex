defmodule Courier.ErrorReporting.Filter do
  @moduledoc """
  The SDK-side half of the redaction boundary, run by Sentry's `before_send`
  before an envelope is built.


  core's `redaction.schema.json` has a `defenceInDepth` field, and this is what
  it describes: "two independent controls, because the realistic failure is one of
  them being removed by a well-meaning change and nobody noticing for a month".

  The chokepoint is `Courier.ErrorRelay.Policy`, which every event passes through
  on its way to the store. This is the barrier in front of it.

  The reason it is not optional is specific rather than general: **the relay is a
  deployment, and deployments get misconfigured.** A service whose DSN points at
  `https://key@sentry.io/1` instead of at courier's relay never reaches
  `Courier.ErrorRelay.Policy` at all, and the event arrives at a third party
  carrying an exception message and a request URL. That is the leak this whole
  packet exists to close, and no amount of correctness in the relay prevents it.

  So this filter exists, and it is deliberately **thin**: it knows about Sentry's
  `Sentry.Event` struct and nothing else. Every list it enforces comes from
  `Courier.ErrorRelay.Policy.vocabulary/0` and every mask from
  `Policy.mask/1`, so there is one policy in this repository and two places it
  runs. A hand-written second copy of the allowlists would be a second thing to
  forget to update, which is the failure `defenceInDepth` warns about.


  `before_send/1` returning `nil` drops the event. An event this filter cannot
  read is an event the store will not receive, and that is the correct direction:
  losing a crash is recoverable, and a customer credential in a third party's
  index is not.


  Class, module, file, line, function, `in_app`, release, environment, the tags
  in the closed set, the four bounded `contexts`, the HTTP method, the route
  template, and the `error.type` from core's vocabulary. Nothing else. The
  exception **message** goes, and so do the frame **variables** — which in Elixir
  are the function arguments, and in the SDK's own rendering include the bound
  local variables. `Courier.ErrorRelay.Policy` argues the trade in full; this
  module is where it is paid.


  `Sentry.Event` is a **struct with atom keys**, while the policy speaks
  string-keyed maps because that is what Jason produces. So this filter converts
  struct → string-keyed map, redacts, and converts back. Both conversions are
  places a value can be silently lost, which is why
  `CourierWeb.ErrorReportingTest` asserts on the SDK's own output rather than on
  this module in isolation: the claim that matters is "a secret does not reach the
  envelope", and the envelope is what the SDK hands the transport.
  """

  alias Courier.ErrorRelay.Policy

  @doc """
  Sentry's `before_send` callback. Returns a redacted `Sentry.Event`, or `nil` to
  drop the event.
  """
  @spec before_send(map()) :: map() | nil
  def before_send(event) do
    with {:ok, redacted} <- redact(event),
         {:ok, rebuilt} <- rebuild(event, redacted) do
      rebuilt
    else
      {:error, _reason} ->
        :telemetry.execute([:courier, :error_reporting, :filter_dropped], %{}, %{})
        nil
    end
  end

  defp redact(event) do
    event
    |> plain_map()
    |> Policy.redact()
  end

  defp rebuild(original, redacted) do
    fields = original |> Map.from_struct() |> Map.keys()

    cleared = Map.new(fields, fn field -> {field, default_for(original, field)} end)

    kept =
      fields
      |> atomise(redacted)
      |> then(fn kept ->
        case Map.fetch(kept, :exception) do
          {:ok, exception} -> Map.put(kept, :exception, unwrap_exception(exception))
          :error -> kept
        end
      end)

    merged =
      cleared
      |> Map.merge(kept)
      |> retyped(original)

    {:ok, struct(Sentry.Event, merged)}
  end

  defp retyped(merged, original) do
    Map.new(merged, fn {field, value} -> {field, retype(Map.get(original, field), value)} end)
  end

  defp retype(%module{} = original, value) when is_map(value) and not is_struct(value) do
    original
    |> Map.from_struct()
    |> Map.keys()
    |> atomise(value)
    |> Map.new(fn {field, field_value} ->
      {field, retype(Map.get(original, field), field_value)}
    end)
    |> then(&struct(module, &1))
  end

  defp retype([%_module{} | _] = originals, values) when is_list(values) do
    originals
    |> Enum.zip(values)
    |> Enum.reject(fn {_original, redacted} -> is_nil(redacted) end)
    |> Enum.map(fn {original, redacted} -> retype(original, redacted) end)
  end

  defp retype(%_module{}, nil), do: nil

  defp retype(_original, value), do: value

  defp unwrap_exception(%{"values" => values}) when is_list(values), do: values
  defp unwrap_exception(%{__struct__: _} = exception), do: [exception]
  defp unwrap_exception(values) when is_list(values), do: values
  defp unwrap_exception(other), do: other

  @defaults %Sentry.Event{event_id: "", timestamp: ""}

  defp default_for(_original, :exception), do: []
  defp default_for(_original, :breadcrumbs), do: []
  defp default_for(_original, field), do: Map.fetch!(@defaults, field)

  defp atomise(fields, redacted) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case Map.fetch(redacted, Atom.to_string(field)) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp plain_map(%Sentry.Event{} = event) do
    event
    |> Map.from_struct()
    |> stringify()
  end

  defp stringify(%{__struct__: _module} = value) do
    value |> Map.from_struct() |> stringify()
  end

  defp stringify(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, inner} -> is_nil(inner) end)
    |> Map.new(fn {key, inner} -> {key_name(key), stringify(inner)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp key_name(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)
end
