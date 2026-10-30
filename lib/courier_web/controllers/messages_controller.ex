defmodule CourierWeb.MessagesController do
  @moduledoc """
  `POST /v1/messages` — courier's HTTP door into `Courier.Deliver`.


  **A 200 means the provider accepted the message for delivery and courier wrote
  the `courier.email.delivered` row in the same transaction. It does not mean the
  mail arrived**, because a submission protocol says nothing about arrival and
  courier does not have a delivery receipt to report one with. `data.status` reads
  `accepted` for the same reason and never `delivered`.


  The whole send happens inside the request: the preference is read, the
  suppression list is consulted, the provider is dialled, and the outbox row is
  written before the response is built. A caller learns the real outcome — sent,
  declined, suppressed, or the provider said no — rather than a receipt for an
  intention.

  The alternative was genuinely considered and is queued in
  `Courier.Workers`: a 202 would answer before the suppression check ran, and a
  refusal that arrives after the response is a refusal the caller cannot act on.
  "A caller that cannot tell suppressed from sent will retry forever" is not a
  cost a queued contract can pay cheaply. So the send is synchronous, and the
  availability price of that is stated rather than assumed: courier holds a
  database transaction open across the provider's dial, and a provider that is
  slow makes this request slow. What makes it survivable is that the failure is
  honest — a 503 with a code the caller retries — and that the retry is free under
  an `Idempotency-Key`.


  Four refusals, distinguishable by status and `code` alone, because a client
  branches on those and not on `detail`:

  | outcome | status | `code` | retry? |
  | --- | --- | --- | --- |
  | accepted for delivery | 200 | — | — |
  | the recipient's mailbox is suppressed | 409 | `conflict` | **no** |
  | the request is wrong, the user declined this type, or they unsubscribed from it | 422 | `validation_failed` | after fixing it |
  | the provider refused, or courier cannot deliver | 503 | `unavailable` | yes, same key |

  **The suppression refusal is a 409 and not a 422**, and the argument is that it
  is not a property of the request. A hard bounce and a spam complaint are facts
  about a *mailbox*, recorded by a provider and not chosen by this caller, and the
  table behind them is never exposed through any route — so this response is the
  only place the fact can surface. 409 `conflict` is core's own code for a request
  that collides with the current state of a resource, and it is the status that
  tells a generated client not to try again. A 422 would tell the caller to change
  a request that cannot be changed.

  **A declined preference is a 422**, which is the opposite answer on purpose. The
  user declining is visible to the caller through
  `GET /v1/notification_preferences/{user_id}`, it is changeable through the `PUT`
  beside it, and `errors[]` — which core reserves for 422 and for nothing else —
  can name `type` as the field that is the problem. A machine reading `code` can
  therefore tell the two refusals apart without parsing prose, and a caller that
  retries neither is the point.

  The suppression response deliberately **does not echo the address** and does not
  distinguish the two states in anything but `detail`. `email_suppressions` has no
  `account_id` by design, so a 409 is a fact about a mailbox rather than about
  another tenant's data; quoting the address would make a probe of guessed
  addresses worth running, and a status nobody can read the table for is the same
  posture the suppression packet took when it declined to expose one.

  **The three sending-domain refusals share those two statuses and none of them is
  a 500.** `Courier.Deliver` chooses the sender by the message's from-domain, and
  refuses rather than falling back to the deployment's credential on a domain the
  caller claimed and did not prove. A row this account registered but has not
  verified, or has revoked, is a **409 `conflict`** with the domain named — the
  caller's own resource in a state that forbids sending. A from-domain nobody
  registered is a **422 `validation_failed`**, because registering it is the
  correction. The refusal names the domain and never a credential behind it, dials
  no provider and writes no outbox row; `Courier.DeliverSendingDomainTest` is the
  send path and `CourierWeb.MessagesControllerSendingDomainConfigTest` is this
  door.


  `Courier.MailerAdapter` refuses to boot a courier whose adapter cannot deliver,
  and `Courier.Application` checks the *effective* adapter a second time. This
  action asks the same question a third time, per request, and it exists for a
  reason neither of the other two covers: **the refusal has to be visible to the
  caller.** A courier that booted with a silent adapter and is asked to send would
  otherwise answer 200, write an outbox row and publish `courier.email.delivered`
  for mail nobody receives — the whole failure the adapter work exists to end, one
  layer further out. 503 `unavailable` is the honest answer, and it costs one
  `Application.get_env/2` read.

  It is scoped to production exactly as `verify_boot!/1` is, because `Test` and
  `Local` are the correct adapters in the environments that configure them.


  `conn.assigns.current_account`, from `CourierWeb.Plugs.Principal`, and nowhere
  else — and `CourierWeb.Messages` refuses an `account_id` in a body as the
  unknown field it is. The tenancy of a *send* is the caller's; the tenancy of the
  recipient's mailbox is not a question courier asks, because the suppression table
  has none to ask with.


  One question, and it is answered before the action: is there a principal. The
  default resolver authenticates nobody, so a courier deployed without identity's
  JWT verifier locks this route rather than serving it —
  `test/courier_web/controllers/messages_controller_test.exs` proves the 401, and
  a send endpoint without it would be the platform's open mail relay.
  """

  use CourierWeb, :controller

  require Logger

  alias Courier.Deliver
  alias Courier.MailerAdapter
  alias Courier.Repo
  alias Courier.Tenancy
  alias CourierWeb.Messages
  alias CourierWeb.Problem

  @doc """
  Sends one message, or says exactly why it was not sent.
  """
  def create(conn, params) do
    scoped(conn, fn ->
      with :ok <- deliverable(),
           {:ok, payload} <- Messages.validate(params),
           {:ok, result} <- Deliver.email(params["type"], payload) do
        json(conn, accepted(result, payload))
      else
        {:error, :adapter_cannot_deliver} ->
          adapter_cannot_deliver(conn)

        {:error, fields} when is_list(fields) ->
          validation_failed(conn, fields)

        {:error, {:invalid_payload, changeset}} ->
          invalid_payload(conn, changeset)

        {:error, :unknown_notification_type} ->
          unknown_type(conn)

        {:error, :missing_user_id} ->
          missing_user_id(conn)

        {:error, :suppressed} ->
          declined(conn)

        {:error, {:unsubscribed, _type}} ->
          unsubscribed(conn)

        {:error, {:suppressed_address, state}} ->
          suppressed(conn, state)

        {:error, {:unverified_sending_domain, domain}} ->
          unverified_sending_domain(conn, domain)

        {:error, {:revoked_sending_domain, domain}} ->
          revoked_sending_domain(conn, domain)

        {:error, {:no_sending_domain, domain}} ->
          no_sending_domain(conn, domain)

        {:error, {:delivery_failed, reason}} ->
          provider_refused(conn, reason)

        {:error, {:unsubscribe_failed, reason}} ->
          unsubscribe_failed(conn, reason)

        {:error, {:event_not_recorded, detail}} ->
          not_recorded(conn, detail)

        {:error, :empty_message} ->
          empty_message(conn)

        {:error, reason} when reason in [:from_not_configured, :subject_misconfigured] ->
          misconfigured(conn, reason)
      end
    end)
  end

  defp accepted(result, payload) do
    %{
      data: %{
        message_id: result.message_id,
        event_id: result.event_id,
        notification_type: result.notification_type,
        user_id: payload.user_id,
        status: "accepted"
      }
    }
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

  defp deliverable do
    if adapter_deliverable?(), do: :ok, else: {:error, :adapter_cannot_deliver}
  end

  defp adapter_deliverable? do
    MailerAdapter.config_env() != :prod or MailerAdapter.deliverable?(effective_adapter())
  end

  defp effective_adapter do
    :courier
    |> Application.get_env(Courier.Mailer, [])
    |> Keyword.get(:adapter)
  end

  defp adapter_cannot_deliver(conn) do
    Logger.error(
      "message send refused: courier cannot deliver through " <>
        MailerAdapter.describe(adapter: effective_adapter())
    )

    Problem.send(
      conn,
      503,
      :unavailable,
      "courier cannot deliver mail: the configured adapter never reaches a provider. " <>
        "See COURIER_MAIL_ADAPTER."
    )
  end

  defp validation_failed(conn, fields) do
    Problem.send(conn, 422, :validation_failed, "The message was not valid.", fields)
  end

  defp invalid_payload(conn, changeset) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "The message was not valid: " <>
        Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
          "#{field} #{message}"
        end),
      Enum.map(changeset.errors, fn {field, {_message, opts}} ->
        %{
          "field" => to_string(field),
          "code" => Keyword.get(opts, :code, "invalid_format")
        }
      end)
    )
  end

  defp unknown_type(conn) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "That is not a notification type courier sends.",
      [%{"field" => "type", "code" => "unknown_notification_type"}]
    )
  end

  defp missing_user_id(conn) do
    Problem.send(conn, 422, :validation_failed, "The message names no user.", [
      %{"field" => "user_id", "code" => "required"}
    ])
  end

  defp declined(conn) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "The recipient has asked not to receive this notification by email. " <>
        "Read or change it through GET or PUT /v1/notification_preferences/{user_id}.",
      [%{"field" => "type", "code" => "notification_preferences_disabled"}]
    )
  end

  defp unsubscribed(conn) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "The recipient unsubscribed from this notification type with the one-click " <>
        "unsubscribe link in an earlier message. courier does not send it again, and " <>
        "there is no API that puts it back.",
      [%{"field" => "type", "code" => "unsubscribed"}]
    )
  end

  defp suppressed(conn, :undeliverable) do
    Problem.send(
      conn,
      409,
      :conflict,
      "That mailbox does not exist: it hard-bounced a previous message, and courier " <>
        "does not write to a mailbox that has said it is gone."
    )
  end

  defp suppressed(conn, :suppressed) do
    Problem.send(
      conn,
      409,
      :conflict,
      "That recipient reported a previous message as spam. courier does not write " <>
        "to someone who has asked not to be written to."
    )
  end


  defp unverified_sending_domain(conn, domain) do
    Problem.send(
      conn,
      409,
      :conflict,
      "courier is not sending from #{domain}: this account registered the domain but " <>
        "has not proven it, so the send is refused rather than falling back to the " <>
        "deployment's own sending domain. Finish verification through " <>
        "POST /v1/sending_domains/{id}/verify and send again."
    )
  end

  defp revoked_sending_domain(conn, domain) do
    Problem.send(
      conn,
      409,
      :conflict,
      "courier is not sending from #{domain}: this account revoked the domain, and a " <>
        "revoked domain does not send. There is no API that un-revokes it."
    )
  end

  defp no_sending_domain(conn, domain) do
    Problem.send(
      conn,
      422,
      :validation_failed,
      "courier is not configured to send from #{domain}, and this account has not " <>
        "registered it. Register the domain through POST /v1/sending_domains and " <>
        "prove it before sending from it."
    )
  end

  defp provider_refused(conn, reason) do
    Logger.error("message send failed at the provider: #{inspect(reason)}")

    Problem.send(
      conn,
      503,
      :unavailable,
      "The mail provider did not accept the message. Nothing was sent and nothing " <>
        "was recorded, so this request is safe to retry with the same Idempotency-Key."
    )
  end

  defp unsubscribe_failed(conn, reason) do
    Logger.error(
      "message send refused: the one-click unsubscribe token could not be minted: " <>
        inspect(reason)
    )

    Problem.send(
      conn,
      503,
      :unavailable,
      "courier could not prepare this message's unsubscribe token, so nothing was sent " <>
        "and nothing was recorded. This request is safe to retry."
    )
  end

  defp not_recorded(conn, detail) do
    Logger.error("message sent but its event was not recorded: #{inspect(detail)}")

    Problem.send(
      conn,
      500,
      :internal,
      "The message was accepted but courier could not record it. The send was " <>
        "rolled back, so nothing is delivered and nothing is claimed."
    )
  end

  defp empty_message(conn) do
    Logger.error("message rendered with no body in either format; refusing to send it")

    Problem.send(
      conn,
      500,
      :internal,
      "courier rendered this message with no body, and refused to send it. This is " <>
        "courier's own defect rather than the request's."
    )
  end

  defp misconfigured(conn, reason) do
    Logger.error("courier is misconfigured for this send: #{inspect(reason)}")

    Problem.send(
      conn,
      500,
      :internal,
      "courier is not configured to send this notification."
    )
  end
end
