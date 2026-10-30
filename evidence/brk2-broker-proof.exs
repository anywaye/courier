
url = System.get_env("NATS_URL") || raise "NATS_URL must name the broker"

Application.put_env(:courier, :nats, url: url)
Application.put_env(:courier, :nats_publisher, Courier.NatsPublisher.Bus)

_ = Courier.Nats.start_link([])
{:ok, _connection} = Courier.Nats.connection()

envelope =
  Courier.Events.envelope(%{
    id: Ecto.UUID.bingenerate() |> Ecto.UUID.cast!(),
    type: "courier.email.delivered",
    source: "courier",
    subject: Ecto.UUID.bingenerate() |> Ecto.UUID.cast!(),
    time: DateTime.utc_now(),
    data: %{
      "user_id" => Ecto.UUID.bingenerate() |> Ecto.UUID.cast!(),
      "email" => "kaka@example.com",
      "name" => "Kaka",
      "url" => "https://anywaye.com/verify?token=abc123"
    }
  })

IO.puts("subject:  #{envelope["type"]}")
IO.puts("publish:  #{inspect(Courier.NatsPublisher.Bus.publish(envelope))}")
