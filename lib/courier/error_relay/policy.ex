defmodule Courier.ErrorRelay.Policy do
  @moduledoc ~S"""
  The redaction boundary for the error path, as an allowlist over a Sentry event.


  It does not already redact **this**. PLAN.md §7b and
  `core/schemas/telemetry/redaction.schema.json` put the redaction boundary at
  one chokepoint — the OTel collector — and that chokepoint is real and enforced
  for traces, metrics and logs. A Sentry envelope is a **fourth signal** and the
  collector cannot reach it: GlitchTip speaks the Sentry envelope protocol and
  has no OTLP receiver for errors, so there is no point in the pipeline where an
  error could be handed to the `redaction` processor. That is the caveat the
  packet is honest about, and it is why this module exists rather than a
  sentence in a README.

  So the architecture is: **the SDK sends to the relay, and the relay is the
  chokepoint.** One implementation of the policy, in one place, in one language,
  that every service's error path passes through — which is the same property
  the collector has for the other three signals, obtained the only way it could
  be here.


  This policy removes the **exception message** and the **frame variables** from
  every event. That is deliberate and it is the price of admission.

  An error store is a retained, indexed, widely-readable store that a human
  reads on purpose — which is exactly the threat model core's redaction policy
  was written for. The collector already deletes `exception.message` and
  `exception.stacktrace` off span events for the same reason; its own comment
  calls `exception.message` "a path straight to a prompt", and notes that "a
  content-policy rejection quotes the offending content back at you". In Go and
  Ruby the frame variables are the **arguments**, and in Elixir an exception
  raised with a token in its message carries that token in `type` as often as
  in `value`.

  What a stored error therefore has is: the exception's class, the file, the
  line, the function, whether the frame is application code, the release, the
  environment, the HTTP method, the route template, the runtime, and the
  `error.type` class from core's closed vocabulary. That is enough to act on a
  crash — it names the bug and the line — and none of it is something a customer
  typed. What it does not have is the message, which is the sentence a human
  most wants. **That is the trade, and it is a trade, not an oversight.**

  A team that needs the message needs a decision to make deliberately, and the
  decision is not this module's to make quietly.


  Every map is rebuilt from an allowlist. A key that is not named below is not
  "sanitised" — it never existed as far as the forwarded event is concerned.
  A denylist of bad key names has to enumerate everything that can leak, and the
  realistic leak is a name nobody predicted: a Sentry `context` a service
  invented last week, an `extra` key added by a library, a `request` field a new
  SDK version started sending. Default-allow would make the safe case the thing
  you have to remember, and the safe case is the one nobody is thinking about
  when they are debugging something at 3am.


  The allowlist keeps a *key* out. It cannot keep a credential out of a key the
  allowlist *keeps* — `transaction` is allowlisted, and a caller who
  interpolates a tenant id into it has put an unbounded string in a bounded
  field. So every surviving string is also passed through the collector's own
  three credential shapes and masked.

  Two independent controls, because the realistic way this leaks is one of them
  being removed by a well-meaning change and nobody noticing for a month. The
  vocabulary below is **byte-identical** to `blocked_values` in kit's
  `redaction/anywaye_traces` processor. Two lists that can drift are one list too
  many, so this is the collector's list and a change to one is a change to both.


  core's `error.type` is an `enum` of twelve classes plus the OTel fallback
  `_OTHER`, identical on traces, metrics and logs. An event whose
  `error.type` is outside it is **replaced with `_OTHER`, not passed through** —
  core-04 constrained the value with a `pattern` and got `user_42_email_invalid`
  validating cleanly, which is a value per user on the dimension a dashboard
  groups by.

  An event with **no** class at all is refused outright, by `classify/1` and not
  here. Defaulting it would put `_OTHER` in the store and make an alert on
  `_OTHER` — which is an alert that *this service has not classified its own
  errors* — silently unreachable.

  This is the whole reason the packet standardises on the OTel conventions
  rather than on Sentry's own grouping. Because the same attribute name, with
  the same closed vocabulary, is what the trace signal already carries, the error
  store is joinable to the trace signal and a future move to a different backend
  is a change of DSN rather than a rewrite of every call site.


  The OTel spec is explicit — "Errors that were retried or handled (allowing an
  operation to complete gracefully) SHOULD NOT be recorded on spans or metrics
  that describe this operation" — and this policy cannot enforce it, because by
  the time an event reaches it the decision has been made upstream. It is
  enforced where the decision is made, in `Courier.ErrorReporting.capture/3` and
  its two siblings in the other two services: only a failure that reached the
  top of the stack is captured, and a rescued-and-retried one never is.
  """

  @typedoc "A Sentry event, decoded. Keys are strings, because that is what Jason gives us."
  @type event :: %{optional(String.t()) => term()}

  @error_types ~w(
    invalid_request
    policy_denied
    provider_auth
    provider_rejected
    rate_limited
    timeout
    connection_failed
    circuit_open
    dependency_unavailable
    conflict
    cancelled
    internal_error
    _OTHER
  )

  @doc """
  Core's closed error vocabulary, in the order `core/docs/observability.md`
  documents it. `test/courier/error_relay/policy_test.exs` walks every member,
  so a class dropped from this list is a test failure rather than a silent
  narrowing of what may be stored.
  """
  @spec error_types() :: [String.t()]
  def error_types, do: @error_types

  @event_keys ~w(
    event_id
    timestamp
    platform
    level
    release
    environment
    transaction
    tags
    contexts
    exception
    request
    sdk
  )

  @context_keys ~w(runtime device os trace)

  @tag_keys ~w(error.type service.name deployment.environment release anywaye.redacted)

  @frame_keys ~w(filename function lineno in_app module)

  @blocked_values [
    ~r/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    ~r/sk-[A-Za-z0-9_-]{16,}/,
    ~r/sk-ant-[A-Za-z0-9_-]{16,}/,
    ~r/[Bb]earer[ ]+[A-Za-z0-9._-]{16,}/
  ]

  @marker "anywaye.redacted"

  @doc """
  Redact one decoded Sentry event.

  Returns the event to forward, or `{:error, :not_an_event}` when the input is
  not a JSON object. **It does not raise**, and that is a contract rather than an
  accident: the relay parses bytes off a socket, and a raise inside this module
  would be a crash in the process every other service's error reporting depends
  on. A malformed event is a malformed event, and the caller drops it with a
  counted reason.
  """
  @spec redact(term()) :: {:ok, event()} | {:error, :not_an_event}
  def redact(event) when is_map(event) do
    event
    |> take(@event_keys)
    |> mask_values()
    |> reduce()
    |> then(&{:ok, &1})
  end

  def redact(_other), do: {:error, :not_an_event}

  defp reduce(event) do
    event
    |> Map.put("tags", tags(event))
    |> Map.put("contexts", contexts(event))
    |> reduce_exception()
    |> reduce_request()
  end

  @doc """
  The event's `error.type`, if it is one of core's classes.

  `{:error, :unclassified}` is a real answer and the relay acts on it by
  dropping the event. An error store that defaults a missing class to `_OTHER`
  makes the alert on `_OTHER` unreachable, which is the one alert that means
  "this service has not classified its own errors".
  """
  @spec classify(event()) :: {:ok, String.t()} | {:error, :unclassified}
  def classify(%{} = event) do
    case get_in(event, ["tags", "error.type"]) do
      class when is_binary(class) ->
        if class in @error_types, do: {:ok, class}, else: {:error, :undeclared}

      _absent ->
        {:error, :unclassified}
    end
  end

  def classify(_other), do: {:error, :unclassified}

  @doc """
  A stable grouping key for one bug.

  Computed from the **redacted** event, so two occurrences of the same crash
  group together regardless of how far apart they were or what request they
  arrived on, and so a caller cannot influence grouping by putting something in
  a field the fingerprint reads.

  What is in it: the service, the class, the operation, the exception classes,
  and the application frames' module/function/line. What is **not**: `release`,
  so a deploy does not open a second group for a bug that was never fixed, and
  the exception message, so two different messages from the same line are one
  bug.

  An input that cannot be redacted fingerprints to a constant rather than
  raising — see the note in the test. A malformed event has to land in the
  throttle table *somewhere*, and one key is better than no key.
  """
  @spec fingerprint(term()) :: String.t()
  def fingerprint(event) do
    event
    |> safe_redact()
    |> group_key()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The policy's own vocabulary, exported so a second enforcement point cannot
  drift from this one.

  `Courier.ErrorReporting.Filter` applies **the same allowlists** on the way out
  of the SDK, before an envelope is even built. That is the second barrier core's
  `redaction.schema.json` asks for in its `defenceInDepth` field — "two
  independent controls, because the realistic failure is one of them being removed
  by a well-meaning change and nobody noticing for a month".

  It matters here more than it does elsewhere, because the failure it prevents is
  not hypothetical: the relay is a *deployment*, and a deployment can be
  misconfigured. If somebody points a service's DSN at a Sentry SaaS endpoint
  instead of the relay, the relay's policy is not in the path at all — and a
  filter that had to be a second hand-written copy of these lists is a second
  thing to forget to update. So the SDK-side filter calls **these functions**
  rather than holding its own, and the test asserts both boundaries from one
  vocabulary.
  """
  @spec vocabulary() :: %{
          event: [String.t()],
          tag: [String.t()],
          context: [String.t()],
          frame: [String.t()],
          request: [String.t()]
        }
  def vocabulary do
    %{
      event: @event_keys,
      tag: @tag_keys,
      context: @context_keys,
      frame: @frame_keys,
      request: ~w(method route)
    }
  end

  @doc """
  Mask credential-shaped values in a string. The collector's `blocked_values`,
  byte for byte — see the moduledoc on why this list is not a second list.
  """
  @spec mask(String.t()) :: String.t()
  def mask(string) when is_binary(string), do: mask_string(string)

  @doc "The token this policy stamps on every event it forwards."
  @spec marker() :: String.t()
  def marker, do: @marker


  defp safe_redact(event) do
    case redact(event) do
      {:ok, redacted} -> redacted
      {:error, _} -> %{}
    end
  end

  defp group_key(%{} = event) do
    %{
      service: event["tags"]["service.name"],
      class: event["tags"]["error.type"],
      operation: event["transaction"],
      classes: exception_classes(event),
      frames: in_app_frames(event)
    }
  end

  defp exception_classes(%{} = event) do
    event
    |> exception_values()
    |> List.wrap()
    |> Enum.map(&Map.get(&1, "type"))
    |> Enum.map(&if(is_binary(&1), do: &1, else: "unknown"))
    |> Enum.sort()
  end

  defp in_app_frames(%{} = event) do
    event
    |> exception_values()
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"stacktrace" => %{"frames" => frames}} when is_list(frames) -> frames
      _other -> []
    end)
    |> Enum.filter(&(&1["in_app"] == true))
    |> Enum.map(&{&1["module"], &1["function"], &1["lineno"]})
    |> Enum.sort()
  end

  defp tags(%{"tags" => tags}) when is_map(tags) do
    tags
    |> take(@tag_keys)
    |> normalize_class()
    |> Map.put(@marker, "true")
  end

  defp tags(_other), do: %{@marker => "true"}

  defp normalize_class(tags) do
    case Map.fetch(tags, "error.type") do
      {:ok, class} when is_binary(class) and class in @error_types ->
        tags

      {:ok, _undeclared} ->
        Map.put(tags, "error.type", "_OTHER")

      :error ->
        tags
    end
  end

  defp contexts(%{"contexts" => contexts}) when is_map(contexts),
    do: take(contexts, @context_keys)

  defp contexts(_other), do: %{}

  defp reduce_exception(event) do
    case exception_values(event) do
      values when is_list(values) ->
        reduced = values |> Enum.map(&reduce_value/1) |> Enum.reject(&is_nil/1)
        Map.put(event, "exception", %{"values" => reduced})

      _other ->
        Map.delete(event, "exception")
    end
  end

  defp exception_values(%{"exception" => %{"values" => values}}) when is_list(values), do: values
  defp exception_values(%{"exception" => values}) when is_list(values), do: values
  defp exception_values(_other), do: nil

  defp reduce_value(value) when is_map(value) do
    value
    |> take(~w(type value module stacktrace))
    |> Map.update("stacktrace", nil, &reduce_stacktrace/1)
    |> then(fn reduced ->
      case reduced["stacktrace"] do
        nil -> Map.delete(reduced, "stacktrace")
        _kept -> reduced
      end
    end)
  end

  defp reduce_value(_other), do: nil

  defp reduce_stacktrace(%{"frames" => frames} = trace) when is_list(frames) do
    %{"frames" => frames |> Enum.map(&take(&1, @frame_keys)) |> Enum.reject(&(&1 == %{}))}
    |> then(fn kept ->
      if kept == %{"frames" => []}, do: trace, else: kept
    end)
  end

  defp reduce_stacktrace(_other), do: nil

  defp reduce_request(event) do
    case event["request"] do
      %{} = request ->
        case take(request, ~w(method route)) do
          %{"route" => route} = kept ->
            if template?(route) do
              Map.put(event, "request", kept)
            else
              Map.put(event, "request", Map.delete(kept, "route"))
            end

          kept ->
            if kept == %{}, do: event, else: Map.put(event, "request", kept)
        end

      _absent ->
        event
    end
  end

  @doc """
  Is this a route **template** rather than a concrete path?

  The test is deliberately crude and the reason is that the real defence is the
  SDK contract — `http.route` comes from Phoenix's `conn.private.phoenix_route`,
  which is the pattern, not the path — plus the fact that nothing else from the
  request survives. What this catches is the case where a service hands the SDK
  a URL instead of a pattern, which is the mistake that would actually happen,
  and it catches it by refusing the one shape a URL has and a template does not:
  a query string.
  """
  @spec template?(term()) :: boolean()
  def template?(route) when is_binary(route) do
    String.starts_with?(route, "/") and
      not String.contains?(route, "?") and
      byte_size(route) <= 200
  end

  def template?(_other), do: false

  defp mask_values(event) do
    Enum.reduce(event, event, fn {key, value}, acc ->
      Map.put(acc, key, mask_value(value))
    end)
  end

  defp mask_value(value) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {key, mask_value(inner)} end)

  defp mask_value(value) when is_list(value), do: Enum.map(value, &mask_value/1)
  defp mask_value(value) when is_binary(value), do: mask(value)
  defp mask_value(value), do: value

  defp mask_string(string) do
    Enum.reduce(@blocked_values, string, fn pattern, acc ->
      Regex.replace(pattern, acc, @marker)
    end)
  end

  defp take(map, keys) when is_map(map), do: Map.take(map, keys)
  defp take(_other, _keys), do: %{}
end
