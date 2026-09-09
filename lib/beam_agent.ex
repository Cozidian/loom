defmodule BeamAgent do
  @moduledoc """
  Public API for the OTP-native agent harness.

  A project owns ephemeral goal subtrees. A goal is initially backed by one
  durable root session, whose agent is a GenServer and whose source of truth is
  an append-only event log.
  """

  alias BeamAgent.{
    Agent,
    AgentConstructor,
    CapabilityEnvelope,
    Goal,
    ModelRegistry,
    MCP.Registry,
    Names,
    OutcomeStore,
    Project,
    ProjectRootSupervisor,
    ProjectSupervisor,
    SessionSupervisor,
    Workspace
  }

  alias BeamAgent.Session.{
    AttachmentStore,
    Context,
    ConversationContext,
    EventLog,
    StreamHub,
    ToolPolicy
  }

  alias BeamAgent.Goal.EventHub
  alias BeamAgent.Goal.Verifier

  def start_session(opts \\ []) do
    id = Keyword.get_lazy(opts, :session_id, &new_session_id/0)
    workspace_root = Keyword.get(opts, :workspace_root, File.cwd!())

    with :ok <- validate_session_id(id),
         {:ok, workspace_root} <- Workspace.canonical_root(workspace_root),
         {:ok, project_id} <- start_project(project_options(opts, workspace_root)) do
      opts =
        opts
        |> Keyword.put(:session_id, id)
        |> Keyword.put(:goal_id, id)
        |> Keyword.put(:workspace_root, workspace_root)

      case start_goal(project_id, opts) do
        {:ok, ^id} -> {:ok, id}
        {:error, {:goal_already_started, ^id}} -> {:error, {:session_already_started, id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def start_project(opts \\ []) do
    workspace_root = Keyword.get(opts, :workspace_root, File.cwd!())

    with {:ok, workspace_root} <- Workspace.canonical_root(workspace_root) do
      project_id = Project.id_for_workspace(workspace_root)

      project_opts =
        opts
        |> Keyword.put(:project_id, project_id)
        |> Keyword.put(:workspace_root, workspace_root)

      with {:ok, _pid} <- ProjectRootSupervisor.start_project(project_opts),
           {:ok, %{workspace_root: ^workspace_root}} <- Project.snapshot(project_id),
           :ok <- sync_model_registry(project_id, opts) do
        {:ok, project_id}
      end
    end
  end

  def start_goal(project_id, opts \\ []) do
    goal_id = Keyword.get_lazy(opts, :goal_id, &new_goal_id/0)
    session_id = Keyword.get(opts, :session_id, goal_id)

    with :ok <- validate_session_id(goal_id),
         :ok <- validate_session_id(session_id),
         :ok <- validate_goal_session_identity(goal_id, session_id),
         {:ok, project} <- Project.snapshot(project_id),
         :ok <- validate_goal_workspace(opts, project.workspace_root) do
      data_dir = Keyword.get(opts, :data_dir, Application.fetch_env!(:beam_agent, :data_dir))

      goal_opts =
        opts
        |> Keyword.put(:goal_id, goal_id)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:project_id, project_id)
        |> Keyword.put(:workspace_root, project.workspace_root)
        |> Keyword.put(:data_dir, data_dir)
        |> Keyword.put_new_lazy(:capability_envelope, fn ->
          CapabilityEnvelope.root(Keyword.get(opts, :capabilities, :all))
        end)

      with {:ok, agent_spec} <- AgentConstructor.root(goal_opts) do
        goal_opts = Keyword.put(goal_opts, :agent_spec, agent_spec)

        case ProjectSupervisor.start_goal(project_id, goal_opts) do
          {:ok, _pid} -> {:ok, goal_id}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def resume_session(session_id, opts \\ []) do
    start_session(Keyword.put(opts, :session_id, session_id))
  end

  def spawn_subagent(parent_session_id, opts \\ []) do
    SessionSupervisor.spawn_subagent(parent_session_id, opts)
  end

  def spawn_worker(parent_session_id, proposal, opts \\ []),
    do: SessionSupervisor.spawn_worker(parent_session_id, proposal, opts)

  def worker_delegations(goal_id), do: BeamAgent.Goal.DelegationManager.list(goal_id)

  def start_worker(%BeamAgent.WorkerHandle{} = handle, prompt, opts \\ []) when is_binary(prompt),
    do: BeamAgent.Goal.DelegationManager.start(handle.goal_id, handle, prompt, opts)

  def await_worker(%BeamAgent.WorkerHandle{} = handle, timeout_ms \\ 120_000),
    do: BeamAgent.Goal.DelegationManager.await(handle.goal_id, handle.delegation_id, timeout_ms)

  def await_delegation(goal_id, delegation_id, timeout_ms \\ 120_000),
    do: BeamAgent.Goal.DelegationManager.await(goal_id, delegation_id, timeout_ms)

  def worker_status(goal_id, delegation_id),
    do: BeamAgent.Goal.DelegationManager.status(goal_id, delegation_id)

  def cancel_delegation(goal_id, delegation_id, reason \\ :cancelled) do
    with {:ok, delegation} <- worker_status(goal_id, delegation_id),
         :ok <- BeamAgent.Goal.DelegationManager.cancel(goal_id, delegation_id, reason) do
      stop_session(delegation.worker_id)
    end
  end

  def execute_decomposition(parent_session_id, plan, opts \\ []),
    do: BeamAgent.Goal.WorkRunManager.run(parent_session_id, plan, opts)

  def work_runs(goal_id, work_run_id \\ :all),
    do: BeamAgent.Goal.WorkRunManager.snapshot(goal_id, work_run_id)

  def worker_organizations(goal_id, organization_id \\ :all),
    do: BeamAgent.Goal.OrganizationManager.snapshot(goal_id, organization_id)

  def auction_providers(goal_id, session_id, input, opts \\ []),
    do: BeamAgent.Goal.ProviderBidCoordinator.auction(goal_id, session_id, input, opts)

  def provider_market(goal_id), do: BeamAgent.Goal.ProviderBidCoordinator.latest(goal_id)

  def race_workers(parent_session_id, candidates, opts \\ []),
    do: BeamAgent.Goal.Race.run(parent_session_id, candidates, opts)

  def tournament_workers(parent_session_id, candidates, opts \\ []),
    do: BeamAgent.Goal.Tournament.run(parent_session_id, candidates, opts)

  def speculate_implementations(parent_session_id, candidates, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:isolation, :worktree)
      |> Keyword.put(:verify_candidates, true)
      |> Keyword.put_new(:evaluator, :verified_patch)

    BeamAgent.Goal.Tournament.run(parent_session_id, candidates, opts)
  end

  def complete_worker(
        %BeamAgent.WorkerHandle{} = handle,
        content,
        verification \\ %{status: :unverified}
      ) do
    BeamAgent.Goal.DelegationManager.complete(
      handle.goal_id,
      handle.delegation_id,
      handle.worker_id,
      content,
      verification
    )
  end

  def cancel_worker(%BeamAgent.WorkerHandle{} = handle, reason \\ :cancelled) do
    _ = BeamAgent.Goal.DelegationManager.cancel(handle.goal_id, handle.delegation_id, reason)
    stop_session(handle.worker_id)
  end

  def agent_spec(session_id), do: Agent.spec(session_id)
  def budget(goal_id), do: BeamAgent.Goal.BudgetManager.snapshot(goal_id)
  def resource_pools(project_id), do: BeamAgent.Project.ResourceScheduler.snapshot(project_id)
  def repository(project_id), do: BeamAgent.Project.RepositoryIndex.snapshot(project_id)
  def refresh_repository(project_id), do: BeamAgent.Project.RepositoryIndex.refresh(project_id)

  def repository_file(project_id, path),
    do: BeamAgent.Project.RepositoryIndex.file(project_id, path)

  def project_context(project_id, request \\ %{}),
    do: BeamAgent.Project.ContextStore.assemble(project_id, request)

  def project_context_artifacts(project_id), do: BeamAgent.Project.ContextStore.list(project_id)

  def project_preferences(project_id), do: BeamAgent.ModelRouter.preferences(project_id)

  def set_project_preferences(project_id, preferences) when is_map(preferences) do
    with {:ok, normalized} <- BeamAgent.ModelRouter.update_preferences(project_id, preferences),
         {:ok, _artifact} <-
           BeamAgent.Project.ContextStore.put_preferences(project_id, normalized) do
      {:ok, normalized}
    end
  end

  def create_worktree(project_id, owner_worker_id, opts \\ []),
    do: BeamAgent.Project.WorktreeManager.create(project_id, owner_worker_id, opts)

  def inspect_worktree(project_id, handle_id),
    do: BeamAgent.Project.WorktreeManager.inspect(project_id, handle_id)

  def cleanup_worktree(project_id, handle_id, opts \\ []),
    do: BeamAgent.Project.WorktreeManager.cleanup(project_id, handle_id, opts)

  def worktrees(project_id), do: BeamAgent.Project.WorktreeManager.list(project_id)

  def diff_summary(workspace_root), do: BeamAgent.GitDiff.summary(workspace_root)

  def diff(workspace_root, opts \\ []), do: BeamAgent.GitDiff.inspect(workspace_root, opts)

  def sessions(data_dir, opts \\ []), do: BeamAgent.SessionIndex.list(data_dir, opts)

  def session_detail(data_dir, session_id),
    do: BeamAgent.SessionIndex.summarize(data_dir, session_id)

  def start_json_api(session_id, opts \\ []) do
    BeamAgent.Runtime.JSONLineServer.start_link(Keyword.put(opts, :session_id, session_id))
  end

  def start_web_control_plane(session_id, opts \\ []) do
    BeamAgent.ControlPlane.HTTPServer.start_link(Keyword.put(opts, :session_id, session_id))
  end

  def execution_nodes(project_id), do: BeamAgent.Project.ExecutionNodeRegistry.nodes(project_id)

  def claim_distributed_job(project_id, job_id, requirements \\ %{}),
    do: BeamAgent.Project.ExecutionNodeRegistry.claim_job(project_id, job_id, requirements)

  def complete_distributed_job(project_id, job_id, result_fingerprint),
    do:
      BeamAgent.Project.ExecutionNodeRegistry.complete_job(
        project_id,
        job_id,
        result_fingerprint
      )

  def request_capability(worker_id, request),
    do: BeamAgent.Goal.CapabilityManager.request(worker_id, request)

  def capability_leases(goal_id), do: BeamAgent.Goal.CapabilityManager.leases(goal_id)

  def revoke_capability_lease(goal_id, lease_id),
    do: BeamAgent.Goal.CapabilityManager.revoke(goal_id, lease_id)

  def issue_secret_handle(goal_id, worker_id, kind, secret, opts \\ []),
    do: BeamAgent.Goal.SecretBroker.issue(goal_id, worker_id, kind, secret, opts)

  def invoke_secret_handle(goal_id, worker_id, handle_id, resource, fun),
    do: BeamAgent.Goal.SecretBroker.invoke(goal_id, worker_id, handle_id, resource, fun)

  def revoke_secret_handle(goal_id, handle_id),
    do: BeamAgent.Goal.SecretBroker.revoke(goal_id, handle_id)

  def secret_handles(goal_id), do: BeamAgent.Goal.SecretBroker.handles(goal_id)

  def ask(session_id, prompt), do: ask(session_id, prompt, [], :infinity)

  def ask(session_id, prompt, attachment_ids) when is_list(attachment_ids),
    do: ask(session_id, prompt, attachment_ids, :infinity)

  def ask(session_id, prompt, timeout), do: ask(session_id, prompt, [], timeout)

  def ask(session_id, prompt, attachment_ids, timeout) do
    case Names.pid(:goal, session_id) do
      {:ok, _pid} -> Goal.submit(session_id, prompt, attachment_ids, timeout)
      {:error, :not_found} -> Agent.ask(session_id, prompt, attachment_ids, timeout)
    end
  end

  def cancel(session_id) do
    case Names.pid(:goal, session_id) do
      {:ok, _pid} -> Goal.cancel(session_id)
      {:error, :not_found} -> Agent.cancel(session_id)
    end
  end

  def steer(session_id, message) when is_binary(message) do
    case Names.pid(:goal, session_id) do
      {:ok, _pid} -> Goal.steer(session_id, message)
      {:error, :not_found} -> Agent.steer(session_id, message)
    end
  end

  def path_leases(project_id), do: BeamAgent.Project.PathLeaseManager.snapshot(project_id)

  def subscribe(session_id, subscriber \\ self()), do: StreamHub.subscribe(session_id, subscriber)

  def unsubscribe(session_id, subscriber \\ self()),
    do: StreamHub.unsubscribe(session_id, subscriber)

  def sync_stream(session_id), do: StreamHub.sync(session_id)
  def subscribe_goal(goal_id), do: EventHub.subscribe(goal_id)

  def subscribe_goal(goal_id, subscriber) when is_pid(subscriber),
    do: EventHub.subscribe(goal_id, subscriber)

  def subscribe_goal(goal_id, opts) when is_list(opts), do: EventHub.subscribe(goal_id, opts)

  def subscribe_goal(goal_id, subscriber, opts),
    do: EventHub.subscribe(goal_id, subscriber, opts)

  def subscribe_goal_from(goal_id, after_cursor),
    do: EventHub.subscribe_from(goal_id, self(), after_cursor)

  def subscribe_goal_from(goal_id, after_cursor, subscriber) when is_pid(subscriber),
    do: EventHub.subscribe_from(goal_id, subscriber, after_cursor)

  def subscribe_goal_from(goal_id, after_cursor, opts) when is_list(opts),
    do: EventHub.subscribe_from(goal_id, self(), after_cursor, opts)

  def subscribe_goal_from(goal_id, after_cursor, subscriber, opts),
    do: EventHub.subscribe_from(goal_id, subscriber, after_cursor, opts)

  def unsubscribe_goal(goal_id, subscriber \\ self()),
    do: EventHub.unsubscribe(goal_id, subscriber)

  def goal_events(goal_id, opts \\ []), do: EventHub.events(goal_id, opts)

  def inspect_goal_events(goal_id, query \\ "", opts \\ []),
    do: EventHub.inspect_events(goal_id, query, opts)

  def sync_goal(goal_id), do: EventHub.sync(goal_id)

  def goal_tree(goal_id), do: EventHub.goal_tree(goal_id)
  def work_blocks(goal_id), do: EventHub.work_blocks(goal_id)
  def progress(goal_id), do: BeamAgent.Goal.ProgressMonitor.snapshot(goal_id)
  def verify(goal_id, plan \\ :auto), do: Verifier.run(goal_id, plan)
  def cancel_verification(goal_id), do: Verifier.cancel(goal_id)

  def models(project_id), do: ModelRegistry.list(project_id)
  def model(project_id, endpoint_id), do: ModelRegistry.fetch(project_id, endpoint_id)
  def register_model(project_id, endpoint), do: ModelRegistry.register(project_id, endpoint)

  def refresh_models(project_id, endpoint_id \\ :all),
    do: ModelRegistry.refresh_health(project_id, endpoint_id)

  def route_model(project_id, input), do: BeamAgent.ModelRouter.route(project_id, input)
  def outcomes(project_id, opts \\ []), do: OutcomeStore.list(project_id, opts)

  def routing_evidence(project_id, opts \\ []),
    do: OutcomeStore.routing_evidence(project_id, opts)

  def attach_verification(project_id, outcome_id, result),
    do: OutcomeStore.attach_verification(project_id, outcome_id, result)

  def export_outcomes(project_id), do: OutcomeStore.export(project_id)
  def outcome_log_path(project_id), do: OutcomeStore.path(project_id)

  def start_mcp_server(goal_id, spec), do: Registry.start_server(goal_id, spec)
  def stop_mcp_server(goal_id, name), do: Registry.stop_server(goal_id, name)
  def mcp_servers(goal_id), do: Registry.servers(goal_id)
  def mcp_tools(goal_id), do: Registry.tool_schemas(goal_id)

  def respond_approval(session_id, approval_id, decision),
    do: ToolPolicy.respond(session_id, approval_id, decision)

  def set_approval_handler(session_id, handler), do: ToolPolicy.set_handler(session_id, handler)
  def approval_handler(session_id), do: ToolPolicy.handler(session_id)
  def pending_approvals(session_id), do: ToolPolicy.pending(session_id)
  def approval_policy(session_id), do: ToolPolicy.policy(session_id)
  def set_approval_policy(session_id, policy), do: ToolPolicy.set_policy(session_id, policy)

  def goal_sessions(goal_id), do: Agent.goal_sessions(goal_id)

  def set_goal_approval_policy(goal_id, policy) do
    with {:ok, session_ids} <- Agent.goal_sessions(goal_id) do
      Enum.reduce_while(session_ids, :ok, fn session_id, :ok ->
        case ToolPolicy.set_policy(session_id, policy) do
          :ok -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {session_id, reason}}}
        end
      end)
    end
  end

  def permissions(session_id), do: ToolPolicy.permissions(session_id)

  def revoke_permission(session_id, permission_id),
    do: ToolPolicy.revoke(session_id, permission_id)

  def events(session_id) do
    case EventLog.events(session_id) do
      {:ok, _events} = result -> result
      {:error, :not_found} -> EventHub.session_events(session_id)
      {:error, _reason} = error -> error
    end
  end

  def context_snapshot(session_id), do: Context.snapshot(session_id)

  def conversation_context_stats(session_id) do
    with {:ok, project_context} <- Context.snapshot(session_id) do
      ConversationContext.stats(
        session_id,
        project_context.system_prompt,
        BeamAgent.CapabilityCatalog.tool_schemas()
      )
    end
  end

  def compact_context(session_id) do
    with {:ok, options} <- Agent.context_options(session_id),
         {:ok, project_context} <- Context.snapshot(session_id),
         tool_schemas <- BeamAgent.CapabilityCatalog.tool_schemas(),
         {:ok, _messages, stats} <-
           ConversationContext.compact(
             session_id,
             options.provider_module,
             options.provider_options,
             project_context.system_prompt,
             tool_schemas
           ) do
      if stats.compacted?, do: {:ok, :compacted, stats}, else: {:ok, :not_needed, stats}
    end
  end

  def skills(session_id), do: Context.skills(session_id)
  def reload_context(session_id), do: Context.reload(session_id)
  def event_log_path(session_id), do: EventLog.path(session_id)
  def import_attachment(session_id, attrs), do: AttachmentStore.import(session_id, attrs)
  def attachments(session_id), do: AttachmentStore.list(session_id)
  def draft_attachments(session_id), do: AttachmentStore.drafts(session_id)

  def delete_attachment(session_id, attachment_id),
    do: AttachmentStore.delete(session_id, attachment_id)

  def attachment_store_pid(session_id), do: Names.pid(:attachment_store, session_id)
  def agent_pid(session_id), do: Names.pid(:agent, session_id)
  def event_log_pid(session_id), do: Names.pid(:event_log, session_id)
  def stream_hub_pid(session_id), do: Names.pid(:stream_hub, session_id)
  def tool_policy_pid(session_id), do: Names.pid(:tool_policy, session_id)
  def context_pid(session_id), do: Names.pid(:context, session_id)
  def conversation_context_pid(session_id), do: Names.pid(:conversation_context, session_id)
  def project_pid(project_id), do: Names.pid(:project, project_id)
  def project_supervisor_pid(project_id), do: Names.pid(:project_supervisor, project_id)
  def goal_pid(goal_id), do: Names.pid(:goal, goal_id)
  def goal_supervisor_pid(goal_id), do: Names.pid(:goal_supervisor, goal_id)
  def goal_event_hub_pid(goal_id), do: Names.pid(:goal_event_hub, goal_id)
  def model_registry_pid(project_id), do: Names.pid(:model_registry, project_id)
  def project(project_id), do: Project.snapshot(project_id)
  def goal(goal_id), do: Goal.snapshot(goal_id)

  def stop_session(session_id) do
    case stop_goal(session_id) do
      :ok ->
        :ok

      {:error, :not_found} ->
        case Names.pid(:session_supervisor, session_id) do
          {:ok, pid} -> stop_supervisor(pid)
          {:error, :not_found} -> :ok
        end
    end
  end

  def stop_goal(goal_id) do
    with {:ok, pid} <- Names.pid(:goal_supervisor, goal_id) do
      case goal_root_parent(pid) do
        {:ok, parent} -> DynamicSupervisor.terminate_child(parent, pid)
        :not_found -> stop_supervisor(pid)
      end
    end
  end

  defp stop_supervisor(pid) do
    Supervisor.stop(pid, :normal, 2_500)
  catch
    :exit, {:noproc, _call} ->
      :ok

    :exit, {:timeout, _call} ->
      Process.exit(pid, :kill)
      :ok
  end

  defp goal_root_parent(goal_supervisor) do
    BeamAgent.Registry
    |> Elixir.Registry.select([
      {{{:goal_root_supervisor, :"$1"}, :"$2", :"$3"}, [], [:"$2"]}
    ])
    |> Enum.find_value(:not_found, fn parent ->
      try do
        if Enum.any?(DynamicSupervisor.which_children(parent), fn
             {_id, ^goal_supervisor, _type, _modules} -> true
             _child -> false
           end),
           do: {:ok, parent},
           else: nil
      catch
        :exit, _reason -> nil
      end
    end)
  end

  def stop_project(project_id) do
    with {:ok, pid} <- Names.pid(:project_supervisor, project_id) do
      Supervisor.stop(pid, :normal)
    end
  end

  def new_goal_id, do: new_session_id()

  def new_session_id do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "session-#{suffix}"
  end

  defp project_options(opts, workspace_root) do
    opts
    |> Keyword.take([
      :model_endpoints,
      :provider,
      :provider_options,
      :provider_profile,
      :data_dir,
      :outcome_telemetry,
      :outcome_retention,
      :resource_limits,
      :repository_scan_interval_ms,
      :routing_evidence_mode,
      :routing_exploration_percent,
      :routing_excluded_endpoints,
      :routing_preferred_endpoints,
      :distributed_execution_enabled
    ])
    |> Keyword.put(:workspace_root, workspace_root)
  end

  defp sync_model_registry(project_id, opts) do
    if Keyword.has_key?(opts, :model_endpoints) do
      ModelRegistry.replace(project_id, Keyword.fetch!(opts, :model_endpoints))
    else
      register_session_model(project_id, opts)
    end
  end

  defp register_session_model(project_id, opts) do
    provider = Keyword.get(opts, :provider, Application.fetch_env!(:beam_agent, :provider))
    provider_options = Keyword.get(opts, :provider_options, [])

    endpoint = %{
      id: Keyword.get(opts, :provider_profile, Atom.to_string(provider)),
      provider: provider,
      model: Keyword.get(provider_options, :model),
      base_url: Keyword.get(provider_options, :base_url),
      api_key_env: Keyword.get(provider_options, :api_key_env)
    }

    ModelRegistry.register(project_id, endpoint)
  end

  defp validate_session_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id), do: :ok, else: {:error, :invalid_session_id}
  end

  defp validate_session_id(_id), do: {:error, :invalid_session_id}

  defp validate_goal_session_identity(id, id), do: :ok

  defp validate_goal_session_identity(goal_id, session_id),
    do: {:error, {:goal_session_id_mismatch, goal_id, session_id}}

  defp validate_goal_workspace(opts, expected) do
    case Keyword.fetch(opts, :workspace_root) do
      {:ok, workspace_root} ->
        case Workspace.canonical_root(workspace_root) do
          {:ok, ^expected} -> :ok
          {:ok, actual} -> {:error, {:project_workspace_mismatch, expected, actual}}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        :ok
    end
  end
end
