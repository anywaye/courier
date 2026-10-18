defmodule CourierWeb.NotificationTypesController do
  use CourierWeb, :controller

  alias Courier.NotificationTypes
  alias CourierWeb.Problem

  def index(conn, _params) do
    types = NotificationTypes.list()
    json(conn, %{data: Enum.map(types, &type_json/1)})
  end

  def show(conn, %{"type" => type}) do
    case NotificationTypes.get(type) do
      nil -> not_found(conn)
      nt -> json(conn, %{data: type_json(nt)})
    end
  end

  def create(conn, params) do
    attrs = %{
      "type" => params["type"],
      "kind" => params["kind"] || "transactional",
      "required" => params["required"] || [],
      "subject" => params["subject"],
      "html_template" => params["html_template"],
      "text_template" => params["text_template"]
    }

    case NotificationTypes.create(attrs) do
      {:ok, nt} ->
        conn |> put_status(:created) |> json(%{data: type_json(nt)})

      {:error, %Ecto.Changeset{} = changeset} ->
        validation_failed(conn, changeset)
    end
  end

  def update(conn, %{"type" => type} = params) do
    attrs =
      params
      |> Map.take(["kind", "required", "subject", "html_template", "text_template"])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case NotificationTypes.update(type, attrs) do
      {:ok, nt} -> json(conn, %{data: type_json(nt)})
      {:error, :not_found} -> not_found(conn)
      {:error, %Ecto.Changeset{} = changeset} -> validation_failed(conn, changeset)
    end
  end

  def delete(conn, %{"type" => type}) do
    case NotificationTypes.delete(type) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_found} -> not_found(conn)
    end
  end

  defp type_json(nt) do
    %{
      type: nt.type,
      kind: nt.kind,
      required: nt.required,
      subject: nt.subject,
      html_template: nt.html_template,
      text_template: nt.text_template
    }
  end

  defp not_found(conn) do
    Problem.send(conn, 404, :not_found, "No notification type with that name.")
  end

  defp validation_failed(conn, changeset) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      detail(changeset),
      Enum.map(changeset.errors, fn {field, {_message, _opts}} ->
        %{"field" => to_string(field), "code" => "invalid"}
      end)
    )
  end

  defp detail(changeset) do
    "The notification type was not valid: " <>
      Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
        "#{field} #{message}"
      end)
  end
end