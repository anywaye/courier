defmodule CourierWeb.ErrorJSONTest do
  @moduledoc """
  Every non-2xx response courier sends is core's problem+json
  (`core/docs/openapi-conventions.md`), and this is where the ones Phoenix
  renders by itself are pinned: a request that matched no route, and a request
  that blew up, must be the same envelope as the ones a controller sends
  deliberately.

  The shape this file used to assert — `%{errors: %{detail: "Not Found"}}`, the
  Phoenix default the generated application shipped with — is not a cafaye error
  body. The endpoints and the clients in this platform are written against
  `application/problem+json` with a stable `code` and a `trace_id`, so
  courier-02 replaced it. `CourierWeb.NotificationPreferencesControllerTest`
  covers the same envelope as a client sees it, over a real request.

  Rendering is `render/2` on its own here — the assigns a request would leave
  behind are the interesting part and are exercised end to end by the
  controller test, so the unit here is about the code and title.
  """

  use ExUnit.Case, async: true

  alias CourierWeb.ErrorJSON

  test "renders 404 as not_found" do
    assert ErrorJSON.render("404.json", %{}) == %{
             "type" => "https://docs.cafaye.com/errors/not_found",
             "title" => "Not found",
             "status" => 404,
             "detail" => "There is no route for that request.",
             "instance" => nil,
             "code" => :not_found,
             "trace_id" => nil
           }
  end

  test "renders 500 as internal, without the reason" do
    # Terse on purpose: this body is readable by anyone who can reach courier,
    # and it is public. The reason is in the logs, where it belongs.
    assert ErrorJSON.render("500.json", %{}) == %{
             "type" => "https://docs.cafaye.com/errors/internal",
             "title" => "Internal server error",
             "status" => 500,
             "detail" => "The request could not be completed.",
             "instance" => nil,
             "code" => :internal,
             "trace_id" => nil
           }
  end

  test "names the request it was made to and the trace it is answered with" do
    envelope = ErrorJSON.render("404.json", %{instance: "/v1/nope", trace_id: "6f5d4c3b"})

    assert envelope["instance"] == "/v1/nope"
    assert envelope["trace_id"] == "6f5d4c3b"
  end
end
