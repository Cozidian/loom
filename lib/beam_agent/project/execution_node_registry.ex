defmodule BeamAgent.Project.ExecutionNodeRegistry do
  @moduledoc """
  Project-owned trust, compatibility, partition, and duplicate-work policy for
  optional BEAM-node execution.

  Remote execution is disabled by default. This registry deliberately stops at
  selecting and leasing compatible nodes; callers cannot smuggle arbitrary
  functions through it.
  """
  use GenServer

  alias BeamAgent.{ExecutionNode, Names}

  @heartbeat_timeout_ms 30_000

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:execution_node_registry, project_id))
  end

  def register(project_id, descriptor), do: call(project_id, {:register, descriptor})
  def heartbeat(project_id, node_id), do: call(project_id, {:heartbeat, node_id})
  def select(project_id, requirements \\ %{}), do: call(project_id, {:select, requirements})

  def claim_job(project_id, job_id, requirements \\ %{}),
    do: call(project_id, {:claim_job, job_id, requirements})

  def complete_job(project_id, job_id, result_fingerprint),
    do: call(project_id, {:complete_job, job_id, result_fingerprint})

  def nodes(project_id), do: call(project_id, :nodes)

  @impl true
  def init(opts) do
    version = to_string(Application.spec(:beam_agent, :vsn) || "development")
    now = System.monotonic_time(:millisecond)

    local = %ExecutionNode{
      id: "local",
      node: node(),
      trust: :local,
      code_version: version,
      capabilities: :all,
      data_locality: :project,
      status: :available,
      last_heartbeat_at: now
    }

    {:ok,
     %{
       project_id: Keyword.fetch!(opts, :project_id),
       version: version,
       remote_enabled: Keyword.get(opts, :distributed_execution_enabled, false),
       nodes: %{local.id => local},
       jobs: %{}
     }}
  end

  @impl true
  def handle_call({:register, descriptor}, _from, state) do
    with true <- state.remote_enabled or {:error, :distributed_execution_disabled},
         {:ok, execution_node} <- normalize_node(descriptor, state.version) do
      {:reply, {:ok, execution_node}, put_in(state, [:nodes, execution_node.id], execution_node)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:heartbeat, node_id}, _from, state) do
    case state.nodes[node_id] do
      nil ->
        {:reply, {:error, :unknown_execution_node}, state}

      execution_node ->
        execution_node = %{
          execution_node
          | status: :available,
            last_heartbeat_at: System.monotonic_time(:millisecond)
        }

        {:reply, :ok, put_in(state, [:nodes, node_id], execution_node)}
    end
  end

  def handle_call({:select, requirements}, _from, state) do
    {nodes, state} = refresh_partitions(state)

    case select_node(nodes, requirements) do
      nil -> {:reply, {:error, :no_compatible_execution_node}, state}
      execution_node -> {:reply, {:ok, execution_node}, state}
    end
  end

  def handle_call({:claim_job, job_id, requirements}, _from, state)
      when is_binary(job_id) and job_id != "" do
    case state.jobs[job_id] do
      %{status: :completed} = job ->
        {:reply, {:ok, {:duplicate_completed, job}}, state}

      %{status: :running} ->
        {:reply, {:error, :duplicate_job_running}, state}

      nil ->
        {nodes, state} = refresh_partitions(state)

        case select_node(nodes, requirements) do
          nil ->
            {:reply, {:error, :no_compatible_execution_node}, state}

          execution_node ->
            job = %{
              id: job_id,
              node_id: execution_node.id,
              status: :running,
              result_fingerprint: nil,
              claimed_at: DateTime.utc_now()
            }

            {:reply, {:ok, {:claimed, job}}, put_in(state, [:jobs, job_id], job)}
        end
    end
  end

  def handle_call({:claim_job, _job_id, _requirements}, _from, state),
    do: {:reply, {:error, :invalid_distributed_job_id}, state}

  def handle_call({:complete_job, job_id, result_fingerprint}, _from, state) do
    case state.jobs[job_id] do
      %{status: :running} = job when is_binary(result_fingerprint) ->
        job = %{job | status: :completed, result_fingerprint: result_fingerprint}
        {:reply, {:ok, job}, put_in(state, [:jobs, job_id], job)}

      %{status: :completed, result_fingerprint: ^result_fingerprint} = job ->
        {:reply, {:ok, job}, state}

      %{status: :completed} ->
        {:reply, {:error, :distributed_job_result_conflict}, state}

      nil ->
        {:reply, {:error, :unknown_distributed_job}, state}
    end
  end

  def handle_call(:nodes, _from, state) do
    {nodes, state} = refresh_partitions(state)
    {:reply, {:ok, nodes |> Map.values() |> Enum.sort_by(& &1.id)}, state}
  end

  defp normalize_node(descriptor, expected_version) when is_map(descriptor) do
    id = value(descriptor, :id)
    remote_node = value(descriptor, :node)
    version = value(descriptor, :code_version)
    trusted = value(descriptor, :trusted)

    cond do
      trusted != true ->
        {:error, :untrusted_execution_node}

      version != expected_version ->
        {:error, :execution_node_version_mismatch}

      not is_binary(id) or id == "" or not is_atom(remote_node) ->
        {:error, :invalid_execution_node}

      true ->
        {:ok,
         %ExecutionNode{
           id: id,
           node: remote_node,
           trust: :trusted_remote,
           code_version: version,
           capabilities: value(descriptor, :capabilities) || [],
           data_locality: value(descriptor, :data_locality) || :remote,
           status: :available,
           last_heartbeat_at: System.monotonic_time(:millisecond)
         }}
    end
  end

  defp normalize_node(_descriptor, _expected_version), do: {:error, :invalid_execution_node}

  defp select_node(nodes, requirements) do
    required_capabilities = value(requirements, :capabilities) || []
    locality = value(requirements, :data_locality) || :any

    nodes
    |> Map.values()
    |> Enum.filter(&(&1.status == :available))
    |> Enum.filter(&(locality == :any or &1.data_locality == locality))
    |> Enum.filter(&capable?(&1, required_capabilities))
    |> Enum.sort_by(fn execution_node ->
      {if(execution_node.trust == :local, do: 0, else: 1), execution_node.id}
    end)
    |> List.first()
  end

  defp capable?(%{capabilities: :all}, _required), do: true

  defp capable?(execution_node, required),
    do: Enum.all?(required, &(&1 in execution_node.capabilities))

  defp refresh_partitions(state) do
    now = System.monotonic_time(:millisecond)

    nodes =
      Map.new(state.nodes, fn
        {"local", execution_node} ->
          {"local", %{execution_node | status: :available, last_heartbeat_at: now}}

        {id, execution_node} ->
          status =
            if now - execution_node.last_heartbeat_at > @heartbeat_timeout_ms,
              do: :partitioned,
              else: execution_node.status

          {id, %{execution_node | status: status}}
      end)

    {nodes, %{state | nodes: nodes}}
  end

  defp value(map, key) when is_map(map), do: map[key] || map[to_string(key)]

  defp call(project_id, message) do
    with {:ok, pid} <- Names.pid(:execution_node_registry, project_id),
         do: GenServer.call(pid, message)
  end
end
