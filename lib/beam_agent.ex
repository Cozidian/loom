defmodule BeamAgent do
  @moduledoc """
  Public API for the OTP-native agent harness.

  A project owns ephemeral goal subtrees. A goal is initially backed by one
  durable root session, whose agent is a GenServer and whose source of truth is
  an append-only event log.
  """

  alias BeamAgent.{
    Agent,
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

  alias BeamAgent.Session.{Context, ConversationContext, EventLog, StreamHub, ToolPolicy}
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

      case ProjectSupervisor.start_goal(project_id, goal_opts) do
        {:ok, _pid} -> {:ok, goal_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def resume_session(session_id, opts \\ []) do
    start_session(Keyword.put(opts, :session_id, session_id))
  end

  def spawn_subagent(parent_session_id, opts \\ []) do
    SessionSupervisor.spawn_subagent(parent_session_id, opts)
  end

  def ask(session_id, prompt, timeout \\ :infinity), do: Agent.ask(session_id, prompt, timeout)
  def cancel(session_id), do: Agent.cancel(session_id)
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
  def approval_policy(session_id), do: ToolPolicy.policy(session_id)
  def set_approval_policy(session_id, policy), do: ToolPolicy.set_policy(session_id, policy)
  def permissions(session_id), do: ToolPolicy.permissions(session_id)

  def revoke_permission(session_id, permission_id),
    do: ToolPolicy.revoke(session_id, permission_id)

  def events(session_id), do: EventLog.events(session_id)
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
        with {:ok, pid} <- Names.pid(:session_supervisor, session_id) do
          Supervisor.stop(pid, :normal)
        end
    end
  end

  def stop_goal(goal_id) do
    with {:ok, pid} <- Names.pid(:goal_supervisor, goal_id) do
      Supervisor.stop(pid, :normal)
    end
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
      :outcome_retention
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
