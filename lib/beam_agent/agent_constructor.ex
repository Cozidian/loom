defmodule BeamAgent.AgentConstructor do
  @moduledoc """
  Deterministically populates runtime `AgentSpec` values from proposals and
  policy-owned parent/project state.

  Proposal fields are soft configuration. Effective capabilities, restrictions,
  resources, and lifecycle always come from the runtime.
  """

  alias BeamAgent.{
    Agent,
    AgentConstructionPolicy,
    AgentSpec,
    AgentTemplate,
    ProjectContext,
    ResourceBudget,
    TaskClassifier
  }

  @maximum_delegation_depth 4

  def root(opts) when is_list(opts) do
    envelope = Keyword.fetch!(opts, :capability_envelope)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    goal = Keyword.get(opts, :objective) || "Coordinate work requested through this session"
    classification = TaskClassifier.classify(goal, workspace_root)
    template = AgentTemplate.resolve("coordinator", classification)
    role = Keyword.get(opts, :role) || template.role

    instructions =
      normalize_instructions(
        template.instructions ++
          normalize_instructions(Keyword.get(opts, :agent_instructions, []))
      )

    with {:ok, context} <- ProjectContext.load(workspace_root),
         {:ok, authority} <- AgentConstructionPolicy.evaluate_root(envelope) do
      AgentSpec.new(%{
        goal: goal,
        role: role,
        instructions: instructions,
        context_refs: [%{kind: "project_context", id: context.fingerprint}],
        requested_capabilities: authority.requested,
        effective_capabilities: authority.effective,
        restrictions: restrictions(workspace_root, envelope),
        resources: resources(opts),
        model_requirements: root_model_requirements(opts, template),
        verification_requirements:
          Map.merge(
            %{required: false, source: "goal_default"},
            template.verification_requirements
          ),
        parent: nil,
        lifecycle: lifecycle(0),
        template: template.id,
        template_version: template.version,
        template_source: template.source,
        execution_strategy: template.execution_strategy,
        authority_decision: authority,
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
         {:ok, authority} <-
           AgentConstructionPolicy.evaluate_child(parent.capability_envelope, proposal) do
      classification = TaskClassifier.classify(goal, parent.workspace_root)
      template = AgentTemplate.resolve(value(proposal, :template), classification)
      role = role(proposal, classification, template)

      instructions =
        normalize_instructions(
          template.instructions ++ normalize_instructions(value(proposal, :instructions) || [])
        )

      AgentSpec.new(%{
        goal: goal,
        role: role,
        instructions: instructions,
        context_refs: [
          %{kind: "project_context", id: project_context.fingerprint},
          %{kind: "parent_worker", id: parent_session_id}
        ],
        requested_capabilities: authority.requested,
        effective_capabilities: authority.effective,
        restrictions: restrictions(parent.workspace_root, authority.effective),
        resources: resources_from_parent(parent, opts),
        model_requirements: model_requirements(proposal, parent, template),
        verification_requirements: verification_requirements(proposal, template),
        parent: %{
          worker_id: parent_session_id,
          delegation_id: Keyword.get(opts, :delegation_id),
          spec_id: parent.agent_spec && parent.agent_spec.spec_id,
          capability_envelope_id: parent.capability_envelope.id
        },
        lifecycle: lifecycle(depth),
        template: template.id,
        template_version: template.version,
        template_source: template.source,
        execution_strategy: template.execution_strategy,
        authority_decision: authority,
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
            if(authority.requested == :inherit,
              do: "parent_inheritance",
              else: "parent_proposal"
            ),
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

  defp role(proposal, classification, template) do
    case value(proposal, :role) do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        if value(proposal, :template), do: template.role, else: inferred_role(classification)
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
    allocation =
      ResourceBudget.root_allocation(
        Keyword.fetch!(opts, :goal_id),
        Keyword.get(opts, :budget, %{})
      )

    Map.put(allocation, :context_window_tokens, Keyword.get(opts, :context_window_tokens, 32_000))
  end

  defp resources_from_parent(parent, opts) do
    %{
      context_window_tokens:
        Keyword.get(opts, :context_window_tokens, parent.context_window_tokens),
      allocation_id: parent.agent_spec.resources.allocation_id,
      worker_id: parent.session_id,
      parent_allocation_id: parent.agent_spec.resources.parent_allocation_id,
      limits: parent.agent_spec.resources.limits,
      usage: parent.agent_spec.resources.usage,
      status: :provisional
    }
  end

  defp root_model_requirements(opts, template) do
    Map.merge(template.model_requirements, %{
      reasoning: :standard,
      locality: if(Keyword.get(opts, :model_strategy) == :local_only, do: :local, else: :any),
      privacy:
        if(Keyword.get(opts, :model_strategy) == :local_only,
          do: :local,
          else: :provider_allowed
        ),
      cost: :prefer_low,
      latency: :interactive
    })
  end

  defp model_requirements(proposal, parent, template) do
    requested = value(proposal, :model_requirements)
    requested = if is_map(requested), do: requested, else: %{}

    inherited_privacy =
      if parent.model_strategy == :local_only, do: :local, else: :provider_allowed

    %{
      reasoning:
        enum_value(
          requested,
          :reasoning,
          [:standard, :high],
          Map.get(template.model_requirements, :reasoning, :standard)
        ),
      locality:
        enum_value(
          requested,
          :locality,
          [:any, :local, :remote],
          Map.get(template.model_requirements, :locality, :any)
        ),
      privacy:
        enum_value(
          requested,
          :privacy,
          [:provider_allowed, :local],
          Map.get(template.model_requirements, :privacy, inherited_privacy)
        ),
      cost:
        enum_value(
          requested,
          :cost,
          [:prefer_low, :balanced],
          Map.get(template.model_requirements, :cost, :prefer_low)
        ),
      latency:
        enum_value(
          requested,
          :latency,
          [:interactive, :batch],
          Map.get(template.model_requirements, :latency, :interactive)
        )
    }
    |> constrain_privacy(inherited_privacy)
  end

  defp constrain_privacy(requirements, :local),
    do: %{requirements | privacy: :local, locality: :local}

  defp constrain_privacy(%{privacy: :local} = requirements, _inherited),
    do: %{requirements | locality: :local}

  defp constrain_privacy(requirements, _inherited), do: requirements

  defp verification_requirements(proposal, template) do
    requested = value(proposal, :verification_requirements)
    requested = if is_map(requested), do: requested, else: %{}

    %{
      required:
        boolean_value(
          requested,
          :required,
          Map.get(template.verification_requirements, :required, false)
        ),
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
