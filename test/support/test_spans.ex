defmodule Courier.TestSpans do
  @moduledoc """
  The spans courier actually produced, read out of the export path.

  ## Why this goes through an exporter at all

  The Erlang OpenTelemetry SDK cannot start a span processor, in any published
  version, for reasons that are in `Courier.SpanCollector` and reproduced there in
  two commands. So the redaction tests could not have read a collector-bound
  export even if courier's wiring were the SDK's own — which means reading the
  table directly was the obvious alternative and it is WRONG:

  `otel_span_ets:end_span/3` does `ets:take(SPAN_TAB, SpanId)` and hands the
  record to the on-end processor list. The row is destroyed on the way out. There
  is no "finished spans" table to read; there is a queue that the processor is
  supposed to drain.

  So the tests go through the same route a deployment does — courier's own
  `Courier.SpanCollector` calling the exporter — which is also the stronger claim.
  It is not "courier put these attributes on a span"; it is "these are the
  attributes that left courier".

  ## Why every absence assertion here is paired with a presence one

  A redaction boundary that deletes all attributes is indistinguishable from a
  working one when the only assertion is that a canary is missing, and it is
  useless in production. `rendered!/0` refuses to return an empty string for
  exactly that reason, so a suite in which courier exported nothing fails loudly
  rather than passing quietly.
  """

  # The SDK's `#span{}` field order, declared ONCE and used to build the index map
  # below.
  #
  # Not `Record.extract/2`, which reads a header from `_build/<env>/lib/<app>/
  # include/` — a path rebar3 does not produce for a Mix dependency, so the first
  # version raised `enoent`. And not `record[:field]`, which is what reads most
  # naturally: `Access` resolves a field name only for a MAP, so on an Erlang
  # record it raises a FunctionClauseError. Hence `elem/2` with indices derived
  # from this one list, so there is a single place where the order is written down
  # and a second place that would notice it being wrong.
  #
  # The offset is 1, not 2: the record TAG occupies element 0, so `trace_id` —
  # the first declared field — is `elem/2` index 1. Getting that wrong reads
  # `kind` as `name` and reports a span called "server", which is how the mistake
  # was caught the first time.
  @span_fields [
    :trace_id,
    :span_id,
    :tracestate,
    :parent_span_id,
    :parent_span_is_remote,
    :name,
    :kind,
    :start_time,
    :end_time,
    :attributes,
    :events,
    :links,
    :status,
    :trace_flags,
    :is_recording,
    :instrumentation_scope
  ]

  @indexes @span_fields |> Enum.with_index(1) |> Map.new()

  @doc "Every span the exporter received, oldest first."
  defdelegate finished_spans(), to: Courier.TestSpanExporter, as: :take

  @doc """
  The spans the exporter received SINCE `mark`, oldest first.

  The pair to `finished_spans/0` for a test that must not read anybody else's
  evidence.

  Read `Courier.TestSpanExporter.mark/0` before using this, and specifically the
  part about what a watermark is NOT on its own: a span another test produced and
  never flushed is INSERTED into the table after any mark taken now, so a caller
  that marks and reads since the mark has to drain `Courier.SpanCollector` first or
  it reads the backlog along with its own.
  """
  defdelegate finished_spans_since(mark), to: Courier.TestSpanExporter, as: :take_since

  @doc """
  The finished spans rendered as one string: name, kind, status, and every
  attribute's name AND value.

  Rendered rather than compared key-by-key, and that is the whole design. A
  key-by-key assertion only catches a leak through a key the test already knew to
  look for; rendering catches a leak through a VALUE as well, and through a key
  nobody predicted. The leak this file exists to prevent arrives as a new attribute
  name, and a test that asserts on the names it knows about goes green on the day
  the new name is added.
  """
  def rendered do
    finished_spans()
    |> Enum.map_join("\n", fn span ->
      pairs =
        span.attributes
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)

      "name=#{span.name} kind=#{span.kind} status=#{span.status} #{pairs}"
    end)
  end

  @doc """
  The whole export as one string, with a guard against an empty one.

  Every caller is about to assert that something is ABSENT, and "absent" is true
  of an empty export — so the guard is checked once, here, rather than repeated as a
  presence assertion in twenty tests that a future refactor could drop.
  """
  def rendered! do
    rendered = rendered()

    if rendered == "" do
      raise """
      nothing was exported, so every assertion about a canary being absent from the \
      export would be vacuously true.

      Check that the request really reached `CourierWeb.Plugs.Telemetry`, that \
      `Courier.Telemetry.enabled?/0` is true, and that \
      `config/test.exs` still names `Courier.TestSpanExporter` as \
      `config :courier, :otel_exporter`.
      """
    end

    rendered
  end

  @doc "The spans named `name`."
  def by_name(name), do: Enum.filter(finished_spans(), &(&1.name == name))

  @doc """
  Turn one SDK span record into a plain map a test can read.

  `attributes` is a STRUCT, not a map: `otel_attributes:t()` is
  `{:attributes, count_limit, value_length_limit, link_limit, map}`, so the pairs
  are its LAST element. The first version read it as a map and every attribute
  assertion in the repository failed with a confusing `Enum.sort_by` on a tuple —
  which is a shape error, not a redaction failure, and the two should never look
  alike.
  """
  def readable(record) do
    %{
      name: to_string(field(record, :name)),
      kind: field(record, :kind) |> Kernel.||("internal") |> to_string(),
      status: status(field(record, :status)),
      trace_id: field(record, :trace_id),
      span_id: field(record, :span_id),
      parent_span_id: field(record, :parent_span_id),
      parent_is_remote: field(record, :parent_span_is_remote),
      start_time: field(record, :start_time),
      end_time: field(record, :end_time),
      attributes: attribute_map(field(record, :attributes))
    }
  end

  defp field(record, name), do: elem(record, Map.fetch!(@indexes, name))

  defp attribute_map({:attributes, _count_limit, _length_limit, _link_limit, pairs}),
    do: pairs

  defp attribute_map(pairs) when is_map(pairs), do: pairs
  defp attribute_map(_other), do: %{}

  # The SDK stores the status as `{code, description}`, and the code is spelled
  # `:unset` / `:ok` / `:error` — core's vocabulary, which is what a test compares
  # against rather than a translation of it.
  defp status(nil), do: "unset"
  # `:undefined` and not `nil` is what a span that never had `set_status/2` called
  # on actually carries, and mapping it to `:undefined.to_string()` would render
  # "undefined" — which reads as a status value and is not one.
  defp status(:undefined), do: "unset"
  defp status({code, _description}) when is_atom(code), do: Atom.to_string(code)
  defp status(code) when is_atom(code), do: Atom.to_string(code)
  defp status(_status), do: "unset"

  @doc false
  def span_fields, do: @span_fields
end
