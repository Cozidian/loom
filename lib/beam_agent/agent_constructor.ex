defmodule BeamAgent.AgentConstructor do
  @moduledoc """
  Deterministically populates runtime `AgentSpec` values from proposals and
  policy-owned parent/project state.

  Proposal fields are soft configuration. Effective capabilities, restrictions,
  resources, and lifecycle always come from the runtime.
  """

  alias BeamAgent.{Agent, AgentSpec, CapabilityEnvelope, ProjectContext, TaskClassifier}

  @maximum_delegation_depth 4

  def root(opts) when is_list(opts) do
    envelope = Keyword.fetch!(opts, :capability_envelope)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    goal = Keyword.get(opts, :objective) || "Coordinate work requested through this session"
    role = Keyword.get(opts, :role) || "Goal coordinator"
    instructions = normalize_instructions(Keyword.get(opts, :agent_instructions, []))

    with {:ok, context} <- ProjectContext.load(workspace_root) do
      AgentSpec.new(%{
        goal: goal,
        role: role,
        instructions: instructions,
        context_refs: [%{kind: "project_context", id: context.fingerprint}],
        requested_capabilities: :inherit,
        effective_capabilities: envelope,
        restrictions: restrictions(workspace_root, envelope),
        resources: resources(opts),
        model_requirements: root_model_requirements(opts),
        verification_requirements: %{required: false, source: "goal_default"},
        parent: nil,
        lifecycle: lifecycle(0),
        template: "goal-coordinator",
        provenance: %{
          goal: if(Keyword.get(opts, :objective), do: "user", else: "runtime_default"),
          role: if(Keyword.get(opts, :role), do: "user", else: "runtime_default"),
          instructions:
            if(Keyword.get(opts, :agent_instructions), do: "user", else: "runtime_default"),
          context_refs: "project_state",
          requested_capabilities: "runtime_root",
          effective_capabilities: "runtime_policy",
          restrictions: "runtime_policy",
          resources: "project_default",
          model_requirements: "project_default",
          verification_requirements: "goal_default",
          lifecycle: "runtime_policy",
          template: "runtime_default"
        }
      })
    end
  end

  def child(parent_session_id, proposal, opts \\ [])

  def child(parent_session_id, proposal, opts)
      when is_binary(parent_session_id) and is_map(proposal) and is_list(opts) do
    with {:ok, parent} <- Agent.construction_context(parent_session_id),
         {:ok, project_context} <- ProjectContext.load(parent.workspace_root),
         depth <- parent_depth(parent.agent_spec) + 1,
         :ok <- validate_depth(depth),
         goal when is_binary(goal) and goal != "" <- value(proposal, :goal),
         {:ok, requested} <- requested_capabilities(proposal),
         {:ok, envelope} <- effective_envelope(parent.capability_envelope, requested) do
      classification = TaskClassifier.classify(goal, parent.workspace_root)
      role = role(proposal, classification)
      instructions = normalize_instructions(value(proposal, :instructions) || [])
      template = normalize_template(value(proposal, :template), classification)

      AgentSpec.new(%{
        goal: goal,
        role: role,
        instructions: instructions,
        context_refs: [
          %{kind: "project_context", id: project_context.fingerprint},
          %{kind: "parent_worker", id: parent_session_id}
        ],
        requested_capabilities: requested,
        effective_capabilities: envelope,
        restrictions: restrictions(parent.workspace_root, envelope),
        resources: resources_from_parent(parent, opts),
        model_requirements: model_requirements(proposal, parent),
        verification_requirements: verification_requirements(proposal),
        parent: %{
          worker_id: parent_session_id,
          spec_id: parent.agent_spec && parent.agent_spec.spec_id,
          capability_envelope_id: parent.capability_envelope.id
        },
        lifecycle: lifecycle(depth),
        template: template,
        provenance: %{
          goal: "parent_proposal",
          role: if(value(proposal, :role), do: "parent_proposal", else: "runtime_inference"),
          instructions:
            if(value(proposal, :instructions),
              do: "parent_proposal",
              else: "runtime_default"
            ),
          context_refs: "runtime_context_selection",
          requested_capabilities:
            if(requested == :inherit, do: "parent_inheritance", else: "parent_proposal"),
          effective_capabilities: "runtime_policy",
          restrictions: "runtime_policy",
          resources: "parent_allocation",
          model_requirements:
            if(value(proposal, :model_requirements),
              do: "parent_proposal_runtime_constrained",
              else: "parent_inheritance"
            ),
          verification_requirements: "runtime_policy",
          lifecycle: "runtime_policy",
          template:
            if(value(proposal, :template), do: "parent_proposal", else: "runtime_inference")
        }
      })
    else
      nil -> {:error, :missing_agent_goal}
      false -> {:error, :missing_agent_goal}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_agent_proposal}
    end
  end

  def child(_parent_session_id, _proposal, _opts), do: {:error, :invalid_agent_proposal}

  defp effective_envelope(parent, :inherit), do: {:ok, parent}
  defp effective_envelope(parent, requested), do: CapabilityEnvelope.restrict(parent, requested)

  defp requested_capabilities(proposal) do
    case value(proposal, :capabilities) do
      nil -> {:ok, :inherit}
      requested when is_map(requested) -> {:ok, requested}
      _invalid -> {:error, :invalid_requested_capabilities}
    end
  end

  defp role(proposal, classification) do
    case value(proposal, :role) do
      value when is_binary(value) and value != "" -> value
      _other -> inferred_role(classification)
    end
  end

  defp inferred_role(classification) do
    language =
      case classification.language do
        :unknown -> nil
        value -> value |> to_string() |> String.capitalize()
      end

    focus =
      case classification.task_type do
        :orchestration -> "coordination"
        :architecture -> "architecture"
        :debugging -> "debugging"
        :verification -> "verification"
        :implementation -> "implementation"
        :deterministic -> "deterministic"
        :simple -> "focused"
        _other -> "general"
      end

    [language, focus, "specialist"] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp normalize_template(nil, classification), do: "dynamic-#{classification.task_type}"

  defp normalize_template(template, _classification) when is_binary(template) and template != "",
    do: template

  defp normalize_template(_template, classification), do: "dynamic-#{classification.task_type}"

  defp normalize_instructions(instructions) when is_binary(instructions), do: [instructions]

  defp normalize_instructions(instructions) when is_list(instructions) do
    instructions
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.take(16)
  end

  defp normalize_instructions(_instructions), do: []

  defp restrictions(workspace_root, envelope) do
    %{
      workspace_root: workspace_root,
      external_network: :denied,
      capability_envelope_id: envelope.id,
      authority_source: :runtime_policy
    }
  end

  defp resources(opts) do
    %{
      context_window_tokens: Keyword.get(opts, :context_window_tokens, 32_000),
      budget: :not_allocated
    }
  end

  defp resources_from_parent(parent, opts) do
    %{
      context_window_tokens:
        Keyword.get(opts, :context_window_tokens, parent.context_window_tokens),
      budget: :not_allocated
    }
  end

  defp root_model_requirements(opts) do
    %{
      reasoning: :standard,
      locality: if(Keyword.get(opts, :model_strategy) == :local_only, do: :local, else: :any),
      privacy:
        if(Keyword.get(opts, :model_strategy) == :local_only,
          do: :local,
          else: :provider_allowed
        ),
      cost: :prefer_low,
      latency: :interactive
    }
  end

  defp model_requirements(proposal, parent) do
    requested = value(proposal, :model_requirements)
    requested = if is_map(requested), do: requested, else: %{}

    inherited_privacy =
      if parent.model_strategy == :local_only, do: :local, else: :provider_allowed

    %{
      reasoning: enum_value(requested, :reasoning, [:standard, :high], :standard),
      locality: enum_value(requested, :locality, [:any, :local, :remote], :any),
      privacy: enum_value(requested, :privacy, [:provider_allowed, :local], inherited_privacy),
      cost: enum_value(requested, :cost, [:prefer_low, :balanced], :prefer_low),
      latency: enum_value(requested, :latency, [:interactive, :batch], :interactive)
    }
    |> constrain_privacy(inherited_privacy)
  end

  defp constrain_privacy(requirements, :local),
    do: %{requirements | privacy: :local, locality: :local}

  defp constrain_privacy(%{privacy: :local} = requirements, _inherited),
    do: %{requirements | locality: :local}

  defp constrain_privacy(requirements, _inherited), do: requirements

  defp verification_requirements(proposal) do
    requested = value(proposal, :verification_requirements)
    requested = if is_map(requested), do: requested, else: %{}

    %{
      required: boolean_value(requested, :required, false),
      source: :runtime_policy
    }
  end

  defp lifecycle(depth) do
    %{
      depth: depth,
      maximum_delegation_depth: @maximum_delegation_depth,
      restart: :temporary,
      terminate_after_result: false,
      retention: :until_goal_shutdown
    }
  end

  defp validate_depth(depth) when depth <= @maximum_delegation_depth, do: :ok
  defp validate_depth(_depth), do: {:error, :delegation_depth_exceeded}

  defp parent_depth(%AgentSpec{lifecycle: %{depth: depth}}) when is_integer(depth), do: depth
  defp parent_depth(_spec), do: 0

  defp enum_value(map, key, allowed, default) do
    value = value(map, key)

    normalized =
      if is_binary(value), do: Enum.find(allowed, &(to_string(&1) == value)), else: value

    if normalized in allowed, do: normalized, else: default
  end

  defp boolean_value(map, key, default) do
    case value(map, key) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
