defmodule BeamAgent.Session.Context do
  @moduledoc "Session-owned immutable snapshot of project instructions and lazily activated skills."
  use GenServer

  alias BeamAgent.{AgentSpec, Names, ProjectContext}
  alias BeamAgent.Session.EventLog
  alias BeamAgent.Tools.FileSupport

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:context, id))
  end

  def snapshot(session_id) do
    with {:ok, pid} <- Names.pid(:context, session_id) do
      GenServer.call(pid, :snapshot)
    end
  end

  def skills(session_id) do
    with {:ok, pid} <- Names.pid(:context, session_id) do
      GenServer.call(pid, :skills)
    end
  end

  def read_skill(session_id, name) do
    with {:ok, pid} <- Names.pid(:context, session_id) do
      GenServer.call(pid, {:read_skill, name})
    end
  end

  def reload(session_id) do
    with {:ok, pid} <- Names.pid(:context, session_id) do
      GenServer.call(pid, :reload)
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    agent_spec = Keyword.fetch!(opts, :agent_spec)

    with {:ok, project_snapshot} <- ProjectContext.load(workspace_root),
         snapshot <- apply_agent_spec(project_snapshot, agent_spec),
         {:ok, _event} <-
           EventLog.append(session_id, :context_loaded, event_data(snapshot, "session_start")) do
      {:ok, snapshot |> Map.put(:session_id, session_id) |> Map.put(:agent_spec, agent_spec)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    public =
      state
      |> Map.drop([:session_id])
      |> Map.update!(:agent_spec, &AgentSpec.to_map/1)
      |> Map.put(:skills, Enum.map(state.skills, &public_skill/1))

    {:reply, {:ok, public}, state}
  end

  def handle_call(:skills, _from, state) do
    {:reply, {:ok, Enum.map(state.skills, &public_skill/1)}, state}
  end

  def handle_call(:reload, _from, state) do
    with {:ok, project_snapshot} <- ProjectContext.load(state.workspace_root),
         snapshot <- apply_agent_spec(project_snapshot, state.agent_spec),
         {:ok, _event} <-
           EventLog.append(state.session_id, :context_loaded, event_data(snapshot, "reload")) do
      next =
        snapshot
        |> Map.put(:session_id, state.session_id)
        |> Map.put(:agent_spec, state.agent_spec)

      {:reply, {:ok, summary(snapshot)}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_skill, name}, _from, state) when is_binary(name) do
    case Enum.find(state.skills, &(&1.name == name)) do
      nil ->
        {:reply, {:error, {:unknown_skill, name}}, state}

      skill ->
        case EventLog.append(state.session_id, :skill_activated, %{
               "name" => skill.name,
               "path" => skill.path,
               "sha256" => skill.sha256,
               "context_fingerprint" => state.fingerprint
             }) do
          {:ok, _event} -> {:reply, {:ok, skill}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:read_skill, _name}, _from, state),
    do: {:reply, {:error, :invalid_skill_name}, state}

  defp event_data(snapshot, reason) do
    %{
      "fingerprint" => snapshot.fingerprint,
      "prompt_version" => snapshot.prompt_version,
      "agent_spec_id" => snapshot.agent_spec_id,
      "agent_role" => snapshot.agent_role,
      "reason" => reason,
      "instructions" => Enum.map(snapshot.instructions, &Map.take(&1, [:path, :sha256])),
      "skills" => Enum.map(snapshot.skills, &public_skill/1),
      "warnings" => snapshot.warnings
    }
  end

  defp summary(snapshot) do
    %{
      fingerprint: snapshot.fingerprint,
      prompt_version: snapshot.prompt_version,
      instruction_count: length(snapshot.instructions),
      skill_count: length(snapshot.skills),
      warnings: snapshot.warnings
    }
  end

  defp public_skill(skill), do: Map.take(skill, [:name, :description, :path, :sha256])

  defp apply_agent_spec(snapshot, agent_spec) do
    %{
      snapshot
      | fingerprint: FileSupport.sha256(snapshot.fingerprint <> ":" <> agent_spec.spec_id),
        system_prompt: snapshot.system_prompt <> "\n\n" <> AgentSpec.system_prompt(agent_spec)
    }
    |> Map.put(:agent_spec_id, agent_spec.spec_id)
    |> Map.put(:agent_role, agent_spec.role)
  end
end
