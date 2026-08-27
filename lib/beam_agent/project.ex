defmodule BeamAgent.Project do
  @moduledoc "The identity and long-lived state boundary for one canonical workspace."
  use GenServer

  alias BeamAgent.Names

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:project, project_id))
  end

  def snapshot(project_id) do
    with {:ok, pid} <- Names.pid(:project, project_id) do
      GenServer.call(pid, :snapshot)
    end
  end

  def id_for_workspace(workspace_root) when is_binary(workspace_root) do
    digest =
      :sha256
      |> :crypto.hash(workspace_root)
      |> Base.url_encode64(padding: false)

    "project-#{digest}"
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       project_id: Keyword.fetch!(opts, :project_id),
       workspace_root: Keyword.fetch!(opts, :workspace_root)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state}, state}
end
