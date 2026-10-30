defmodule Courier.TestSupport.RecordingSender do
  @moduledoc """
  A `Courier.Webhooks.Sender` that records the request instead of making it.

  The assertions in `Courier.Webhooks.SenderTest` and
  `Courier.Workers.DeliverWebhookWorkerTest` are about what courier *puts on the
  wire* and *does with the answer* — the header names, the exact body bytes, the
  status classification, the retry budget — and none of that needs a socket. A
  local HTTP server would add a port, a supervisor and a timing dependency to
  assertions that are otherwise pure data, and a webhook test that fails because a
  listener had not come up yet is a test that has stopped being about webhooks.

  Two ways to drive it, because there are two kinds of caller:

    * **In the request** — `response_status`, `response_headers` and `error` are
      keys the caller puts in the request map, so one double answers every case
      without a per-case module. `Courier.Webhooks.SenderTest` uses this.
    * **Through the process dictionary** — `answer_with/1` sets the response the
      *next* sends will get, and `reset/0` clears it. The delivery worker builds
      its own request and has nowhere to put a test's status code, so the test
      tells the double instead. `Courier.Workers.DeliverWebhookWorkerTest` uses
      this.

  `reset/0` clears both the recording and the queued answer, which is what lets
  one test send several requests without reading the first one's.
  """

  alias Courier.Webhooks.Sender
  alias Courier.Webhooks.Signature

  @behaviour Sender

  @doc "The last request this double was handed, or `nil`."
  def last, do: Process.get(:courier_recording_sender_last)

  @doc """
  Sets what the next send will be answered with.

  Accepts a map of `response_status`, `response_headers` and `error`. One-shot:
  the answer is consumed by the next `send/1`, so a test that sends twice
  answers them differently without a per-call setup.
  """
  def answer_with(response) when is_map(response) do
    Process.put(:courier_recording_sender_response, response)
  end

  @doc "Forgets the recorded request and the queued answer."
  def reset do
    Process.delete(:courier_recording_sender_last)
    Process.delete(:courier_recording_sender_response)
  end

  @impl Sender
  def send(request) do
    Process.put(:courier_recording_sender_last, %{
      method: "POST",
      url: request.url,
      headers: Map.merge(%{"content-type" => "application/json"}, signature_headers(request)),
      body: request.payload
    })

    response = Process.delete(:courier_recording_sender_response) || Map.new(request)

    answer(response)
  end

  defp signature_headers(request) do
    Signature.headers(request.secret, request.msg_id, request.timestamp, request.payload)
  end

  defp answer(%{error: error}) do
    {:ok,
     %Sender.Result{
       success?: false,
       status_code: nil,
       duration_ms: 0,
       error: error
     }}
  end

  defp answer(response) do
    status = Map.get(response, :response_status, 200)

    {:ok,
     %Sender.Result{
       success?: status in 200..299,
       status_code: status,
       duration_ms: Map.get(response, :duration_ms, 12),
       retry_after_seconds: retry_after(response)
     }}
  end

  defp retry_after(%{response_headers: headers}) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, ""} -> seconds
          _not_delta_seconds -> nil
        end

      _absent ->
        nil
    end
  end

  defp retry_after(_response), do: nil
end
