defmodule BeamAgent do
  @moduledoc """
  Public API for the OTP-native agent harness.

  A session is a supervision subtree, an agent is a GenServer, and its durable
  source of truth is an append-only event log.
  """

  alias BeamAgent.{Agent, Names, SessionSupervisor, Workspace}
  alias BeamAgent.Session.{Context, EventLog, StreamHub, ToolPolicy}

  def start_session(opts \\ []) do
    id = Keyword.get_lazy(opts, :session_id, &new_session_id/0)

    workspace_root = Keyword.get(opts, :workspace_root, File.cwd!())

    with :ok <- validate_session_id(id),
         {:ok, workspace_root} <- Workspace.canonical_root(workspace_root) do
      data_dir = Keyword.get(opts, :data_dir, Application.fetch_env!(:beam_agent, :data_dir))

      child_opts =
        opts
        |> Keyword.put(:session_id, id)
        |> Keyword.put(:data_dir, data_dir)
        |> Keyword.put(:workspace_root, workspace_root)

      case DynamicSupervisor.start_child(
             BeamAgent.SessionRootSupervisor,
             {SessionSupervisor, child_opts}
           ) do
        {:ok, _pid} -> {:ok, id}
        {:error, {:already_started, _pid}} -> {:error, {:session_already_started, id}}
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

  def ask(session_id, prompt, timeout \\ 30_000), do: Agent.ask(session_id, prompt, timeout)
  def cancel(session_id), do: Agent.cancel(session_id)
  def subscribe(session_id, subscriber \\ self()), do: StreamHub.subscribe(session_id, subscriber)

  def unsubscribe(session_id, subscriber \\ self()),
    do: StreamHub.unsubscribe(session_id, subscriber)

  def sync_stream(session_id), do: StreamHub.sync(session_id)

  def respond_approval(session_id, approval_id, decision),
    do: ToolPolicy.respond(session_id, approval_id, decision)

  def set_approval_handler(session_id, handler), do: ToolPolicy.set_handler(session_id, handler)

  def events(session_id), do: EventLog.events(session_id)
  def context_snapshot(session_id), do: Context.snapshot(session_id)
  def skills(session_id), do: Context.skills(session_id)
  def reload_context(session_id), do: Context.reload(session_id)
  def event_log_path(session_id), do: EventLog.path(session_id)
  def agent_pid(session_id), do: Names.pid(:agent, session_id)
  def event_log_pid(session_id), do: Names.pid(:event_log, session_id)
  def stream_hub_pid(session_id), do: Names.pid(:stream_hub, session_id)
  def tool_policy_pid(session_id), do: Names.pid(:tool_policy, session_id)
  def context_pid(session_id), do: Names.pid(:context, session_id)

  def stop_session(session_id) do
    with {:ok, pid} <- Names.pid(:session_supervisor, session_id) do
      Supervisor.stop(pid, :normal)
    end
  end

  def new_session_id do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "session-#{suffix}"
  end

  defp validate_session_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id), do: :ok, else: {:error, :invalid_session_id}
  end

  defp validate_session_id(_id), do: {:error, :invalid_session_id}
end
