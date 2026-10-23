defmodule Courier.ErrorRelay.Policy do
  @moduledoc ~S"""
  The redaction boundary for the error path, as an allowlist over a Sentry event.

  ## Why this module exists at all, given the collector already redacts

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

  ## The consequence, stated where nobody can miss it

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

  ## Default-deny, and why that is the load-bearing word

  Every map is rebuilt from an allowlist. A key that is not named below is not
  "sanitised" — it never existed as far as the forwarded event is concerned.
  A denylist of bad key names has to enumerate everything that can leak, and the
  realistic leak is a name nobody predicted: a Sentry `context` a service
  invented last week, an `extra` key added by a library, a `request` field a new
  SDK version started sending. Default-allow would make the safe case the thing
  you have to remember, and the safe case is the one nobody is thinking about
  when they are debugging something at 3am.

  ## `blocked_values` is the second barrier, and it is a different KIND of one

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

  ## `error.type` is the closed vocabulary, which is what keeps this reversible

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

  ## Handled and retried errors are not recorded

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

  # ---------------------------------------------------------------------------
  # error.type — core's closed vocabulary, verbatim.
  #
  #   core/schemas/telemetry/logs.schema.json  (and traces, and metrics: one enum
  #   on all three signals, which is what makes the cross-signal rule
  #   enforceable without comparing two documents)
  #   core/docs/observability.md, "error.type", the table of twelve plus `_OTHER`
  #
  # Copied rather than derived, because there is no YAML in this repository and
  # `core/docs/observability.md#the-error-type-vocabulary` is the prose the enum
  # was generated from. A class added to core belongs here in the same commit.
  # ---------------------------------------------------------------------------
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

  # Top-level event keys that survive. Everything else is dropped whole.
  #
  # `server_name`, `user`, `request`, `breadcrumbs` and `extra` are the
  # interesting omissions and each is argued in the moduledoc and the tests.
  #
  # `request` is the one key listed here that is then reduced rather than kept:
  # it has to reach `reduce_request/1` to be cut down to the method and the route
  # template, and a key absent from this list would be gone before that ran. The
  # reduction is the only way it is ever re-added.
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

  # `contexts` — the one map a Sentry SDK populates with bounded, structural
  # facts. `runtime` is the BEAM version, the OS, the runtime name; `trace` is
  # the OTel context, which is a set of hex ids rather than content. Both are
  # kept because both are how a human reads a stack, and neither can carry a
  # caller's words. `device`, `os`, `runtime` and `trace` are the four the three
  # SDKs emit.
  @context_keys ~w(runtime device os trace)

  # `tags` — the closed set, so a tag cannot become a cardinality axis.
  #
  # `error.type` is core's class. `service.name` is the fleet partition.
  # `anywaye.redacted` is the constant marker this policy stamps on every event
  # it forwards. `deployment.environment` and `release` mirror the top-level
  # fields so a GlitchTip issue can be filtered on them as indexed tags.
  @tag_keys ~w(error.type service.name deployment.environment release anywaye.redacted)

  # Stack frame keys. `vars` is the one that matters and it is the reason this
  # table exists: in Go and Ruby the frame variables are the function's
  # arguments, so keeping them is keeping whatever the caller passed in.
  @frame_keys ~w(filename function lineno in_app module)

  # The collector's `blocked_values`, character for character. See the moduledoc
  # on why this list is the collector's list rather than a second one.
  @blocked_values [
    # A JWT. Nobody allowlists a key for a JWT, so on the other three signals
    # this only fires on a key somebody allowed by accident. Here it fires on
    # `transaction` and on an exception `type`, both of which are allowlisted.
    ~r/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    # `sk-` prefixed provider keys, and the Anthropic shape.
    ~r/sk-[A-Za-z0-9_-]{16,}/,
    ~r/sk-ant-[A-Za-z0-9_-]{16,}/,
    # `Bearer <token>`, if a header ever reaches a value rather than a key.
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
    # The order of the two halves is load-bearing, and the bug this shape exists
    # to prevent is the one it was written after: `mask_values/1` ran first and
    # the reductions that followed read the **original** event, so the reduced
    # `exception.type` was written back over the masked one and the credential
    # came out the other side. Every reduction below therefore reads the event
    # it is reducing, not the one it was handed, so there is no unmasked copy
    # left in the process to read by accident.
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

  # --- the pieces ------------------------------------------------------------

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
    # A masked type is still the right grouping input: two occurrences of the
    # same crash with the same credential in the message group together, which
    # is what a fingerprint is for.
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
    # Only application frames. A frame inside a dependency is the same three
    # lines of the same library version for every caller, so including it makes
    # the fingerprint the same for unrelated bugs and the group useless.
    |> Enum.filter(&(&1["in_app"] == true))
    |> Enum.map(&{&1["module"], &1["function"], &1["lineno"]})
    # Deepest frame first, the way a stack reads. Sorted afterwards so the order
    # two SDKs emit frames in cannot split one bug into two groups.
    |> Enum.sort()
  end

  # `tags` is rebuilt, not filtered: an allowlist over a map a caller controls
  # needs the *values* checked too, which is what `mask_values/1` then does to
  # the whole event.
  defp tags(%{"tags" => tags}) when is_map(tags) do
    tags
    |> take(@tag_keys)
    |> normalize_class()
    |> Map.put(@marker, "true")
  end

  defp tags(_other), do: %{@marker => "true"}

  # An **undeclared** class becomes the OTel fallback; an **absent** one stays
  # absent.
  #
  # The distinction is the whole reason `classify/1` can do its job. The first
  # version of this function also filled in a missing class with `_OTHER`, which
  # meant a service that reported errors with no `error.type` at all had them
  # stored as `_OTHER` and the relay could never refuse them — so the alert on
  # `_OTHER` that core says means "this service has not classified its own
  # errors" was reachable **only** from services that had classified their
  # errors and got one wrong. Which is the opposite of useful: the alert fired
  # for the harmless case and stayed silent for the case it exists for.
  #
  # So: present-and-undeclared becomes `_OTHER`, because a real crash somebody
  # has to look at should not be dropped over a typo in a class name. Absent
  # stays absent, because that is a service that has not opted into the
  # vocabulary at all, and `classify/1` refuses it with a counted reason.
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

  # `exception` keeps its structure and loses its content: the classes, the
  # modules, and the frames reduced to `filename`/`function`/`lineno`/`in_app`.
  # `value` is the message and is the single most likely place in a whole
  # Sentry event for a caller's data to be.
  # Two shapes for `exception`, and both are real.
  #
  #   * `{"values" => [...]}` — the Sentry **wire** format, which is what arrives
  #     at the relay from the SDK's transport.
  #   * a **bare list** — the Sentry **struct** format, which is what
  #     `Sentry.Event`'s `:exception` field holds before the SDK serialises it,
  #     and therefore what `Courier.ErrorReporting.Filter` hands to this function
  #     on the way out of the SDK.
  #
  # Handling only the first is a leak, and it is the leak the packet exists to
  # close: the SDK-side filter is the barrier that survives a DSN pointed at a
  # third party, and if the exception is a list then `get_in(event,
  # ["exception", "values"])` is nil, the branch below removes nothing, and the
  # message and the frame variables go out in the clear. `value` is dropped in
  # both shapes, so the difference is only in how the list is *reached*.
  defp reduce_exception(event) do
    case exception_values(event) do
      values when is_list(values) ->
        reduced = values |> Enum.map(&reduce_value/1) |> Enum.reject(&is_nil/1)
        Map.put(event, "exception", %{"values" => reduced})

      _other ->
        # No exception at all. A Sentry *message* event has none, and a message
        # event is one this relay accepts — a background failure logged at error
        # level with no exception is exactly the signal the packet is for. What is
        # dropped is the message itself, which is the content: `logentry.formatted`
        # and the `message` key are on no allowlist and never reach this line.
        Map.delete(event, "exception")
    end
  end

  defp exception_values(%{"exception" => %{"values" => values}}) when is_list(values), do: values
  defp exception_values(%{"exception" => values}) when is_list(values), do: values
  defp exception_values(_other), do: nil

  defp reduce_value(value) when is_map(value) do
    value
    |> take(~w(type module stacktrace))
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
      # The `frames` key itself is kept even when empty, because its absence
      # means "this exception had no stack" and its presence means "every frame
      # was non-application code, and we dropped them all" — two different
      # facts a reader would otherwise see as one.
      if kept == %{"frames" => []}, do: trace, else: kept
    end)
  end

  defp reduce_stacktrace(_other), do: nil

  # `request` reduces to the method and the route template, or to nothing.
  #
  # The route is rejected unless it looks like a template, because a `route`
  # carrying a query string is not a route — it is the URL the caller was
  # reached on, and the query string is where a token, an email address and a
  # search term all live. core is explicit that `http.route` is the template and
  # that `url.full`/`url.path` are on no allowlist.
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

  # The second barrier. Applied to the WHOLE rebuilt event rather than to a list
  # of fields, so a value that reaches a key nobody thought of is still masked —
  # which is the point of a second barrier being of a different kind.
  defp mask_values(event) do
    Enum.reduce(event, event, fn {key, value}, acc ->
      Map.put(acc, key, mask_value(value))
    end)
  end

  # The recursive walk over whatever shape a value has. `mask/1` is the public
  # entry point and only takes a binary, so the walker cannot be the same
  # function: a second `mask/1` clause set here would be a compile error, and
  # widening the public one to accept maps would make `Policy.mask/1` a function
  # whose return type depends on its input.
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
