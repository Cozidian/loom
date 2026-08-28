defmodule BeamAgent.Runtime.JSONLineServer do
  @moduledoc """
  Authenticated loopback JSON-lines transport for editor and external clients.

  Each connection owns an ordinary `BeamAgent.Runtime` observer. Commands use
  `BeamAgent.Runtime.JSONProtocol`; goal events are pushed on the same socket.
  The listener never owns the goal, so disconnects and server shutdown do not
  terminate autonomous work.
  """
  use GenServer

  alias BeamAgent.Runtime
  alias BeamAgent.Runtime.JSONProtocol

  @maximum_packet_bytes 1_048_576

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def address(server), do: GenServer.call(server, :address)
  def token(server), do: GenServer.call(server, :token)

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    token = Keyword.get_lazy(opts, :token, &new_token/0)
    port = Keyword.get(opts, :port, 0)

    listen_opts = [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      packet_size: @maximum_packet_bytes
    ]

    with true <- is_binary(token) and byte_size(token) >= 16,
         {:ok, listener} <- :gen_tcp.listen(port, listen_opts),
         {:ok, {_ip, actual_port}} <- :inet.sockname(listener) do
      owner = self()
      acceptor = spawn_link(fn -> accept_loop(listener, owner, session_id, token) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         session_id: session_id,
         token: token,
         address: {{127, 0, 0, 1}, actual_port}
       }}
    else
      false -> {:stop, :invalid_api_token}
      {:error, reason} -> {:stop, {:api_listener_failed, reason}}
    end
  end

  @impl true
  def handle_call(:address, _from, state), do: {:reply, {:ok, state.address}, state}
  def handle_call(:token, _from, state), do: {:reply, {:ok, state.token}, state}

  @impl true
  def handle_info({:acceptor_failed, reason}, state),
    do: {:stop, {:api_acceptor_failed, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(listener, owner, session_id, token) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn(fn -> await_socket(session_id, token) end)

        case :gen_tcp.controlling_process(socket, handler) do
          :ok -> send(handler, {:socket, socket})
          {:error, _reason} -> :gen_tcp.close(socket)
        end

        accept_loop(listener, owner, session_id, token)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(owner, {:acceptor_failed, reason})
    end
  end

  defp await_socket(session_id, token) do
    receive do
      {:socket, socket} -> serve(socket, session_id, token)
    after
      5_000 -> :ok
    end
  end

  defp serve(socket, session_id, token) do
    case Runtime.connect(session_id, subscriber: self(), view: :public) do
      {:ok, runtime} ->
        :ok = :inet.setopts(socket, active: :once)
        connection_loop(socket, runtime, token)

      {:error, reason} ->
        send_json(socket, error_response(nil, reason))
        :gen_tcp.close(socket)
    end
  end

  defp connection_loop(socket, runtime, token) do
    receive do
      {:tcp, ^socket, line} ->
        response = dispatch_line(runtime, token, line)
        send_json(socket, response)
        :ok = :inet.setopts(socket, active: :once)
        connection_loop(socket, runtime, token)

      {:tcp_closed, ^socket} ->
        Runtime.disconnect(runtime)

      {:tcp_error, ^socket, _reason} ->
        Runtime.disconnect(runtime)

      {:beam_agent_runtime, ^runtime, {:event, event}} ->
        send_json(socket, JSONProtocol.event(event))
        connection_loop(socket, runtime, token)

      {:beam_agent_runtime, ^runtime, message} ->
        send_json(socket, %{
          version: 1,
          type: "notification",
          message: JSONProtocol.normalize(message)
        })

        connection_loop(socket, runtime, token)
    after
      300_000 ->
        Runtime.disconnect(runtime)
        :gen_tcp.close(socket)
    end
  end

  defp dispatch_line(runtime, token, line) do
    with {:ok, request} when is_map(request) <- JSON.decode(String.trim(line)),
         true <- authorized?(token, request["token"] || request[:token]) do
      request = Map.drop(request, ["token", :token])
      JSONProtocol.dispatch(runtime, request)
    else
      false -> error_response(nil, :unauthorized)
      {:ok, _other} -> error_response(nil, :invalid_protocol_request)
      {:error, _reason} -> error_response(nil, :invalid_json)
    end
  end

  defp authorized?(expected, supplied) when is_binary(supplied) do
    byte_size(expected) == byte_size(supplied) and
      :crypto.hash(:sha256, expected) == :crypto.hash(:sha256, supplied)
  end

  defp authorized?(_expected, _supplied), do: false

  defp error_response(request_id, reason) do
    %{
      version: 1,
      type: "response",
      request_id: request_id,
      ok: false,
      error: to_string(reason)
    }
  end

  defp send_json(socket, value),
    do: :gen_tcp.send(socket, [JSONProtocol.encode_response(value), "\n"])

  defp new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
