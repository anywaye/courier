# DIAGNOSTIC (brk-2R): where does the manager's verbatim message come from?
#
#     stream_refused 404: "stream not found for subject: courier.email.delivered"
#
# A plain `Gnat.request/4` on the SUBJECT times out against a broker whose
# streams do not cover it (measured, both with no stream at all and with a
# stream carrying a narrower subject list). So the 404 must arrive from a
# publish addressed at the JetStream API subject instead. This probe asks the
# API directly and prints exactly what the server answers, for the shapes the
# subscriber might have used.

url = System.get_env("NATS_URL") || raise "NATS_URL must name the broker"
Application.put_env(:courier, :nats, url: url)
_ = Courier.Nats.start_link([])
{:ok, conn} = Courier.Nats.connection()

payload = Base.encode64(Jason.encode!(%{"probe" => true}))

probes = [
  {"API publish, stream anywaye (does not exist)",
   "$JS.API.STREAM.PUBLISH.anywaye",
   Jason.encode!(%{"subject" => "courier.email.delivered", "payload" => payload})},
  {"API publish, stream narrowtest (exists, courier.> not covered)",
   "$JS.API.STREAM.PUBLISH.narrowtest",
   Jason.encode!(%{"subject" => "courier.email.delivered", "payload" => payload})},
  {"plain subject publish with reply-to (courier.> not covered)",
   "courier.email.delivered", "{}"}
]

for {label, subject, body} <- probes do
  answer =
    try do
      Gnat.request(conn, subject, body, receive_timeout: 5_000)
    catch
      kind, reason -> {:raised, kind, reason}
    end

  IO.puts("#{label}:\n  #{inspect(answer, limit: 8, pretty: false)}\n")
end
