defmodule BeamAgent.Tools.DelegateTasks do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "delegate_tasks"

  @impl true
  def description do
    "Execute a small dependency graph of dynamically constructed specialist workers with bounded parallelism."
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
          maxItems: 8,
          items: %{
            type: "object",
            properties: %{
              id: %{type: "string"},
              goal: %{type: "string"},
              role: %{type: "string"},
              template: %{type: "string"},
              instructions: %{type: "array", items: %{type: "string"}},
              depends_on: %{type: "array", items: %{type: "string"}},
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
      when is_list(tasks) and length(tasks) in 1..8 do
    opts = [
      strategy: arguments["strategy"] || "coordinate",
      worker_options: [
        provider: context.provider,
        provider_profile: context.provider_profile,
        provider_options: context.provider_options,
        strategy: context.strategy,
        data_dir: context.data_dir,
        workspace_root: context.workspace_root,
        approval_policy: context.approval_policy,
        approval_handler: context.approval_handler,
        context_window_tokens: context.context_window_tokens,
        compaction_threshold_percent: context.compaction_threshold_percent,
        model_strategy: context.model_strategy,
        correlation_id: context.runtime_command.correlation_id,
        causation_id: context.causation_id
      ]
    ]

    case BeamAgent.execute_decomposition(context.session_id, %{tasks: tasks}, opts) do
      {:ok, result} -> {:ok, encode_result(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_one_to_eight_tasks}

  defp encode_result(result) do
    tasks =
      Map.new(result.results, fn {id, value} ->
        content = get_in(value, [:result, Access.key(:content)])
        {id, %{status: result.tasks[id], content: content}}
      end)

    JSON.encode!(%{
      organization_id: result.organization_id,
      plan_id: result.plan_id,
      status: result.status,
      tasks: tasks
    })
  end
end
