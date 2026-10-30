defmodule Courier.Inbound do
  @moduledoc """
  What a provider tells courier about a recipient, in courier's own words.

  courier sends mail through a provider and then never hears what happened to it:
  a submission protocol's whole reply is "accepted for delivery". So the provider
  reports back, by webhook, and this is the package that turns those reports into
  the events `Courier.Suppressions.ingest/1` acts on.


  `Courier.Suppressions.ingest/1` was written, tested, and documented as "the HTTP
  surface's entry point" — and nothing called it. The suppression table was
  therefore only ever written by tests, permanently empty in production, and a
  customer who hard-bounced was mailed again forever. That is how a sending
  domain's reputation dies, killed by the list meant to prevent it. This package
  is the missing caller, minus the route: parsing, and the verification that has
  to happen before any of it.


      1. Courier.Inbound.Signature   is this POST really from the provider?
      2. Courier.Inbound.Resend      what does this provider's JSON mean?
      3. Courier.Suppressions        what does courier do about it?

  The order is the security property, not a style preference. **An unauthenticated
  body is never parsed.** A hostile or malformed payload cannot reach a decoder, an
  event builder, or the suppression table, because step 1 does not return `:ok`
  until the signature matches. `handle/4` is the whole pipeline in that order and
  `Courier.InboundTest` asserts the parser is never reached.


  A provider's JSON is not courier's to design, and each one brings its own
  vocabulary, its own event names and its own idea of what a bounce is. The
  translation is therefore one module per provider behind `@callback parse/1`, so
  adding Postmark or SES is a new module and a new entry in a dispatch table rather
  than a branch somebody has to find. The vocabulary that comes OUT is courier's
  and is fixed by `Courier.Suppressions.kinds/0`.

  What the behaviour does NOT include is signature verification, on purpose: the
  scheme is a property of the transport, not of the payload vocabulary. Resend
  signs with Svix, which is the scheme Standard Webhooks was standardised from and
  the one `Courier.Webhooks.Signature` already implements for outbound webhooks,
  so a second provider on the same scheme shares the verifier rather than
  reimplementing it. A provider on a DIFFERENT scheme brings its own verifier and
  still implements this behaviour.


    * **The raw body, as a binary.** Never a decoded map. Spec §Signature scheme
      names parse-then-re-serialize as "a very common failure mode" of signature
      verification, and a parser that accepted a map would invite a route that
      parsed before it verified.
    * **A vocabulary courier can act on, or an error.** An event courier cannot
      classify is refused, never defaulted. `Courier.Suppressions` is explicit:
      "an event courier cannot classify is not an event courier acts on.
      Storing an unclassifiable event as 'not suppressed' would be a decision
      courier could not defend."
    * **One event per (report, recipient).** A provider's report may name many
      recipients, and `Courier.Suppressions` acts on one address at a time.
    * **An idempotency key that is stable per report.** `Courier.Suppressions`'s
      unique index is what makes a redelivery harmless, and providers retry.
    * **Nothing else.** Every field not in `Courier.Suppressions.event/0` is
      dropped, and dropping it is the point: `Courier.Suppression`'s moduledoc
      calls a stored payload "a copy of somebody's inbox held for no operational
      reason", and `Courier.Observability` is a span-attribute allowlist that a
      subject line in a map would eventually leak into.
  """

  alias Courier.Inbound.Signature

  @typedoc "One report about one address, ready for `Courier.Suppressions.ingest/1`."
  @type event :: Courier.Suppressions.event()

  @typedoc "The three `svix-` headers, as a map of strings to strings."
  @type headers :: map()

  @doc """
  The name this provider is recorded under in `email_suppressions.provider`, and
  half of the unique index `(provider, provider_event_id)`.
  """
  @callback provider() :: String.t()

  @doc """
  Turns one authenticated provider payload into zero or more courier events.

  Returns `{:ok, events}` where `events` is a list of `t:event/0`, or
  `{:error, reason}` when the payload could not be read or not be classified.

  `{:ok, []}` is a distinct and deliberate answer: the payload was understood and
  courier has no opinion on it. It is not a success the caller should retry and
  not a failure to log loudly.
  """
  @callback parse(body :: binary()) :: {:ok, [event()]} | {:error, term()}

  @doc """
  The whole inbound path for one request, in the order that makes it safe.

  Verifies the signature FIRST and parses only if that succeeded, then hands every
  event to `Courier.Suppressions.ingest/1`.

  Returns `{:ok, results}` where `results` is one entry per event, in the order
  the parser produced them. An entry is whatever `ingest/1` returned:
  `{:ok, :new, row}`, `{:ok, :duplicate, row}`, or `{:ok, :ignored}` for a kind
  courier deliberately does nothing about.

  Returns `{:error, reason}` without touching the database when the request is not
  authentic, is not readable, or is not classifiable — and that refusal is the
  security property: an unsigned or badly-signed payload records nothing, which
  `Courier.InboundTest` asserts against a real `email_suppressions` table rather
  than against a mock.

  `secret` is the provider's signing secret, and it is an ARGUMENT rather than
  something read from application env. `Courier.Webhooks.Verifier` takes its secret
  the same way, and a function that reached into the process dictionary on its own
  could not be tested against a vector and a test could not use two providers at
  once.
  """
  @spec handle(module(), binary(), headers(), String.t(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def handle(provider, body, headers, secret, opts \\ []) do
    with :ok <- Signature.verify(body, headers, secret, opts),
         {:ok, events} <- provider.parse(body) do
      {:ok, Enum.map(events, &Courier.Suppressions.ingest/1)}
    end
  end
end
