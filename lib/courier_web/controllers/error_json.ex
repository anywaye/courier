defmodule CourierWeb.ErrorJSON do
  @moduledoc """
  Every non-2xx response courier sends, in the one shape core requires
  (`core/docs/openapi-conventions.md`).

  This module is what Phoenix calls for a request that failed before a
  controller could answer it — an unknown route, a 500 — and it is why those
  responses are the same envelope as the ones a controller sends deliberately.
  `CourierWeb.Problem` builds the envelope; this decides which code a status
  means.

  The assigns are the request's (`CourierWeb.Plugs.Trace` put the trace id and the
  path there before the router ran), so a 404 for a path courier does not serve
  still carries the same id as its `X-Trace-Id` header.
  """

  alias CourierWeb.Problem

  def render(template, assigns) do
    status = status(template, assigns)
    code = Problem.for_status(status)

    Problem.build(assigns, status, code, detail(status, code))
  end

  defp status(_template, %{status: status}) when is_integer(status), do: status
  defp status(template, _assigns), do: template |> Path.rootname() |> String.to_integer()

  defp detail(404, :not_found), do: "There is no route for that request."
  defp detail(400, :bad_request), do: "The request could not be understood."
  defp detail(422, :validation_failed), do: "The request was not valid."
  defp detail(_status, _code), do: "The request could not be completed."
end
