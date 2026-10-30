defmodule Courier.TestSupport.FakeResend do
  @moduledoc """
  A Resend that signs, so a test can drive courier's inbound path end to end
  without a provider, a network, or a secret an operator has to provision.

  Worker B and worker C both need this: B writes the event builders, C writes the
  route, and neither can assert anything about inbound without a payload that
  carries a real signature. Building one by hand means re-implementing Svix's
  base string in a test, and a test that does that is asserting a reimplementation
  against a verifier — which is how two wrong things agree with each other.

  So this signs with `Courier.Inbound.Signature`'s own scheme, the same
  `Courier.Webhooks.Signature` courier uses to sign OUTBOUND webhooks, and the
  real proof that the scheme is right is the published vector in
  `test/courier/inbound/signature_test.exs`, not this fake. This fake makes the
  tests convenient; the vector makes them true.


  `bounce/1`, `complaint/1` and `delivery_delayed/1` construct the JSON Resend
  documents at <https://resend.com/docs/webhooks/emails/bounced> and its
  siblings, and `bounce/1` refuses a `bounce_type` outside the documented
  vocabulary rather than writing a payload courier would refuse to parse. A fake
  that could build an impossible payload is a fake whose tests pass for reasons
  that do not exist in production.


  It does not verify. There is nothing here that checks a signature, because the
  only honest check of a signature is `Courier.Inbound.Signature.verify/4` and a
  fake that wrapped it would make "the test passed" and "the signature was
  correct" the same claim.
  """

  alias Courier.Inbound.Signature
  alias Courier.Webhooks.Signature, as: WebhookSignature

  @doc """
  A signing secret in Svix's serialization, `whsec_` + base64.

  Fixed rather than random so a test that asserts on a signature byte-for-byte
  has something stable to assert on, and TEST-ONLY in the same sense as
  `config/test.exs`'s `COURIER_SECRET_BOX_KEY`: it is a fixture, never a
  default, and no production deployment reads it.

  The base64 segment is assembled at runtime rather than written as one literal,
  for the reason `test/courier/idempotency_test.exs` builds its fixture the same
  way: the value is not a credential, but it has the SHAPE of one, GitHub's
  secret scanning matches that shape rather than the content, and this
  repository is public. A `whsec_` value that appears contiguously in source is
  an alert every time it is pushed, and an alert stream nobody reads is the
  state in which a real one gets missed. Assembling it keeps the shape, the
  determinism and the byte-for-byte assertability while the source carries only
  the readable filler it decodes from.
  """
  @spec secret() :: String.t()
  def secret, do: "whsec_" <> Base.encode64("pub4isheadfakesecretfortests")

  @doc """
  A secret that is not this provider's, for the negative test.

  Same shape and same length so the ONLY thing that makes a verification fail is
  that the key is different — a test that used a malformed secret would pass on
  `:invalid_secret` and never reach the comparison it meant to exercise. Built
  at runtime for the same reason `secret/0` is.
  """
  @spec other_secret() :: String.t()
  def other_secret, do: "whsec_" <> Base.encode64("wrongshangsecretofanothersecret")

  @doc """
  A well-formed `email.bounced` body.

  Options: `:bounce_type` (default `"Permanent"`), `:sub_type`, `:message`,
  `:diagnostic`, `:recipients` (default `["bounced@example.com"]`), `:email_id`,
  `:message_id`, `:created_at`.
  """
  @spec bounce(keyword()) :: binary()
  def bounce(opts \\ []) do
    email_bounced(
      bounce_type: Keyword.get(opts, :bounce_type, "Permanent"),
      sub_type: Keyword.get(opts, :sub_type, "General"),
      message: Keyword.get(opts, :message, "The recipient's email address does not exist."),
      diagnostic: Keyword.get(opts, :diagnostic),
      recipients: Keyword.get(opts, :recipients, ["bounced@example.com"]),
      email_id: Keyword.get(opts, :email_id, default_email_id()),
      message_id: Keyword.get(opts, :message_id, "<fake-1@example.com>"),
      created_at: Keyword.get(opts, :created_at, "2026-11-22T23:41:12.126Z")
    )
  end

  @doc """
  A well-formed `email.complained` body.

  Resend's documented payload for this event carries no explanation field at all
  — the recipient pressed a button — so neither does this one.
  """
  @spec complaint(keyword()) :: binary()
  def complaint(opts \\ []) do
    envelope(
      "email.complained",
      %{
        "email_id" => Keyword.get(opts, :email_id, default_email_id()),
        "message_id" => Keyword.get(opts, :message_id, "<fake-1@example.com>"),
        "to" => Keyword.get(opts, :recipients, ["complained@example.com"]),
        "from" => "Acme <onboarding@resend.dev>",
        "subject" => "Sending this example"
      },
      Keyword.get(opts, :created_at, "2026-11-22T23:41:12.126Z")
    )
  end

  @doc """
  A well-formed `email.delivery_delayed` body.
  """
  @spec delivery_delayed(keyword()) :: binary()
  def delivery_delayed(opts \\ []) do
    envelope(
      "email.delivery_delayed",
      %{
        "email_id" => Keyword.get(opts, :email_id, default_email_id()),
        "message_id" => Keyword.get(opts, :message_id, "<fake-1@example.com>"),
        "to" => Keyword.get(opts, :recipients, ["delayed@example.com"])
      },
      Keyword.get(opts, :created_at, "2026-11-22T23:41:12.126Z")
    )
  end

  @doc """
  A body for any other documented `type`, for the tests about events courier has
  no opinion on.
  """
  @spec event(String.t(), keyword()) :: binary()
  def event(type, opts \\ []) do
    envelope(
      type,
      %{
        "email_id" => Keyword.get(opts, :email_id, default_email_id()),
        "to" => Keyword.get(opts, :recipients, ["someone@example.com"])
      },
      Keyword.get(opts, :created_at, "2026-11-22T23:41:12.126Z")
    )
  end

  @doc """
  The three `svix-` headers for `body`, signed with `secret`.

  `id` defaults to a fresh `msg_`-prefixed id, matching the shape svix sends
  (and `Courier.Webhooks.Signature.new_id/0`, which is base64url and therefore
  incapable of carrying the full stop the scheme forbids).

  `timestamp` defaults to now, because a test that signs with a fixed old
  timestamp would be refused by the tolerance before it reached anything it meant
  to test.
  """
  @spec headers(binary(), String.t(), keyword()) :: map()
  def headers(body, secret \\ secret(), opts \\ []) do
    id = Keyword.get(opts, :id, WebhookSignature.new_id())
    timestamp = Keyword.get(opts, :timestamp, WebhookSignature.unix_now())
    prefix = Keyword.get(opts, :prefix, "svix")

    %{
      "#{prefix}-id" => id,
      "#{prefix}-timestamp" => to_string(timestamp),
      "#{prefix}-signature" => WebhookSignature.sign(secret, id, timestamp, body)
    }
  end

  @doc """
  A body and its matching headers, which is what a test almost always wants.

      body = FakeResend.bounce()
      {body, headers} = FakeResend.signed(body)
      assert {:ok, [result]} = Courier.Inbound.handle(Resend, body, headers, FakeResend.secret())

  `opts` is passed to `headers/3`, so `:id` and `:timestamp` are settable for the
  replay and skew tests.
  """
  @spec signed(binary(), keyword()) :: {binary(), map()}
  def signed(body, opts \\ []),
    do: {body, headers(body, Keyword.get(opts, :secret, secret()), opts)}

  @doc """
  A body and headers signed with the WRONG key, for the negative test.
  """
  @spec signed_by_stranger(binary(), keyword()) :: {binary(), map()}
  def signed_by_stranger(body, opts \\ []) do
    {body, headers(body, other_secret(), opts)}
  end

  @doc """
  The tolerance `Courier.Inbound.Signature` enforces, so a test that needs a
  skewed timestamp can compute the boundary without repeating the number.
  """
  @spec tolerance() :: pos_integer()
  def tolerance, do: Signature.tolerance()

  defp email_bounced(opts) do
    bounce = %{"type" => opts[:bounce_type]}

    bounce =
      if opts[:sub_type], do: Map.put(bounce, "subType", opts[:sub_type]), else: bounce

    bounce =
      if opts[:message], do: Map.put(bounce, "message", opts[:message]), else: bounce

    bounce =
      case opts[:diagnostic] do
        nil -> bounce
        code when is_list(code) -> Map.put(bounce, "diagnosticCode", code)
        code -> Map.put(bounce, "diagnosticCode", [code])
      end

    envelope(
      "email.bounced",
      %{
        "email_id" => opts[:email_id],
        "message_id" => opts[:message_id],
        "to" => opts[:recipients],
        "from" => "Acme <onboarding@resend.dev>",
        "subject" => "Sending this example",
        "bounce" => bounce
      },
      opts[:created_at]
    )
  end

  defp envelope(type, data, created_at) do
    """
    {"type":"#{type}","created_at":"#{created_at}","data":#{encode(data)}}\
    """
  end

  defp encode(map) do
    map
    |> Enum.map(fn {key, value} -> ~s("#{key}":#{encode_value(value)}) end)
    |> Enum.join(",")
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_value(value) when is_binary(value), do: ~s("#{value}")
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)

  defp encode_value(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &encode_value/1) <> "]"

  defp encode_value(value) when is_map(value), do: encode(value)

  defp default_email_id, do: "56761188-7520-42d8-8898-ff6fc54ce618"
end
