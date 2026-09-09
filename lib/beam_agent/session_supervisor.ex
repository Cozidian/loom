defmodule BeamAgent.SessionSupervisor do
  @moduledoc "One supervision subtree for one durable session."
  use Supervisor

  @shutdown_timeout_ms 2_000

  alias BeamAgent.{Agent, AgentConstructor, AgentSpec, Names, WorkerHandle}
  alias BeamAgent.Goal.{BudgetManager, DelegationManager}

  alias BeamAgent.Session.{
    AttachmentStore,
    ConversationContext,
    Context,
    EventLog,
    FileTracker,
    ResourceSupervisor,
    StreamHub,
    SubagentSupervisor,
    ToolPolicy
  }

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: Names.via(:session_supervisor, id))
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: @shutdown_timeout_ms,
      type: :supervisor
    }
  end

  def spawn_subagent(parent_session_id, opts \\ []) do
    case do_spawn_worker(parent_session_id, opts) do
      {:ok, handle} -> {:ok, handle.worker_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def spawn_worker(parent_session_id, proposal, opts \\ [])
      when is_map(proposal) and is_list(opts) do
    do_spawn_worker(parent_session_id, Keyword.put(opts, :agent_proposal, proposal))
  end

  defp do_spawn_worker(parent_session_id, opts) do
    with {:ok, parent} <- Agent.construction_context(parent_session_id),
         {:ok, supervisor} <- Names.pid(:subagent_supervisor, parent_session_id) do
      child_id = Keyword.get_lazy(opts, :session_id, &BeamAgent.new_session_id/0)
      proposal = proposal(opts, parent_session_id)
      goal = proposal[:goal] || proposal["goal"]

      criteria =
        proposal[:completion_criteria] || proposal["completion_criteria"] ||
          "Return a result that directly addresses the delegated goal"

      with {:ok, delegation} <-
             DelegationManager.request(
               parent.goal_id,
               parent_session_id,
               child_id,
               goal,
               criteria
             ),
           {:ok, _event} <-
             EventLog.append(
               parent_session_id,
               :agent_construction_requested,
               proposal_metadata(proposal, child_id)
             ) do
        opts = Keyword.put(opts, :delegation_id, delegation.id)

        construct_and_start(
          parent,
          supervisor,
          parent_session_id,
          child_id,
          proposal,
          opts,
          delegation.id
        )
      end
    end
  end

  defp construct_and_start(
         parent,
         supervisor,
         parent_session_id,
         child_id,
         proposal,
         opts,
         delegation_id
       ) do
    case AgentConstructor.child(parent_session_id, proposal, opts) do
      {:ok, spec} ->
        reserve_and_start(
          parent,
          supervisor,
          parent_session_id,
          child_id,
          spec,
          opts,
          delegation_id
        )

      {:error, reason} = error ->
        _ = DelegationManager.reject(parent.goal_id, delegation_id, reason)

        _ =
          EventLog.append(parent_session_id, :agent_construction_failed, %{
            "target_session_id" => child_id,
            "failure_code" => error_code(reason)
          })

        error
    end
  end

  defp reserve_and_start(
         parent,
         supervisor,
         parent_session_id,
         child_id,
         spec,
         opts,
         delegation_id
       ) do
    requested = Keyword.get(opts, :resource_limits, %{})

    case BudgetManager.reserve(parent.goal_id, parent_session_id, child_id, requested) do
      {:ok, allocation} ->
        allocation =
          Map.put(allocation, :context_window_tokens, spec.resources.context_window_tokens)

        case AgentSpec.with_resources(spec, allocation) do
          {:ok, allocated_spec} ->
            with {:ok, allocated_spec, opts} <-
                   apply_worktree(parent, child_id, allocated_spec, opts) do
              with {:ok, _event} <-
                     EventLog.append(
                       parent_session_id,
                       :agent_constructed,
                       AgentSpec.metadata(allocated_spec, child_id)
                     ) do
                start_constructed_child(
                  parent,
                  supervisor,
                  parent_session_id,
                  child_id,
                  allocated_spec,
                  opts,
                  delegation_id
                )
              else
                {:error, reason} = error ->
                  _ = BudgetManager.release(parent.goal_id, allocation.allocation_id, reason)
                  error
              end
            else
              {:error, reason} = error ->
                _ = BudgetManager.release(parent.goal_id, allocation.allocation_id, reason)
                _ = DelegationManager.reject(parent.goal_id, delegation_id, reason)
                error
            end

          {:error, reason} = error ->
            _ = BudgetManager.release(parent.goal_id, allocation.allocation_id, reason)
            error
        end

      {:error, reason} = error ->
        _ = DelegationManager.reject(parent.goal_id, delegation_id, reason)

        _ =
          EventLog.append(parent_session_id, :agent_construction_failed, %{
            "target_session_id" => child_id,
            "failure_code" => error_code(reason)
          })

        error
    end
  end

  defp start_constructed_child(
         parent,
         supervisor,
         parent_session_id,
         child_id,
         spec,
         opts,
         delegation_id
       ) do
    child_opts =
      opts
      |> Keyword.delete(:agent_proposal)
      |> Keyword.put(:session_id, child_id)
      |> Keyword.put(:parent_session_id, parent_session_id)
      |> Keyword.put(:project_id, parent.project_id)
      |> Keyword.put(:goal_id, parent.goal_id)
      |> Keyword.put(:workspace_root, spec.restrictions.workspace_root)
      |> Keyword.put_new(:data_dir, parent.data_dir)
      |> Keyword.put_new(:provider, parent.provider)
      |> Keyword.put_new(:provider_profile, parent.provider_profile)
      |> Keyword.put_new(:provider_options, parent.provider_options)
      |> Keyword.put_new(:strategy, parent.strategy)
      |> Keyword.put_new(:approval_policy, current_approval_policy(parent))
      |> Keyword.put_new(:approval_handler, current_approval_handler(parent))
      |> Keyword.put_new(:context_window_tokens, parent.context_window_tokens)
      |> Keyword.put_new(
        :compaction_threshold_percent,
        parent.compaction_threshold_percent
      )
      |> Keyword.put_new(:model_strategy, parent.model_strategy)
      |> Keyword.put(:capability_envelope, spec.effective_capabilities)
      |> Keyword.put(:agent_spec, spec)

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
      {:ok, child_pid} ->
        with :ok <-
               BudgetManager.bind(parent.goal_id, spec.resources.allocation_id, child_pid),
             {:ok, _event} <-
               EventLog.append(parent_session_id, :subagent_spawned, %{
                 "child_session_id" => child_id,
                 "spec_id" => spec.spec_id,
                 "role" => spec.role,
                 "template" => spec.template,
                 "delegation_id" => delegation_id,
                 "budget_allocation_id" => spec.resources.allocation_id
               }) do
          :ok = DelegationManager.accept(parent.goal_id, delegation_id, spec.spec_id)
          {:ok, WorkerHandle.from_spec(child_id, parent.goal_id, spec, delegation_id)}
        else
          {:error, reason} ->
            Supervisor.stop(child_pid, :normal)
            _ = BudgetManager.release(parent.goal_id, spec.resources.allocation_id, reason)
            _ = DelegationManager.reject(parent.goal_id, delegation_id, reason)
            {:error, {:subagent_start_failed, reason}}
        end

      {:error, {:already_started, _pid}} ->
        _ = DelegationManager.reject(parent.goal_id, delegation_id, :session_already_started)
        {:error, {:session_already_started, child_id}}

      {:error, reason} ->
        _ = BudgetManager.release(parent.goal_id, spec.resources.allocation_id, reason)
        _ = DelegationManager.reject(parent.goal_id, delegation_id, reason)

        _ =
          EventLog.append(parent_session_id, :agent_construction_failed, %{
            "target_session_id" => child_id,
            "spec_id" => spec.spec_id,
            "failure_code" => error_code(reason)
          })

        {:error, reason}
    end
  end

  defp proposal(opts, parent_session_id) do
    base =
      case Keyword.get(opts, :agent_proposal) do
        proposal when is_map(proposal) -> proposal
        _other -> %{}
      end

    base
    |> put_proposal_default(:goal, Keyword.get(opts, :goal))
    |> put_proposal_default(
      :goal,
      "Complete delegated work requested by parent #{parent_session_id}"
    )
    |> put_proposal_default(:role, Keyword.get(opts, :role))
    |> put_proposal_default(:instructions, Keyword.get(opts, :agent_instructions))
    |> put_proposal_default(:template, Keyword.get(opts, :template))
    |> put_proposal_default(:completion_criteria, Keyword.get(opts, :completion_criteria))
    |> put_proposal_default(:capabilities, Keyword.get(opts, :capabilities))
    |> put_proposal_default(:model_requirements, Keyword.get(opts, :model_requirements))
    |> put_proposal_default(
      :verification_requirements,
      Keyword.get(opts, :verification_requirements)
    )
  end

  defp put_proposal_default(map, _key, nil), do: map

  defp put_proposal_default(map, key, value) do
    if Map.has_key?(map, key) or Map.has_key?(map, to_string(key)),
      do: map,
      else: Map.put(map, key, value)
  end

  defp proposal_metadata(proposal, child_id) do
    instructions = proposal[:instructions] || proposal["instructions"] || []
    instructions = if is_list(instructions), do: instructions, else: [instructions]

    %{
      "target_session_id" => child_id,
      "role_requested" => proposal[:role] || proposal["role"],
      "template_requested" => proposal[:template] || proposal["template"],
      "goal_fingerprint" => hash_text(proposal[:goal] || proposal["goal"] || ""),
      "instruction_count" => length(instructions),
      "capabilities_requested" => not is_nil(proposal[:capabilities] || proposal["capabilities"])
    }
  end

  defp current_approval_policy(parent) do
    case BeamAgent.approval_policy(parent.session_id) do
      {:ok, policy} -> policy
      {:error, _reason} -> parent.approval_policy
    end
  end

  defp current_approval_handler(parent) do
    case BeamAgent.approval_handler(parent.session_id) do
      {:ok, handler} -> handler
      {:error, _reason} -> parent.approval_handler
    end
  end

  defp error_code(reason) when is_atom(reason), do: to_string(reason)

  defp error_code(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: to_string(elem(reason, 0))

  defp error_code(_reason), do: "agent_construction_failed"

  defp hash_text(text) do
    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end

  defp apply_worktree(parent, child_id, spec, opts) do
    case Keyword.get(opts, :worktree_handle) do
      nil ->
        {:ok, spec, opts}

      %BeamAgent.WorktreeHandle{id: id, project_id: project_id}
      when project_id == parent.project_id ->
        with {:ok, handle} <-
               BeamAgent.Project.WorktreeManager.validate(project_id, id, child_id),
             {:ok, spec} <- AgentSpec.with_workspace(spec, handle.path, handle.id) do
          {:ok, spec, Keyword.delete(opts, :worktree_handle)}
        end

      _other ->
        {:error, :invalid_worktree_handle}
    end
  end

  @impl true
  def init(opts) do
    children =
      [
        {EventLog, opts},
        {AttachmentStore, opts},
        {StreamHub, opts},
        {ResourceSupervisor, opts},
        {Context, opts},
        {ConversationContext, opts},
        {FileTracker, opts},
        {ToolPolicy, opts},
        {SubagentSupervisor, opts},
        {BeamAgent.Agent, opts}
      ] ++ provider_conversation_children(opts)

    # The event log is the first dependency. If it fails, every downstream
    # session process is rebuilt. A stream hub failure keeps the log alive while
    # rebuilding all request-owning processes below it.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp provider_conversation_children(opts) do
    # Dormant until invoked; supports changing provider without replacing a session.
    [{BeamAgent.CodexAppServer.Conversation, opts}]
  end
end
