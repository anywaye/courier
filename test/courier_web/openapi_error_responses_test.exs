defmodule CourierWeb.OpenAPIErrorResponsesTest do
  @moduledoc """
  `openapi.yaml` and courier's endpoint have to agree about **responses**, the way
  `CourierWeb.OpenAPIDocumentTest` holds them to agreeing about paths.


  courier-12 was opened on a measurement that every operation could return a **500**
  and none of the eight declared one, that every operation could return a **406**
  and none declared it, and that six of core's nine reserved codes appeared
  nowhere in the document. The path check that already existed could not have
  caught any of it, and could not be made to: it compares `{method, path}` sets,
  which are identical whether or not a 500 is declared. This file compares
  statuses, and it compares them in **both** directions, because the two failures
  are different and only one of them is visible.

  A status a client can receive and the document does not describe is a case the
  client handles with whatever its default branch is. A status the document
  describes and the client can never receive is a case a client wrote for nothing,
  and it is the one that reads as tidiness — courier-12 found both, on the same
  file, in the same status.


  The direction *a status the endpoint can return is a status the document
  declares* is checked by **provoking** it and asking. There is no table of
  statuses per operation written down anywhere in this file, because a table is a
  check that can only fail for a case somebody remembered to type. The operations
  come from `Courier.TestSupport.OpenAPIPaths`, the path parameters are filled in
  mechanically, and the statuses come from sending requests to the real endpoint.

  That is also the half a neutral, language-agnostic harness cannot do: it needs a
  running Phoenix, a plug pipeline, and a real `problem+json` body. This is the
  language-specific half, and it is why the document's own path test and this one
  are both kept.

  The other direction — *the document declares nothing courier cannot return* —
  cannot be proved by provoking, because the way to prove a status is unreachable
  is to fail to reach it. It is therefore asserted against a short, named list of
  statuses courier was measured not to send, each with the reason, and each also
  required to appear in the document's own header. A status courier starts
  returning has to be added in the same commit that starts returning it, and this
  test is what makes that a decision rather than a drift.

  `async: true`, like the two document checks it sits beside: it reads a file and
  sends requests through the test adapter, and starts no process the suite shares.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.TestSupport.OpenAPIPaths, as: Paths

  @document "openapi.yaml"

  @account "6f5d4c3b-2a18-4e8f-9c07-1b2d3e4f5061"
  @id "6f5d4c3b-2a18-4e8f-9c07-1b2d3e4f5061"
  @missing_id "7f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  @reserved ~w(unauthorized forbidden not_found conflict validation_failed
               rate_limited idempotency_key_reused internal unavailable)
  @extra_codes ~w(bad_request not_acceptable)

  setup_all do
    %{
      responses: Paths.document_responses!(@document),
      components: Paths.component_responses!(@document),
      header: @document |> File.read!() |> String.split("openapi: 3.1.0") |> List.first(),
      router: Paths.router_operations!(),
      idempotent: Paths.document_idempotency_keys!(@document)
    }
  end


  describe "a status the endpoint can return is a status the document declares" do
    test "401 — every operation behind the Principal plug declares it", %{responses: responses} do
      {must_declare, need_not} =
        responses
        |> Map.keys()
        |> Enum.split_with(fn operation -> provoke(operation, anonymous: true) == 401 end)

      assert must_declare != [],
             "nothing answered 401, so this test proved nothing: either the plug " <>
               "stopped refusing anonymous callers or the probes stopped reaching it"

      assert Enum.all?(must_declare, fn op -> Map.has_key?(responses[op], "401") end),
             undeclared(must_declare, "401", responses)

      for operation <- need_not do
        refute Map.has_key?(responses[operation], "401"),
               "#{label(operation)} answers #{provoke(operation, anonymous: true)} to an " <>
                 "anonymous request, and declares a 401. Core's conventions and courier's " <>
                 "router agree that an operation outside the `:authenticated` pipeline is " <>
                 "served unauthenticated; declaring 401 would be a document lying about auth."
      end
    end

    test "406 — every operation in the :api pipeline declares it", %{responses: responses} do
      unreachable =
        Enum.reject(Map.keys(responses), fn operation ->
          provoke(operation, accept: "text/html") == 406
        end)

      assert unreachable == [],
             "these operations did not answer 406 to `Accept: text/html`, so this test " <>
               "cannot claim 406 is reachable on all of them: #{inspect(unreachable)}"

      undeclared = Enum.filter(Map.keys(responses), &(not Map.has_key?(responses[&1], "406")))

      assert undeclared == [], undeclared(undeclared, "406", responses)
    end

    test "400 — the document and the parser agree, in both directions", %{responses: responses} do
      probed =
        for operation <- Map.keys(responses), into: %{} do
          {operation, provoke_malformed_body(operation) == 400}
        end

      assert Enum.any?(probed, fn {_op, reachable} -> reachable end),
             "no operation answered 400 to a body that is not JSON, so this test " <>
               "proved nothing: the parser has stopped refusing one"

      signed =
        Map.keys(responses)
        |> Enum.filter(&signed_webhook?/1)
        |> Enum.map(&{&1, provoke_malformed_body(&1)})

      assert signed != [],
             "no operation in #{@document} declares `webhookSignature`, so the signed " <>
               "malformed-body probe this file added for the inbound surface is not being " <>
               "used by anything. Either the probe is dead or the document stopped saying " <>
               "how that operation is authenticated — and the 400 below would then be " <>
               "declared against a status nobody can reach."

      for {operation, status} <- signed do
        assert status == 400,
               "#{label(operation)} is signature-authenticated and its malformed body was " <>
                 "signed, yet it answered #{status}. A signed body that is not JSON must be " <>
                 "a 400 — that is the only way this operation's 400 is reachable at all."
      end

      for {operation, reachable} <- Enum.sort(probed) do
        declared = Map.has_key?(responses[operation], "400")

        assert declared == reachable,
               "#{label(operation)} #{if declared,
                 do: "declares a 400 a client cannot receive — the parser reads no body " <> "on this verb, so the response is unreachable (openapi.yaml declares " <> "#{inspect(Enum.sort(Map.keys(responses[operation])))})",
                 else: "answers 400 to a body that is not JSON and does not declare it. " <> undeclared([operation], "400", responses)}"
      end
    end

    test "404 — every operation addressing one resource by id declares it", %{
      responses: responses,
      router: router
    } do
      by_id =
        for {{_method, _path} = operation, route} <- router,
            String.contains?(route["path"], ":"),
            Map.has_key?(responses, operation),
            do: operation

      assert by_id != [], "no route with a path parameter was found, so nothing was checked"

      for operation <- by_id do
        status = provoke(operation, id: @missing_id)

        assert status in [404, 422],
               "#{label(operation)} answered #{status} for an id courier has never issued. " <>
                 "A documented operation has to answer one of the two a client can act on; " <>
                 "anything else is a case this test has to be taught."

        assert Map.has_key?(responses[operation], to_string(status)),
               "#{label(operation)} answers #{status} for an unknown id and does not " <>
                 "declare it. #{undeclared([operation], to_string(status), responses)}"
      end
    end

    test "500 — every operation declares it, because RenderErrors can render it for any of them",
         %{responses: responses} do
      assert render_errors_json?(),
             "CourierWeb.Endpoint is no longer configured to render errors with " <>
               "CourierWeb.ErrorJSON, so a 500 on any route is no longer courier's " <>
               "envelope and this file's 500 claim is no longer true."

      undeclared = Enum.filter(Map.keys(responses), &(not Map.has_key?(responses[&1], "500")))

      assert undeclared == [], undeclared(undeclared, "500", responses)
    end

    test "the 500 body is courier's envelope, with a reserved code", %{responses: responses} do
      body =
        "500.json"
        |> CourierWeb.ErrorJSON.render(%{
          status: 500,
          instance: "/v1/webhook_endpoints",
          trace_id: "0af7651916cd43dd8448eb211c80319c"
        })
        |> Jason.encode!()
        |> Jason.decode!()

      assert body["code"] == "internal"
      assert body["type"] == "https://docs.anywaye.com/errors/internal"
      assert body["status"] == 500
      assert is_binary(body["trace_id"])

      refute Map.has_key?(body, "errors"),
             "core says `errors[]` appears only on a 422, and a 500 that carries one " <>
               "tells a client to look for a field that is not about their request"

      for operation <- Map.keys(responses) do
        assert Map.has_key?(responses[operation], "500"),
               undeclared([operation], "500", responses)
      end
    end
  end


  describe "the envelope is attached to every non-2xx the document declares" do
    test "every non-2xx names application/problem+json", %{responses: responses} do
      bare =
        for {{method, path}, declared} <- responses,
            {status, response} <- declared,
            not success?(status),
            not response.problem_json,
            do: "#{method} #{path} #{status} (openapi.yaml:#{response.line})"

      assert bare == [],
             """
             these non-2xx responses do not name `application/problem+json`, so a client
             that switches on the content type cannot tell they are errors:


             This is courier-12's headline finding in its original form: the envelope
             was declared in `components` and wired to nothing. Every non-2xx in this
             document has to name the media type, through a `$ref` that resolves to a
             component that names it.
             """
    end

    test "every non-2xx carries the Problem schema, not merely the media type", %{
      responses: responses
    } do
      bare =
        for {{method, path}, declared} <- responses,
            {status, response} <- declared,
            not success?(status),
            not response.ref_schema,
            do: "#{method} #{path} #{status} (openapi.yaml:#{response.line})"

      assert bare == [],
             """
             these non-2xx responses name the problem media type over some other schema,
             which is a content type promising courier's error shape and delivering
             something else:

             """
    end

    test "every reusable response names the envelope, whether or not one points at it", %{
      components: components
    } do
      assert map_size(components) > 0, """
      no reusable response was read from
      is written as a `$ref` into `components.responses`, so a reader that found none
      would be reporting every non-2xx as unwired and the check above would pass for
      the wrong reason.
      """

      for {name, component} <- components do
        assert component.problem_json,
               "components.responses.#{name} (openapi.yaml:#{component.line}) does not " <>
                 "name `application/problem+json`, and it is what every non-2xx points at"
      end
    end
  end


  describe "the document does not declare a status courier cannot return" do
    @unreachable %{
      "403" => {"Principal", "`CourierWeb.Plugs.Principal` answers 401 and 503, never 403"},
      "415" => {"pass:", "the parser is configured `pass: [\"*/*\"]` and refuses nothing"},
      "429" => {"no limiter", "thirty rapid writes answer thirty 201s"}
    }

    test "no operation declares one", %{responses: responses} do
      declared =
        for {{method, path}, statuses} <- responses,
            status <- Map.keys(statuses),
            Map.has_key?(@unreachable, status),
            do: "#{method} #{path} declares #{status}"

      assert declared == [],
             """
             these operations declare a status courier cannot return:


             A document that promises a 409 or a 429 is worse than one that is
             incomplete: a client generated from it will branch on a response that
             never arrives, and a client told to retry on 429 will hammer a service
             that was never rate limiting anything.

             If courier has started returning one of these, the fix is to implement it
             and then say so here — not to delete the line.
             """
    end

    test "and each one is admitted in the document's header", %{header: header} do
      for {status, {token, reason}} <- @unreachable do
        assert header =~ status,
               "#{@document} does not declare #{status} anywhere, which is correct, and " <>
                 "its header does not say why either. #{reason}. An omission the document " <>
                 "does not admit is the silent kind this header exists to prevent."

        assert header =~ token,
               "#{@document} omits #{status} but its header never mentions #{inspect(token)}, " <>
                 "so a reader is told what is missing and not why. The measured reason is: " <>
                 "#{reason}."
      end
    end
  end


  describe "Idempotency-Key" do
    test "a 409 courier can send is a 409 the document declares", %{
      responses: responses
    } do
      operation = {"POST", "/v1/webhook_endpoints"}
      body = idempotency_conflict(operation)

      assert body["status"] == 409,
             "#{label(operation)} answered the reused key with #{body["status"]} and " <>
               "`#{inspect(body["code"])}`. If courier has stopped sending a 409 here, " <>
               "this test is now measuring nothing and the 409 below should be removed " <>
               "from the document in the same commit that stopped sending it."

      assert body["code"] in ["idempotency_key_reused", "conflict"],
             "#{label(operation)} answered 409 with `code` #{inspect(body["code"])}, which " <>
               "is neither of the two codes core's reserved list puts at 409 for this case"

      assert Map.has_key?(responses[operation], "409"),
             undeclared([operation], "409", responses)
    end

    test "every operation the document gives the header to is behind the plug", %{
      idempotent: idempotent
    } do
      for operation <- Map.keys(idempotent) do
        assert idempotent_in_router?(operation),
               "#{@document} declares `Idempotency-Key` on #{label(operation)}, and the " <>
                 "router does not put it behind `CourierWeb.Plugs.Idempotency`. A client " <>
                 "generating a retry from this document would be retrying against a " <>
                 "service that ignores the header."
      end
    end

    test "every operation behind the plug is one the document gives the header to", %{
      idempotent: idempotent
    } do
      guarded = guarded_operations()

      assert MapSet.size(guarded) > 0,
             "no operation is behind the idempotency plug, so the plug is not in the " <>
               "router. Either the pipeline was removed or these tests are checking " <>
               "nothing at all."

      for operation <- Enum.to_list(guarded) do
        assert Map.has_key?(idempotent, operation),
               "the router puts #{label(operation)} behind `CourierWeb.Plugs.Idempotency`, " <>
                 "and #{@document} does not declare `Idempotency-Key` on it. The behaviour " <>
                 "is real and a client generated from this document does not know about it."
      end
    end

    test "each one declares the 409 the plug can send, with problem+json", %{
      responses: responses,
      idempotent: idempotent
    } do
      for operation <- Map.keys(idempotent) do
        assert Map.has_key?(responses[operation], "409"),
               "#{label(operation)} accepts `Idempotency-Key` and declares " <>
                 "#{inspect(Enum.sort(Map.keys(responses[operation])))}. Core's conventions: a client " <>
                 "holding a key has to be able to look up what happens when it sends the " <>
                 "key twice with different bytes, and an operation with no 409 has told " <>
                 "that client nothing."

        assert responses[operation]["409"].problem_json,
               "#{label(operation)} declares a 409 (openapi.yaml:#{responses[operation]["409"].line}) " <>
                 "that does not name `application/problem+json`. The 409 is courier's " <>
                 "envelope, so a client switching on the content type has to see it."
      end
    end

    test "the document says the header is implemented, because it now is" do
      header = File.read!(@document) |> String.split("openapi: 3.1.0") |> List.first()

      assert header =~ "Idempotency-Key"

      refute header =~ "does not implement it",
             "#{@document} still says courier does not implement `Idempotency-Key`. It " <>
               "does, and a client reading this header would be told to protect a retry " <>
               "by something courier will not do."
    end
  end


  describe "the codes are core's reserved codes, used as core says" do
    test "the document has examples to check, so the two checks below are not vacuous" do
      assert length(examples()) > 0,
             "no `example:` was read from #{@document}. Every reusable response ships " <>
               "one, and a check over none is a check that cannot fail."
    end

    test "every example's code is the last segment of its type" do
      for %{line: line, type: type, code: code} <- examples() do
        assert type |> String.split("/") |> List.last() == code,
               "openapi.yaml:#{line} has an example whose `code` is #{inspect(code)} and " <>
                 "whose `type` ends in #{inspect(type)}. Core says `code` is the last " <>
                 "segment of `type`, in snake_case, and a client that branches on `code` " <>
                 "is reading the one of the two that this document has to keep right."
      end
    end

    test "every example's code is one CourierWeb.Problem can actually emit" do
      known = @reserved ++ @extra_codes

      for %{line: line, code: code} <- examples() do
        assert code in known,
               "openapi.yaml:#{line} promises the code #{inspect(code)}, and " <>
                 "`CourierWeb.Problem` has no such code, so no error courier can send will " <>
                 "ever carry it. A code a client handles and courier cannot send is a " <>
                 "branch that never runs. The codes courier can emit are: " <>
                 "#{Enum.join(known, ", ")}."
      end
    end

    test "every non-2xx courier really sends satisfies the same rule", %{responses: responses} do
      probes = [
        {400, [malformed_body: true]},
        {401, [anonymous: true]},
        {404, [id: @missing_id]},
        {422, [id: @missing_id, anonymous: true, malformed_body: true]}
      ]

      provoked =
        for {status, opts} <- probes,
            operation <- Map.keys(responses),
            conn = safe_conn_for(operation, opts),
            conn.status == status,
            do: {operation, conn}

      assert provoked != [],
             "no provoked request produced one of the statuses under test, so this " <>
               "test proved nothing: the probes have stopped reaching the endpoint."

      for {operation, conn} <- provoked do
        assert problem_json?(conn),
               "#{label(operation)} answered #{conn.status} as " <>
                 "#{inspect(Plug.Conn.get_resp_header(conn, "content-type"))}, and a client " <>
                 "that switches on the content type reads an error as a success"

        payload = body(conn)

        assert payload["code"] == payload["type"] |> String.split("/") |> List.last(),
               "#{label(operation)} answered #{conn.status} with `code` " <>
                 "#{inspect(payload["code"])} and `type` #{inspect(payload["type"])}. Core " <>
                 "says `code` is the last segment of `type`, and a client branching on " <>
                 "`code` is reading one of the two."

        assert payload["code"] in (@reserved ++ @extra_codes),
               "#{label(operation)} answered #{conn.status} with `code` " <>
                 "#{inspect(payload["code"])}, which is not a code `CourierWeb.Problem` " <>
                 "documents, and therefore not one a client can be told to expect"

        assert is_binary(payload["trace_id"]) and payload["trace_id"] != "",
               "#{label(operation)} answered #{conn.status} with no `trace_id`, and core " <>
                 "says it is always present"

        assert payload["trace_id"] ==
                 Plug.Conn.get_resp_header(conn, "x-trace-id") |> List.first(),
               "#{label(operation)} answered #{conn.status} with a `trace_id` that does not " <>
                 "match its X-Trace-Id header, and core says support starts from that id"
      end
    end

    test "a 406 carries `not_acceptable`, not `internal`" do
      assert CourierWeb.Problem.for_status(406) == :not_acceptable
      assert CourierWeb.Problem.for_code(:not_acceptable) == {406, "Not acceptable"}
    end

    test "every status courier can answer has its own code, not the `internal` fallback" do
      for status <- [400, 401, 404, 406, 422, 500] do
        assert CourierWeb.Problem.for_status(status) != :internal or status == 500,
               "#{status} resolves to the `internal` code, so a client branching on " <>
                 "`code` is told courier failed internally whatever actually happened"
      end
    end
  end


  defp guarded_operations do
    CourierWeb.Router.__routes__()
    |> Enum.filter(fn route ->
      path = String.replace(route.path, ~r/:[a-z_]+/, @id)
      verb = route.verb |> to_string() |> String.upcase()

      case Phoenix.Router.route_info(CourierWeb.Router, verb, path, "") do
        %{pipe_through: pipelines} -> :idempotent in pipelines
        _no_such_route -> false
      end
    end)
    |> MapSet.new(fn route ->
      Paths.normalise_operation(route.verb |> to_string() |> String.upcase(), route.path)
    end)
  end

  defp idempotent_in_router?(operation) do
    MapSet.member?(guarded_operations(), operation)
  end

  defp provoke_malformed_body(operation) do
    if signed_webhook?(operation) do
      body = "{not json"
      {body, headers} = Courier.TestSupport.FakeResend.signed(body)

      conn =
        headers
        |> Enum.reduce(build_conn(), fn {name, value}, acc ->
          put_req_header(acc, name, value)
        end)
        |> put_req_header("content-type", "application/json")
        |> dispatch(CourierWeb.Endpoint, :post, fill(elem(operation, 1), @id), body)

      conn.status
    else
      provoke(operation, malformed_body: true)
    end
  end

  defp signed_webhook?(operation) do
    {_method, path} = operation

    case operation_block(path) do
      nil ->
        false

      block ->
        Enum.any?(block, fn {_indent, text, _n} -> String.contains?(text, "webhookSignature") end)
    end
  end

  defp operation_block(path) do
    lines = document_lines()

    with {_indent, _text, start} <-
           Enum.find(lines, fn {indent, text, _n} -> indent == 0 and text == "paths:" end),
         block =
           lines
           |> Enum.drop_while(fn {_i, _t, n} -> n <= start end)
           |> Enum.take_while(fn {indent, _t, _n} -> indent > 0 end),
         [path_level | _rest] <- block |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() do
      case Enum.find(block, fn {indent, text, _n} ->
             indent == path_level and String.trim_trailing(text, ":") == path
           end) do
        nil ->
          nil

        {indent, _text, number} ->
          block
          |> Enum.drop_while(fn {_i, _t, n} -> n <= number end)
          |> Enum.take_while(fn {i, _t, _n} -> i > indent end)
      end
    else
      _no_paths_block -> nil
    end
  end

  defp document_lines do
    @document
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      stripped = String.trim_leading(line, " ")

      if stripped == "" or String.starts_with?(stripped, "#") do
        []
      else
        [
          {String.length(line) - String.length(stripped), String.trim_trailing(stripped), number}
        ]
      end
    end)
  end

  defp idempotency_conflict({method, path} = operation) do
    url = fill(path, @id)
    key = "11111111-1111-1111-1111-111111111111"
    conn = put_req_header(build_conn(), "x-courier-account", @account)

    first =
      conn |> put_req_header("idempotency-key", key) |> send(method, url, conflict_body("a"))

    second =
      conn |> put_req_header("idempotency-key", key) |> send(method, url, conflict_body("b"))

    unless first.status in 200..299 do
      raise """
      `Idempotency-Key`, so no response was stored and the second request cannot be a \
      replay. The 409 check below needs the first one to be a 2xx: a request that did not \
      succeed releases its key on purpose, so that a client which fixed the request and \
      retried with the same key gets its new answer rather than a 409.
      """
    end

    _ = operation
    body(second)
  end

  defp conflict_body(suffix) do
    %{url: "https://hooks.example.com/idempotency-#{suffix}"}
  end


  defp success?("2" <> _), do: true
  defp success?(_), do: false

  defp label({method, path}), do: "#{method} #{path}"

  defp undeclared(operations, status, responses) do
    """

    A status a client can receive and the document does not describe is a case the
    client has to handle with no documentation: a generated client falls through to
    whatever its default branch is, and courier's envelope is the shape that branch
    will receive.
    """
  end

  defp fill(path, id), do: String.replace(path, ~r/\{[^}]+\}/, id)

  defp conn_for({method, path}, opts) do
    url = fill(path, Keyword.get(opts, :id, @id))
    conn = build_conn()

    conn =
      if Keyword.get(opts, :anonymous, false) do
        conn
      else
        put_req_header(conn, "x-courier-account", @account)
      end

    conn =
      if accept = opts[:accept] do
        put_req_header(conn, "accept", accept)
      else
        conn
      end

    if opts[:malformed_body] do
      conn
      |> put_req_header("content-type", "application/json")
      |> send(method, url, "{not json")
    else
      send(conn, method, url)
    end
  end

  defp safe_conn_for(operation, opts) do
    operation |> conn_for(opts)
  rescue
    Phoenix.NotAcceptableError -> nil
  end

  defp provoke(operation, opts) do
    operation |> conn_for(opts) |> Map.fetch!(:status)
  rescue
    error in [Phoenix.NotAcceptableError] -> error.plug_status
  end

  defp send(conn, method, url), do: send(conn, method, url, nil)

  defp send(conn, method, url, nil) do
    case String.upcase(method) do
      "GET" -> get(conn, url)
      "POST" -> post(conn, url, %{})
      "PUT" -> put(conn, url, %{})
      "PATCH" -> patch(conn, url, %{})
      "DELETE" -> delete(conn, url)
    end
  end

  defp send(conn, method, url, body) do
    Phoenix.ConnTest.dispatch(conn, CourierWeb.Endpoint, method_atom(method), url, body)
  end

  defp method_atom(method), do: method |> String.downcase() |> String.to_existing_atom()

  defp problem_json?(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> List.first()
    |> Kernel.||("")
    |> String.starts_with?("application/problem+json")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp examples do
    reusable_response_lines()
    |> Enum.reduce({[], nil}, fn
      {line, number}, {found, nil} ->
        if problem_type?(line),
          do: {found, {number, String.replace_prefix(String.trim(line), "type: ", "")}},
          else: {found, nil}

      {line, _number}, {found, {type_line, type}} ->
        if String.starts_with?(String.trim(line), "code: "),
          do: {found ++ [%{line: type_line, type: type, code: code_of(line)}], nil},
          else: {found, {type_line, type}}
    end)
    |> elem(0)
  end

  defp reusable_response_lines do
    indexed = @document |> File.read!() |> String.split("\n") |> Enum.with_index(1)

    case Enum.find(indexed, fn {line, _n} -> line == "  responses:" end) do
      nil ->
        []

      {_line, number} ->
        indexed
        |> Enum.drop(number)
        |> Enum.take_while(fn {line, _n} ->
          String.trim(line) == "" or String.starts_with?(line, "    ")
        end)
    end
  end

  defp problem_type?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "type: https://docs.anywaye.com/errors/") and
      not String.starts_with?(line, "              ")
  end

  defp code_of(line) do
    line |> String.trim() |> String.replace_prefix("code: ", "") |> String.trim("\"")
  end

  defp render_errors_json? do
    :courier
    |> Application.get_env(CourierWeb.Endpoint, [])
    |> Keyword.get(:render_errors, [])
    |> Keyword.get(:formats, [])
    |> Keyword.get(:json) == CourierWeb.ErrorJSON
  end
end
