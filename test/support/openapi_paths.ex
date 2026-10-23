defmodule Courier.TestSupport.OpenAPIPaths do
  @moduledoc """
  Reads courier's OpenAPI document and `CourierWeb.Router`, and says where they
  disagree. The check built on this is `CourierWeb.OpenAPIDocumentTest`; this
  module is the part of it that has to be right for the check to mean anything.

  It lives in courier's own `test/support` rather than in a shared helper, so the
  next service that publishes a document copies one file and reads it.

  ## It reads responses too, not only paths

  `document_operations!/1` answers *which routes does this document describe*.
  That is not the same question as *which responses does it declare*, and a
  document can pass the first and fail the second: courier-12 found
  `openapi.yaml` describing eight operations, wiring the RFC 9457 envelope into
  every response it declared, and declaring no 500 on any of them — a status
  every one of them could return, and one a generated client needs to know is
  not a retry.

  So this module also reads each operation's `responses:` block
  (`document_responses!/1`) and the reusable responses under
  `components.responses` (`component_responses!/1`), and follows a `$ref` from
  one to the other. The check built on those is
  `CourierWeb.OpenAPIErrorResponsesTest`, which is the language-specific half a
  neutral harness cannot be: it provokes each status against the running
  endpoint and asks the document whether it admits it.

  ## Both sets are read, neither is written down

  The document's operations come from `openapi.yaml` and the router's come from
  `CourierWeb.Router.__routes__/0`. Neither side is a list this repository
  maintains, because a list is a check that can only fail for a name somebody
  remembered to type — the failure mode that made pantry-03's coverage test
  useless, and the one this check must not share.

  ## Every reader refuses rather than under-reading

  A document reader that finds nothing returns an empty set, and an empty set
  agrees with an empty set. So every way this reader could come back with less
  than it should — no `paths:` key, an empty block, a path item with no
  operations, a path key that is not a path, an indentation it did not expect, a
  missing file, a router with no routes — is a raised error whose message names
  what it found. A loud failure in the reader is worth more than a green check
  over nothing.

  ## Why this is not a YAML parser

  courier has no YAML dependency, and adding one is a decision this repository
  has not made (`AGENTS.md`: "No dependency without approval"). So this reads
  the part of the document that describes routes — the `paths:` block and the
  keys under it — by indentation, and understands exactly that.

  The subset is small and stated:

    * `paths:` at column 0, path items one level in, operations one level below
      that, and anything deeper is an operation's body and is not read. The two
      indentation levels are **derived from the document**, not assumed to be two
      and four, so four-space YAML is read correctly rather than read as empty.
    * A direct child of `paths:` is a path if it starts with `/`; otherwise it
      has to be one of the fields OpenAPI 3.1 allows directly under a path —
      `summary`, `description`, `servers`, `parameters`, `$ref`, `x-…` — and
      anything else is an error rather than a guess.
    * A key under a path is an operation if it is one of the eight HTTP method
      names and nothing else. `getaway:` is not a `GET`.
    * A key under an operation's `responses:` is a status if it is three quoted
      digits, which is how OpenAPI 3.1 writes them (`'404':`). A `default:` key is
      a response too and is read as `default`, so a document that hides an error
      behind one cannot slip past unnoticed.
    * `application/problem+json` is recognised as a **key** under a response's
      `content:`, wherever its value sits. How a media type maps to a schema is
      YAML parsing, and this reader does not parse YAML — but the question the
      check asks is "does this response name the problem media type at all", and
      that is a key at a known level.

  Anything outside that subset raises. A service that needs a real parser should
  add one and delete this; the check itself does not change.
  """

  # OpenAPI 3.1's Operation Object fields, plus `trace` — in HTTP, not in
  # OpenAPI's fixed field list, but a router can declare it and a document that
  # declares it is at least telling the truth about a route that exists.
  @methods ~w(get head post put patch delete options trace)

  # The fields OpenAPI 3.1 allows directly under a path key, in the Path Item
  # Object. They belong to the path, not to any of its operations.
  @path_item_fields ~w(summary description servers parameters $ref)

  @typedoc """
  One operation, keyed by its normalised `{method, path}` and carrying the
  spelling the source used — so a failure can name a path as written rather than
  as normalised, with the document's `{id}` on one side and the router's `:id` on
  the other.
  """
  @type operation :: %{required(String.t()) => term()}

  @type operations :: %{{String.t(), String.t()} => operation()}

  @doc """
  Every operation in the OpenAPI document at `path`, or a raised error.
  """
  @spec document_operations!(Path.t()) :: operations()
  def document_operations!(path \\ "openapi.yaml") do
    lines =
      case File.read(path) do
        {:ok, contents} -> significant_lines(contents)
        {:error, reason} -> raise "could not read #{path}: #{:file.format_error(reason)}"
      end

    block = paths_block!(path, lines)
    {path_level, method_level} = levels!(path, block)

    # Each group is one direct child of `paths:` plus everything indented under
    # it, because the level a key sits at is what makes it a path item.
    block
    |> groups(path_level)
    |> Enum.reduce(%{}, fn [{_indent, text, number} | children], acc ->
      key = String.trim_trailing(text, ":")

      cond do
        path?(key) ->
          # Only a key at the operation level is an operation. Anything deeper is
          # inside an operation's body, and a body may contain a key that happens
          # to be spelled like a method: a schema property named `delete` is not
          # a `DELETE` route.
          methods =
            children
            |> Enum.filter(fn {indent, _, _} -> indent == method_level end)
            |> Enum.map(&method_key/1)
            |> Enum.filter(&method?/1)

          if methods == [] do
            raise "#{path}:#{number} — the path `#{key}` has no operation under it. " <>
                    "An OpenAPI path item with no operation is not something a client " <>
                    "can be generated from, and skipping it would leave this check " <>
                    "agreeing with a document that says nothing about this route."
          end

          Enum.reduce(methods, acc, &record(path, &2, key, number, &1))

        path_item_field?(key) ->
          acc

        true ->
          raise "#{path}:#{number} — `#{key}` is not a valid OpenAPI path. Every key " <>
                  "directly under `paths:` is a path starting with `/`, or a field of " <>
                  "the Path Item Object (#{Enum.join(@path_item_fields, ", ")}, x-…). " <>
                  "This reader refuses the document rather than guessing which was meant."
      end
    end)
  end

  @doc """
  Every operation `router` serves, taken from its own `__routes__/0`, or a raised
  error.
  """
  @spec router_operations!(module()) :: operations()
  def router_operations!(router \\ CourierWeb.Router) do
    routes =
      if Code.ensure_loaded?(router) and function_exported?(router, :__routes__, 0) do
        router.__routes__()
      else
        raise "#{inspect(router)} is not a Phoenix router: it has no __routes__/0. The " <>
                "route set has to come from the router's own definitions, because a list " <>
                "written out in a test only ever describes the routes somebody remembered."
      end

    if routes == [] do
      raise "#{inspect(router)} defines 0 routes. A router-reading check that finds no " <>
              "routes agrees with a document-reading check that finds no paths, and two " <>
              "empty sets always agree."
    end

    Enum.reduce(routes, %{}, fn route, acc ->
      method = normalise_method(route.verb)
      path = route.path

      put_operation!(
        acc,
        normalise_operation(method, path),
        %{
          "method" => method,
          "path" => path,
          "label" => "#{method} #{path}",
          "plug" => route.plug,
          "action" => route.plug_opts
        },
        inspect(router)
      )
    end)
  end

  @doc """
  Where the two sets disagree, in three parts.

    * `documented_not_served` — the document has it, the router does not. This
      is the direction that 404s a client.
    * `served_not_documented` — every operation the router serves that the
      document does not describe, whatever the reason.
    * `unexplained` — the ones no exclusion covers. This is what a check fails
      on; the difference between it and `served_not_documented` is a declared
      choice rather than an oversight, and the test prints the choice so it
      cannot be read as an accident.

  `exclusions` is a map of a normalised `{method, path}` to the reason that
  operation is allowed to be missing. It is keyed exactly as the sets are, so a
  carve-out names one operation rather than one path and cannot quietly cover a
  second method on the same path.
  """
  @spec diff(operations(), operations(), operations()) :: %{
          documented_not_served: [operation()],
          served_not_documented: [operation()],
          unexplained: [operation()],
          excluded: [operation()]
        }
  def diff(document, router, exclusions \\ %{}) do
    document_keys = MapSet.new(Map.keys(document))
    router_keys = MapSet.new(Map.keys(router))
    excluded_keys = MapSet.new(Map.keys(exclusions))
    served = difference(router, router_keys, document_keys)
    {explained, unexplained} = Enum.split_with(served, &MapSet.member?(excluded_keys, key(&1)))

    %{
      documented_not_served: difference(document, document_keys, router_keys),
      served_not_documented: served,
      unexplained: unexplained,
      excluded: Enum.map(explained, &Map.put(&1, "reason", exclusions[key(&1)]))
    }
  end

  @doc """
  The message a failure prints, built to be actionable on its own: every
  offending path is named, each says which side has it, and the two ways to fix
  it are spelled out with the file to change.
  """
  @spec describe_drift(map()) :: String.t()
  def describe_drift(diff) do
    [
      section(
        diff.documented_not_served,
        "openapi.yaml documents",
        "the router does not serve",
        "An endpoint in the menu that answers 404 is a product configured against a " <>
          "route that does not exist, and they find out at their outage.",
        [
          "The route is real and shipping — add it to `lib/courier_web/router.ex`.",
          "The operation is not shipping — delete it from `openapi.yaml`."
        ]
      ),
      section(
        diff.unexplained,
        "CourierWeb.Router serves",
        "openapi.yaml does not describe",
        "A route nobody documented is a route the next generated client will not " <>
          "have, so the surface grows and the contract does not.",
        [
          "The route is part of courier's public surface — document it in `openapi.yaml`.",
          "The route is not meant to be public — say so in the document's header, the way " <>
            "`/healthz` and `/readyz` are, rather than leaving it to be found."
        ]
      ),
      exclusions_note(diff.excluded)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.intersperse("\n")
    |> Enum.join()
  end

  @doc """
  The operation key for a method written either way: `Phoenix.Router.Route.verb`
  is an atom (`:get`) and a document's key is the string `"get"`, and neither is a
  difference between the two sides.
  """
  @spec normalise_method(atom() | String.t()) :: String.t()
  def normalise_method(method), do: method |> to_string() |> String.upcase()

  @doc """
  The normalised `{method, path}` an operation is keyed by, from either spelling.
  """
  @spec normalise_operation(atom() | String.t(), String.t()) :: {String.t(), String.t()}
  def normalise_operation(method, path) do
    {normalise_method(method), normalise_path(path)}
  end

  @doc """
  The path with a path parameter's whole segment replaced by `{}` and any trailing
  slash removed. Both rewrites are mechanical, and both are applied to the
  document and the router alike — there is no "document rules" and "router
  rules", because a normaliser that treats the two sides differently is one that
  can hide a difference.

    * `:id`, `{id}` and `{id}.json` all read as `{}`, because a client
      substitutes a path parameter positionally, so renaming the parameter is a
      rename inside one route rather than a second route. Failing on it would
      make the check cry wolf, and a check people turn off is worse than none.
    * A trailing slash is not a difference because the router agrees: Phoenix
      resolves `/healthz/` to the `/healthz` route.

  Two things are deliberately **not** rewritten. A `*glob` segment is left
  alone, because it matches an arbitrary tail of a path, which is a different
  shape from a `{param}`'s single segment, and treating the two as one is the
  kind of rewrite that hides a real difference — courier declares no glob, and a
  service that does will see this check report it, which is the honest answer,
  since OpenAPI has no way to write "any tail of segments" in a path template. A
  path that is missing its leading slash is not given one either: the document
  is invalid, and quietly repairing an invalid document hides the invalidity.

  A rewrite is only safe while it cannot map two different routes onto one, so
  `put_operation!` raises when it does rather than keeping either of them.
  """
  @spec normalise_path(String.t()) :: String.t()
  def normalise_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &rewrite_segment/1)
    |> strip_trailing_slash()
  end

  # --- reading responses out of a document -------------------------------------

  @typedoc """
  One response, as the document declares it.

    * `:status` — `"404"`, or `"default"` for OpenAPI's catch-all key.
    * `:ref` — the `#/components/responses/…` this response points at, or `nil`
      when it is written out inline.
    * `:problem_json` — whether the response names `application/problem+json`,
      following a `$ref` into `components.responses` when there is one. This is
      the field that answers "is the envelope attached, or merely defined?".
    * `:ref_schema` — whether it points at `#/components/schemas/Problem`, so a
      response can claim the media type while carrying a different body.
    * `:line` — where in the document it is, so a failure names a line.
  """
  @type response :: %{
          status: String.t(),
          ref: String.t() | nil,
          problem_json: boolean(),
          ref_schema: boolean(),
          line: pos_integer()
        }

  @typedoc "Every declared response, keyed by the same `{method, path}` as the routes."
  @type responses :: %{{String.t(), String.t()} => %{optional(String.t()) => response()}}

  @doc """
  Every response every operation declares, or a raised error.

  A `$ref` to `#/components/responses/…` is resolved through
  `component_responses!/1`, so a response that says nothing itself is still known
  to carry the envelope. **A `$ref` that names a component the document does not
  define is an error**, because that is precisely the shape this reader exists to
  catch: a response wired to nothing, described as though it were wired.

  Every operation must have a `responses:` block with at least one status in it.
  An operation with no `responses:` raises rather than contributing an empty map,
  because an empty map is a set that agrees with every other empty map.
  """
  @spec document_responses!(Path.t()) :: responses()
  def document_responses!(path \\ "openapi.yaml") do
    lines = document_lines!(path)
    components = component_responses!(path)
    block = paths_block!(path, lines)
    {path_level, method_level} = levels!(path, block)

    block
    |> groups(path_level)
    |> Enum.reduce(%{}, fn [{_indent, text, _number} | children], acc ->
      current = String.trim_trailing(text, ":")

      if path?(current) do
        children
        |> method_subtrees(method_level)
        |> Enum.reduce(acc, fn {method, line, subtree}, inner ->
          operation = normalise_operation(method, current)

          put_responses!(
            inner,
            operation,
            responses!(path, method, current, line, subtree, components)
          )
        end)
      else
        acc
      end
    end)
  end

  # Two methods on one path that normalise onto one operation is a collision, and
  # the same collision guard the route reader has. Without it the second would
  # overwrite the first and the check would compare one operation's promises
  # against the other's.
  defp put_responses!(acc, key, responses) do
    case Map.fetch(acc, key) do
      {:ok, existing} ->
        {method, path} = key

        raise "two operations both read as #{method} #{path}, so the responses declared " <>
                "for one would be checked against the other. The first declares " <>
                "#{inspect(Enum.sort(Map.keys(existing)))}, the second " <>
                "#{inspect(Enum.sort(Map.keys(responses)))}."

      :error ->
        Map.put(acc, key, responses)
    end
  end

  @doc """
  Every operation that accepts an `Idempotency-Key` header, or a raised error.

  Read because core's conventions require the header on a mutating `POST` and
  courier-14 added it to two of them, and the question this file exists to answer
  is whether the **document and the router name the same operations**. That
  cannot be checked by reading either side alone: a document that documents the
  header on a route the router does not guard describes a retry courier is not
  listening for, and a router that guards a route the document does not mention
  is a behaviour a generated client has never been told about. Both are the
  `openapi_paths_test.exs` failure mode, in a new place.

  ## What "accepts" means here, and what it does not

  An operation counts if its own subtree names the header — either as a `$ref` to
  `#/components/parameters/IdempotencyKey` or as an inline `name: Idempotency-Key`
  parameter line. That is a **text** match over the operation's block rather than
  a parse, and the honest limit is worth stating: an unrelated line somewhere in
  the operation could be mistaken for the parameter.

  It cannot produce a false *negative*, which is the direction that matters here
  — a parameter declared in either of the two forms is found, and a missing
  declaration is a missing declaration. A false positive would be a document that
  mentions the header without declaring it, and core's own
  `openapi.idempotency-key` rule checks the declaration properly against a real
  parse, so the two checks together have no gap between them. Neither is
  sufficient alone; the point of writing them down is that neither is silently
  load-bearing.
  """
  @spec document_idempotency_keys!(Path.t()) :: operations()
  def document_idempotency_keys!(path \\ "openapi.yaml") do
    block = paths_block!(path, document_lines!(path))
    {path_level, method_level} = levels!(path, block)

    block
    |> groups(path_level)
    |> Enum.reduce(%{}, fn [{_indent, text, _number} | children], acc ->
      current = String.trim_trailing(text, ":")

      if path?(current) do
        children
        |> method_subtrees(method_level)
        |> Enum.reduce(acc, fn {method, _line, subtree}, inner ->
          if accepts_idempotency_key?(subtree) do
            Map.put(inner, normalise_operation(method, current), %{})
          else
            inner
          end
        end)
      else
        acc
      end
    end)
  end

  # The two forms a document may use, and nothing else. `in: header` is not
  # required in the match because the `$ref` form does not carry it, and a `$ref`
  # to a parameter that turned out to be a query parameter would be caught by core's
  # rule rather than guessed at here.
  defp accepts_idempotency_key?(subtree) do
    Enum.any?(subtree, fn {_indent, text, _number} ->
      String.contains?(text, "#/components/parameters/IdempotencyKey") or
        String.contains?(text, "name: Idempotency-Key")
    end)
  end

  @doc """
  Every reusable response under `components.responses`, or a raised error.

  Keyed by the name a `$ref` would use. Each entry says whether it names
  `application/problem+json` and whether its body is `#/components/schemas/Problem`,
  which are two different questions: the first is the content type a client
  switches on, the second is the shape it parses. A response can be right about
  one and wrong about the other, and only the second one makes the first true.
  """
  @spec component_responses!(Path.t()) :: %{optional(String.t()) => response()}
  def component_responses!(path \\ "openapi.yaml") do
    lines = document_lines!(path)

    case Enum.find(lines, fn {indent, text, _} -> indent == 0 and text == "components:" end) do
      nil ->
        raise "#{path} has no top-level `components:` key. A reusable response is " <>
                "defined there, and a reader that cannot find them cannot tell a " <>
                "response that carries the envelope from one that only says it does."

      {_indent, _text, number} ->
        rest = Enum.drop_while(lines, fn {_i, _t, n} -> n <= number end)

        case Enum.find(rest, fn {indent, text, _} ->
               indent == 2 and text == "responses:"
             end) do
          nil ->
            %{}

          entry ->
            rest
            |> Enum.drop_while(fn {_i, _t, n} -> n <= elem(entry, 2) end)
            |> Enum.take_while(fn {indent, _t, _n} -> indent > 2 end)
            |> groups(4)
            |> Enum.reduce(%{}, fn [{_i, text, line} | subtree], acc ->
              name = String.trim_trailing(text, ":")
              shape = component_shape(subtree)

              Map.put(
                acc,
                name,
                %{
                  status: name,
                  ref: nil,
                  problem_json: shape.problem_json,
                  ref_schema: shape.ref_schema,
                  line: line
                }
              )
            end)
        end
    end
  end

  # The `responses:` block of one operation, or a raise.
  #
  # `subtree` is the operation's own lines: the method key, everything under it,
  # and nothing belonging to a sibling method. The status keys are the least-
  # indented lines in the block, because `responses:` is immediately followed by
  # them and nothing else is allowed to be shallower.
  defp responses!(path, method, current, line, subtree, components) do
    case Enum.find(subtree, fn {indent, text, _} -> indent > 0 and text == "responses:" end) do
      nil ->
        raise "#{path}:#{line} — #{method} #{current} has no `responses:` block. An " <>
                "operation that declares no response declares no contract: a client " <>
                "generated from it cannot know what success looks like, let alone " <>
                "what failure does."

      {indent, _text, number} ->
        block =
          Enum.drop_while(subtree, fn {_i, _t, n} -> n <= number end)
          |> Enum.take_while(fn {i, _t, _n} -> i > indent end)

        if block == [] do
          raise "#{path}:#{number} — the `responses:` block of #{method} #{current}, " <>
                  "declared at line #{line}, is empty. An empty responses object and a " <>
                  "missing one are the same absence, and neither is something a client " <>
                  "can be generated from."
        end

        level = block |> Enum.map(&elem(&1, 0)) |> Enum.min()

        responses =
          Enum.reduce(
            each_status(block, level),
            %{},
            &collect_status(&1, &2, path, method, current, components)
          )

        Map.put(responses, "", %{
          status: "",
          ref: nil,
          problem_json: false,
          ref_schema: false,
          line: number
        })
        |> Map.delete("")
    end
  end

  # Each status key in a `responses:` block, with the lines that are its body.
  defp each_status(block, level) do
    block
    |> Enum.with_index()
    |> Enum.filter(fn {{indent, _text, _n}, _i} -> indent == level end)
    |> Enum.map(fn {{indent, text, number}, index} ->
      body =
        block
        |> Enum.slice(index, length(block) - index)
        |> Enum.take_while(fn {i, _t, _n} -> i >= indent end)

      {text, number, body}
    end)
  end

  defp collect_status({text, line, body}, acc, path, method, current, components) do
    status = status_key(text)
    ref = component_ref(body)

    resolved =
      case ref do
        # An inline response answers for itself. A `$ref` is followed into the
        # component, because the one-line form names no media type and no schema
        # and the promise is in the component it points at.
        nil ->
          component_shape(body)

        name ->
          Map.get(components, name) ||
            raise(
              "#{path}:#{line} — #{method} #{current} points at " <>
                "#/components/responses/#{name}, and this document defines no response " <>
                "of that name. This is the failure this reader exists for: a response " <>
                "wired to nothing, described as though it were wired. Define the " <>
                "component, or point the response at one that exists."
            )
      end

    Map.put(acc, status, %{
      status: status,
      ref: ref,
      problem_json: resolved.problem_json,
      ref_schema: resolved.ref_schema,
      line: line
    })
  end

  # The component name a response points at, or `nil` when it is inline.
  defp component_ref(body) do
    body
    |> Enum.find_value(fn {_indent, text, _n} ->
      case Regex.run(~r/#\/components\/responses\/([A-Za-z0-9_.-]+)/, text) do
        [_, name] -> name
        _ -> nil
      end
    end)
  end

  @problem_json "application/problem+json:"

  @doc false
  # Two questions a response has to answer about itself, and only the second makes
  # the first true: does it NAME the problem media type, and is its body
  # `#/components/schemas/Problem`? A response can name the media type over some
  # other schema, which is a content type that promises courier's error shape and
  # delivers something else.
  defp component_shape(subtree) do
    %{
      problem_json:
        Enum.any?(subtree, fn {indent, text, _n} ->
          text == @problem_json and indent > 0
        end),
      ref_schema:
        Enum.any?(subtree, fn {_indent, text, _n} ->
          String.contains?(text, "#/components/schemas/Problem")
        end)
    }
  end

  # `'404':` on its own, or `'404': { $ref: '#/components/responses/NotFound' }` on
  # one line. OpenAPI 3.1 writes status keys quoted, and this document writes the
  # reusable ones inline, so the key is the quoted run at the start of the line
  # rather than the whole line.
  defp status_key(text) do
    case Regex.run(~r/^'([0-9A-Za-z]+)':/, text) do
      [_, key] -> key
      _ -> String.trim_trailing(text, ":")
    end
  end

  # Each method under a path, with its own subtree: the method line and every
  # following line until the next line at or above the method level. Without this
  # a method would inherit its sibling's `responses:`, and `POST` would be checked
  # against `GET`\'s promises.
  defp method_subtrees(children, method_level) do
    starts =
      for {entry, index} <- Enum.with_index(children),
          elem(entry, 0) == method_level,
          method?(String.trim_trailing(elem(entry, 1), ":")),
          do: {elem(entry, 1), elem(entry, 2), index}

    for {text, number, index} <- starts do
      rest = Enum.drop(children, index + 1)

      take =
        Enum.find_index(rest, fn {indent, _text, _n} -> indent <= method_level end) ||
          length(rest)

      {String.trim_trailing(text, ":"), number, Enum.slice(children, index, take + 1)}
    end
  end

  defp document_lines!(path) do
    case File.read(path) do
      {:ok, contents} -> significant_lines(contents)
      {:error, reason} -> raise "could not read #{path}: #{:file.format_error(reason)}"
    end
  end

  # --- reading a document -----------------------------------------------------

  defp significant_lines(contents) do
    contents
    |> String.split(~r/\R/)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {raw, number} ->
      stripped = String.trim_leading(raw, " ")

      cond do
        stripped == "" -> []
        String.starts_with?(stripped, "#") -> []
        true -> [{indent_of(raw), String.trim_trailing(stripped), number}]
      end
    end)
  end

  defp indent_of(raw),
    do: raw |> String.length() |> Kernel.-(String.trim_leading(raw, " ") |> String.length())

  defp paths_block!(path, lines) do
    case Enum.find_index(lines, fn {indent, text, _} -> indent == 0 and text == "paths:" end) do
      nil ->
        raise "#{path} has no top-level `paths:` key. A reader that cannot find the " <>
                "document's paths finds none, and a check over none passes — so this is " <>
                "an error, not an empty result."

      index ->
        lines |> Enum.drop(index + 1) |> Enum.take_while(fn {indent, _, _} -> indent > 0 end)
    end
  end

  # The two levels are derived from the document rather than assumed to be two and
  # four spaces, so four-space YAML is read correctly instead of read as empty.
  # Only the first two distinct levels are levels: anything deeper is inside an
  # operation's body, and an operation's body is not part of the route set.
  defp levels!(path, block) do
    case block |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() do
      [] ->
        raise "#{path} documents no operations: nothing is under its `paths:` key. Two " <>
                "readers that both find nothing agree, which is how a check over nothing " <>
                "goes green."

      [only] when only > 0 ->
        raise "#{path} documents no operations: what is under `paths:` is one indentation " <>
                "level deep, so there is no operation level below the path items."

      [path_level, method_level | _bodies] ->
        {path_level, method_level}
    end
  end

  # A direct child of `paths:` and everything indented under it, in one list each.
  # `chunk_by/2` groups consecutive equal keys, so the key here is a counter that
  # only advances on a path-level line.
  defp groups(block, path_level) do
    block
    |> Enum.map_reduce(-1, fn {indent, _text, _number} = line, group ->
      group = if indent == path_level, do: group + 1, else: group
      {{group, line}, group}
    end)
    |> elem(0)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn group -> Enum.map(group, &elem(&1, 1)) end)
  end

  defp record(path, acc, current_path, line, method) do
    put_operation!(
      acc,
      normalise_operation(method, current_path),
      %{
        "method" => normalise_method(method),
        "path" => current_path,
        "label" => "#{normalise_method(method)} #{current_path}"
      },
      "#{path}:#{line} (the path starting at line #{line})"
    )
  end

  defp put_operation!(acc, key, operation, origin) do
    case Map.fetch(acc, key) do
      {:ok, existing} ->
        {method, path} = key

        raise "two operations both read as #{method} #{path}: `#{existing["label"]}` and " <>
                "`#{operation["label"]}`. They normalise onto one route, so a check that " <>
                "could not see the collision would be blind to it. Found in #{origin}."

      :error ->
        Map.put(acc, key, operation)
    end
  end

  defp method_key({_indent, text, _number}), do: String.trim_trailing(text, ":")

  defp path?(key), do: String.starts_with?(key, "/")

  defp path_item_field?(key), do: key in @path_item_fields or String.starts_with?(key, "x-")

  defp method?(key), do: String.downcase(key) in @methods

  defp rewrite_segment(segment) do
    if segment != "" and String.match?(segment, ~r/^[{:]/) do
      "{}"
    else
      segment
    end
  end

  defp strip_trailing_slash(path) do
    case String.trim_trailing(path, "/") do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  # --- comparing and reporting ------------------------------------------------

  defp difference(operations, keys, others) do
    keys
    |> MapSet.difference(others)
    |> MapSet.to_list()
    |> Enum.map(&Map.fetch!(operations, &1))
    |> Enum.sort_by(& &1["label"])
  end

  defp key(operation), do: {operation["method"], operation["path"]}

  defp section(offenders, subject, absence, why, fixes) do
    if offenders == [] do
      nil
    else
      """
      #{subject} #{count(offenders, "operation")} #{absence}.

        #{why}

        Offending operations:
      #{Enum.map_join(offenders, "\n", &offender_line/1)}

        To fix this, do one of the two things:
      #{fixes |> Enum.with_index(1) |> Enum.map_join("\n", fn {fix, n} -> "      #{n}. #{fix}" end)}

        `anywaye.yml` declares `exposes.api: openapi.yaml` and PLAN.md MD6 has SDK
        generation reading that file, so every operation in it is a method on a
        generated client. This check is `test/courier_web/openapi_document_test.exs`;
        the reader, and a test per normalisation, is
        `test/courier_web/openapi_paths_test.exs`.
      """
    end
  end

  # The omissions that were declared on purpose, printed so a carve-out reads as
  # a choice somebody made rather than as a gap the check happened to miss.
  defp exclusions_note([]), do: nil

  defp exclusions_note(excluded) do
    """
    Declared omissions — the router serves these and `openapi.yaml` does not, on purpose:
    #{Enum.map_join(excluded, "\n", &"  #{&1["label"]} — #{&1["reason"]}")}
    """
  end

  defp offender_line(operation) do
    served =
      if operation["plug"],
        do: "\n      served by #{inspect(operation["plug"])}.#{handler(operation["action"])}/2",
        else: ""

    "    #{operation["label"]}#{served}"
  end

  # A plug action is an atom in every route this repository declares, and
  # `inspect/1` on an atom is `:show`, which reads as a typo in a sentence.
  defp handler(action) when is_atom(action), do: Atom.to_string(action)
  defp handler(action), do: inspect(action)

  defp count(offenders, noun) do
    "#{length(offenders)} #{noun}#{if length(offenders) == 1, do: "", else: "s"}"
  end
end
