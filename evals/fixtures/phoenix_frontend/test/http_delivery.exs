# Exercise the actual HTTP error boundary, not ConnTest's exception handling.
# Run separately from mix test so starting/stopping the endpoint cannot disturb it.
Application.load(:harness_fixture)
{:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
{:ok, port} = :inet.port(socket)
:ok = :gen_tcp.close(socket)
endpoint = HarnessFixtureWeb.Endpoint
config = Application.get_env(:harness_fixture, endpoint, [])

Application.put_env(
  :harness_fixture,
  endpoint,
  Keyword.merge(config, http: [ip: {127, 0, 0, 1}, port: port], server: true)
)

{:ok, _} = Application.ensure_all_started(:harness_fixture)

try do
  for {method, path, expected} <- [
        {:get, "/", 200},
        {:get, "/missing-delivery-route", 404},
        {:post, "/goals", 403}
      ] do
    body = if method == :post, do: "objective=must-not-start", else: ""
    {:ok, connection} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(connection, [
        String.upcase(to_string(method)),
        " ",
        path,
        " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ",
        to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])

    receive_all = fn recur, acc ->
      case :gen_tcp.recv(connection, 0, 5_000) do
        {:ok, bytes} when byte_size(acc) + byte_size(bytes) <= 1_000_000 ->
          recur.(recur, acc <> bytes)

        {:error, :closed} ->
          acc

        other ->
          raise "HTTP read failed: #{inspect(other)}"
      end
    end

    response = receive_all.(receive_all, "")
    :gen_tcp.close(connection)
    [headers, body] = String.split(response, "\r\n\r\n", parts: 2)
    [_, code] = Regex.run(~r/\AHTTP\/1.[01] (\d{3})/, headers)
    status = String.to_integer(code)

    unless status == expected and byte_size(body) > 0 do
      raise "#{method} #{path}: expected a nonempty HTTP #{expected} response, got #{status}"
    end
  end

  unless HarnessFixture.Runtime.goals() == [], do: raise("CSRF rejection changed actor state")
  IO.puts("HTTP delivery checks passed: page, missing route, CSRF rejection and actor integrity")
after
  Application.stop(:harness_fixture)
end
