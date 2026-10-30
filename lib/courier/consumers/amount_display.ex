defmodule Courier.Consumers.AmountDisplay do
  @moduledoc """
  A payment amount, rendered into the string a mail prints.


  The payment family has two consumers — the receipt (`billing.payment.succeeded`)
  and the failure warning (`billing.payment.failed`) — and billing builds both
  events with ONE builder and the same `amount: {"amount_minor", "currency"}`
  shape. Two copies of this function would be two answers to "what does 1900
  USD read as", and the day they disagreed, the same amount would print
  differently in the two mails about the same subscription. So the rendering
  lives here, and the consumers hand it the amount.


  There is no Money module, no currency table, and no arithmetic — the mail
  prints a figure this module produced from integer minor units, which is how
  every number in this fleet crosses a wire. The template never computes; the
  consumer renders; and this is where "render" means exactly one function.


  The places come from a small zero-decimal table — the currencies that have
  no minor unit, where the number IS the number — and default to 2. The
  default is the safe direction precisely because it is only a count: a wrong
  count produces a mail with a decimal point in a figure nobody moved money
  by, which a reader notices; a currency this table does not name is still a
  receipt and still a warning.
  """

  @zero_decimal ~w(JPY KRW CLP VND ISK)

  @spec render({integer(), String.t()}) :: String.t()
  def render({minor, currency}) do
    currency = String.upcase(currency)

    if currency in @zero_decimal do
      "#{minor} #{currency}"
    else
      whole = div(minor, 100)
      cents = rem(rem(minor, 100) + 100, 100)
      "#{whole}.#{Integer.to_string(cents) |> String.pad_leading(2, "0")} #{currency}"
    end
  end
end
