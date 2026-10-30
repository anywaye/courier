defmodule Courier.Principal.Introspection.Transport do
  @moduledoc """
  How courier asks identity a question.

  A behaviour with one function rather than a direct `Req` call, for the reason
  every other seam in this repository has one: the answer is the security property,
  and a security property that can only be asserted by dialling the real thing is a
  security property the suite does not assert at all. `Courier.TestSupport.
  IntrospectionTransport` answers from a table, and
  `Courier.Principal.Introspection.Transport.Req` is the one that opens a socket
  — exercised against Req's own plug adapter, so neither side of the seam is
  untested.


  `{:ok, status, body}` or `{:error, reason}`, where **`reason` is a symbol
  carrying no part of either credential**. Both tokens are in flight on this call
  — the caller's in the body, courier's in a header — and every reason string
  below is chosen so that interpolating one into a log line cannot quote either.
  See `Courier.MailerAdapter.describe/1` for the same rule about a value at SMTP.
  """

  @doc """
  POSTs `body` to `url` and answers the status and the raw body.
  """
  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: String.t()) ::
              {:ok, non_neg_integer(), String.t()} | {:error, atom()}
end
