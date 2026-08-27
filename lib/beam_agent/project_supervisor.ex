defmodule BeamAgent.ProjectSupervisor do
  @moduledoc "One supervision subtree for one canonical project workspace."
  use Supervisor

  alias BeamAgent.{ModelRegistry, Names, Project}
  alias BeamAgent.Project.GoalRootSupervisor

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    Supervisor.start_link(__MODULE__, opts, name: Names.via(:project_supervisor, project_id))
  end

  def child_spec(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    %{
      id: {__MODULE__, project_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :supervisor
    }
  end

  def start_goal(project_id, opts) do
    with {:ok, project} <- Project.snapshot(project_id),
         :ok <- validate_workspace(opts, project.workspace_root),
         {:ok, supervisor} <- Names.pid(:goal_root_supervisor, project_id) do
      goal_opts =
        opts
        |> Keyword.put(:project_id, project_id)
        |> Keyword.put(:workspace_root, project.workspace_root)

      case DynamicSupervisor.start_child(supervisor, {BeamAgent.GoalSupervisor, goal_opts}) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, _pid}} ->
          {:error, {:goal_already_started, Keyword.fetch!(opts, :goal_id)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def init(opts) do
    children = [
      {Project, opts},
      {Task.Supervisor,
       name: Names.via(:model_health_supervisor, Keyword.fetch!(opts, :project_id))},
      {ModelRegistry, opts},
      {GoalRootSupervisor, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp validate_workspace(opts, expected) do
    case Keyword.fetch(opts, :workspace_root) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:project_workspace_mismatch, expected, actual}}
      :error -> :ok
    end
  end
end
