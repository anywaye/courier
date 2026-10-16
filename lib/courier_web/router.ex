defmodule CourierWeb.Router do
  use CourierWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The provider surface's pipeline, and it is one line long because the
  # authentication is the *body's* signature rather than a plug: there is no
  # `CourierWeb.Plugs.Signed` to put here, because the verifier needs the raw
  # bytes and a plug that has read the body cannot hand them back unchanged.
  #
  # `:api` is **not** folded in — the scope lists it beside this one — so the 406
  # every operation in `openapi.yaml` declares comes from the same pipeline it
  # comes from everywhere else, rather than from a second `:accepts` that would
  # have to be kept in step with the first.
  #
  # It names the provider rather than the controller inferring it from its own
  # route, so a second provider is a second scope entry and a second secret with
  # nothing in this file that has to change. Deliberately **not** including
  # `:authenticated` or `:idempotent` — see the scope's comment and
  # `Courier.InboundReports`'s moduledoc, which is where the reasoning for the
  # second of those lives.
  pipeline :inbound do
    plug :inbound_provider
  end

  # Everything that needs to know who is asking. The plug refuses an anonymous
  # caller outright rather than defaulting to an account — see its moduledoc for
  # why a seam that authenticates nobody is the right default until identity's
  # JWT verifier lands.
  #
  # **The database half of the same question lives in each action, not in this
  # pipeline, and the placement is the mechanism.** `CourierWeb.Plugs.Principal`
  # puts the account on the `conn`; each controller action and
  # `CourierWeb.Plugs.Idempotency` then opens its own `Courier.Tenancy.
  # with_account/3` transaction around its database work, so the
  # row-level-security policies on `idempotency_keys`,
  # `notification_preferences`, `webhook_endpoints`, `notification_events` and
  # `notifications` have an identity to key on. A plug in THIS pipeline cannot
  # do it for them: a plug's `call/2` returns before the downstream plugs and
  # the controller run, so a transaction it opened is already committed — and a
  # commit discards the transaction-local identity — by the time the first
  # protected write happens. The previous shape did exactly that
  # (`CourierWeb.Plugs.TenantIdentity`, removed), and every authenticated
  # request died on its first protected write with a 42501.
  #
  # `Principal` halts a 401, so an unauthenticated request never reaches a
  # scoped action.
  pipeline :authenticated do
    plug CourierWeb.Plugs.Principal
  end

  # `Idempotency-Key`, on the mutating POSTs and nothing else. Core requires it on
  # a POST that can be retried safely, which is these two and not the other six
  # actions: `GET` and `DELETE` are idempotent by HTTP's definition, `PATCH` here
  # is a partial update whose repeat is already the same row, and `PUT` on
  # notification preferences stores the state it is given rather than accumulating
  # deltas.
  #
  # After `:authenticated` on purpose — the key is scoped to the principal, so it
  # cannot be claimed before courier knows who is asking.
  pipeline :idempotent do
    plug CourierWeb.Plugs.Idempotency
  end

  # The paths whose request bodies have to reach a controller UNPARSED, and the
  # reason this list is here rather than written into
  # `CourierWeb.Plugs.ParseBody`: a path written into the plug is a path nothing
  # in this module knows about, so a rename leaves the parser reading a body whose
  # signature covered bytes that have since been re-encoded — and a JSON round trip
  # is byte-identical for most payloads, so the verifier that then refuses is the
  # only thing standing between a rename and a broken inbound surface.
  #
  # `test/courier_web/router_test.exs` asserts every path here is a route this
  # router serves, which is what stops the list going stale.
  @signed_body_paths ["/inbound/resend"]

  @doc """
  Whether a request to `path` is a signed inbound body courier must not decode.

  Trailing-slash insensitive, because `Phoenix.Router` matches `/inbound/resend/`
  to the same route: a check that only knew the spelling without the slash would
  parse exactly the request a copy-pasted URL produces.
  """
  @spec signed_body?(term()) :: boolean()
  def signed_body?(path) when is_binary(path) do
    case String.trim_trailing(path, "/") do
      "" -> false
      trimmed -> trimmed in @signed_body_paths
    end
  end

  def signed_body?(_other), do: false

  @doc "The paths `signed_body?/1` answers for, so a test can hold them to the router."
  @spec signed_body_paths() :: [String.t()]
  def signed_body_paths, do: @signed_body_paths

  # Probes. Deliberately outside /api and outside every other pipeline: they run
  # before routing, auth, and the rest of the platform exist, so they must not
  # depend on any of it. See CourierWeb.HealthController.
  #
  # **And they need no account, which is measured rather than assumed.** Readiness
  # runs `SELECT 1` (`Courier.Health`), which is not one of the three protected
  # tables, and liveness runs no query at all. Both answers are therefore
  # unaffected by `cafaye.account_id` being unset — which matters more than it
  # sounds: a readiness probe that needed a tenant identity would report courier
  # not ready whenever the identity was wrong, so an orchestration fault would be
  # reported as an outage and an outage would be restarted.
  scope "/", CourierWeb do
    pipe_through :api

    get "/healthz", HealthController, :healthz
    get "/readyz", HealthController, :readyz
  end

  # Everything a caller must be an authenticated caller for.
  #
  # Webhook endpoints were the first of these, because an endpoint's url and
  # signing secret are a way to make courier send signed requests and a list
  # endpoint with no authentication is a way to enumerate them. Notification
  # preferences joined them for the same reason at a smaller scale: a `user_id` in
  # a path is a string anybody can write, so a surface that reads and writes by
  # one is a surface where any caller can read and overwrite any other tenant's
  # answers by guessing an id.
  #
  # Both live in one scope because there is nothing left to distinguish them: the
  # refusal is the same plug's refusal and the same `401`, and a caller that has
  # to handle two kinds of 401 is a caller that will handle one of them wrongly.
  #
  # `CourierWeb.Plugs.Principal`, whose default resolver authenticates nobody —
  # so a courier deployed without identity's JWT verifier locks these rather than
  # serving them.
  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated]

    get "/notification_preferences/:user_id", NotificationPreferencesController, :show
    put "/notification_preferences/:user_id", NotificationPreferencesController, :update

    get "/webhook_endpoints", WebhookEndpointsController, :index
    get "/webhook_endpoints/:id", WebhookEndpointsController, :show
    patch "/webhook_endpoints/:id", WebhookEndpointsController, :update
    delete "/webhook_endpoints/:id", WebhookEndpointsController, :delete

    # The in-app notification reader, and it is behind `:authenticated` for the
    # reason the two surfaces above are: a notification is addressed to a user,
    # and a surface that reads by a user id is a surface where any caller can
    # read anybody's inbox by naming their id. The recipient here is the caller's
    # own identity subject, resolved from the token by
    # `CourierWeb.Plugs.Principal` — never from the request — so the path carries
    # no user id at all, and there is nothing for a caller to guess.
    #
    # **The two marks are not behind `:idempotent`, and that is a decision rather
    # than an omission.** `Courier.Notifications.mark_seen/3` and `mark_read/3`
    # set their timestamps with `coalesce`, so a repeat is a no-op that returns
    # the first timestamp — idempotence by construction, the same reason `PUT
    # /v1/notification_preferences/:user_id` is not behind the header. A retry
    # without a key is safe, and a key would be a credential scoped to a
    # principal for a request that needs none.
    get "/notifications", NotificationsController, :index
    get "/notifications/unread_count", NotificationsController, :unread_count
    post "/notifications/:id/seen", NotificationsController, :mark_seen
    post "/notifications/:id/read", NotificationsController, :mark_read

    # The domains a tenant proves control of and sends mail from, as a management
    # surface. Behind `:authenticated` for the reason every surface above is: a
    # `tenant_sending_domains` row carries a sealed provider credential, and a
    # row courier signs outbound mail with is not something an anonymous caller
    # may read, register or revoke. The account is the caller's, from the token,
    # and `CourierWeb.SendingDomains` refuses an `account_id` in a body as an
    # unknown field.
    #
    # `revoke` is a POST and not behind `:idempotent`, and that is a decision
    # rather than an omission: it sets `status` to `:revoked` and a repeat is the
    # same row with the same status, so a retry without a key is already safe —
    # the same idempotence-by-construction that keeps the notification marks and
    # `PUT /v1/notification_preferences/:user_id` out of that pipeline.
    get "/sending_domains", SendingDomainsController, :index
    get "/sending_domains/:id", SendingDomainsController, :show
    post "/sending_domains/:id/revoke", SendingDomainsController, :revoke
  end

  # The same resource, on the two POSTs. A separate scope rather than one
  # pipeline over all eight, because the header is for a POST that can be retried
  # and putting it on the other six would claim an idempotency courier does not
  # provide — `GET` and `DELETE` are idempotent by HTTP's definition, `PATCH`
  # here is a partial update whose repeat is already the same row, and `PUT` is
  # idempotent by construction because it stores the state it is given rather than
  # accumulating deltas. `test/courier_web/router_test.exs` asserts
  # `:authenticated` on every action, and this keeps that true while adding the
  # second pipeline.
  scope "/v1", CourierWeb do
    pipe_through [:api, :authenticated, :idempotent]

    post "/webhook_endpoints", WebhookEndpointsController, :create
    post "/webhook_endpoints/:id/test", WebhookEndpointsController, :ping

    # Registering a domain and proving it are both behind `:idempotent`, for the
    # same reason `createWebhookEndpoint` is: a caller that timed out on a
    # registration has no other way to learn whether the first attempt landed,
    # and a retry without a key is a second domain claim refused by the
    # `(account_id, domain)` index rather than a replay of the first. `verify`
    # re-runs the two-part proof and re-dials the provider, so a retry is not
    # free either; the stored response answers it without doing the work twice.
    post "/sending_domains", SendingDomainsController, :create
    post "/sending_domains/:id/verify", SendingDomainsController, :verify

    # courier's only door into its send path, and the reason this scope exists in
    # the shape it does. It is behind `:idempotent` for the reason every other POST
    # here is: a send is not idempotent by HTTP's definition, so a caller that
    # timed out would otherwise mail somebody twice, and it is behind
    # `:authenticated` because an unauthenticated POST to a mail egress is an open
    # relay.
    post "/messages", MessagesController, :create
  end

  # The provider surface, and it is OUTSIDE `/v1` on purpose. `/v1` is courier's
  # versioned contract with a tenant and every operation under it is authenticated
  # with a bearer token; `PLAN.md` MD6 has the platform generating client SDKs
  # from `openapi.yaml`, and an operation filed under `/v1` that cannot take a
  # bearer token is a method a generated client will call wrongly.
  #
  # It is in a scope of its own with no `pipe_through :authenticated`, and both
  # halves of that are load-bearing:
  #
  #   * **A provider is not a tenant.** Resend signs its webhook with Svix and
  #     sends no token. Behind `CourierWeb.Plugs.Principal` every delivery would be
  #     a 401.
  #   * **An unauthenticated `POST` that records suppressions is a denial of
  #     service on the whole product**, delivered by the feature meant to prevent
  #     it. So this route authenticates with a SIGNATURE instead —
  #     `Courier.Inbound.Signature`, verified before the body is parsed — which is
  #     core's own rule for an inbound webhook: "Inbound webhooks are not
  #     JWT-authenticated: they are signed, per the sender's convention, and the
  #     receiver checks the signature before parsing."
  #
  # **And it reaches no protected table, so it needs no identity.** That is the
  # deliberate half of the decision and it is measured rather than assumed:
  # `Courier.Inbound.handle/5` writes `email_suppressions` and `outbox_events`,
  # and of those only `outbox_events` has an `account_id` — which the protection
  # migration deliberately left unprotected, for the reason its moduledoc gives
  # (`Courier.Deliver` records `email.delivered` for a *user* courier cannot place
  # in an account, so `with check (account_id = current_account_id())` would refuse
  # every such insert with `42501` and the relay would read zero rows). So there
  # is no account on this path for `cafaye.begin_account/1` to be given, and
  # giving one would be inventing a tenancy claim for a provider.
  #
  # `:api` and nothing else: the `:accepts` plug is the 406 every operation in
  # `openapi.yaml` declares, and the other two things this route needs — the body
  # left unparsed and a bound on how much of it courier will buffer — are decisions
  # about one request rather than about a class of requests, so they live in the
  # action next to the order they happen in.
  #
  # The provider is in the PATH, so a second provider is a second path rather than
  # a discriminator in a body: a body is untrusted input until a signature has
  # verified it, and the path is chosen by whoever configured the webhook.
  scope "/inbound", CourierWeb do
    pipe_through [:api, :inbound]

    post "/resend", InboundController, :create
  end

  # The one-click unsubscribe, and it is outside `/v1` for the same reason
  # `/inbound` is: the only operation under `/v1` is authenticated with a bearer
  # token, and a mail client holds none.
  #
  # **RFC 8058 §3.1 says the request must not carry authorization at all** — "The
  # POST request MUST NOT include cookies, HTTP authorization, or any other
  # context information" — so there is no `:authenticated` here and there could
  # not be. The credential is the token in the path, which is a resource address
  # rather than a presented secret, and it is 32 bytes of `:crypto.
  # strong_rand_bytes/1` stored as a digest. `CourierWeb.Plugs.Principal` behind
  # this route would 401 every mail client in the world.
  #
  # **THE TOKEN IS AN AUTHENTICATED IDENTITY THAT IS NOT AN ACCOUNT, and the
  # answer is that this route reaches no protected table.** That is the hard case
  # this packet had to decide, and the decision is measured rather than a
  # preference between two shapes:
  #
  #   * `Courier.Unsubscribes.unsubscribe/1` reads `unsubscribe_tokens` and writes
  #     `email_suppressions`. **Neither has an `account_id`** — measured from
  #     `information_schema`, and the reason is in `Courier.Unsubscribes`' own
  #     moduledoc: an unsubscribe is a row with **no `state`**, in a table that
  #     records facts about a *mailbox* and belongs to whoever mailed it.
  #     `notification_preferences` is the one table here that IS protected, and
  #     this route deliberately does not write it — `Courier.Unsubscribes` records
  #     the measured alternative: the wrong account claims the user, and the
  #     account that actually owns them gets a 404 from a settings endpoint that
  #     worked yesterday.
  #   * So there is no account for `cafaye.begin_account/1` to be given here.
  #     **Inventing one would be the failure, not the fix.** The token carries no
  #     account; deriving one means the unsubscribe names an account, which is a
  #     tenancy claim made on behalf of a person by whoever mailed them.
  #   * And **exempting a table** would be worse than doing neither: the tables
  #     this route touches are unprotected *because they hold no customer rows*,
  #     which is core's honest zero and not a gap. Nothing is being exempted that
  #     was ever protected, so there is no policy being loosened to keep this URL
  #     working.
  #
  # The arrangement is therefore: `/v1/*` is identity-scoped by each action's
  # own `Courier.Tenancy.with_account/3` transaction (and the `:idempotent`
  # plug's, for its claim); `/unsubscribe/:token`, `/inbound/resend`
  # and the two probes reach no policy and so need no identity. If a future change
  # makes one of them touch `notification_preferences` or `webhook_endpoints`,
  # `reports/courier-row-level-security/prove-unauthenticated.sh` goes red on its
  # table list rather than on a symptom somebody reports later.
  #
  # **Both verbs, on one path, and that is §3.2's own sentence**: "The target of
  # the POST action is the same as the one in the GET action for a manual
  # unsubscription". Some clients only ever follow a link, and a bulk sender whose
  # header points at a 405 is a bulk sender whose unsubscribe requirement is not
  # met by the clients people actually use.
  #
  # `:api` and nothing else, so the 406 every operation in `openapi.yaml` declares
  # comes from the same plug it comes from everywhere else. Deliberately **not**
  # `:idempotent`: `CourierWeb.Plugs.Idempotency` is scoped to a principal, there
  # is none, and the replay is answered by the stored preference instead — see
  # `Courier.Unsubscribes`.
  scope "/unsubscribe", CourierWeb do
    pipe_through :api

    get "/:token", UnsubscribeController, :show
    post "/:token", UnsubscribeController, :create
  end

  scope "/api", CourierWeb do
    pipe_through :api
  end

  # The provider a signed inbound request is from, as an assign.
  #
  # The route is `/inbound/resend`, so the provider is in the PATH — which is
  # where a webhook URL is configured, in the provider's own dashboard, and a
  # path segment is therefore a thing courier does not get to disagree with. A
  # body naming the provider would be a caller choosing which vocabulary its own
  # payload is read with, which is the wrong direction for a field the sender
  # controls.
  #
  # It is an assign rather than a `Reports.secret(conn)` inside the controller so
  # that the pipeline reads as the whole of what this surface does before the
  # action runs, and so a test can put a provider there without a route.
  defp inbound_provider(conn, _opts) do
    assign(conn, :inbound_provider, provider_for(conn.request_path))
  end

  defp provider_for(path) when is_binary(path) do
    path
    |> String.split("/")
    |> List.last()
    |> case do
      "resend" -> "resend"
      _unknown -> nil
    end
  end
end
