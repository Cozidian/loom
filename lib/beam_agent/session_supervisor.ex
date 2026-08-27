defmodule BeamAgent.SessionSupervisor do
  @moduledoc "One supervision subtree for one durable session."
  use Supervisor

  alias BeamAgent.{Agent, Names}

  alias BeamAgent.Session.{
    ConversationContext,
    Context,
    EventLog,
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
      type: :supervisor
    }
  end

  def spawn_subagent(parent_session_id, opts \\ []) do
    with {:ok, identity} <- Agent.runtime_identity(parent_session_id),
         {:ok, supervisor} <- Names.pid(:subagent_supervisor, parent_session_id) do
      child_id = Keyword.get_lazy(opts, :session_id, &BeamAgent.new_session_id/0)

      child_opts =
        opts
        |> Keyword.put(:session_id, child_id)
        |> Keyword.put(:parent_session_id, parent_session_id)
        |> Keyword.put(:project_id, identity.project_id)
        |> Keyword.put(:goal_id, identity.goal_id)
        |> Keyword.put(:workspace_root, identity.workspace_root)
        |> Keyword.put_new(:data_dir, identity.data_dir)

      case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
        {:ok, child_pid} ->
          case EventLog.append(parent_session_id, :subagent_spawned, %{
                 "child_session_id" => child_id
               }) do
            {:ok, _event} ->
              {:ok, child_id}

            {:error, reason} ->
              Supervisor.stop(child_pid, :normal)
              {:error, {:subagent_event_failed, reason}}
          end

        {:error, {:already_started, _pid}} ->
          {:error, {:session_already_started, child_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def init(opts) do
    children = [
      {EventLog, opts},
      {StreamHub, opts},
      {ResourceSupervisor, opts},
      {Context, opts},
      {ConversationContext, opts},
      {ToolPolicy, opts},
      {SubagentSupervisor, opts},
      {BeamAgent.Agent, opts}
    ]

    # The event log is the first dependency. If it fails, every downstream
    # session process is rebuilt. A stream hub failure keeps the log alive while
    # rebuilding all request-owning processes below it.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
