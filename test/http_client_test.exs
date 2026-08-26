defmodule BeamAgent.HTTPClientTest do
  use ExUnit.Case, async: false

  alias BeamAgent.HTTPClient.Httpc

  test "LLM HTTP requests do not inherit a fixed or legacy timeout" do
    {url, listener, server} = delayed_server(JSON.encode!(%{"delayed" => true}))
    close_server_on_exit(listener, server)

    assert {:ok, 200, %{"delayed" => true}} =
             Httpc.post_json(url, [], %{}, timeout_ms: 1)
  end

  test "streamed LLM responses can remain quiet longer than a legacy timeout" do
    {url, listener, server} = delayed_server("delayed stream")
    close_server_on_exit(listener, server)

    assert {:ok, 200, :streamed, chunks} =
             Httpc.post_json_stream(url, [], %{}, [timeout_ms: 1], [], fn chunk, chunks ->
               {:ok, [chunk | chunks]}
             end)

    assert chunks |> Enum.reverse() |> IO.iodata_to_binary() == "delayed stream"
  end

  defp delayed_server(body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        Process.sleep(50)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "connection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
      end)

    {"http://127.0.0.1:#{port}/chat", listener, server}
  end

  defp close_server_on_exit(listener, server) do
    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :shutdown)
    end)
  end
end
