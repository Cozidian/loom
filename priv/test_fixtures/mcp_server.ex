defmodule FixtureMCP do
  def run do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      line ->
        id =
          case Regex.run(~r/"id":(\d+)/, line) do
            [_, value] -> value
            _ -> nil
          end

        cond do
          String.contains?(line, "\"method\":\"initialize\"") ->
            IO.write(
              ~s({"jsonrpc":"2.0","id":#{id},"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}\n)
            )

          String.contains?(line, "\"method\":\"tools/list\"") ->
            IO.write(
              ~s({"jsonrpc":"2.0","id":#{id},"result":{"tools":[{"name":"ping","description":"Return pong","inputSchema":{"type":"object"}}]}}\n)
            )

          String.contains?(line, "\"method\":\"tools/call\"") ->
            if String.contains?(line, "\"crash\":true"), do: System.halt(2)
            if String.contains?(line, "\"slow\":true"), do: Process.sleep(5_000)

            IO.write(
              ~s({"jsonrpc":"2.0","id":#{id},"result":{"content":[{"type":"text","text":"pong"}],"isError":false}}\n)
            )

          true ->
            :ok
        end

        run()
    end
  end
end

FixtureMCP.run()
