defmodule BeamAgent.Tools.SpawnSubagent do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "spawn_subagent"

  @impl true
  def description,
    do:
      "Request one independently bounded specialist, then await its answer. Do not use this to transfer or duplicate ownership of a coherent implementation. The runtime controls authority, resources, model eligibility, and lifecycle."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        prompt: %{type: "string", description: "Specific delegated goal"},
        role: %{type: "string", description: "Optional fit-for-purpose specialist role"},
        instructions: %{
          type: "array",
          items: %{type: "string"},
          description: "Optional behavioral instructions; these cannot grant authority"
        },
        template: %{type: "string", description: "Optional starting strategy name"},
        capabilities: %{
          type: "object",
          description: "Optional capability reduction requested from the parent envelope",
          properties: %{
            tools: %{type: "array", items: %{type: "string"}},
            paths: %{type: "array", items: %{type: "string"}},
            commands: %{type: "array", items: %{type: "string"}},
            hosts: %{type: "array", items: %{type: "string"}},
            git_operations: %{type: "array", items: %{type: "string"}},
            browser_scopes: %{type: "array", items: %{type: "string"}},
            mcp_servers: %{type: "array", items: %{type: "string"}},
            model_classes: %{type: "array", items: %{type: "string"}},
            secret_kinds: %{type: "array", items: %{type: "string"}},
            approval_scopes: %{type: "array", items: %{type: "string"}}
          }
        },
        model_requirements: %{
          type: "object",
          properties: %{
            preferred_endpoint_id: %{
              type: "string",
              description: "Optional endpoint from list_models; may be the same as the owner"
            },
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
        completion_criteria: %{type: "string"},
        background: %{
          type: "boolean",
          description: "Return a handle immediately and let the worker run concurrently"
        }
      },
      required: ["prompt"]
    }
  end

  @impl true
  def access, do: :delegate

  @impl true
  def execute(%{"prompt" => prompt} = arguments, context)
      when is_binary(prompt) and prompt != "" do
    approval_policy =
      case BeamAgent.approval_policy(context.session_id) do
        {:ok, policy} -> policy
        {:error, _reason} -> context.approval_policy
      end

    approval_handler =
      case BeamAgent.approval_handler(context.session_id) do
        {:ok, handler} when is_pid(handler) -> handler
        _other -> context.approval_handler
      end

    opts = [
      provider: context.provider,
      provider_profile: context.provider_profile,
      provider_options: context.provider_options,
      strategy: context.strategy,
      data_dir: context.data_dir,
      workspace_root: context.workspace_root,
      approval_policy: approval_policy,
      approval_handler: approval_handler,
      context_window_tokens: context.context_window_tokens,
      compaction_threshold_percent: context.compaction_threshold_percent,
      model_strategy: context.model_strategy,
      agent_proposal:
        arguments
        |> Map.take([
          "role",
          "instructions",
          "template",
          "capabilities",
          "model_requirements",
          "verification_requirements",
          "completion_criteria"
        ])
        |> Map.put("goal", prompt),
      correlation_id: context.runtime_command.correlation_id,
      causation_id: context.causation_id
    ]

    with {:ok, handle} <- BeamAgent.spawn_worker(context.session_id, opts[:agent_proposal], opts) do
      if Map.get(arguments, "background", false) do
        with :ok <- BeamAgent.start_worker(handle, prompt) do
          {:ok,
           JSON.encode!(%{
             child_session_id: handle.worker_id,
             delegation_id: handle.delegation_id,
             agent_spec_id: handle.spec_id,
             role: handle.role,
             status: "running",
             background: true
           })}
        end
      else
        try do
          case BeamAgent.ask(handle.worker_id, prompt) do
            {:ok, answer} ->
              {:ok, result} = BeamAgent.complete_worker(handle, answer)

              {:ok,
               JSON.encode!(%{
                 child_session_id: handle.worker_id,
                 delegation_id: handle.delegation_id,
                 agent_spec_id: handle.spec_id,
                 role: handle.role,
                 status: result.status,
                 answer: answer
               })}

            {:error, reason} = error ->
              _ = BeamAgent.cancel_worker(handle, reason)
              error
          end
        after
          _ = BeamAgent.stop_session(handle.worker_id)
        end
      end
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_non_empty_prompt}
end
