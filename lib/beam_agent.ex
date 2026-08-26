defmodule BeamAgent do
  @moduledoc """
  Public API for the OTP-native agent harness.

  A session is a supervision subtree, an agent is a GenServer, and its durable
  source of truth is an append-only event log.
  """

  alias BeamAgent.{Agent, Names, SessionSupervisor}
  alias BeamAgent.Session.EventLog

  def start_session(opts \\ []) do
    id = Keyword.get_lazy(opts, :session_id, &new_session_id/0)

    with :ok <- validate_session_id(id) do
      data_dir = Keyword.get(opts, :data_dir, Application.fetch_env!(:beam_agent, :data_dir))
      child_opts = opts |> Keyword.put(:session_id, id) |> Keyword.put(:data_dir, data_dir)

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
  def events(session_id), do: EventLog.events(session_id)
  def event_log_path(session_id), do: EventLog.path(session_id)
  def agent_pid(session_id), do: Names.pid(:agent, session_id)
  def event_log_pid(session_id), do: Names.pid(:event_log, session_id)

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
