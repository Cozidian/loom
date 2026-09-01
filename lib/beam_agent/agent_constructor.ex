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
    CapabilityCatalog,
    CapabilityEnvelope,
    ProjectContext,
    ResourceBudget,
    TaskClassifier,
    Workspace
  }

  alias BeamAgent.MCP.Registry, as: MCPRegistry

  @default_maximum_delegation_depth 2
  @hard_maximum_delegation_depth 4

  def root(opts) when is_list(opts) do
    envelope = Keyword.fetch!(opts, :capability_envelope)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    goal = Keyword.get(opts, :objective) || "Coordinate work requested through this session"
    classification = TaskClassifier.classify(goal, workspace_root)
    template = AgentTemplate.resolve("goal-worker", classification)
    role = Keyword.get(opts, :role) || template.role
    maximum_delegation_depth = maximum_delegation_depth(opts)

    instructions =
      normalize_instructions(
        template.instructions ++
          normalize_instructions(Keyword.get(opts, :agent_instructions, []))
      )

    verification_requirements =
      %{required: false, source: "goal_default"}
      |> Map.merge(template.verification_requirements)
      |> Map.put(:review_required, Keyword.get(opts, :completion_review, :runtime) != :external)

    with :ok <- validate_maximum_delegation_depth(maximum_delegation_depth),
         {:ok, context} <- ProjectContext.load(workspace_root),
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
        verification_requirements: verification_requirements,
        parent: nil,
        lifecycle: lifecycle(0, maximum_delegation_depth),
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
         maximum_delegation_depth <- parent_maximum_delegation_depth(parent.agent_spec),
         :ok <- validate_depth(depth, maximum_delegation_depth),
         goal when is_binary(goal) and goal != "" <- value(proposal, :goal),
         {:ok, proposal} <- normalize_capability_paths(proposal, parent.workspace_root),
         classification <- TaskClassifier.classify(goal, parent.workspace_root),
         {:ok, authority} <-
           AgentConstructionPolicy.evaluate_child(parent.capability_envelope, proposal) do
      template = AgentTemplate.resolve(value(proposal, :template), classification)
      role = role(proposal, classification, template)

      instructions =
        normalize_instructions(
          template.instructions ++
            inherited_contract(parent, proposal) ++
            normalize_instructions(value(proposal, :instructions) || [])
        )

      with :ok <- validate_delegation_shape(parent.agent_spec, template.execution_strategy),
           {:ok, authority} <-
             constrain_delegation_authority(
               authority,
               parent,
               template,
               depth,
               maximum_delegation_depth
             ),
           :ok <- validate_worker_coherence(role, template, authority, parent.goal_id) do
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
          verification_requirements: verification_requirements(proposal, template, opts),
          parent: %{
            worker_id: parent_session_id,
            delegation_id: Keyword.get(opts, :delegation_id),
            spec_id: parent.agent_spec && parent.agent_spec.spec_id,
            capability_envelope_id: parent.capability_envelope.id
          },
          lifecycle: lifecycle(depth, maximum_delegation_depth),
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
      end
    else
      nil -> {:error, :missing_agent_goal}
      false -> {:error, :missing_agent_goal}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_agent_proposal}
    end
  end

  def child(_parent_session_id, _proposal, _opts), do: {:error, :invalid_agent_proposal}

  defp normalize_capability_paths(proposal, workspace_root) do
    case value(proposal, :capabilities) do
      capabilities when is_map(capabilities) ->
        case value(capabilities, :paths) do
          paths when is_list(paths) ->
            with {:ok, normalized} <- normalize_path_list(paths, workspace_root) do
              {:ok, put_capability_paths(proposal, capabilities, normalized)}
            end

          path when is_binary(path) and path not in ["all", ""] ->
            with {:ok, normalized} <- normalize_capability_path(path, workspace_root) do
              {:ok, put_capability_paths(proposal, capabilities, [normalized])}
            end

          "" ->
            {:error, {:invalid_capability_path, ""}}

          _inherited_or_all ->
            {:ok, proposal}
        end

      _inherited ->
        {:ok, proposal}
    end
  end

  defp normalize_path_list(paths, workspace_root) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, normalized} ->
      case normalize_capability_path(path, workspace_root) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_capability_path(path, workspace_root) when is_binary(path) and path != "" do
    with {:ok, expanded} <- Workspace.canonical_path(Path.expand(path, workspace_root)) do
      relative = Path.relative_to(expanded, workspace_root)

      if workspace_escape?(relative) do
        {:error, {:capability_path_outside_workspace, path}}
      else
        {:ok, if(relative == "", do: ".", else: relative)}
      end
    else
      {:error, reason} -> {:error, {:invalid_capability_path, path, reason}}
    end
  end

  defp normalize_capability_path(path, _workspace_root),
    do: {:error, {:invalid_capability_path, path}}

  defp put_capability_paths(proposal, capabilities, paths) do
    capabilities = capabilities |> Map.delete("paths") |> Map.put(:paths, paths)
    proposal |> Map.delete("capabilities") |> Map.put(:capabilities, capabilities)
  end

  defp workspace_escape?(relative) do
    relative == ".." or String.starts_with?(relative, "../") or
      String.starts_with?(relative, "..\\") or Path.type(relative) == :absolute
  end

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

  defp verification_requirements(proposal, template, opts) do
    requested = value(proposal, :verification_requirements)
    requested = if is_map(requested), do: requested, else: %{}

    %{
      required:
        boolean_value(
          requested,
          :required,
          Map.get(template.verification_requirements, :required, false)
        ),
      review_required: Keyword.get(opts, :completion_review, :runtime) != :external,
      source: :runtime_policy
    }
  end

  defp lifecycle(depth, maximum_delegation_depth) do
    %{
      depth: depth,
      maximum_delegation_depth: maximum_delegation_depth,
      restart: :temporary,
      terminate_after_result: false,
      retention: :until_goal_shutdown
    }
  end

  defp maximum_delegation_depth(opts),
    do: Keyword.get(opts, :maximum_delegation_depth, @default_maximum_delegation_depth)

  defp validate_maximum_delegation_depth(depth)
       when is_integer(depth) and depth in 1..@hard_maximum_delegation_depth,
       do: :ok

  defp validate_maximum_delegation_depth(_depth),
    do: {:error, :invalid_maximum_delegation_depth}

  defp validate_depth(depth, maximum) when depth <= maximum, do: :ok
  defp validate_depth(_depth, _maximum), do: {:error, :delegation_depth_exceeded}

  defp parent_maximum_delegation_depth(%AgentSpec{
         lifecycle: %{maximum_delegation_depth: depth}
       })
       when is_integer(depth),
       do: depth

  defp parent_maximum_delegation_depth(_spec), do: @default_maximum_delegation_depth

  defp validate_delegation_shape(
         %AgentSpec{execution_strategy: %{id: "implement"}},
         %{id: "implement"}
       ),
       do: {:error, :recursive_implementation_delegation}

  defp validate_delegation_shape(_parent_spec, _execution_strategy), do: :ok

  defp validate_worker_coherence(role, template, authority, goal_id) do
    implementation_role? =
      is_binary(role) and Regex.match?(~r/\bimplement(?:ation|er)?\b/iu, role)

    cond do
      implementation_role? and template.execution_strategy.id != "implement" ->
        {:error, :contradictory_worker_contract}

      template.execution_strategy.id == "implement" and
          not Enum.any?(effective_tool_names(authority.effective, goal_id), &write_tool?/1) ->
        {:error, :implementation_worker_without_write_authority}

      true ->
        :ok
    end
  end

  defp write_tool?(name) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} -> function_exported?(module, :access, 0) and module.access() == :write
      {:error, _reason} -> false
    end
  end

  defp constrain_delegation_authority(authority, parent, template, depth, maximum) do
    strategy = template.execution_strategy.id

    cond do
      strategy in ["investigate", "review", "verify"] ->
        allowed_tools =
          authority.effective
          |> effective_tool_names(parent.goal_id)
          |> Enum.filter(&read_only_tool?/1)

        attenuate_tools(
          authority,
          allowed_tools,
          "investigation, review, and verification workers receive read-only runtime authority"
        )

      strategy == "implement" or depth >= maximum ->
        allowed_tools =
          authority.effective
          |> effective_tool_names(parent.goal_id)
          |> Enum.reject(&(&1 in ["delegate_tasks", "spawn_subagent"]))

        reason =
          if depth >= maximum,
            do: "delegation is disabled at the configured maximum depth",
            else: "delegation tools require an explicit runtime capability lease for this worker"

        attenuate_tools(authority, allowed_tools, reason)

      true ->
        {:ok, authority}
    end
  end

  defp attenuate_tools(authority, allowed_tools, reason) do
    with {:ok, effective} <-
           CapabilityEnvelope.restrict(authority.effective, %{tools: allowed_tools}) do
      {:ok, AgentConstructionPolicy.attenuate(authority, effective, reason)}
    end
  end

  defp read_only_tool?(name) do
    case CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted
        access in [:read, :trusted]

      {:error, _reason} ->
        false
    end
  end

  defp effective_tool_names(%CapabilityEnvelope{scopes: %{tools: :all}}, goal_id) do
    builtin = Enum.map(CapabilityCatalog.tool_schemas(), & &1.name)

    mcp =
      case MCPRegistry.tool_schemas(goal_id) do
        schemas when is_list(schemas) -> Enum.map(schemas, & &1.name)
        _other -> []
      end

    Enum.uniq(builtin ++ mcp)
  end

  defp effective_tool_names(%CapabilityEnvelope{scopes: %{tools: tools}}, _goal_id),
    do: tools

  defp parent_depth(%AgentSpec{lifecycle: %{depth: depth}}) when is_integer(depth), do: depth
  defp parent_depth(_spec), do: 0

  defp inherited_contract(%{agent_spec: %AgentSpec{} = parent_spec} = parent, proposal) do
    parent_goal = String.trim(parent_spec.goal || "")
    root_contract = root_acceptance_contract(parent) || parent_goal
    criteria = value(proposal, :completion_criteria)

    (contract_instructions(
       "Root acceptance contract (authoritative; do not narrow it or silently replace it with an MVP)",
       root_contract
     ) ++
       contract_instructions("Immediate parent goal", parent_goal) ++
       [
         if(is_binary(criteria) and String.trim(criteria) != "",
           do: "Delegated completion criteria: #{String.trim(criteria)}",
           else: nil
         )
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp inherited_contract(_parent, _proposal), do: []

  defp root_acceptance_contract(parent) do
    with {:ok, goal} <- BeamAgent.Goal.snapshot(parent.goal_id),
         {:ok, events} <- BeamAgent.Session.EventLog.events(goal.session_id) do
      events
      |> Enum.reverse()
      |> Enum.find_value(fn event ->
        if event["type"] == "user_message" do
          case event["data"]["content"] do
            content when is_binary(content) and content != "" -> content
            _other -> nil
          end
        end
      end)
    else
      _error -> nil
    end
  end

  defp contract_instructions(_label, ""), do: []
  defp contract_instructions(_label, nil), do: []

  defp contract_instructions(label, text) when is_binary(text) do
    text
    |> utf8_chunks(3_000)
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, index} -> "#{label} [part #{index}]: #{chunk}" end)
  end

  defp utf8_chunks(text, maximum_bytes) do
    {chunks, current, _bytes} =
      Enum.reduce(String.codepoints(text), {[], [], 0}, fn codepoint, {chunks, current, bytes} ->
        size = byte_size(codepoint)

        if bytes > 0 and bytes + size > maximum_bytes do
          {[current |> Enum.reverse() |> Enum.join() | chunks], [codepoint], size}
        else
          {chunks, [codepoint | current], bytes + size}
        end
      end)

    [current |> Enum.reverse() |> Enum.join() | chunks]
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
  end

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
