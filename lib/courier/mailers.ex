defmodule Courier.Mailers do
  @moduledoc """
  courier composes mail. It does not send it (`Courier.Mailer` does), store it,
  or model users — the payload arrives already keyed the way the platform keys
  its events, and courier renders it.

      iex> build(:welcome, %{user_id: id, email: "kaka@example.com", name: "Kaka", url: url})
      {:ok, %Swoosh.Email{}}

  `build/2` returns the message rather than sending it, which is the seam that
  keeps Swoosh out of the assertions: a built email can be read field by field,
  with no adapter, no mailbox, and no network. `deliver/2` is `build/2` plus
  `Courier.Mailer.deliver/1`.

  ## The six types

  `welcome`, `password_reset`, `team_invitation`, `account_security`,
  `email_change_current` and `email_change_new` are courier's whole catalog.
  Each has its own required fields, and each says so:

  | type               | required                                |
  | ------------------ | --------------------------------------- |
  | `welcome`          | `email`                                 |
  | `password_reset`   | `email`, `url`                          |
  | `team_invitation`  | `email`, `url`, `account_name`, `invited_by` |
  | `account_security` | `email`, `reason`                       |
  | `email_change_current` | `email`, `url`                     |
  | `email_change_new` | `email`, `previous_email`               |
  | `receipt`         | `email`, `amount_display`, `invoice_id` (optional) |

  `account_security` is the password-reset notice's sibling: the notice a
  person is owed when their credentials end. It is rendered from one template
  that branches on `reason` — `password reset` ("your password was changed")
  or `email address changed` ("the email address on your account was moved") —
  because the two facts have different remediations and a notice that does not
  name which one happened forces the reader to guess. The `reason` is required
  because the template cannot render a branch for a reason it was not given.

  `receipt` is the money event's other half: `billing.payment.succeeded`
  carries the recipient (`email`, the recipient fact the payment packet exists
  to give courier — see its `with_recipient`), the amount already rendered by
  the consumer, and the processor's invoice id when the payment came with
  one. It is `:transactional` for the obvious reason a receipt is: a person
  who unsubscribes from mail has not unsubscribed from their own accounting.
  `invoice_id` is the one optional field in the table — a Checkout-backed
  one-off has no invoice — so the template renders the reference line when it
  is present and skips it when it is not, rather than the send being refused
  for a payment shape the platform legitimately produces.

  The two email-change notices are the two halves of one event, and they are
  two types because they are mailed to **two different addresses** with two
  different jobs: `email_change_current` warns the address the account uses
  today that somebody asked to move it (and carries the confirmation link),
  `email_change_new` tells the address the account is moving to where it is
  moving from. Both are security notices, so both are `:transactional` and
  neither carries an unsubscribe header — a person who must act on an address
  change must always be able to receive the mail about it.

  A payload courier cannot send is `{:error, {:invalid_payload, changeset}}`
  rather than a mail with a hole in it: a reset mail with no link, or an
  invitation with nobody to attribute it to, is noise in a person's inbox.

  ## Bulk and transactional, and who decides

  Every type is also a **kind**, and the kind is what decides whether the message
  may carry `List-Unsubscribe` and `List-Unsubscribe-Post` — the headers Gmail and
  Yahoo require of bulk senders and the ones RFC 8058 defines the one-click POST
  for. `kinds/0` is the whole of that decision, it is closed over `types/0`, and
  it is **not** something a caller, a request body, or an operator's configuration
  can set. See the comment on the table for why the default is
  `:transactional`, and `Courier.Unsubscribes` for what the header does when it is
  present.

  ## Configuration

  The sender and the subject lines are configuration
  (`config :courier, :mailing`, with the address overridden from the
  environment in `config/runtime.exs`), because they are the two things an
  operator should be able to reword without touching a module. Subjects are
  templates with `%{key}` placeholders filled from the payload.

  Both are reported as their own errors rather than as a malformed mail: a
  subject template naming a key the payload does not carry
  (`:subject_misconfigured`) or an unconfigured sender
  (`:from_not_configured`) is a deployment that is wrong, not a request that is
  wrong, and the two must not be confused in an operator's logs.

  ## Templates

  Bodies are `EEx` templates under `lib/courier/mailers/templates/`, compiled at
  build time by `Courier.Mailers.Templates` and wrapped in one shared layout per
  format, so every email courier sends is wrapped alike. They are not HEEx: this
  repository's dependency list has no HEEx engine (`phoenix_template` 1.1 with no
  LiveView, no `phoenix_component`), and AGENTS.md's rule is that a dependency is
  not added "just to prepare". The trade is explicit rather than hidden: the one
  free-text field per message, the recipient's `name`, is escaped where it enters
  the template assigns (`Plug.HTML.html_escape/1`), because plain EEx
  interpolates what it is given.
  """

  import Ecto.Changeset

  alias Courier.Mailer
  alias Courier.Mailers.Templates

  @typedoc "The notification types courier sends, and no others."
  @type type :: String.t()

  @typedoc """
  What a message is for, which is not the same question as what it is called.

  `:transactional` is mail the recipient cannot meaningfully refuse: a password
  reset they asked for, a verification of an account they just made, an
  invitation to a team somebody put them on. `:bulk` is mail a person subscribed
  to and can stop receiving.
  """
  @type kind :: :transactional | :bulk

  # `reason` and `previous_email` are the fields not every type uses: only
  # `account_security` branches on the first, only `email_change_new` needs the
  # second. Both are in the shared list rather than the type's own because the
  # payload is normalised over one vocabulary, and a second per-type list would
  # be a second place for a field to be dropped.
  @fields ~w(user_id email name url account_name invited_by role reason previous_email amount_display invoice_id)a
  @payload_types Map.new(@fields, &{&1, :string})
  # Types and kinds are now discovered from registered notifiers. See
  # `Courier.Notifiers`. This module no longer owns the catalog.

  @doc """
  Every notification type courier sends, in the order the platform names them.

  This list is also `Courier.NotificationPreferences`' catalog and the `events`
  in `cafaye.yml`; a new entry here is a row in the manifest in the same commit.
  """
  @spec types() :: [type()]
  def types, do: Courier.Notifiers.types()

  @doc """
  Every type courier sends, paired with what it is for.

  Keys are `types/0`, always — asserted in `Courier.MailersTest`, because a table
  that had fallen behind the catalog would classify nothing and default
  everything, and a default that happens to be right is a default nothing checked.
  """
  @spec kinds() :: %{type() => kind()}
  def kinds do
    Map.new(Courier.Notifiers.types(), fn t -> {t, Courier.Notifiers.kind(t)} end)
  end

  @doc """
  What `type` is for, and therefore whether it may carry `List-Unsubscribe`.

  `:transactional` for a type with no row in the table, on the terms the table's
  comment gives. The default is the safe direction and it is a default rather than
  a refusal: `build/2` has already refused a type courier does not send before
  anything asks this, so the only inputs that reach it are types in `types/0` —
  and if the table ever falls behind, a refusal here would take down a send that
  would otherwise be fine.
  """
  @spec kind(atom() | type()) :: kind()
  def kind(type) do
    Courier.Notifiers.kind(type)
  end

  @doc """
  Whether a message of `type` is bulk mail, and so carries the one-click
  unsubscribe headers (`Courier.Unsubscribes.decorate/2`).
  """
  @spec bulk?(atom() | type()) :: boolean()
  def bulk?(type) do
    case kind(type) do
      :bulk -> true
      :transactional -> false
    end
  end

  @doc """
  The user a payload is about, or `nil` when it names none.

  `Courier.Deliver` needs it for the preference check and for the event's
  `user_id`; courier does not own users, so a payload with no user is a case
  courier refuses rather than one it invents an id for.
  """
  @spec user_id(map()) :: String.t() | nil
  def user_id(payload) when is_map(payload), do: payload |> normalize() |> Map.get(:user_id)

  @doc """
  Builds the message for `type` and `payload` without sending it.

  Returns `{:ok, email}`, or one of:

    * `{:error, :unknown_notification_type}` — courier has no such message
    * `{:error, {:invalid_payload, changeset}}` — the payload cannot be sent
    * `{:error, :from_not_configured}` — no sender is configured
    * `{:error, :subject_misconfigured}` — no subject, or a subject naming a key
      the payload does not carry

  `type` may be an atom or a string: it arrives as a string over JSON and as an
  atom from `Courier.Deliver`.
  """
  @spec build(atom() | type(), map()) ::
          {:ok, Swoosh.Email.t()} | {:error, atom() | {:invalid_payload, Ecto.Changeset.t()}}
  def build(type, payload) when is_map(payload) do
    with {:ok, type} <- fetch_type(type),
         {:ok, fields} <- cast(type, payload),
         {:ok, from} <- from(),
         {:ok, subject} <- subject(type, fields) do
      {:ok, compose(type, fields, from, subject)}
    end
  end

  @doc """
  Builds the message for `type` and hands it to `Courier.Mailer`.

  Same errors as `build/2`, plus `{:error, reason}` from the adapter — which in
  test is `Swoosh.Adapters.Test` and cannot fail.
  """
  @spec deliver(atom() | type(), map()) :: {:ok, term()} | {:error, term()}
  def deliver(type, payload) do
    with {:ok, email} <- build(type, payload), do: Mailer.deliver(email)
  end

  @doc """
  Whether a built message carries a body in at least one format.

  The one thing about a rendered message that the renderer itself cannot be
  trusted to get right, and it is checked here rather than at a caller because
  the message is only in hand here.

  Every template courier renders today produces both a text and an HTML body, so
  this is green by construction and exists for the case where it would not be: a
  template that renders empty, a layout that swallows its body, a format added
  later without one. `Swoosh` accepts an email with no body at all and hands back a
  provider-shaped id for it, so a bodiless message that reached a provider would
  be reported as sent, written to the outbox, and published as
  `courier.email.delivered` — the silent-default failure the whole adapter work
  exists to end, reached by a different road.

  Empty strings are **not** bodies. `""` renders to a mail a person opens and finds
  blank, which is the same defect as no body with one more step of indirection.

  Public and tested on hand-built messages because a predicate that only ever sees
  messages it is guaranteed to accept is a predicate nothing has checked.
  """
  @spec body?(Swoosh.Email.t()) :: boolean()
  def body?(%Swoosh.Email{text_body: text, html_body: html}), do: present?(text) or present?(html)

  @doc """
  The domain part of the configured sender, lowercased, or `nil` when no sender
  is configured or it is not an address.

  Public because `Courier.Deliver` needs exactly this question answered — "is
  the message's from-domain the deployment's own?" — to tell the deployment's
  own mail (which keeps the deployment credential, as it always has) from a
  from-address nobody configured (which is refused). It is answered here and
  not read a second time in the send path because there is one module that
  knows what courier's sender is, and a second `Application.get_env` would be a
  second answer to the same question.

  This reads configuration and does not send anything: the from-address still
  reaches the message through `build/2`, and this is the same value that
  address carries.
  """
  @spec sender_domain() :: String.t() | nil
  def sender_domain do
    domain_of(Application.get_env(:courier, :mailing, [])[:from])
  end

  @doc """
  The deployment's OWN sending domain — the domain courier's own mail (a
  password reset, an invitation) has always gone out as, on the deployment
  credential.

  This is distinct from `sender_domain/0` in a hosted, multi-sender courier: a
  message's from-address can be a TENANT's domain, while the deployment's own
  domain is a fact about the deployment and does not move with the message.
  `Courier.Deliver` compares the message's from-domain against this to tell
  "courier's own mail, keep the deployment credential" from "a from-address
  nobody registered, refuse".

  `config :courier, :mailing, :deployment_domain` is the value, and it falls
  back to `sender_domain/0` when unset — which is correct for the single-sender
  deployment courier has today, where the configured sender IS the deployment's
  own domain. `config/runtime.exs` sets it from `MAIL_FROM` so a deployment that
  moves its own address keeps the two in step.
  """
  @spec deployment_domain() :: String.t() | nil
  def deployment_domain do
    case Application.get_env(:courier, :mailing, [])[:deployment_domain] do
      nil -> sender_domain()
      domain when is_binary(domain) -> String.downcase(domain)
    end
  end

  @doc """
  The domain part of a `{name, address}` sender, lowercased, or `nil`.

  Public so `config/runtime.exs` can keep `deployment_domain` in step with the
  `MAIL_FROM` it resolves at boot, without a second copy of this parsing.
  """
  @spec domain_of(term()) :: String.t() | nil
  def domain_of({_name, address}) when is_binary(address) do
    case String.split(address, "@") do
      [_local, domain] when domain != "" -> String.downcase(domain)
      _other -> nil
    end
  end

  def domain_of(_other), do: nil

  defp present?(nil), do: false
  defp present?(body) when is_binary(body), do: String.trim(body) != ""
  defp present?(_other), do: false

  # Type, then payload, then configuration: the two configuration errors are
  # reported after the caller's payload is known good, because a deployment that
  # is misconfigured should not hide a request that is also wrong.

  defp fetch_type(type) do
    if Courier.Notifiers.get(type) != nil,
      do: {:ok, to_string(type)},
      else: {:error, :unknown_notification_type}
  end

  # A payload is not a schema — it is a map the platform handed over and courier
  # does not own — so it is cast through Ecto with an explicit type map rather
  # than onto a struct that does not exist. That is what makes a missing address
  # a changeset error a caller can read instead of a mail to nobody.
  defp cast(type, payload) do
    changeset =
      {empty(), @payload_types}
      |> cast(normalize(payload), @fields)
      |> validate_required(required(type))
      |> validate_format(:email, ~r/^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/,
        message: "is not an email address"
      )

    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, {:invalid_payload, changeset}}
    end
  end

  defp required(type) do
    Courier.Notifiers.required(type)
  end

  defp compose(type, fields, from, subject) do
    Swoosh.Email.new()
    |> Swoosh.Email.from(from)
    |> Swoosh.Email.to({fields.name, fields.email})
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.html_body(body(type, :html, fields))
    |> Swoosh.Email.text_body(body(type, :text, fields))
  end

  # Bodies are rendered per format and then wrapped in the shared layout, so
  # every email courier sends is wrapped alike and a change to the wrapper is a
  # change to one template.
  defp body(type, format, fields) do
    assigns = [
      greeting: greeting(fields.name),
      email: escape(fields.email),
      url: fields.url,
      account_name: escape(fields.account_name),
      invited_by: escape(fields.invited_by),
      role: escape(fields.role),
      reason: escape(fields.reason),
      previous_email: escape(fields.previous_email),
      amount_display: escape(fields.amount_display),
      invoice_id: escape(fields.invoice_id),
      billing_url: escape(billing_url())
    ]

    body_inner =
      case Courier.Notifiers.render_body(type, format, assigns) do
        "" -> Templates.render("#{type}.#{format}", assigns)
        rendered -> rendered
      end

    body_inner
    |> then(&Templates.render("layout.#{format}", body: &1))
  end

  # The platform keys a payload map either way — decoded JSON has strings, an
  # Elixir caller has atoms — and a payload that arrived with strings must not
  # come back as "email can't be blank".
  defp normalize(payload) do
    Map.new(@fields, fn field ->
      key = field |> Atom.to_string()
      {field, Map.get(payload, field, Map.get(payload, key))}
    end)
  end

  defp empty, do: Map.new(@fields, &{&1, nil})

  defp from do
    case Application.get_env(:courier, :mailing, [])[:from] do
      {name, address} when is_binary(name) and is_binary(address) ->
        if name == "" or address == "",
          do: {:error, :from_not_configured},
          else: {:ok, {name, address}}

      _ ->
        {:error, :from_not_configured}
    end
  end

  # Where a reader of `payment_failed` goes to update their payment method.
  #
  # Configuration rather than payload: the payload carries facts about the
  # event, and this is a fact about the deployment (which page its billing
  # screens live on) — the same split as the from-address, which is why it is
  # read here and not required of any consumer. `nil` when unset, and the
  # template renders the sentence without a link then: a warning that named an
  # address nobody configured would be worse than one that asks in words.
  defp billing_url, do: Application.get_env(:courier, :mailing, [])[:billing_url]

  defp subject(type, fields) do
    case subject_template(type) do
      nil -> {:error, :subject_misconfigured}
      template -> fill(template, fields)
    end
  end

  # Read by string rather than by `:erlang.binary_to_existing_atom`, so a
  # configuration key cannot become an atom that nothing in the code holds.
  defp subject_template(type) do
    Courier.Notifiers.subject_template(type)
  end

  defp fill(template, fields) do
    template
    |> placeholders()
    |> Enum.reduce_while({:ok, template}, fn key, {:ok, acc} ->
      case Enum.find(@fields, &(to_string(&1) == key)) do
        nil -> {:halt, {:error, :subject_misconfigured}}
        field -> {:cont, {:ok, String.replace(acc, "%{#{key}}", to_string(fields[field]))}}
      end
    end)
  end

  defp placeholders(template) do
    ~r/%\{(\w+)\}/
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp greeting(nil), do: "Hi,"
  defp greeting(name), do: "Hi #{escape(name)},"

  defp escape(nil), do: nil
  defp escape(value) when is_binary(value), do: Plug.HTML.html_escape(value)
  defp escape(value), do: to_string(value)
end
