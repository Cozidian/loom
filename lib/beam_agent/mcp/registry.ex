defmodule BeamAgent.MCP.Registry do
  @moduledoc "Goal-owned MCP server inventory, discovery, and namespaced tool dispatch."
  use GenServer

  alias BeamAgent.{Names, ToolRunner}
  alias BeamAgent.MCP.Server
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:mcp_registry, goal_id))
  end

  def start_server(goal_id, spec), do: call(goal_id, {:start_server, spec}, 30_000)
  def stop_server(goal_id, server), do: call(goal_id, {:stop_server, server})
  def servers(goal_id), do: call(goal_id, :servers)
  def tool_schemas(goal_id), do: call(goal_id, :tool_schemas)

  def execute(goal_id, namespaced_name, arguments, context) do
    with {:ok, tool} <- call(goal_id, {:resolve_tool, namespaced_name}) do
      ToolRunner.execute_mcp(tool.server, tool.original_name, arguments, context, fn ->
        safe_call(tool.pid, tool.original_name, arguments)
      end)
    end
  end

  @impl true
  def init(opts),
    do:
      {:ok,
       %{
         goal_id: Keyword.fetch!(opts, :goal_id),
         session_id: Keyword.fetch!(opts, :session_id),
         servers: %{},
         tools: %{}
       }}

  @impl true
  def handle_call(:servers, _from, state) do
    result =
      state.servers
      |> Map.values()
      |> Enum.map(fn server ->
        status = if is_pid(server.pid), do: health(server.pid), else: server.status

        server |> Map.drop([:pid, :monitor, :child_opts, :restarts]) |> Map.put(:status, status)
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, {:ok, result}, state}
  end

  def handle_call(:tool_schemas, _from, state),
    do: {:reply, Map.values(state.tools) |> Enum.map(& &1.schema), state}

  def handle_call({:start_server, spec}, _from, state) do
    name = value(spec, :name)

    with :ok <- validate_name(name),
         :ok <- ensure_absent(state.servers, name),
         {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id),
         {:ok, executable} <- executable(spec),
         child_opts <- [
           executable: executable,
           args: value(spec, :args) || [],
           cwd: value(spec, :cwd),
           env: value(spec, :env),
           session_id: state.session_id,
           startup_timeout_ms: value(spec, :startup_timeout_ms) || 10_000
         ],
         {:ok, pid} <- DynamicSupervisor.start_child(supervisor, {Server, child_opts}),
         {:ok, tools} <- Server.tools(pid) do
      server = %{
        name: name,
        pid: pid,
        monitor: Process.monitor(pid),
        status: :available,
        tool_count: length(tools),
        child_opts: child_opts,
        restarts: 0
      }

      namespaced = namespace_tools(name, pid, tools)

      state = %{
        state
        | servers: Map.put(state.servers, name, server),
          tools: Map.merge(state.tools, namespaced)
      }

      record(state, :mcp_server_started, %{"server" => name, "tool_count" => length(tools)})
      {:reply, {:ok, Map.drop(server, [:pid, :monitor, :child_opts, :restarts])}, state}
    else
      {:error, reason} ->
        record(state, :mcp_server_failed, %{"server" => name, "reason" => inspect(reason)})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_server, name}, _from, state) do
    case Map.pop(state.servers, name) do
      {nil, _} ->
        {:reply, {:error, {:unknown_mcp_server, name}}, state}

      {server, servers} ->
        if is_reference(server.monitor), do: Process.demonitor(server.monitor, [:flush])

        if is_pid(server.pid) do
          DynamicSupervisor.terminate_child(
            Names.pid(:goal_resource_supervisor, state.goal_id) |> elem(1),
            server.pid
          )
        end

        tools = Map.reject(state.tools, fn {_name, tool} -> tool.server == name end)
        state = %{state | servers: servers, tools: tools}
        record(state, :mcp_server_stopped, %{"server" => name, "reason" => "requested"})
        {:reply, :ok, state}
    end
  end

  def handle_call({:resolve_tool, namespaced}, _from, state) do
    case state.tools[namespaced] do
      nil ->
        {:reply, {:error, {:unknown_tool, namespaced}}, state}

      tool ->
        {:reply, {:ok, Map.drop(tool, [:schema])}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.servers, fn {_name, server} -> server.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {name, server} ->
        record(state, :mcp_server_unavailable, %{"server" => name, "reason" => inspect(reason)})
        tools = Map.reject(state.tools, fn {_key, tool} -> tool.server == name end)

        if server.restarts < 3 do
          Process.send_after(self(), {:restart_server, name}, 100)

          server = %{
            server
            | pid: nil,
              monitor: nil,
              status: :restarting,
              restarts: server.restarts + 1
          }

          {:noreply, %{state | servers: Map.put(state.servers, name, server), tools: tools}}
        else
          {:noreply, %{state | servers: Map.delete(state.servers, name), tools: tools}}
        end
    end
  end

  def handle_info({:restart_server, name}, state) do
    case state.servers[name] do
      %{status: :restarting} = server ->
        with {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id),
             {:ok, pid} <- DynamicSupervisor.start_child(supervisor, {Server, server.child_opts}),
             {:ok, tools} <- Server.tools(pid) do
          server = %{
            server
            | pid: pid,
              monitor: Process.monitor(pid),
              status: :available,
              tool_count: length(tools)
          }

          state = %{
            state
            | servers: Map.put(state.servers, name, server),
              tools: Map.merge(state.tools, namespace_tools(name, pid, tools))
          }

          record(state, :mcp_server_restarted, %{
            "server" => name,
            "attempt" => server.restarts,
            "tool_count" => length(tools)
          })

          {:noreply, state}
        else
          {:error, reason} ->
            record(state, :mcp_server_failed, %{
              "server" => name,
              "reason" => inspect(reason),
              "restart" => true
            })

            {:noreply, %{state | servers: Map.delete(state.servers, name)}}
        end

      _other ->
        {:noreply, state}
    end
  end

  defp namespace_tools(server, pid, tools) do
    Map.new(tools, fn tool ->
      original = tool["name"]
      name = "mcp__#{sanitize(server)}__#{sanitize(original)}"

      schema = %{
        name: name,
        description: tool["description"] || "MCP tool #{original}",
        input_schema: tool["inputSchema"] || %{type: "object"}
      }

      {name, %{server: server, pid: pid, original_name: original, schema: schema}}
    end)
  end

  defp executable(spec) do
    case value(spec, :command) do
      command when is_binary(command) and command != "" ->
        System.find_executable(command)
        |> case do
          nil -> {:error, {:mcp_executable_not_found, command}}
          path -> {:ok, path}
        end

      _ ->
        {:error, :mcp_command_required}
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/, name),
      do: :ok,
      else: {:error, {:invalid_mcp_server_name, name}}
  end

  defp validate_name(name), do: {:error, {:invalid_mcp_server_name, name}}

  defp ensure_absent(servers, name),
    do: if(Map.has_key?(servers, name), do: {:error, {:mcp_server_exists, name}}, else: :ok)

  defp sanitize(value), do: String.replace(value, ~r/[^a-zA-Z0-9_-]/, "_")
  defp value(spec, key) when is_list(spec), do: Keyword.get(spec, key)
  defp value(spec, key), do: spec[key] || spec[to_string(key)]
  defp record(state, type, data), do: EventLog.append(state.session_id, type, data)

  defp health(pid) do
    case Server.health(pid) do
      {:ok, value} -> value
      _ -> :unavailable
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp safe_call(pid, name, arguments) do
    Server.call(pid, name, arguments)
  catch
    :exit, reason -> {:error, {:mcp_unavailable, reason}}
  end

  defp call(goal_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:mcp_registry, goal_id),
         do: GenServer.call(pid, message, timeout)
  end
end
