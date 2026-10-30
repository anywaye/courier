defmodule CourierWeb.UnsubscribeController do
  @moduledoc """
  `POST` and `GET /unsubscribe/:token` — the door RFC 8058 §3.1 points every bulk
  message's `List-Unsubscribe` header at.


  **A mail client, on the recipient's behalf.** Not a tenant, not a provider, not
  a browser session. So this route is deliberately outside `/v1` and behind no
  authentication plug, for the same two reasons `/inbound/resend` is: every
  operation under `/v1` is authenticated with a bearer token, and a mail client
  holds none and must not be asked for one — RFC 8058 §3.1 says the request
  "MUST NOT include cookies, HTTP authorization, or any other context
  information", and behind `CourierWeb.Plugs.Principal` every unsubscribe would
  be a 401.


  RFC 8058 §3.1 asks for "an opaque identifier or another hard-to-forge component"
  in the URI and §6 says why, in the plainest terms in the RFC: a malicious mailer
  could otherwise "send spam with List-Unsubscribe links for a victim list, with
  the intention of causing list unsubscriptions from the victim list as a side
  effect of users reporting the spam". courier's answer is 32 bytes of
  `:crypto.strong_rand_bytes/1`, stored as a SHA-256 and never as itself
  (`Courier.UnsubscribeToken`), so the space is 2^256 and a database dump is not a
  list of things to unsubscribe.

  **The token is read from `conn.path_params` and never from `params`**, and that
  is a decision rather than tidiness. `Plug.Parsers` merges the POST body into
  `conn.params`, so a body carrying its own `token` could otherwise name a
  different mailbox than the path did — and the whole authority of this route is
  the path segment. `UnsubscribeControllerTest` drives exactly that request.


  `404 not_found` for a token courier never issued, a token of the wrong shape,
  and a token that is not a string. One answer, no oracle: a caller that could
  tell "this token exists but is not yours" from "this token does not exist" would
  be able to test tokens, and there is nothing here to tell apart.

  **Not a 401**, and that is worth reading twice. A 401 says "your credential is
  not acceptable" and would tell a mail client, and an operator reading logs, that
  something about a *request* was wrong. The token is the resource's address, not
  a credential presented to a door — so a token that names nothing is a resource
  that does not exist, which is what `404` has always meant in this service and
  what `openapi.yaml` declares for every other operation addressing one resource
  by id.


  "The mail sender MUST NOT return an HTTPS redirect, since redirected POST
  actions have historically not worked reliably, and many browsers have turned
  redirected HTTP POSTs into GETs." So the success is the answer — 200 with the
  body below — and there is no `Location` header on any status this action sends.
  The test asserts the absence, because a redirect is the one thing here that
  would work for a browser and silently break the mail client that matters.


  RFC 8058 §3.2 says the POST target is "the same as the one in the GET action for
  a manual unsubscription", and some clients and some corporate link-scanners only
  ever follow a link. So both verbs are served and both have the same effect.

  **courier renders nothing**, so the `GET` answers JSON rather than a confirmation
  page. That is this service's shape, not a shortcut: it has no HTML layer, no
  assets and no view, and inventing a page for one URL would be the first of both.
  The consequence is stated rather than hidden — a person who follows the link in
  a browser sees a small JSON object that says the same thing the mail client's
  button would have done, and there is no pretty version of it.


  `{"data": {"status": "unsubscribed"}}` and nothing else. **No address, no user
  id, no notification type**, on any status: this is an unauthenticated surface, so
  anything echoed back is available to whoever found the URL, and the token is not
  a session. The address appears in courier's logs, which is the one place
  `Courier.Suppressions` and this route agree a mailbox may be named.

  The body is **identical on a replay**, and that is the idempotency a mail client
  needs: a `POST` that timed out is a `POST` courier cannot distinguish from one
  that worked, so the second call writes nothing, publishes nothing, and says the
  same thing.
  """

  use CourierWeb, :controller

  require Logger

  alias Courier.Unsubscribes
  alias CourierWeb.Problem

  @doc """
  The one-click `POST`. RFC 8058 §3.1, and the verb a mail client uses.
  """
  def create(conn, _params), do: unsubscribe(conn)

  @doc """
  The `GET` a person follows from a link, for the clients that only ever fetch.
  """
  def show(conn, _params), do: unsubscribe(conn)

  defp unsubscribe(conn) do
    case Unsubscribes.unsubscribe(conn.path_params["token"]) do
      {:ok, _outcome} -> unsubscribed(conn)
      {:error, :unknown_token} -> no_such_token(conn)
      {:error, reason} -> not_recorded(conn, reason)
    end
  end

  defp unsubscribed(conn), do: json(conn, %{data: %{status: "unsubscribed"}})

  defp no_such_token(conn) do
    Problem.send(conn, 404, :not_found, "No unsubscribe with that token.")
  end

  defp not_recorded(conn, reason) do
    Logger.error("unsubscribe could not be recorded, and nothing was written: #{inspect(reason)}")

    Problem.send(
      conn,
      503,
      :unavailable,
      "courier could not record this unsubscribe, so nothing was written and no event " <>
        "was published. It is safe to try again."
    )
  end
end
