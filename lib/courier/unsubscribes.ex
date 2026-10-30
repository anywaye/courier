defmodule Courier.Unsubscribes do
  @moduledoc """
  RFC 8058 one-click unsubscribe: the header on the message, and the door it opens.

  Gmail's and Yahoo's bulk-sender requirements (in force since June 2024) are
  about a `List-Unsubscribe` header whose HTTPS URI a mail client POSTs to on the
  recipient's behalf, with no session and no human in the loop. A courier that
  sends bulk mail without it is a courier whose bulk mail lands in spam, so this is
  the deliverability gate rather than a feature.

      iex> {:ok, message} = decorate_for(:product_update, user_id, message)
      iex> message.headers["List-Unsubscribe-Post"]
      "List-Unsubscribe=One-Click"


  | § | requirement | this module |
  | --- | --- | --- |
  | 3.1 | one `List-Unsubscribe` header containing one **HTTPS** URI | `decorate/2` |
  | 3.1 | one `List-Unsubscribe-Post: List-Unsubscribe=One-Click` | `decorate/2` |
  | 3.1 | the URI carries an opaque, hard-to-forge component | `Courier.UnsubscribeToken` |
  | 3.1 | the POST must not carry cookies or authorization | `CourierWeb.UnsubscribeController` |
  | 3.1 | **the sender must not return a redirect** | the controller answers 200 in place |
  | 3.2 | the receiver POSTs to the same URI a person would GET | one route, two verbs |
  | 4 | DKIM covering both headers, in the `h=` tag | **not courier's — see below** |

  **§4 is the one requirement this repository does not meet, and it cannot.**
  RFC 8058 §4 requires a valid DKIM signature covering `List-Unsubscribe` and
  `List-Unsubscribe-Post` and listed in `h=`, and §3.2 says a receiver that finds
  no such signature "SHOULD NOT offer a one-click unsubscribe for that message".
  courier submits through `Swoosh.Adapters.SMTP` to a relay and holds no private
  key for the sending domain, so the signing is the relay's — the same place SPF,
  DMARC and everything else about the sending domain lives. The consequence is
  worth stating rather than hiding: **if the relay does not DKIM-sign, the header
  is on the wire and the mail client ignores it.** That is an operational fact
  about the relay, and the header is not a substitute for it.


  `base_url/0` reads `CourierWeb.Endpoint.url/0` rather than taking a setting, and
  the reason is that there is no other honest source: the one an operator sets is
  `PHX_HOST`, which `config/runtime.exs` already turns into
  `url: [host: host, port: 443, scheme: "https"]`. So in production the header
  courier writes is an **HTTPS** URI as §3.1 requires, and it is the same host
  Phoenix uses for its own generated URLs — one setting, one answer, and no
  variable that can be right for the endpoint and wrong for the header.

  `Courier.UnsubscribeHeadersTest` asserts the scheme from **production's
  configuration** rather than from this paragraph.


  It writes a row in `email_suppressions` with `provider: "unsubscribe"`, a
  `reason`, the address, the notification type, the user, and **no `state`** — plus
  a `courier.notification.suppressed` event in the same transaction. The
  idempotency is the same `(provider, provider_event_id)` unique index every
  provider report uses, keyed on the token's id, so a second `POST` is a
  `:duplicate` rather than a second row.


  A bounce and a complaint carry a `state` and refuse **every** notification type
  courier sends, because they are facts about the MAILBOX. `Courier.Deliver`
  consults this table for a password reset exactly as firmly as it does for a
  newsletter. An unsubscribe is an instruction about **one** type, so it carries
  no state at all:

      state: nil   ->  invisible to Courier.Suppressions.state/1
                   ->  invisible to find/1 and to suppressed?/1
                   ->  visible to Suppressions.unsubscribed?(email, type)

  A `nil` state is not a new shape for this table: the fold in `state/1` already
  ignores rows with no state, and that is exactly how a soft bounce "records
  nothing". So the precedence the moduledoc boasts — "`:suppressed` outranks
  `:undeliverable`, and a later bounce cannot withdraw a complaint" — is
  **untouched**, and so is every query on the table.

  And the alternative was measured rather than assumed. Writing the unsubscribe as
  a `notification_preferences` row — which is what "the user's own answer" sounds
  like, and which is what the first draft of this packet did — is **not
  available**: that table's `account_id` is `NOT NULL`, and the account is
  recorded by whoever writes first. An unsubscribe has no principal, so the row
  would have to carry the account that sent the mail, which is a **tenancy claim**
  made for a user id an authenticated caller chose. Two accounts could then
  disagree about who owns a person's settings, and the account that actually owns
  the user would get a 404 from a route that worked yesterday. Writing the answer
  where the table has no tenancy column at all is the direction in which the worst
  case is "the user stops getting this one kind of mail".


  **The answer is immutable and no route removes it.** `Courier.Suppressions`'s
  rows are immutable by design and this is one of them, so a recipient who
  unsubscribes from a product update in error cannot put it back through any
  surface courier has, and the only remedy today is another address. That is a
  real cost and it belongs with the first bulk type rather than with this
  endpoint: a route that clears an unsubscribe is one `DELETE` on this table and
  an authenticated caller, and it is deliberately **not** added here — a delete on
  an immutable table is a decision about what "immutable" means, and it is not one
  to make in the same commit as the thing it would undo. The alternative costs
  more than it saves: courier sends no bulk mail today, so nothing is being taken
  away from anybody yet, whereas a wrong tenancy claim breaks a route that works.

  The `reason` is what makes the row readable to an operator: it says who wrote it
  and why, which is the same reason `reason` exists for a provider's own words.


  `Courier.Events` has carried a builder for `courier.notification.suppressed`
  since courier-01, and `anywaye.yml` has declared the type, with no caller — the
  moduledoc says so and says the sentence to argue with is `Courier.Deliver`'s
  "no mail, no event, no record of a send that did not happen". It is not
  contradicted here: **this is not a send that was refused, it is a standing
  answer that changed**, and the type's schema is exactly that —
  `subject` the user id, `data` `user_id` / `notification_type` / `email` /
  `reason`, and **no `message_id`**, because no message was rendered and there is
  none to name. `reason` is `preference_off`, one of the three values core's
  `suppressed.schema.json` freezes, and it is the right one of the three: the user
  turned the type off.

  A new event type would have needed a core payload schema this repository does
  not own, and would have left the one courier already declares with its first
  caller still empty.


  An MUA is entitled to retry: a `POST` that timed out is a `POST` courier cannot
  distinguish from one that worked. So the second call answers the **same 200 with
  the same body**, writes nothing, and publishes nothing — `{:ok, :duplicate, row}`
  from the index courier already had, and the event is published only on `:new`.
  The alternative, a 409, would send the mail client round a retry loop over
  something that is already true, which is the argument
  `Courier.InboundReports` makes about a redelivered provider report and the same
  argument in a different table.

  There is no `Idempotency-Key` here, for the reason `POST /inbound/resend` has
  none: the header is scoped to a principal, and this route has none by RFC 8058
  §3.1's own instruction that the request carry no authorization at all.


  `decorate_for/3` is called by `Courier.Deliver` inside the transaction that sends
  the mail, so a provider that refuses rolls the token row back with the send. A
  token for a message nobody received is a live credential for an unsubscribe
  nobody was ever offered, which is the same "row that lies" the outbox exists to
  prevent.


  All three of courier's types are `:transactional` — see `Courier.Mailers.kinds/0`
  for why, which includes that adding a bulk type is a change in **core** rather
  than here. So `decorate_for/3` returns the message untouched for every type
  courier can currently send, and that is asserted over real rendered messages for
  all three. The positive half of the gate is asserted where it can be asserted
  honestly: on a real rendered message the function decorates, and on the wire a
  real SMTP server received.
  """

  import Ecto.Query

  alias Courier.Events
  alias Courier.Mailers
  alias Courier.OutboxEvent
  alias Courier.Repo
  alias Courier.Suppression
  alias Courier.Suppressions
  alias Courier.UnsubscribeToken

  require Logger

  @list_unsubscribe "List-Unsubscribe"
  @list_unsubscribe_post "List-Unsubscribe-Post"

  @one_click "List-Unsubscribe=One-Click"

  @reason "preference_off"

  @provider "unsubscribe"

  @why "one-click unsubscribe (RFC 8058)"

  @typedoc """
  What one unsubscribe attempt did.

  `:recorded` and `:already_unsubscribed` are both successes and both answer the
  same HTTP body. They are separate because a caller counting "did this change
  anything" is a different question from "did this succeed", and
  `Courier.InboundReports` keeps the same three apart for the same reason.
  """
  @type outcome :: :recorded | :already_unsubscribed

  @doc "The RFC 8058 §5 header name for the one-click signal."
  @spec one_click_header() :: String.t()
  def one_click_header, do: @list_unsubscribe_post

  @doc "The exact value that header must carry, byte for byte."
  @spec one_click_value() :: String.t()
  def one_click_value, do: @one_click

  @doc "The `reason` this path publishes, transcribed from core's payload schema."
  @spec reason() :: String.t()
  def reason, do: @reason

  @doc "The `provider` the row it writes is recorded under, beside `\"resend\"`."
  @spec provider() :: String.t()
  def provider, do: @provider

  @doc """
  The path a token is reached at, without the host.

  One definition, and the router does not read it — a router cannot, it matches a
  pattern — so what holds the two together is `Courier.UnsubscribesTest`, which
  asks the ROUTER whether it serves this exact path and the header whether it
  points at it. A rename that moved one of them is a header pointing at a 404, and
  the failure mode of that is a silently broken deliverability requirement.
  """
  @spec path_prefix() :: String.t()
  def path_prefix, do: "/unsubscribe"

  @doc """
  courier's public base URL, with no trailing slash.

  `CourierWeb.Endpoint.url/0`, read through `Application.get_env/2` rather than
  called, and the reason is start order: the endpoint's own `url/0` is generated
  against configuration cached in `:persistent_term` when the endpoint starts,
  and `mix test` configures the endpoint with `server: false`. Reading the config
  directly is the same answer with no dependency on a process being up, which
  matters because the only caller is the send path and a send must not depend on
  the listener.
  """
  @spec base_url() :: String.t()
  def base_url do
    :courier
    |> Application.get_env(CourierWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> url_from()
  end

  defp url_from(url) do
    scheme = Keyword.get(url, :scheme, "http")
    host = Keyword.get(url, :host, "localhost")
    port = Keyword.get(url, :port)

    base = "#{scheme}://#{host}"

    if port in [nil, default_port(scheme)] do
      base
    else
      "#{base}:#{port}"
    end
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_other), do: nil

  @doc """
  The absolute `List-Unsubscribe` URI for `token`.

  A single angle-bracketed URI and nothing else. RFC 2369's header is a
  comma-separated list and §3.1 says the header "MAY contain other non-HTTP/S
  URIs such as MAILTO:" — courier adds none, and that is a decision: a
  `mailto:` fallback is a second door that needs an inbox round trip and a
  human, and §3.1's whole subject is the case where there is no human.
  """
  @spec url(String.t()) :: String.t()
  def url(token) when is_binary(token), do: "#{base_url()}#{path_prefix()}/#{token}"

  @doc """
  Adds the two headers to a message, and mints nothing.

  Public and separated from `decorate_for/3` so the header construction can be
  asserted on its own, and so a caller that already has a token — a test proving
  the wire, a future resend of a stored message — can decorate without a row.

  Idempotent on the same message: `Swoosh.Email.header/3` replaces by name, so
  decorating twice leaves the second value rather than two headers, which is the
  RFC 8058 §3.1 requirement of "**one** `List-Unsubscribe` header field and one
  `List-Unsubscribe-Post` header field".
  """
  @spec decorate(Swoosh.Email.t(), String.t()) :: Swoosh.Email.t()
  def decorate(message, token) do
    message
    |> Swoosh.Email.header(@list_unsubscribe, "<#{url(token)}>")
    |> Swoosh.Email.header(@list_unsubscribe_post, @one_click)
  end

  @doc """
  Mints the token a message of `type` should carry, and puts the headers on it.

  **This is the send path's call site**, and it is one function so that the whole
  conditional — is this bulk, mint, decorate — is a single decision a test can
  drive on a real rendered message rather than something spread across the
  transaction in `Courier.Deliver`.

  For a `:transactional` type it returns the message **untouched** and mints
  nothing: no row, no headers. That is the whole of the negative case, and it is
  the case every type courier can currently send takes.

  The address the token records is read out of **the message** rather than passed
  in, so a token can never be minted for a mailbox the message was not addressed
  to. Two copies of the same address in one send path is a way for the preference
  an unsubscribe writes and the mail that carried the link to disagree.
  """
  @spec decorate_for(atom() | Mailers.type(), Ecto.UUID.t() | String.t(), Swoosh.Email.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, Ecto.Changeset.t()}
  def decorate_for(type, user_id, %Swoosh.Email{} = message) do
    if Mailers.bulk?(type) do
      with {:ok, token} <- issue(user_id, type, recipient(message)) do
        {:ok, decorate(message, token)}
      end
    else
      {:ok, message}
    end
  end

  @doc """
  Mints one token for `(user_id, type, email)` and returns **the token itself**.

  The only function in this module that hands out the plaintext, and it exists
  because the caller has to put it in a header. Nothing can read it back: the row
  holds a digest, and `find/1` matches on that.

  The token is 32 bytes of `:crypto.strong_rand_bytes/1`, so two tokens are never
  equal and the unique index is a backstop rather than the mechanism.
  """
  @spec issue(Ecto.UUID.t() | String.t(), Mailers.type(), String.t()) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t()}
  def issue(user_id, type, email) do
    token = UnsubscribeToken.generate()

    %UnsubscribeToken{}
    |> UnsubscribeToken.changeset(%{
      token_digest: UnsubscribeToken.digest(token),
      user_id: user_id,
      notification_type: to_string(type),
      email: email
    })
    |> Repo.insert()
    |> case do
      {:ok, _row} -> {:ok, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The row `token` names, or `:error`.

  `:error` for a token that is not a token's shape as well as for one courier
  never issued, and the two are not told apart: the endpoint answers 404 either
  way, so distinguishing them here would be a distinction with no consequence and
  one more thing to get wrong. `Courier.Inbound.Signature` draws the same line
  between a refusal a caller can act on and one it cannot.
  """
  @spec find(term()) :: {:ok, UnsubscribeToken.t()} | :error
  def find(token) when is_binary(token) and token != "" do
    case Repo.one(by_digest(UnsubscribeToken.digest(token))) do
      %UnsubscribeToken{} = row -> {:ok, row}
      nil -> :error
    end
  end

  def find(_not_a_token), do: :error

  @doc """
  Acts on `token`: the recipient's answer is recorded, and the change is announced.

  Returns `{:ok, :recorded}`, `{:ok, :already_unsubscribed}`, or `{:error, reason}`
  — and the two successes are the same HTTP body, because a mail client that
  retried a `POST` courier already honoured must not be told it failed.

  **The row and the event are written in one transaction**, and the rule is
  `Courier.InboundReports`'s: there is no answer without its announcement, and no
  announcement about an answer courier does not hold. The one asymmetry is that an
  event courier cannot build is a rollback rather than a log line, because here
  there is nothing to fall back on — the `courier.notification.suppressed`
  builder's payload is four fields courier already has on the token, so an event
  it cannot build means the table is not what this module thinks it is.

  **The duplicate is answered by asking first**, and that is not a different
  mechanism from the index — it is the workaround `Suppressions.find_by_event/2`
  documents at length: `unsubscribe/1` finds a duplicate by inserting and catching
  the violation, which cannot work inside a transaction because PostgreSQL has
  already aborted it by then. So the lookup asks, the insert still loses the index
  if two identical `POST`s race, and the loser rolls back for a retry.
  """
  @spec unsubscribe(term()) :: {:ok, outcome()} | {:error, term()}
  def unsubscribe(token) do
    case find(token) do
      {:ok, row} -> record(row)
      :error -> {:error, :unknown_token}
    end
  end

  defp record(row) do
    case Repo.transaction(fn ->
           case Suppressions.find_by_event(@provider, row.id) do
             %Suppression{} -> :already_unsubscribed
             nil -> insert(row)
           end
         end) do
      {:ok, outcome} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert(row) do
    case Suppressions.unsubscribe(attrs(row)) do
      {:ok, :new, _suppression} -> publish(row)
      {:ok, :duplicate, _row} -> Repo.rollback({:concurrent_duplicate, row.id})
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp attrs(row) do
    %{
      email: row.email,
      provider: @provider,
      provider_event_id: row.id,
      notification_type: row.notification_type,
      user_id: row.user_id,
      reason: @why
    }
  end

  defp publish(row) do
    attrs = %{
      type: Events.suppressed_type(),
      subject: row.user_id,
      data: %{
        "user_id" => row.user_id,
        "notification_type" => row.notification_type,
        "email" => row.email,
        "reason" => @reason
      }
    }

    case %OutboxEvent{} |> OutboxEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _event} -> :recorded
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp by_digest(digest) do
    from token in UnsubscribeToken, where: token.token_digest == ^digest, limit: 1
  end

  defp recipient(%Swoosh.Email{to: [{_name, address} | _]}), do: address

  defp recipient(%Swoosh.Email{}) do
    Logger.error("cannot mint an unsubscribe token: the message has no recipient address")

    nil
  end
end
