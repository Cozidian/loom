defmodule BeamAgent.SessionSupervisor do
  @moduledoc "One supervision subtree for one durable session."
  use Supervisor

  alias BeamAgent.Names

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
    with {:ok, supervisor} <- Names.pid(:subagent_supervisor, parent_session_id) do
      child_id = Keyword.get_lazy(opts, :session_id, &BeamAgent.new_session_id/0)

      child_opts =
        opts
        |> Keyword.put(:session_id, child_id)
        |> Keyword.put(:parent_session_id, parent_session_id)

      case DynamicSupervisor.start_child(supervisor, {__MODULE__, child_opts}) do
        {:ok, _pid} -> {:ok, child_id}
        {:error, {:already_started, _pid}} -> {:error, {:session_already_started, child_id}}
        {:error, reason} -> {:error, reason}
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
