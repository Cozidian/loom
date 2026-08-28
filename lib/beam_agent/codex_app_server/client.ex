defmodule BeamAgent.CodexAppServer.Client do
  @moduledoc """
  OTP-owned JSON-RPC client for the local `codex app-server` stdio transport.

  The client owns the external process, correlates requests without blocking its
  mailbox, and forwards server notifications and requests to one owner process.
  """
  use GenServer, restart: :temporary

  @default_timeout 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def request(client, method, params \\ %{}, timeout \\ @default_timeout) do
    GenServer.call(client, {:request, method, params}, timeout)
  end

  def notify(client, method, params \\ %{}) do
    GenServer.call(client, {:notify, method, params}, @default_timeout)
  end

  def respond(client, id, result) do
    GenServer.call(client, {:respond, id, result}, @default_timeout)
  end

  def stop(client) when is_pid(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal, @default_timeout)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())

    with executable when is_binary(executable) <- executable(opts),
         {:ok, port} <- open_port(executable, arguments(opts), opts) do
      {:ok,
       %{
         owner: owner,
         owner_monitor: Process.monitor(owner),
         port: port,
         buffer: "",
         next_id: 1,
         waiters: %{}
       }}
    else
      nil -> {:stop, :codex_not_installed}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = state.next_id
    message = %{"id" => id, "method" => method, "params" => params}

    case write(state.port, message) do
      :ok ->
        {:noreply, %{state | next_id: id + 1, waiters: Map.put(state.waiters, id, from)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    {:reply, write(state.port, %{"method" => method, "params" => params}), state}
  end

  def handle_call({:respond, id, result}, _from, state) do
    {:reply, write(state.port, %{"id" => id, "result" => result}), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {messages, buffer} = decode_lines(state.buffer <> data)
    state = %{state | buffer: buffer}
    {:noreply, Enum.reduce(messages, state, &dispatch/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:codex_app_server_exit, status}
    reply_waiters(state.waiters, {:error, reason})
    send(state.owner, {:codex_app_server, self(), {:exit, reason}})
    {:stop, reason, %{state | waiters: %{}}}
  end

  def handle_info({:DOWN, monitor, :process, owner, reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    {:stop, {:owner_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port), do: Port.close(state.port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp dispatch(%{"id" => id, "result" => result}, state) do
    reply(id, {:ok, result}, state)
  end

  defp dispatch(%{"id" => id, "error" => error}, state) do
    reply(id, {:error, {:codex_app_server_error, error}}, state)
  end

  defp dispatch(%{"id" => _id, "method" => _method} = request, state) do
    send(state.owner, {:codex_app_server, self(), {:request, request}})
    state
  end

  defp dispatch(%{"method" => _method} = notification, state) do
    send(state.owner, {:codex_app_server, self(), {:notification, notification}})
    state
  end

  defp dispatch(%{"decode_error" => reason, "line" => line}, state) do
    send(state.owner, {:codex_app_server, self(), {:protocol_error, reason, line}})
    state
  end

  defp dispatch(_message, state), do: state

  defp reply(id, result, state) do
    case Map.pop(state.waiters, id) do
      {nil, _waiters} ->
        state

      {from, waiters} ->
        GenServer.reply(from, result)
        %{state | waiters: waiters}
    end
  end

  defp reply_waiters(waiters, result) do
    Enum.each(waiters, fn {_id, from} -> GenServer.reply(from, result) end)
  end

  defp decode_lines(data) do
    parts = String.split(data, "\n")
    {complete, [buffer]} = Enum.split(parts, -1)

    messages =
      complete
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        case JSON.decode(line) do
          {:ok, message} when is_map(message) -> message
          {:error, reason} -> %{"decode_error" => reason, "line" => line}
          {:ok, other} -> %{"decode_error" => :non_object_message, "line" => inspect(other)}
        end
      end)

    {messages, buffer}
  end

  defp write(port, message) do
    case Port.command(port, [JSON.encode!(message), "\n"]) do
      true -> :ok
      false -> {:error, :codex_app_server_closed}
    end
  rescue
    error -> {:error, {:codex_app_server_write_failed, Exception.message(error)}}
  end

  defp executable(opts) do
    Keyword.get(opts, :executable) ||
      System.get_env("BEAM_AGENT_CODEX_BIN") ||
      System.find_executable("codex")
  end

  defp arguments(opts) do
    Keyword.get(opts, :arguments, ["app-server", "--stdio"])
  end

  defp open_port(executable, arguments, opts) do
    port_options = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:args, Enum.map(arguments, &String.to_charlist/1)}
    ]

    port_options =
      case Keyword.get(opts, :environment) do
        environment when is_list(environment) ->
          [
            {:env,
             Enum.map(environment, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}
            | port_options
          ]

        _ ->
          port_options
      end

    {:ok,
     Port.open(
       {:spawn_executable, String.to_charlist(executable)},
       port_options
     )}
  rescue
    error -> {:error, {:codex_app_server_start_failed, Exception.message(error)}}
  end
end
