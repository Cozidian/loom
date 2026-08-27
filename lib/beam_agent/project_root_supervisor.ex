defmodule BeamAgent.ProjectRootSupervisor do
  @moduledoc "Owns the long-lived project runtimes currently open in BeamAgent."
  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_project(opts) do
    case DynamicSupervisor.start_child(__MODULE__, {BeamAgent.ProjectSupervisor, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
