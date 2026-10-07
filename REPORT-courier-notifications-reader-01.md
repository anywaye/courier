# REPORT — the notifications reader (courier-32)

**Branch:** `worker/courier-w32-notifread`
**Gate:** `bin/prime` green — `Result: 1520 passed` (floor 1520 in `gate.yml`,
database tier 855 in `.github/workflows/ci.yml`, both re-measured on this
tree: 665 no-database + 855 database = 1520).

## What shipped

The HTTP surface over the in-app notification record. `Courier.Notifications`
was already complete; this packet is the transport and nothing in the context
changed.

1. **Routes** (`lib/courier_web/router.ex`), behind `pipe_through [:api,
   :authenticated]` — `CourierWeb.Plugs.Principal` then
   `CourierWeb.Plugs.TenantIdentity`, so the RLS policies on `notifications`
   have an identity to key on:

   * `GET /v1/notifications` — the caller's own, newest first. `?unread=true`,
     `?limit=`, `?after=` map onto `list/4`'s options.
   * `GET /v1/notifications/unread_count` — the badge number.
   * `POST /v1/notifications/:id/seen` and `POST /v1/notifications/:id/read` —
     the two marks. Not behind `:idempotent`: the marks are idempotent by
     construction (`coalesce` in the UPDATE), so a retry is safe without a key.

2. **Controller** (`lib/courier_web/controllers/notifications_controller.ex`).
   The recipient is `{"user", conn.assigns.current_principal.subject}` — the
   caller's own identity subject, never from the request. The account is
   `conn.assigns.current_account`. `{:error, :not_found}` from the context
   (another account's row, a different recipient's row, or a non-uuid id) is a
   404 in `CourierWeb.Problem`'s envelope, never a 403.

3. **The plug change** (`lib/courier_web/plugs/principal.ex`). The plug
   assigned only `:current_account` and discarded the rest of the
   `Courier.Principal` struct. It now assigns the whole struct as
   `:current_principal` alongside the account — one assign, and a controller
   that later needs `scopes` reads it from the same place. The 401 and 503
   branches are untouched, and `principal_config_test.exs` asserts the 401 is
   still byte-for-byte the same envelope both resolvers produce.

4. **OpenAPI** (`openapi.yaml`). Four operations, the `Notification` schema,
   the `NotificationId` path parameter and the `NotificationNotFound` response.
   Scopes are declared (`notifications:read` / `notifications:write`) and
   **deliberately not enforced** — identity's scope vocabulary cannot mint
   those names, so a scope check today would refuse every credential identity
   can issue. Version 2.3.0 → 2.4.0 (additive: four new operations on two new
   paths, no existing path/verb/field/shape changed). The header's stale "four
   operations" 400 prose was corrected — ten operations now declare a 400, and
   the rule is the verb, not a count.

5. **Tests.** 31 in `test/courier_web/controllers/notifications_controller_test.exs`
   (a `CourierWeb.ConnCase` — every claim is a claim about a row through the
   real router), 1 in `principal_config_test.exs` (the plug assigns the whole
   principal). The empty inbox is `[]`; a row for this recipient is listed
   newest-first and the unread filter narrows it; `unread_count` agrees with
   the filtered list; `seen` then `read` sets both timestamps and a second call
   keeps the first `seen_at`; another account's row is a 404 on both marks; an
   anonymous request is a 401 on all four actions; an `account_id` in the query
   or body cannot reach another account's rows.

## The recipient/subject finding — the assumption holds

The reader addresses `{"user", <subject>}`. The writer
(`Courier.Consumers.MemberAccepted`) records `{"user", membership.user_id}`.
The question was whether identity's introspection `sub` is the same id as
`membership.user_id`. **It is.** Measured in `identity/`:

* `internal/apikeys/claims.go` — `ClaimsFor` sets `Subject: k.UserID`, and
  `internal/apikeys/service.go` sets `UserID: in.MintedBy`: the `sub` of an API
  key is the **user who minted it**. The OIDC provider
  (`internal/oidc/storage.go`) sets the subject to the login subject — also a
  user. `internal/apikeys/claims.go` says it outright: "Subject is `sub`, and
  it is the USER the token names — not the account."
* `identity.member.accepted` is built by `outbox.NewMemberAccepted` with
  `in.User` — the user who redeemed the invitation
  (`internal/accounts/service.go`) — as `user_id`.

Both are ids from identity's same user table, so the reader and the writer
agree **because both derive the recipient from identity** — the reader from
the token, the writer from the event. A signed-in user's own credential names
that user, so the inbox is not empty for any structural reason.

The one deployment caveat, stated rather than assumed: the token's subject is
the user who *minted* the key (or the OIDC login subject). A deployment that
mints a key on behalf of a different acting user would have `sub` naming the
minter. That is identity's token model, not courier's reader, and it is the
same assumption every other user-scoped surface in the fleet makes.

## Judgment on the partial work

The previous attempt's work was **kept** — it was correct. Four defects in it
were fixed:

* `openapi_paths_test.exs` claimed the two POSTs were "the first operations
  since `POST /v1/messages` whose 400 is reachable through the parser". The
  webhook-endpoint POSTs already declared a parser-reachable 400. The comment
  now states the rule (the verb) rather than a false history.
* The CI database-tier floor was still 823. Raised to 855, with the tier label
  (45 → 46 files) and the run-summary table (which still said 1488 / 659 /
  764) re-measured on this tree.
* The `openapi.yaml` header's "the four operations above" 400 prose was stale
  (ten operations declare it now). Rephrased as the rule, without a count.
* The document version was not bumped. 2.3.0 → 2.4.0 with the header's own
  minor-bump convention, and `info.description` now names in-app
  notifications.

## What parlor's inbox screen must do

* **Authenticate as the user.** The recipient is the token's own subject, so
  parlor sends the signed-in user's bearer token and gets that user's inbox.
  There is no user id to pass and none to guess — a token that names a
  different user is a different person's inbox, answered 404 per row.
* **List** via `GET /v1/notifications`, rendering `data[]` newest-first. The
  five fields are `id`, `notification_event_id`, `seen_at`, `read_at` — and
  nothing else; `account_id` and the recipient are deliberately not echoed.
* **Badge** via `GET /v1/notifications/unread_count` (`data.unread`). It counts
  `read_at IS NULL`, so "seen" does not move it — a badge that counted seen
  would fall the moment somebody scrolled past something.
* **Mark** on display (`POST /v1/notifications/{id}/seen`) and on open
  (`POST /v1/notifications/{id}/read`). Both are idempotent and keep the first
  timestamp, so a retry after a timeout is safe without an `Idempotency-Key`.
  A 404 on a mark means the row is gone or was never theirs — refetch.
* **Paginate** with `?after=<RFC 3339 timestamp>` (a cursor, not an offset —
  two notifications in the same microsecond cannot make it skip one),
  `?limit=` (default 25, capped at 100), `?unread=true` for the unread filter.
* **Handle the three refusals** the way every courier client does: 401
  re-authenticates, 503 retries (identity or the dependency is down — courier
  is fine), 404 refetches. A 403 is never the answer to "is this mine?" —
  core's conventions forbid the existence leak, and courier has no role a 403
  could grant.
