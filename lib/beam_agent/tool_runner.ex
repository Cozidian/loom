defmodule BeamAgent.ToolRunner do
  @moduledoc "Guarded execution boundary shared by every model-callable tool."

  alias BeamAgent.{CapabilityEnvelope, Session.ToolPolicy}
  alias BeamAgent.Goal.{BudgetManager, CapabilityManager}

  def execute(module, arguments, context) do
    access = if function_exported?(module, :access, 0), do: module.access(), else: :execute

    resource = resource(module.name(), arguments)

    with :ok <- authorize_capability(context, resource),
         :ok <-
           ToolPolicy.authorize(context.session_id, module.name(), arguments, access, resource),
         :ok <- consume_budget(context, module.name(), arguments) do
      result =
        schedule(context, tool_pool(module.name(), arguments), fn ->
          invoke(module, arguments, context)
        end)

      publish_deterministic_result(context, module.name(), arguments, result)
      result
    end
  end

  def execute_mcp(server, tool, arguments, context, invoke) when is_function(invoke, 0) do
    name = "mcp__#{server}__#{tool}"
    resource = %{tools: name, mcp_servers: server}

    with :ok <- authorize_capability(context, resource),
         :ok <- ToolPolicy.authorize(context.session_id, name, arguments, :execute, resource),
         :ok <- consume_budget(context, name, arguments) do
      schedule(context, :mcp, invoke)
    end
  end

  defp authorize_capability(context, resource) do
    case CapabilityEnvelope.authorize(Map.get(context, :capability_envelope), resource) do
      :ok ->
        :ok

      {:error, envelope_reason} ->
        case CapabilityManager.authorize(context.goal_id, context.session_id, resource) do
          {:ok, _lease_id} ->
            :ok

          {:error, _lease_reason} ->
            _ =
              BeamAgent.Session.EventLog.append(context.session_id, :capability_denied, %{
                "resource" => stringify(resource),
                "reason" => inspect(envelope_reason)
              })

            {:error, envelope_reason}
        end
    end
  end

  defp resource(tool, arguments) do
    %{
      tools: tool,
      paths: arguments["path"] || arguments["cwd"],
      commands: command_family(arguments["command"]),
      hosts: host(arguments["url"]),
      git_operations: git_operation(tool, arguments),
      browser_scopes: browser_scope(tool)
    }
  end

  defp command_family(command) when is_binary(command),
    do: command |> String.trim() |> String.split(~r/\s+/, parts: 2) |> List.first()

  defp command_family(_), do: nil
  defp host(url) when is_binary(url), do: URI.parse(url).host
  defp host(_), do: nil
  defp git_operation("git_inspect", arguments), do: arguments["operation"]
  defp git_operation(_tool, _arguments), do: nil
  defp browser_scope(tool) when tool in ["browser", "browser_control"], do: "interactive"
  defp browser_scope(_tool), do: nil
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp consume_budget(context, tool, arguments) do
    consumption = budget_consumption(tool, arguments)

    if map_size(consumption) == 0,
      do: :ok,
      else: BudgetManager.consume(context.goal_id, context.session_id, consumption)
  end

  defp budget_consumption("run_command", arguments) do
    command = arguments["command"] || ""
    tests = if Regex.match?(~r/(^|\s)(mix|go|npm|pnpm)\s+test\b/, command), do: 1, else: 0
    %{shell_commands: 1, test_runs: tests}
  end

  defp budget_consumption(_tool, _arguments), do: %{}

  defp tool_pool("run_command", arguments) do
    if budget_consumption("run_command", arguments).test_runs > 0, do: :test, else: :shell
  end

  defp tool_pool(_tool, _arguments), do: nil

  defp schedule(_context, nil, fun), do: fun.()

  defp schedule(context, pool, fun) do
    project_id =
      Map.get(context, :project_id) ||
        case BeamAgent.Goal.snapshot(context.goal_id) do
          {:ok, goal} -> goal.project_id
          _other -> nil
        end

    if project_id do
      BeamAgent.Project.ResourceScheduler.run(
        project_id,
        pool,
        [
          session_id: context.session_id,
          priority: if(Map.get(context, :parent_session_id), do: 0, else: 10)
        ],
        fun
      )
    else
      fun.()
    end
  end

  defp publish_deterministic_result(context, tool, arguments, result) do
    if match?({:ok, _}, result) and tool in ["create_file", "edit_file", "apply_patch"] do
      _ = BeamAgent.Project.RepositoryIndex.notify_change(context.project_id)
    end

    if tool == "run_command" and budget_consumption(tool, arguments).test_runs > 0 do
      {status, exit_status, truncated} = command_evidence(result)

      command_fingerprint =
        :crypto.hash(:sha256, arguments["command"] || "") |> Base.encode16(case: :lower)

      _ =
        BeamAgent.Session.EventLog.append(context.session_id, :test_run_finished, %{
          "status" => status,
          "exit_status" => exit_status,
          "truncated" => truncated,
          "command_fingerprint" => command_fingerprint
        })

      persist_test_history(context, command_fingerprint, status, exit_status, truncated)
    end

    :ok
  end

  defp persist_test_history(context, command_fingerprint, status, exit_status, truncated) do
    case project_id(context) do
      nil ->
        :ok

      project_id ->
        observed_at = DateTime.utc_now() |> DateTime.to_iso8601()

        _ =
          BeamAgent.Project.ContextStore.put(project_id, %{
            id: "test:#{command_fingerprint}",
            kind: "test_history",
            source: command_fingerprint,
            source_version: System.system_time(:millisecond),
            content:
              JSON.encode!(%{
                status: status,
                exit_status: exit_status,
                truncated: truncated,
                observed_at: observed_at
              }),
            metadata: %{session_id: context.session_id}
          })

        :ok
    end
  end

  defp project_id(context) do
    Map.get(context, :project_id) ||
      case BeamAgent.Goal.snapshot(context.goal_id) do
        {:ok, goal} -> goal.project_id
        _other -> nil
      end
  end

  defp command_evidence({:ok, encoded}) do
    case JSON.decode(encoded) do
      {:ok, %{"status" => 0} = data} -> {"passed", 0, data["truncated"]}
      {:ok, data} -> {"failed", data["status"], data["truncated"]}
      _other -> {"unknown", nil, false}
    end
  end

  defp command_evidence({:error, {:command_failed, data}}),
    do: {"failed", data.status, data.truncated}

  defp command_evidence(_result), do: {"failed", nil, false}

  defp invoke(module, arguments, context) do
    try do
      module.execute(arguments, context)
    rescue
      error -> {:error, {:tool_exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:tool_throw, kind, reason}}
    end
  end
end
