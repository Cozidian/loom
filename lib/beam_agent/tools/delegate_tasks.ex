defmodule BeamAgent.Tools.DelegateTasks do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Goal.WorkspaceSnapshot

  @impl true
  def name, do: "delegate_tasks"

  @impl true
  def description do
    "Execute a task graph as supervised subagents. Independent tasks overlap within configured capacity; excess tasks wait. Workers may share the same provider/model. Use disjoint paths or dependency handoffs for implementation tasks."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        strategy: %{
          type: "string",
          enum: ["focused", "investigate", "implement", "review", "verify", "coordinate"]
        },
        tasks: %{
          type: "array",
          minItems: 1,
          items: %{
            type: "object",
            properties: %{
              id: %{type: "string"},
              goal: %{type: "string"},
              role: %{type: "string"},
              template: %{type: "string"},
              instructions: %{type: "array", items: %{type: "string"}},
              depends_on: %{type: "array", items: %{type: "string"}},
              capabilities: %{
                type: "object",
                properties: %{
                  paths: %{
                    type: "array",
                    items: %{type: "string"},
                    description:
                      "Optional authority boundary for every file read and write. Omit when the worker must inspect repository context outside its owned implementation paths."
                  }
                }
              },
              model_requirements: %{
                type: "object",
                properties: %{
                  preferred_endpoint_id: %{type: "string"},
                  reasoning: %{type: "string", enum: ["standard", "high"]},
                  locality: %{type: "string", enum: ["any", "local", "remote"]},
                  privacy: %{type: "string", enum: ["provider_allowed", "local"]},
                  cost: %{type: "string", enum: ["prefer_low", "balanced"]},
                  latency: %{type: "string", enum: ["interactive", "batch"]}
                }
              },
              verification_requirements: %{
                type: "object",
                properties: %{required: %{type: "boolean"}}
              },
              maximum_attempts: %{type: "integer", minimum: 1, maximum: 4},
              completion_criteria: %{type: "string"}
            },
            required: ["id", "goal"]
          }
        }
      },
      required: ["tasks"]
    }
  end

  @impl true
  def access, do: :delegate

  @impl true
  def execute(%{"tasks" => tasks} = arguments, context)
      when is_list(tasks) and tasks != [] do
    baseline = workspace_snapshot(context)

    opts = [
      strategy: arguments["strategy"] || "coordinate",
      owner: Map.get(context, :turn_owner),
      owner_turn_id: context.runtime_command.command_id,
      worker_options: [
        provider: context.provider,
        provider_profile: context.provider_profile,
        provider_options: context.provider_options,
        strategy: context.strategy,
        data_dir: context.data_dir,
        workspace_root: context.workspace_root,
        context_window_tokens: context.context_window_tokens,
        compaction_threshold_percent: context.compaction_threshold_percent,
        model_strategy: context.model_strategy,
        correlation_id: context.runtime_command.correlation_id,
        causation_id: context.causation_id
      ]
    ]

    with :ok <- reject_duplicate_goals(tasks),
         {:ok, result} <-
           BeamAgent.execute_decomposition(context.session_id, %{tasks: tasks}, opts) do
      {:ok, encode_result(result, workspace_delta(context, baseline))}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_nonempty_tasks}

  defp reject_duplicate_goals(tasks) do
    if Enum.all?(tasks, &(is_map(&1) and is_binary(Map.get(&1, "goal")))) do
      goals = Enum.map(tasks, &(Map.fetch!(&1, "goal") |> String.trim() |> String.downcase()))
      if Enum.uniq(goals) == goals, do: :ok, else: {:error, :duplicate_delegated_goal}
    else
      {:error, :invalid_decomposition_task}
    end
  end

  defp encode_result(result, workspace_delta) do
    tasks =
      Map.new(result.results, fn {id, value} ->
        content = get_in(value, [:result, Access.key(:content)])

        {id,
         %{
           status: result.tasks[id],
           content: content,
           endpoint_id: value[:endpoint_id],
           attempts: value[:attempts],
           verification: value[:verification],
           recovery: value[:recovery]
         }}
      end)

    used_endpoint_ids =
      tasks
      |> Map.values()
      |> Enum.map(& &1.endpoint_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    JSON.encode!(%{
      organization_id: result.organization_id,
      plan_id: result.plan_id,
      status: result.status,
      changed_files: workspace_delta.changed_files,
      patch_fingerprint: workspace_delta.patch_fingerprint,
      used_endpoint_ids: used_endpoint_ids,
      recovery: result[:recovery],
      tasks: tasks
    })
  end

  defp workspace_snapshot(%{
         project_id: project_id,
         workspace_root: workspace_root,
         data_dir: data_dir
       }) do
    WorkspaceSnapshot.capture(project_id,
      workspace_root: workspace_root,
      data_dir: data_dir
    )
  end

  defp workspace_snapshot(_context), do: {:error, :project_unavailable}

  defp workspace_delta(%{project_id: project_id}, {:ok, baseline}) do
    case WorkspaceSnapshot.capture(project_id,
           workspace_root: baseline.workspace_root,
           exclude: baseline.excluded_roots,
           data_dir: baseline.runtime_data_root
         ) do
      {:ok, current} -> WorkspaceSnapshot.delta(baseline, current)
      {:error, _reason} -> WorkspaceSnapshot.empty_delta()
    end
  end

  defp workspace_delta(_context, _baseline), do: WorkspaceSnapshot.empty_delta()
end
