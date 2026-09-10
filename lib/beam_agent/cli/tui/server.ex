defmodule BeamAgent.CLI.TUI.Server do
  @moduledoc "Authenticated, length-framed TUI bridge to an existing owner. No events are sent before authentication."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def port(server), do: GenServer.call(server, :port)

  def init(opts) do
    with {:ok, listener} <-
           :gen_tcp.listen(0, [
             :binary,
             packet: 4,
             packet_size: 16_777_216,
             active: false,
             ip: {127, 0, 0, 1}
           ]),
         {:ok, {_, port}} <- :inet.sockname(listener),
         {:ok, tasks} <- Task.Supervisor.start_link() do
      acceptor = spawn_link(fn -> accept(listener, tasks, opts) end)
      {:ok, %{listener: listener, port: port, tasks: tasks, acceptor: acceptor}}
    end
  end

  def handle_call(:port, _, state), do: {:reply, {:ok, state.port}, state}

  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Supervisor.stop(state.tasks)
  end

  defp accept(listener, tasks, opts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(tasks, fn ->
            receive do
              {:socket, socket} -> authenticate(socket, opts)
            after
              5000 -> :ok
            end
          end)

        case :gen_tcp.controlling_process(socket, pid) do
          :ok -> send(pid, {:socket, socket})
          _ -> :gen_tcp.close(socket)
        end

        accept(listener, tasks, opts)

      _ ->
        :ok
    end
  end

  defp authenticate(socket, opts) do
    try do
      with {:ok, bytes} <- :gen_tcp.recv(socket, 0, 3000),
           {:ok, %{"token" => supplied}} when is_binary(supplied) <- JSON.decode(bytes),
           true <- :crypto.hash(:sha256, supplied) == :crypto.hash(:sha256, opts[:token]) do
        BeamAgent.CLI.TUI.serve_socket(
          socket,
          opts[:session_id],
          opts[:config],
          opts[:config_path]
        )
      else
        _ -> :gen_tcp.send(socket, JSON.encode!(%{type: "error", error: "unauthorized"}))
      end
    after
      :gen_tcp.close(socket)
    end
  end
end
