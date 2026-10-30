defmodule CourierWeb.WebhookEndpointsController do
  @moduledoc """
  The JSON API over webhook endpoints: `POST`, `GET`, `PATCH`, `DELETE` and
  `POST /:id/test` under `/v1/webhook_endpoints`.


  Every action reads the account from `conn.assigns.current_account`, which
  `CourierWeb.Plugs.Principal` put there, and never from the body. An
  `account_id` in a request is ignored — there is a test for that on `POST` —
  because an account that a caller can name in a body is an account they can
  write to.

  An endpoint in another account is a **404, not a 403**. Core's
  `openapi-conventions.md` is explicit: "Never 404 for authorization failures on a
  resource the caller cannot see — 404 is correct there, 403 is not allowed to leak
  existence." A 403 would tell a caller that `8f3c…` exists and is not theirs,
  which is the only fact the 404 exists to withhold.


  `POST` answers with the `whsec_` signing secret, once. No other action can
  produce it, and there is no action that returns it: a `GET` that could hand out
  a signing secret is a credential endpoint, and a customer who loses theirs
  registers a new endpoint rather than asking courier to re-issue one that might
  have been read on the way.


  Cursor-based, per core: `?limit=` (default 25, capped at 100) and an opaque
  `?cursor=`, answered with `data` and `page`. The cursor is courier's encoding and
  clients must not parse it; one that courier cannot decode is a 422 rather than a
  silent first page.


  `POST /:id/test` sends a signed `ping` and answers with the status the receiver
  gave, so a customer can find out whether their endpoint works without waiting for
  a real event. It is not a delivery and it does not become one: there is no
  `webhook_deliveries` row, no attempt is counted, and a failure does not move the
  circuit — a customer testing their own endpoint and getting a 500 has found out
  something true about the endpoint, and charging their circuit for asking would
  be punishing them for using the diagnostic.
  """

  use CourierWeb, :controller

  alias Courier.Repo
  alias Courier.Tenancy
  alias Courier.WebhookEndpoint
  alias Courier.WebhookEndpoints
  alias Courier.Webhooks.Payload
  alias Courier.Webhooks.Sender
  alias CourierWeb.Problem

  @doc """
  Registers an endpoint and answers 201 with the signing secret.
  """
  def create(conn, params) do
    scoped(conn, fn ->
      attrs = %{
        url: params["url"],
        description: params["description"],
        account_id: conn.assigns.current_account
      }

      case WebhookEndpoints.create(attrs) do
        {:ok, endpoint, secret} ->
          conn
          |> put_status(:created)
          |> json(%{data: endpoint_json(endpoint, secret)})

        {:error, %Ecto.Changeset{} = changeset} ->
          validation_failed(conn, changeset)

        {:error, reason} ->
          blocked(conn, reason)
      end
    end)
  end

  @doc """
  One page of the caller's endpoints.
  """
  def index(conn, params) do
    scoped(conn, fn ->
      account_id = conn.assigns.current_account

      case WebhookEndpoints.page(account_id, params["limit"], params["cursor"]) do
        {:ok, page} ->
          json(conn, %{
            data: Enum.map(page.data, &endpoint_json/1),
            page: page.page
          })

        {:error, :invalid_limit} ->
          invalid_param(conn, "limit", "is not a positive integer")

        {:error, :invalid_cursor} ->
          invalid_param(conn, "cursor", "is not a cursor courier issued")
      end
    end)
  end

  @doc """
  One of the caller's endpoints, or 404.
  """
  def show(conn, %{"id" => id}) do
    scoped(conn, fn ->
      case fetch(conn, id) do
        {:ok, endpoint} -> json(conn, %{data: endpoint_json(endpoint)})
        :error -> not_found(conn)
      end
    end)
  end

  @doc """
  Changes one of the caller's endpoints.
  """
  def update(conn, %{"id" => id} = params) do
    scoped(conn, fn ->
      with {:ok, endpoint} <- fetch(conn, id) do
        attrs =
          params
          |> Map.take(["url", "description", "status"])
          |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

        case WebhookEndpoints.update(endpoint, attrs) do
          {:ok, updated} -> json(conn, %{data: endpoint_json(updated)})
          {:error, %Ecto.Changeset{} = changeset} -> validation_failed(conn, changeset)
          {:error, reason} -> blocked(conn, reason)
        end
      else
        :error -> not_found(conn)
      end
    end)
  end

  @doc """
  Removes one of the caller's endpoints, answering 204.
  """
  def delete(conn, %{"id" => id}) do
    scoped(conn, fn ->
      with {:ok, endpoint} <- fetch(conn, id) do
        case WebhookEndpoints.delete(endpoint) do
          {:ok, _deleted} -> send_resp(conn, 204, "")
          {:error, :not_found} -> not_found(conn)
        end
      else
        :error -> not_found(conn)
      end
    end)
  end

  @doc """
  Sends a signed `ping` to one of the caller's endpoints and reports the answer.
  """
  def ping(conn, %{"id" => id}) do
    scoped(conn, fn ->
      with {:ok, endpoint} <- fetch(conn, id) do
        case ping(endpoint) do
          {:ok, result} ->
            json(conn, %{
              data: %{
                delivered: result.success?,
                status_code: result.status_code,
                duration_ms: result.duration_ms
              }
            })

          {:error, reason} ->
            blocked(conn, reason)
        end
      else
        :error -> not_found(conn)
      end
    end)
  end

  defp ping(%WebhookEndpoint{} = endpoint) do
    with {:ok, secret} <- WebhookEndpoints.secret(endpoint) do
      webhook_id = Courier.Webhooks.Signature.new_id()

      Sender.impl().send(%{
        url: endpoint.url,
        secret: secret,
        msg_id: webhook_id,
        payload: Payload.ping(webhook_id, endpoint.url),
        timestamp: Courier.Webhooks.Signature.unix_now()
      })
    end
  end

  defp fetch(conn, id) do
    case WebhookEndpoints.get(id, conn.assigns.current_account) do
      nil -> :error
      endpoint -> {:ok, endpoint}
    end
  end

  defp scoped(conn, fun) do
    case Tenancy.with_account(Repo, conn.assigns.current_account, fun) do
      {:ok, conn} -> conn
      {:error, _reason} -> unavailable(conn)
    end
  end

  defp unavailable(conn) do
    conn
    |> Problem.send(
      503,
      :unavailable,
      "courier could not scope this request to an account, so it is not serving it."
    )
    |> halt()
  end

  defp endpoint_json(%WebhookEndpoint{} = endpoint), do: endpoint_json(endpoint, nil)

  defp endpoint_json(%WebhookEndpoint{} = endpoint, secret) do
    %{
      id: endpoint.id,
      account_id: endpoint.account_id,
      url: endpoint.url,
      description: endpoint.description,
      status: endpoint.status,
      consecutive_failures: endpoint.consecutive_failures,
      disabled_reason: endpoint.disabled_reason
    }
    |> put_secret(secret)
  end

  defp put_secret(fields, nil), do: fields
  defp put_secret(fields, secret), do: Map.put(fields, :secret, secret)

  defp not_found(conn) do
    Problem.send(conn, 404, :not_found, "No webhook endpoint with that id.")
  end

  defp validation_failed(conn, changeset) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      detail(changeset),
      Enum.map(changeset.errors, fn {field, {_message, opts}} ->
        %{"field" => to_string(field), "code" => code_for(field, opts)}
      end)
    )
  end

  defp blocked(conn, reason) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "That url is one courier will not send webhooks to.",
      [%{"field" => "url", "code" => to_string(reason)}]
    )
  end

  defp invalid_param(conn, field, message) do
    Problem.send(conn, 422, :validation_failed, "The #{field} is not valid.", [
      %{"field" => field, "code" => "invalid_format", "detail" => message}
    ])
  end

  defp code_for(:url, opts) do
    case opts[:constraint] do
      :unique -> "taken"
      _other -> Keyword.get(opts, :code, "invalid_format")
    end
  end

  defp code_for(_field, opts), do: Keyword.get(opts, :code, "invalid_format")

  defp detail(changeset) do
    "The webhook endpoint was not valid: " <>
      Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
        "#{field} #{message}"
      end)
  end
end
