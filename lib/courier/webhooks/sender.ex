defmodule Courier.Webhooks.Sender do
  @moduledoc """
  The behaviour courier's webhook delivery sends through, and the result it comes
  back as.

  A behaviour rather than a direct `Req` call for the same reason
  `Courier.NatsPublisher` is one: the classification rules below — what counts as
  a success, what is worth retrying, what a `410` means — are courier's policy
  and can be tested without a socket in the room.


  The spec §Delivery success and failure is the whole list, and courier follows it
  rather than inventing a retry rule:

  | response | success | retried | why |
  | -------- | ------- | ------- | --- |
  | `2xx` | yes | — | the definition |
  | `3xx` | no | no | "Following redirects causes unnecessary load on both the sender and the receiver, it's therefore recommended to update the webhook URL instead" |
  | `410 Gone` | no | no | the receiver "should disable the webhook endpoint, and stop sending it messages" |
  | `408`, `429` | no | yes | a timeout and a rate limit both mean "not now" |
  | other `4xx` | no | no | the request is wrong and will stay wrong |
  | `5xx` | no | yes | the receiver is having a bad time |
  | no response | no | yes | nothing answered, which is not evidence the url is wrong |

  `retry_after_seconds` carries the consumer's `Retry-After` so the schedule can
  honour it — the spec asks for that explicitly. It is read only in the
  delta-seconds form; a date form is absent rather than misread as a number.


  Because the caller needs four things and a status code cannot hold them: whether
  it worked, what came back, how long it took, and what the receiver said about
  when to come back. Every one of those is recorded on the delivery row, and a
  tuple with four positions would be a tuple nobody can read at the call site.
  """

  @typedoc "One attempt's outcome."
  @type result :: Result.t()

  defmodule Result do
    @moduledoc """
    What one attempt produced: a verdict, a status (or none), a duration, the
    consumer's `Retry-After`, and the transport error if there was no response at
    all.

    `status_code` is `nil` for a transport failure on purpose. A connection
    refused is not a `0` and is not a `503`; recording a number there would make
    "the receiver answered 500" and "the receiver never answered" the same row,
    and those two need different responses from whoever reads it.
    """

    @type t :: %__MODULE__{}

    defstruct success?: false,
              status_code: nil,
              duration_ms: 0,
              retry_after_seconds: nil,
              error: nil
  end

  @doc """
  Sends one signed request.

  `request` is a map with `url`, `secret`, `msg_id`, `payload` and `timestamp`.
  The `payload` is a binary the caller has already encoded, and the implementation
  signs those exact bytes and sends them.
  """
  @callback send(map()) :: {:ok, Result.t()}

  @doc """
  The sender the delivery pipeline talks to.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:courier, :webhook_sender, Courier.Webhooks.Sender.Req)

  @doc """
  Whether a `Result` is worth trying again.

  The rules are the spec's §Delivery success and failure table, and each refusal
  is a case where retrying spends budget on an answer that will not change.
  """
  @spec retryable?(Result.t()) :: boolean()
  def retryable?(%Result{success?: true}), do: false
  def retryable?(%Result{status_code: status}) when status in 300..399, do: false
  def retryable?(%Result{status_code: 410}), do: false

  def retryable?(%Result{status_code: status}) when status in 400..499 do
    status in [408, 429]
  end

  def retryable?(%Result{}), do: true

  @doc """
  Whether a `Result` means the endpoint should be disabled outright.

  Only `410 Gone`. The spec is unambiguous: a receiver answering `410` is saying
  it is "no longer interested in receiving webhooks from this source", and the
  sender "should disable the webhook endpoint, and stop sending it messages".
  Anything else — a `404`, a `400` — might be a url the customer has not finished
  setting up, and disabling on a guess is how a working integration stops working.
  """
  @spec gone?(Result.t()) :: boolean()
  def gone?(%Result{status_code: 410}), do: true
  def gone?(%Result{}), do: false

  @doc """
  A one-line description of a result, for `webhook_deliveries.error`.

  A `500` on its own does not say whether the receiver answered or the network
  gave up, and the two want different things done about them.
  """
  @spec describe(Result.t()) :: String.t()
  def describe(%Result{success?: true}), do: "delivered"

  def describe(%Result{status_code: nil, error: error}),
    do: "no response: #{inspect(error)}"

  def describe(%Result{status_code: status}), do: "HTTP #{status}"
end
