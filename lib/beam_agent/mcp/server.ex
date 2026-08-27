defmodule BeamAgent.MCP.Server do
  @moduledoc "A supervised local stdio MCP transport with bounded JSON-RPC requests."
  use GenServer

  @protocol_version "2025-06-18"
  @max_buffer_bytes 1_000_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :executable)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def tools(pid), do: GenServer.call(pid, :tools)

  def call(pid, name, arguments, timeout \\ 30_000),
    do: GenServer.call(pid, {:call, name, arguments, timeout}, timeout + 1_000)

  def health(pid), do: GenServer.call(pid, :health)

  @impl true
  def init(opts) do
    executable = Keyword.fetch!(opts, :executable)
    args = Keyword.get(opts, :args, [])
    {executable, args} = sanitized_command(executable, args, Keyword.get(opts, :env, %{}))
    timeout = Keyword.get(opts, :startup_timeout_ms, 10_000)

    port_opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args]
    port_opts = if cwd = Keyword.get(opts, :cwd), do: [{:cd, cwd} | port_opts], else: port_opts

    try do
      port = Port.open({:spawn_executable, executable}, port_opts)

      with {:ok, _initialize, buffer} <-
             request(
               port,
               1,
               "initialize",
               %{
                 protocolVersion: @protocol_version,
                 capabilities: %{},
                 clientInfo: %{name: "beam_agent", version: "0.1.0"}
               },
               timeout,
               ""
             ),
           true <-
             Port.command(
               port,
               encode(%{jsonrpc: "2.0", method: "notifications/initialized", params: %{}})
             ),
           {:ok, response, buffer} <- request(port, 2, "tools/list", %{}, timeout, buffer) do
        {:ok,
         %{
           port: port,
           next_id: 3,
           buffer: buffer,
           tools: get_in(response, ["result", "tools"]) || [],
           status: :available,
           pending: %{},
           session_id: Keyword.get(opts, :session_id)
         }}
      else
        false ->
          {:stop, :mcp_port_closed}

        {:error, reason} ->
          Port.close(port)
          {:stop, reason}
      end
    rescue
      error -> {:stop, {:mcp_start_failed, Exception.message(error)}}
    end
  end

  @impl true
  def handle_call(:tools, _from, state), do: {:reply, {:ok, state.tools}, state}
  def handle_call(:health, _from, state), do: {:reply, {:ok, state.status}, state}

  def handle_call({:call, name, arguments, timeout}, from, state) do
    id = state.next_id

    if Port.command(
         state.port,
         encode(%{
           jsonrpc: "2.0",
           id: id,
           method: "tools/call",
           params: %{name: name, arguments: arguments}
         })
       ) do
      {caller, _tag} = from

      pending = %{
        from: from,
        tool: name,
        monitor: Process.monitor(caller),
        timer: Process.send_after(self(), {:request_timeout, id, timeout}, timeout)
      }

      {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, pending)}}
    else
      {:reply, {:error, :mcp_port_closed}, %{state | status: :unavailable}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:shutdown, {:mcp_exit, status}}, %{state | status: :unavailable}}

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    if byte_size(buffer) > @max_buffer_bytes do
      {:stop, :mcp_output_limit, %{state | status: :unavailable}}
    else
      {messages, buffer} = messages(buffer, [])
      {:noreply, Enum.reduce(messages, %{state | buffer: buffer}, &resolve_response/2)}
    end
  end

  def handle_info({:request_timeout, id, timeout}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, rest} ->
        Process.demonitor(pending.monitor, [:flush])

        _ =
          Port.command(
            state.port,
            encode(%{
              jsonrpc: "2.0",
              method: "notifications/cancelled",
              params: %{requestId: id, reason: "request timeout"}
            })
          )

        GenServer.reply(pending.from, {:error, {:mcp_timeout, timeout}})
        {:noreply, %{state | pending: rest, status: :degraded}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state) do
    case Enum.find(state.pending, fn {_id, pending} -> pending.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {id, pending} ->
        Process.cancel_timer(pending.timer)

        _ =
          Port.command(
            state.port,
            encode(%{
              jsonrpc: "2.0",
              method: "notifications/cancelled",
              params: %{requestId: id, reason: "caller exited"}
            })
          )

        if state.session_id do
          _ =
            BeamAgent.Session.EventLog.append(state.session_id, :mcp_call_cancelled, %{
              "request_id" => id,
              "tool" => pending.tool,
              "reason" => "caller_exited"
            })
        end

        {:noreply, %{state | pending: Map.delete(state.pending, id)}}
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp request(port, id, method, params, timeout, buffer) do
    if Port.command(port, encode(%{jsonrpc: "2.0", id: id, method: method, params: params})) do
      await(port, id, timeout, buffer)
    else
      {:error, :mcp_port_closed}
    end
  end

  defp await(port, id, timeout, buffer) do
    if byte_size(buffer) > @max_buffer_bytes do
      {:error, :mcp_output_limit}
    else
      await_message(port, id, timeout, buffer)
    end
  end

  defp await_message(port, id, timeout, buffer) do
    case take_message(buffer) do
      {:ok, %{"id" => ^id} = response, rest} ->
        {:ok, response, rest}

      {:ok, _other, rest} ->
        await(port, id, timeout, rest)

      :more ->
        receive do
          {^port, {:data, data}} -> await(port, id, timeout, buffer <> data)
          {^port, {:exit_status, status}} -> {:error, {:mcp_exit, status}}
        after
          timeout -> {:error, {:mcp_timeout, timeout}}
        end
    end
  end

  defp take_message(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] when line != "" ->
        case JSON.decode(line) do
          {:ok, message} -> {:ok, message, rest}
          {:error, _} -> take_message(rest)
        end

      ["", rest] ->
        take_message(rest)

      _ ->
        :more
    end
  end

  defp messages(buffer, acc) do
    case take_message(buffer) do
      {:ok, message, rest} -> messages(rest, [message | acc])
      :more -> {Enum.reverse(acc), buffer}
    end
  end

  defp resolve_response(%{"id" => id} = response, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {pending, rest} ->
        Process.demonitor(pending.monitor, [:flush])
        Process.cancel_timer(pending.timer)
        result = response["result"] || %{}

        reply =
          cond do
            response["error"] -> {:error, {:mcp_error, response["error"]}}
            result["isError"] -> {:error, {:mcp_tool_error, result}}
            true -> {:ok, content(result)}
          end

        GenServer.reply(pending.from, reply)
        %{state | pending: rest}
    end
  end

  defp resolve_response(_message, state), do: state

  defp encode(message), do: JSON.encode!(message) <> "\n"

  defp sanitized_command(executable, args, env) do
    case System.find_executable("env") do
      nil ->
        {executable, args}

      env_executable ->
        variables =
          [{"PATH", System.get_env("PATH") || ""} | Enum.to_list(env || %{})]
          |> Enum.map(fn
            {"PATH", value} ->
              "PATH=#{value}"

            {key, source_name} ->
              source_name = to_string(source_name)

              case System.fetch_env(source_name) do
                {:ok, value} ->
                  "#{key}=#{value}"

                :error ->
                  raise ArgumentError, "MCP environment variable #{source_name} is not set"
              end
          end)

        {env_executable, ["-i" | variables] ++ [executable | args]}
    end
  end

  defp content(%{"content" => content}), do: JSON.encode!(content)
  defp content(result), do: JSON.encode!(result)
end
