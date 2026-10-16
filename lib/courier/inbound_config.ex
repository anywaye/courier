defmodule Courier.InboundConfig do
  @moduledoc """
  The signing secrets courier verifies inbound webhooks with — optional in
  production, with the cost stated on a boot log line.

  ## This is a *verification* secret, and it is not the outbound one

  courier signs outbound deliveries with a secret it generates per endpoint
  (`Courier.WebhookEndpoints`, sealed under `COURIER_SECRET_BOX_KEY`) and
  verifies inbound reports with a secret **the provider generated and courier was
  given**. They are different secrets for different directions, they live in
  different systems — one in courier's database, one in the provider's dashboard
  — and conflating them would mean a deployment that leaks a customer's outbound
  secret can also forge inbound suppressions. So the two are configured
  separately and this module says so where the variable is read.

  ## Why a secret is OPTIONAL in production — cf-inbound-optional

  Unset, `Courier.Inbound.Signature.verify/4` answers `:invalid_secret` for every
  request, the route answers 500, and **every hard bounce and every complaint
  courier is sent is discarded** — silently enough that the suppression table
  stays empty, `POST /v1/messages` keeps mailing addresses that have permanently
  refused, and a sending domain's reputation dies of a cause nothing in a
  dashboard names. That is precisely the failure `Courier.Suppressions` was
  written to prevent, arriving through the door that was supposed to prevent it.

  So `config/runtime.exs` **used to refuse to boot** a production courier without
  it, on the argument `Courier.MailerAdapter` makes: a courier that is running and
  cannot do the thing is worse than one that will not start, because the damage is
  invisible. That held while every deployment needed a Resend webhook; it no longer
  holds for a Cloudflare-only box (`COURIER_MAIL_ADAPTER=cloudflare`) which has no
  delivery webhook at all — its provider answers synchronously and keeps its own
  suppression list, and the adapter already surfaces a bounce as an error. Forcing
  that box to carry a second vendor's credential makes the cheapest, most
  self-contained mail setup the only one that cannot be completed. So the absence
  is now a **supported state**: `config/runtime.exs` boots with `%{}`, logs
  `inbound: no provider configured — a hard bounce or a spam complaint is discarded
  and courier goes on mailing an address that has said it is gone`, and the route
  answers 500 naming `COURIER_INBOUND_RESEND_SECRET`. A default would still be
  worse than nothing — a secret in version control that every deployment which
  forgot to set one would accept forged suppressions under, which is an
  unauthenticated `POST` that mails nobody.

  **Test and development are not refused**, and the reason is that they are not a
  deployment. `config/test.exs` sets a fixed test-only value in the same sense as
  `COURIER_SECRET_BOX_KEY`'s, and a developer running `mix phx.server` without a
  provider webhook configured is not shipping anything. Both are visible states:
  a request to the route in either environment is a 500 naming the variable, not a
  silent success.

  ## One variable per provider, named for the provider

  `COURIER_INBOUND_RESEND_SECRET` rather than one shared `COURIER_INBOUND_SECRET`,
  because a second provider will need a second secret and a shared variable cannot
  hold both: it would make the second provider's configuration an edit to the
  first's, and a deployment that added Postmark would be one keystroke away from
  verifying Postmark's traffic with Resend's key. It is read into a map keyed by
  the provider, so the route looks up the one it is for and a missing one is a
  `nil` rather than a wrong secret.

  Rotating it means the old and the new are both valid for as long as the
  provider will send the old one. Svix's `v1` scheme supports a **space-delimited**
  signature list for exactly this, and `Courier.Inbound.Signature` already reads
  every entry and tries each — so a rotation is a provider-side change followed by
  a redeploy, and there is a window in which both work by design rather than by
  luck.
  """

  @doc """
  The secret configured for `provider`, or `nil`.

  The lookup key is a **string**, and that is the whole reason it is not an atom:
  the key comes from the request's path (`/inbound/resend`), and an atom keyed on
  caller-supplied text is `String.to_existing_atom/1` on the request path of a
  route, which is either a crash on a path courier has not seen or — with
  `String.to_atom/1` — an unbounded atom table fed by whoever finds the URL. The
  path is a closed set because `CourierWeb.Router` matches it against a literal,
  so an atom would work; a string works for the same reason and cannot go wrong
  if that ever changes.
  """
  @spec secret(String.t() | atom() | nil) :: String.t() | nil
  def secret(provider) when is_binary(provider) do
    case stored() do
      %{} = secrets -> Map.get(secrets, provider)
      # A **keyword list** is what `config :courier, :inbound_secrets, resend: "…"`
      # stores, and it is a plausible thing for a deployment to have. Accepting it
      # rather than raising is the whole reason this is a `case`: a `BadMapError` on
      # the request path of a route whose entire vocabulary is a 400, a 401, a 422
      # and a 500 is a crash where a diagnosis belongs, and the diagnosis is one
      # line of prose. `test/courier/inbound_config_test.exs` asserts the shipped
      # configuration is a map, because the safe direction is also the correct one.
      #
      # Normalised through `to_string/1` on the way, so the lookup key stays a
      # string on both sides. `Keyword.get/2` would want an atom and the obvious
      # way to give it one is `String.to_atom/1` — which is precisely the
      # conversion this module's own docstring says not to do, on the request path
      # of a route.
      secrets when is_list(secrets) -> stringify(secrets) |> Map.get(provider)
      _anything_else -> nil
    end
  end

  def secret(provider) when is_atom(provider) and not is_nil(provider) do
    provider |> Atom.to_string() |> secret()
  end

  def secret(_no_provider), do: nil

  defp stored, do: Application.get_env(:courier, :inbound_secrets, %{})

  defp stringify(pairs), do: Map.new(pairs, fn {key, value} -> {to_string(key), value} end)

  @doc """
  Every provider courier is configured to receive reports from.

  Read for a **boot-time** line, so a deployment can see which inbound surfaces
  are live. It names the providers and never the secrets, for the reason
  `Courier.MailerAdapter.describe/1` omits both SMTP credentials: at a provider a
  "username" is usually the key itself, and the inbound secret is the key.
  """
  @spec configured_providers() :: [String.t()]
  def configured_providers do
    case stored() do
      secrets when is_map(secrets) -> names(Map.to_list(secrets))
      secrets when is_list(secrets) -> names(secrets)
      _anything_else -> []
    end
  end

  defp names(pairs) do
    pairs
    |> Enum.filter(fn {_provider, secret} -> is_binary(secret) and secret != "" end)
    |> Enum.map(fn {provider, _secret} -> to_string(provider) end)
    |> Enum.sort()
  end
end
