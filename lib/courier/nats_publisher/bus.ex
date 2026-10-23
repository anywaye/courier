defmodule Courier.NatsPublisher.Bus do
  @moduledoc """
  The publisher that puts a courier event on the bus, and the half of
  `Courier.NatsPublisher` this packet adds.

  `Courier.NatsPublisher.Noop` is a test double that hands each envelope back to
  the calling process. It is configured in `config/test.exs` and is **not**
  configured anywhere else, on identity's terms:

      Wiring it into the running service would mark every event published and
      drain the outbox into nowhere, which is worse than the honest accumulation
      an unconfigured broker produces: the rows are the promise, and a promise
      this process keeps by discarding is not a promise.

  ## Why the publish is a JetStream request and not a `PUB`

  `published_at` is the only definition of published, and the relay sets it from
  this function's answer. Core NATS' `Gnat.pub/4` returns when the bytes are on
  the wire and not when the broker has them, so marking a row from that return
  is the silent default the adapter work refuses, reached by a different road: a
  `pub` that vanished between the socket and the broker would be a `delivered`
  event nobody received.

  So this is a request-reply against the same subject. A publish to a subject a
  JetStream stream claims is answered by the stream's publish ack — a JSON body
  carrying `stream` and `seq` — and `{:ok, ack}` from `Gnat.request/4` **is** the
  broker saying it stored the message. "Ack, then mark" is the call, not a
  convention layered around it. gnat's `request` opens a one-shot inbox, publishes
  with that inbox as the reply-to, and returns when the reply lands, which is
  exactly `nats.go`'s `PublishMsg`.

  ## The budget, and why an unanswered publish is a failure

  The relay runs inside a database transaction, and a publish that waits for a
  broker that will never answer holds that transaction open for as long as it
  waits. Identity's `DefaultPublishTimeout` is ten seconds for the same reason:

      A full batch against a fully silent broker drains in at most
      DefaultBatchSize * DefaultPublishTimeout, loudly, with every row left
      claimable.

  The budget is applied here, inside `publish/1`, so every caller is protected
  rather than the one caller that remembered to pass a timeout. `{:error,
  :ack_timeout}` is what the relay records in `last_error`, and the row stays
  unpublished — which is the whole of the difference between a slow broker and a
  wedged one.

  ## The subject is the event type

  Core's event-outbox.md: "No mapping table, no prefix rewriting." A row whose
  `type` is `courier.email.delivered` is published on the subject
  `courier.email.delivered`, which is the subject the `anywaye` stream's
  `courier.>` filter claims. It is read off the envelope, so a new event type
  needs no change here — and the only check is that the type is prefixed with
  this service's own name, which is the fleet's contract rule rather than a
  courier preference.

  ## What it does not do

  It does not create a stream. A JetStream publish to a subject no stream matches
  is refused by the broker, and that failure is the correct answer: it leaves the
  row claimable with the reason recorded, and the event leaves the table only
  once a stream exists that covers its subject. A publisher that created one
  would be a service choosing a stream name, a retention policy and a replication
  factor for the fleet's bus. kit's stack defines `anywaye` with
  `identity.>,billing.>,courier.>,muse.>,darkroom.>`; courier's half of that is
  `courier.>` and it is decided there.
  """

  @behaviour Courier.NatsPublisher

  # How long one publish waits for the broker's ack. See the moduledoc: this is
  # the difference between a slow broker and a wedged one, and the amount of
  # time one row can hold the relay's transaction open.
  @ack_timeout 10_000

  # The subject prefix every courier event type carries. `Courier.Events` is the
  # authority on the catalog; this is the one property of the catalog a publish
  # can check on the way out, and `Courier.NatsPublisherBusTest` asserts it over
  # the whole list so the two cannot drift.
  @subject_prefix "courier."

  @impl Courier.NatsPublisher
  @spec publish(Courier.NatsPublisher.envelope()) :: :ok | {:error, term()}
  def publish(envelope) when is_map(envelope) do
    subject = envelope["type"]

    cond do
      is_nil(subject) ->
        {:error, :no_type}

      not String.starts_with?(subject, @subject_prefix) ->
        # Refused rather than defaulted. A publish on a subject the stream does
        # not claim is a message the broker silently accepts and no consumer
        # reads, which is the same as not publishing with a 200 in the log.
        {:error, "subject_is_not_couriers: #{subject}"}

      true ->
        deliver(subject, Jason.encode!(envelope))
    end
  rescue
    # The envelope is courier's own row, so a payload that will not encode is a
    # row courier wrote and cannot read — a defect, not a reason to mark the row
    # published and never mind.
    error in [Protocol.UndefinedError, Jason.EncodeError] ->
      {:error, "unencodable_envelope: #{Exception.message(error)}"}
  end

  def publish(_envelope), do: {:error, :not_an_envelope}

  # Encoded once, and the same bytes that are signed are the bytes that are sent
  # — core's outbox rule, and the reason this is a binary rather than a map the
  # transport re-serialises.
  defp deliver(subject, payload) do
    case Courier.Nats.connection() do
      {:ok, connection} ->
        request(connection, subject, payload)

      {:error, :not_connected} ->
        {:error, :not_connected}
    end
  end

  # One request per publish, over the one connection the application owns.
  #
  # `receive_timeout` is the budget above, and it bounds the whole round trip
  # rather than the broker's thinking: a connect that never negotiated INFO never
  # answers this at all, so the budget is what stops it hanging.
  defp request(connection, subject, payload) do
    case Gnat.request(connection, subject, payload, receive_timeout: @ack_timeout) do
      {:ok, %{body: body}} ->
        check_ack(IO.iodata_to_binary(body))

      {:error, :timeout} ->
        {:error, :ack_timeout}

      {:error, :no_responders} ->
        # No responder means no JetStream layer on this broker, which is a
        # deployment fact and not a retryable blip: the message was never stored
        # and the row must not be marked.
        {:error, :no_responders}

      {:error, :max_payload_exceeded} ->
        {:error, :payload_too_large}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # `Gnat.request/4` raises on an invalid subject and on a connection that has
    # gone away underneath it. Neither may reach the relay as an exception: a
    # publisher that raises has turned an unreachable broker into a stuck queue.
    error -> {:error, {:gnat, Exception.message(error)}}
  end

  # The broker's answer, read as what it is.
  #
  # A JetStream publish ack carries `stream` and `seq` on success and an `error`
  # object on refusal — 503 with "no responders" folded into it, 404 for a
  # subject no stream claims, 400 for a payload the stream rejects. The refusal
  # is passed on as the reason rather than collapsed into one symbol, because the
  # operator reading `last_error` needs to know whether the stream is missing or
  # the message was wrong.
  #
  # **Every reason is a BINARY or a bare ATOM, and that is not style.**
  # `Courier.Workers.ProcessOutboxWorker.mark_refused/2` records the reason in a
  # `last_error` string column with `to_string/1`, and `to_string/1` raises
  # `Protocol.UndefinedError` on a tuple — which would take the relay down inside
  # its own transaction, and the transaction is the relay. Measured: the first
  # version of this module answered `{:stream_refused, 404, "..."}`, the refusal
  # test raised in `mark_refused/2`, and the row was left with no `last_error`
  # at all. A publisher's reason is text for a column; a publisher that needs
  # structure in it has to put that structure in the text.
  defp check_ack(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_map(error) ->
        {:error, describe_refusal(error)}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {:error, "stream_refused: #{error}"}

      {:ok, %{"stream" => _stream, "seq" => _seq}} ->
        :ok

      {:ok, other} ->
        {:error, "unreadable_ack: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "unreadable_ack: #{inspect(reason)}"}
    end
  end

  defp describe_refusal(error) do
    code = error["code"]
    description = error["description"] || error["err_code"]

    "stream_refused #{code}: #{inspect(description)}"
  end
end
