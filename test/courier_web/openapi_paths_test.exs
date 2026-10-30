defmodule CourierWeb.OpenAPIPathsTest do
  @moduledoc """
  The reader's own tests, and the tests for every normalisation it applies.

  This file exists because the check in `CourierWeb.OpenAPIDocumentTest` is only
  worth having if the thing producing the two sets is itself trustworthy. A
  normaliser is a place a check can be made to pass by a rename that should have
  failed it, so every rule gets a test naming the case it covers — and the
  comparison gets tests that inject faults, because a checker that cannot be
  shown to fail has not been shown to work.

  The fault tests drive the real readers rather than hand-built maps, so the
  thing under test is the code the check runs, not a tidier imitation of it.
  """

  use ExUnit.Case, async: true

  alias Courier.TestSupport.OpenAPIPaths, as: Paths

  defp write_document(lines) do
    path = Path.join(System.tmp_dir!(), "openapi-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "reading paths out of a document" do
    test "it reads a path and the methods under it, and nothing else" do
      document =
        write_document([
          "openapi: 3.1.0",
          "info:",
          "  title: courier",
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      summary: list widgets",
          "    post:",
          "    patch:",
          "    delete:",
          "  /v1/widgets/{id}:",
          "    parameters:",
          "      - $ref: '#/components/parameters/WidgetId'",
          "    get:",
          "    put:",
          "components:",
          "  schemas:",
          "    Widget:",
          "      type: object",
          "  /not_a_path:",
          "    nope: 1"
        ])

      operations = Paths.document_operations!(document)

      assert Map.keys(operations) |> Enum.sort() == [
               {"DELETE", "/v1/widgets"},
               {"GET", "/v1/widgets"},
               {"GET", "/v1/widgets/{}"},
               {"PATCH", "/v1/widgets"},
               {"POST", "/v1/widgets"},
               {"PUT", "/v1/widgets/{}"}
             ]
    end

    test "the spellings it keeps are the document's own, not the normalised key's" do
      document = write_document(["paths:", "  /v1/widgets/{id}:", "    get:"])
      operations = Paths.document_operations!(document)

      assert Map.fetch!(operations, {"GET", "/v1/widgets/{}"})["label"] ==
               "GET /v1/widgets/{id}"
    end

    test "a body key that merely starts with a method name is not an operation" do
      document =
        write_document(["paths:", "  /v1/widgets:", "    get:", "    getaway:", "    posting:"])

      assert map_size(Paths.document_operations!(document)) == 1
    end

    test "comments and blank lines inside the block are skipped" do
      document =
        write_document([
          "paths:",
          "  # the only surface courier ships with a contract",
          "  /v1/widgets:",
          "",
          "    # listing",
          "    get:",
          ""
        ])

      assert map_size(Paths.document_operations!(document)) == 1
    end

    test "the two indentation levels are derived from the document, not assumed" do
      document = write_document(["paths:", "    /v1/widgets:", "        get:", "        post:"])

      assert map_size(Paths.document_operations!(document)) == 2
    end

    test "anything deeper than the operation level is an operation's body, not structure" do
      document =
        write_document([
          "paths:",
          "  /v1/widgets/{id}:",
          "    parameters:",
          "      - $ref: '#/components/parameters/WidgetId'",
          "        description:",
          "          deeper still, inside the list entry",
          "    get:",
          "      responses:",
          "        '200':",
          "          description: ok",
          "          content:",
          "            application/json:",
          "              schema:",
          "                type: object"
        ])

      assert Map.keys(Paths.document_operations!(document)) == [{"GET", "/v1/widgets/{}"}]
    end

    test "a key inside an operation's body that is spelled like a method is not an operation" do
      document =
        write_document([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '200':",
          "          content:",
          "            application/json:",
          "              schema:",
          "                properties:",
          "                  delete:",
          "                    type: boolean",
          "                  patch:",
          "                    type: boolean",
          "    post:",
          "      requestBody:",
          "        content:",
          "          application/json:",
          "            schema:",
          "              properties:",
          "                get:",
          "                  type: string"
        ])

      assert Map.keys(Paths.document_operations!(document)) |> Enum.sort() ==
               [{"GET", "/v1/widgets"}, {"POST", "/v1/widgets"}]
    end

    test "a path item's own fields are not operations" do
      document = write_document(["paths:", "  /v1/widgets:", "    summary: widgets", "    get:"])

      assert map_size(Paths.document_operations!(document)) == 1
    end
  end

  describe "the document reader refuses rather than under-reads" do

    test "a document with no top-level paths: is an error, not an empty check" do
      document = write_document(["openapi: 3.1.0", "info:", "  title: courier"])

      assert_raise RuntimeError, ~r/no top-level `paths:`/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a paths: block with no operations under it is an error" do
      document = write_document(["paths:"])

      assert_raise RuntimeError, ~r/documents no operations/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a path item with no operation under it is an error" do
      document =
        write_document(["paths:", "  /v1/widgets:", "    parameters:", "      - $ref: x"])

      assert_raise RuntimeError, ~r/no operation under/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a path key that does not start with a slash is an error, not normalised" do
      document = write_document(["paths:", "  v1/widgets:", "    get:"])

      assert_raise RuntimeError, ~r/not a valid OpenAPI path/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a direct child of paths: that is neither a path nor a path-item field is an error" do
      document = write_document(["paths:", "  widget:", "    get:"])

      assert_raise RuntimeError, ~r/not a valid OpenAPI path/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a paths: block with one indentation level and no operations is an error" do
      document = write_document(["paths:", "  /v1/widgets:"])

      assert_raise RuntimeError, ~r/documents no operations/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a missing document is an error" do
      assert_raise RuntimeError, ~r/could not read/, fn ->
        Paths.document_operations!("/nonexistent/openapi.yaml")
      end
    end
  end

  describe "reading paths out of the router" do
    test "it reads the router's own route definitions, not a list written by hand" do
      operations = Paths.router_operations!()

      assert Enum.any?(operations, fn {_key, op} ->
               op["path"] == "/v1/webhook_endpoints/:id" and op["method"] == "GET" and
                 op["plug"] == CourierWeb.WebhookEndpointsController and op["action"] == :show
             end)

      assert Enum.any?(operations, fn {_key, op} ->
               op["path"] == "/healthz" and op["method"] == "GET" and
                 op["plug"] == CourierWeb.HealthController
             end)
    end

    test "it records the plug and action, so a failure can say what the router does serve" do
      operations = Paths.router_operations!()

      assert Map.fetch!(operations, {"GET", "/v1/notification_preferences/{}"}) == %{
               "method" => "GET",
               "path" => "/v1/notification_preferences/:user_id",
               "label" => "GET /v1/notification_preferences/:user_id",
               "plug" => CourierWeb.NotificationPreferencesController,
               "action" => :show
             }
    end

    test "a router that defines no routes is an error, not an empty check" do
      defmodule EmptyRouter do
        def __routes__, do: []
      end

      assert_raise RuntimeError, ~r/0 routes/, fn -> Paths.router_operations!(EmptyRouter) end
    end

    test "a module that is not a router at all is an error" do
      assert_raise RuntimeError, ~r/not a Phoenix router/, fn ->
        Paths.router_operations!(Enum)
      end
    end
  end

  describe "normalising the method" do
    test "an atom verb and a string verb are the same operation" do
      assert Paths.normalise_method(:get) == "GET"
      assert Paths.normalise_method("get") == "GET"
      assert Paths.normalise_method("GET") == "GET"

      assert Paths.normalise_operation(:get, "/v1/widgets/{id}") ==
               Paths.normalise_operation("get", "/v1/widgets/:id")
    end

    test "a document that writes GET: and get: is a collision, not a duplicate to keep" do
      document = write_document(["paths:", "  /v1/widgets:", "    get:", "    GET:"])

      assert_raise RuntimeError, ~r/both read as GET \/v1\/widgets/, fn ->
        Paths.document_operations!(document)
      end
    end
  end

  describe "normalising a path parameter" do
    test "{id} in a document and :id in the router are the same operation" do
      assert Paths.normalise_operation("GET", "/v1/webhook_endpoints/{id}") ==
               Paths.normalise_operation("GET", "/v1/webhook_endpoints/:id")
    end

    test "renaming a path parameter is not drift" do
      assert Paths.normalise_operation("GET", "/v1/webhook_endpoints/{id}") ==
               Paths.normalise_operation("GET", "/v1/webhook_endpoints/:endpoint_id")
    end

    test "the parameter name is the only thing erased, and only inside a segment" do
      assert Paths.normalise_path("/v1/widgets/:id") == "/v1/widgets/{}"
      assert Paths.normalise_path("/v1/widgets/:id/parts/:part_id") == "/v1/widgets/{}/parts/{}"
      assert Paths.normalise_path("/v1/widgets/extra") == "/v1/widgets/extra"
      assert Paths.normalise_path("/v1/widgets") == "/v1/widgets"
    end

    test "a path parameter is replaced by a whole segment, never by part of one" do
      assert Paths.normalise_path("/v1/widgets/{id}.json") == "/v1/widgets/{}"
      assert Paths.normalise_path("/v1/widgets/:id.json") == "/v1/widgets/{}"
    end
  end

  describe "normalising a trailing slash" do
    test "a trailing slash is not a difference, and the router is the reason why" do
      assert %{route: "/healthz"} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/healthz/", "")

      assert Paths.normalise_path("/v1/webhook_endpoints/") == "/v1/webhook_endpoints"
      assert Paths.normalise_path("/v1/webhook_endpoints//") == "/v1/webhook_endpoints"
    end

    test "the root path keeps its slash" do
      assert Paths.normalise_path("/") == "/"
    end
  end

  describe "a normaliser that maps two different things onto one" do
    test "two router paths that erase to the same route are an error" do
      defmodule CollidingRouter do
        def __routes__ do
          [
            %{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :a},
            %{verb: :get, path: "/v1/widgets/:name", plug: Enum, plug_opts: :b}
          ]
        end
      end

      assert_raise RuntimeError, ~r/both read as GET \/v1\/widgets\/\{\}/, fn ->
        Paths.router_operations!(CollidingRouter)
      end
    end
  end

  describe "the comparison, pointed at an injected fault" do

    defp document_for(lines), do: lines |> write_document() |> Paths.document_operations!()

    defp router_for(routes) do
      module = :"FaultRouter#{System.unique_integer([:positive])}"

      Module.create(
        module,
        {:def, [], [{:__routes__, [], nil}, [do: Macro.escape(routes)]]},
        Macro.Env.location(__ENV__)
      )

      Paths.router_operations!(module)
    end

    defp widget_routes do
      [
        %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
        %{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :show}
      ]
    end

    test "a document path the router does not serve is reported, and named" do
      document =
        document_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "  /v1/widgets/{id}:",
          "    get:",
          "  /v1/gadgets:",
          "    get:"
        ])

      router = router_for(widget_routes())

      diff = Paths.diff(document, router, %{})

      assert [%{"label" => "GET /v1/gadgets"}] = diff.documented_not_served
      assert diff.served_not_documented == []
    end

    test "a router path the document omits is reported, and named" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])
      router = router_for(widget_routes())

      diff = Paths.diff(document, router, %{})

      assert [%{"label" => "GET /v1/widgets/:id"}] = diff.served_not_documented
      assert diff.documented_not_served == []
    end

    test "a renamed path is reported on both sides, not on whichever one moved" do
      document =
        document_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "  /v1/wodgets/{id}:",
          "    get:"
        ])

      router =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :show}
        ])

      diff = Paths.diff(document, router, %{})

      assert Enum.map(diff.documented_not_served, & &1["label"]) == ["GET /v1/wodgets/{id}"]
      assert Enum.map(diff.served_not_documented, & &1["label"]) == ["GET /v1/widgets/:id"]
    end

    test "a method added to one side only is drift, even though the path matches" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])
      router = router_for([%{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list}])

      router_with_delete =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :delete, path: "/v1/widgets", plug: Enum, plug_opts: :remove}
        ])

      assert Paths.diff(document, router, %{}).served_not_documented == []

      assert [%{"label" => "DELETE /v1/widgets"}] =
               Paths.diff(document, router_with_delete, %{}).served_not_documented
    end

    test "a renamed path parameter is not drift" do
      document = document_for(["paths:", "  /v1/widgets/{widget_id}:", "    get:"])

      router =
        router_for([%{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :show}])

      diff = Paths.diff(document, router, %{})

      assert diff.documented_not_served == []
      assert diff.served_not_documented == []
    end

    test "an exclusion covers the route it names, and the difference says so" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])

      router =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :get, path: "/healthz", plug: Enum, plug_opts: :healthz}
        ])

      excluded = %{Paths.normalise_operation("GET", "/healthz") => "an infrastructure probe"}
      diff = Paths.diff(document, router, excluded)

      assert [%{"label" => "GET /healthz"}] = diff.served_not_documented
      assert diff.unexplained == []

      assert [%{"label" => "GET /healthz", "reason" => "an infrastructure probe"}] = diff.excluded

      assert Paths.describe_drift(diff) =~ "GET /healthz — an infrastructure probe"
    end

    test "an exclusion does not carry over to another method on the same path" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])

      router =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :get, path: "/healthz", plug: Enum, plug_opts: :healthz},
          %{verb: :delete, path: "/healthz", plug: Enum, plug_opts: :remove}
        ])

      excluded = %{Paths.normalise_operation("GET", "/healthz") => "an infrastructure probe"}
      diff = Paths.diff(document, router, excluded)

      assert Enum.map(diff.served_not_documented, & &1["label"]) == [
               "DELETE /healthz",
               "GET /healthz"
             ]

      assert [%{"label" => "DELETE /healthz"}] = diff.unexplained
      assert [%{"label" => "GET /healthz"}] = diff.excluded
    end
  end

  describe "reading responses out of a document" do

    defp responses_for(lines) do
      lines |> write_document() |> Paths.document_responses!()
    end

    defp a_document_with_responses do
      write_document([
        "openapi: 3.1.0",
        "paths:",
        "  /v1/widgets:",
        "    get:",
        "      responses:",
        "        '200':",
        "          description: a page",
        "          content:",
        "            application/json:",
        "              schema:",
        "                type: object",
        "        '400': { $ref: '#/components/responses/BadRequest' }",
        "  /v1/widgets/{id}:",
        "    get:",
        "      responses:",
        "        '200':",
        "          description: one",
        "        '404': { $ref: '#/components/responses/NotFound' }",
        "components:",
        "  responses:",
        "    BadRequest:",
        "      description: bad",
        "      content:",
        "        application/problem+json:",
        "          schema: { $ref: '#/components/schemas/Problem' }",
        "    NotFound:",
        "      description: gone",
        "      content:",
        "        application/problem+json:",
        "          schema: { $ref: '#/components/schemas/Problem' }"
      ])
    end

    test "it reads each operation's statuses, and the keys are bare" do
      responses =
        responses_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '200':",
          "          description: ok",
          "        '404': { $ref: '#/components/responses/NotFound' }",
          "        '500':",
          "          description: broke",
          "components:",
          "  responses:",
          "    NotFound:",
          "      description: gone"
        ])

      assert Map.keys(Map.fetch!(responses, {"GET", "/v1/widgets"})) |> Enum.sort() ==
               ["200", "404", "500"]
    end

    test "a $ref is followed, so a response that says nothing still knows the envelope" do
      responses = a_document_with_responses() |> Paths.document_responses!()

      not_found = Map.fetch!(Map.fetch!(responses, {"GET", "/v1/widgets/{}"}), "404")

      assert not_found.ref == "NotFound"
      assert not_found.problem_json
      assert not_found.ref_schema
    end

    test "an inline response is read as well as a $ref" do
      responses =
        responses_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '200':",
          "          description: ok",
          "        '500':",
          "          description: broke",
          "          content:",
          "            application/problem+json:",
          "              schema:",
          "                $ref: '#/components/schemas/Problem'",
          "components:",
          "  responses:",
          "    Unused:",
          "      description: nothing points at it"
        ])

      internal = Map.fetch!(Map.fetch!(responses, {"GET", "/v1/widgets"}), "500")

      assert internal.ref == nil
      assert internal.problem_json
      assert internal.ref_schema
    end

    test "a $ref to a component the document does not define is an error" do
      assert_raise RuntimeError, ~r/defines no response of that name/, fn ->
        responses_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '404': { $ref: '#/components/responses/Nowhere' }",
          "components:",
          "  responses:",
          "    SomethingElse:",
          "      description: defined, but not the one the response points at"
        ])
      end
    end

    test "an operation with no responses: is an error, not an operation with none" do
      assert_raise RuntimeError, ~r/has no `responses:` block/, fn ->
        responses_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      summary: list",
          "components:",
          "  responses:",
          "    Unused:",
          "      description: nothing points at it"
        ])
      end
    end

    test "a responses: block with nothing in it is an error" do
      assert_raise RuntimeError, ~r/is empty/, fn ->
        responses_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "components:",
          "  responses:",
          "    Unused:",
          "      description: nothing points at it"
        ])
      end
    end

    test "a method inherits only its own responses, not its sibling's" do
      responses =
        responses_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '200':",
          "          description: ok",
          "        '404': { $ref: '#/components/responses/NotFound' }",
          "    post:",
          "      responses:",
          "        '201':",
          "          description: made",
          "components:",
          "  responses:",
          "    NotFound:",
          "      description: gone"
        ])

      assert Map.keys(Map.fetch!(responses, {"GET", "/v1/widgets"})) |> Enum.sort() == [
               "200",
               "404"
             ]

      assert Map.keys(Map.fetch!(responses, {"POST", "/v1/widgets"})) |> Enum.sort() == ["201"]
    end

    test "a path item's own `parameters:` is not an operation with no responses" do
      responses = a_document_with_responses() |> Paths.document_responses!()

      assert Map.keys(responses) |> Enum.sort() == [
               {"GET", "/v1/widgets"},
               {"GET", "/v1/widgets/{}"}
             ]
    end

    test "component_responses! reports the media type and the schema separately" do
      path =
        write_document([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '500': { $ref: '#/components/responses/Lying' }",
          "components:",
          "  responses:",
          "    Lying:",
          "      description: promises courier's shape",
          "      content:",
          "        application/problem+json:",
          "          schema:",
          "            $ref: '#/components/schemas/SomethingElse'"
        ])

      lying = Map.fetch!(Paths.component_responses!(path), "Lying")

      assert lying.problem_json
      refute lying.ref_schema
    end

    test "a document with no components: at all is an error, not an empty set" do
      assert_raise RuntimeError, ~r/no top-level `components:`/, fn ->
        Paths.component_responses!(
          write_document([
            "paths:",
            "  /v1/widgets:",
            "    get:",
            "      responses:",
            "        '200':"
          ])
        )
      end
    end

    test "it reads courier's own document, and every non-2xx there is wired" do
      responses = Paths.document_responses!()

      assert map_size(responses) == 26

      for {_operation, declared} <- responses, {status, response} <- declared do
        if not String.starts_with?(status, "2") do
          assert response.problem_json,
                 "#{status} does not name application/problem+json " <>
                   "(openapi.yaml:#{response.line})"
        end
      end
    end
  end

  describe "the failure message" do
    setup do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])
      router = router_for([%{verb: :delete, path: "/v1/widgets", plug: Enum, plug_opts: :remove}])

      %{message: Paths.describe_drift(Paths.diff(document, router, %{}))}
    end

    test "it names the path, and says which side has it", %{message: message} do
      assert message =~ "openapi.yaml documents 1 operation the router does not serve."
      assert message =~ "GET /v1/widgets"
      assert message =~ "CourierWeb.Router serves 1 operation openapi.yaml does not describe."
      assert message =~ "DELETE /v1/widgets"
    end

    test "it says what to do, in both directions", %{message: message} do
      assert message =~ "add it to `lib/courier_web/router.ex`"
      assert message =~ "delete it from `openapi.yaml`"
      assert message =~ "document it in `openapi.yaml`"
    end

    test "it says why that direction matters, in the direction that 404s a client", %{
      message: message
    } do
      assert message =~ "An endpoint in the menu that answers 404 is a product configured"
    end

    test "it says who serves a router operation, so the next person does not have to grep", %{
      message: message
    } do
      assert message =~ "served by Enum.remove/2"
    end

    test "it points at the two files involved", %{message: message} do
      assert message =~ "test/courier_web/openapi_document_test.exs"
      assert message =~ "test/courier_web/openapi_paths_test.exs"
    end
  end

  describe "reading which operations accept Idempotency-Key" do

    test "it finds the operation that refs the parameter" do
      document =
        write_document([
          "openapi: 3.1.0",
          "paths:",
          "  /v1/widgets:",
          "    post:",
          "      parameters:",
          "        - $ref: '#/components/parameters/IdempotencyKey'",
          "    get:",
          "  /v1/widgets/{id}:",
          "    post:",
          "      parameters:",
          "        - $ref: '#/components/parameters/EndpointId'"
        ])

      assert Map.keys(Paths.document_idempotency_keys!(document)) == [
               {"POST", "/v1/widgets"}
             ]
    end

    test "it finds an inline parameter as well as a $ref" do
      document =
        write_document([
          "openapi: 3.1.0",
          "paths:",
          "  /v1/widgets:",
          "    post:",
          "      parameters:",
          "        - name: Idempotency-Key",
          "          in: header",
          "          schema:",
          "            type: string"
        ])

      assert Map.keys(Paths.document_idempotency_keys!(document)) == [
               {"POST", "/v1/widgets"}
             ]
    end

    test "it does not read one operation's header as another's" do
      document =
        write_document([
          "openapi: 3.1.0",
          "paths:",
          "  /v1/widgets:",
          "    post:",
          "      parameters:",
          "        - $ref: '#/components/parameters/IdempotencyKey'",
          "    get:",
          "      summary: no header here",
          "    patch:",
          "      summary: nor here"
        ])

      assert Map.keys(Paths.document_idempotency_keys!(document)) == [
               {"POST", "/v1/widgets"}
             ]
    end

    test "it normalises the path the way the other readers do" do
      document =
        write_document([
          "openapi: 3.1.0",
          "paths:",
          "  /v1/widgets/{id}/test:",
          "    post:",
          "      parameters:",
          "        - $ref: '#/components/parameters/IdempotencyKey'"
        ])

      assert Map.keys(Paths.document_idempotency_keys!(document)) == [
               {"POST", "/v1/widgets/{}/test"}
             ]
    end

    test "it is empty, not broken, for a document that declares the header nowhere" do
      document =
        write_document([
          "openapi: 3.1.0",
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "    post:"
        ])

      assert Paths.document_idempotency_keys!(document) == %{}
    end

    test "it is the same reader the check uses, not a second implementation" do
      operations = Paths.document_idempotency_keys!("openapi.yaml")

      assert Map.keys(operations) |> Enum.sort() == [
               {"POST", "/v1/messages"},
               {"POST", "/v1/sending_domains"},
               {"POST", "/v1/sending_domains/{}/verify"},
               {"POST", "/v1/webhook_endpoints"},
               {"POST", "/v1/webhook_endpoints/{}/test"}
             ]
    end
  end
end
