defmodule BeamAgent.Goal.OrganizationManager do
  @moduledoc "Goal-owned state machine for temporary, dynamically formed worker organizations."
  use GenServer

  alias BeamAgent.{DecompositionPlan, Names}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_organization_manager, goal_id))
  end

  def create(goal_id, coordinator_id, %DecompositionPlan{} = plan, strategy) do
    call(goal_id, {:create, coordinator_id, plan, strategy})
  end

  def transition(goal_id, organization_id, task_id, status, metadata \\ %{}) do
    call(goal_id, {:transition, organization_id, task_id, status, metadata})
  end

  def cancel(goal_id, organization_id, reason \\ :cancelled) do
    call(goal_id, {:cancel, organization_id, reason})
  end

  def snapshot(goal_id, organization_id \\ :all),
    do: call(goal_id, {:snapshot, organization_id})

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       root_session_id: Keyword.fetch!(opts, :session_id),
       organizations: %{}
     }}
  end

  @impl true
  def handle_call({:create, coordinator_id, plan, strategy}, _from, state) do
    organization = %{
      id: "organization-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      goal_id: state.goal_id,
      coordinator_id: coordinator_id,
      plan_id: plan.id,
      strategy: strategy,
      status: :running,
      tasks: Map.new(plan.tasks, fn {id, task} -> {id, Map.put(task, :status, :pending)} end),
      created_at: DateTime.utc_now(),
      finished_at: nil
    }

    state = put_in(state, [:organizations, organization.id], organization)
    record(state, :organization_formed, organization, %{task_count: map_size(plan.tasks)})
    {:reply, {:ok, organization}, state}
  end

  def handle_call({:transition, organization_id, task_id, status, metadata}, _from, state) do
    with %{tasks: tasks} = organization <- state.organizations[organization_id],
         %{status: current} = task <- tasks[task_id],
         :ok <- valid_transition(current, status) do
      task = task |> Map.put(:status, status) |> Map.merge(safe_metadata(metadata))
      tasks = Map.put(tasks, task_id, task)
      organization = %{organization | tasks: tasks} |> finish_if_terminal()
      state = put_in(state, [:organizations, organization_id], organization)

      record(state, :organization_task_transitioned, organization, %{
        task_id: task_id,
        task_status: status,
        worker_id: task[:worker_id]
      })

      if organization.status != :running,
        do: record(state, :organization_finished, organization, %{})

      {:reply, {:ok, organization}, state}
    else
      nil -> {:reply, {:error, :unknown_organization_or_task}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, organization_id, reason}, _from, state) do
    case state.organizations[organization_id] do
      nil ->
        {:reply, {:error, :unknown_organization}, state}

      organization ->
        tasks =
          Map.new(organization.tasks, fn {id, task} ->
            status = if task.status in [:pending, :running], do: :cancelled, else: task.status
            {id, Map.put(task, :status, status)}
          end)

        organization = %{
          organization
          | status: :cancelled,
            tasks: tasks,
            finished_at: DateTime.utc_now()
        }

        state = put_in(state, [:organizations, organization_id], organization)
        record(state, :organization_cancelled, organization, %{reason: reason_code(reason)})
        {:reply, :ok, state}
    end
  end

  def handle_call({:snapshot, :all}, _from, state),
    do: {:reply, {:ok, Map.values(state.organizations)}, state}

  def handle_call({:snapshot, id}, _from, state) do
    case state.organizations[id] do
      nil -> {:reply, {:error, :unknown_organization}, state}
      organization -> {:reply, {:ok, organization}, state}
    end
  end

  defp finish_if_terminal(organization) do
    statuses = Enum.map(organization.tasks, fn {_id, task} -> task.status end)

    if Enum.all?(statuses, &(&1 in [:completed, :failed, :cancelled, :blocked])) do
      status = if Enum.all?(statuses, &(&1 == :completed)), do: :completed, else: :failed
      %{organization | status: status, finished_at: DateTime.utc_now()}
    else
      organization
    end
  end

  defp valid_transition(current, next) do
    allowed = %{
      pending: [:running, :cancelled, :blocked],
      running: [:completed, :failed, :cancelled],
      completed: [],
      failed: [],
      cancelled: [],
      blocked: []
    }

    if next in Map.fetch!(allowed, current), do: :ok, else: {:error, :invalid_task_transition}
  end

  defp safe_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [:worker_id, :delegation_id, :result_fingerprint, :verification_status])
  end

  defp safe_metadata(_metadata), do: %{}

  defp record(state, type, organization, extra) do
    data =
      Map.merge(
        %{
          "organization_id" => organization.id,
          "coordinator_id" => organization.coordinator_id,
          "plan_id" => organization.plan_id,
          "organization_status" => to_string(organization.status),
          "strategy" => strategy_id(organization.strategy)
        },
        Map.new(extra, fn {key, value} -> {to_string(key), stringify(value)} end)
      )

    _ = EventLog.append(state.root_session_id, type, data)
    :ok
  end

  defp strategy_id(%{id: id}), do: id
  defp strategy_id(id) when is_atom(id), do: to_string(id)
  defp strategy_id(id), do: id
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
  defp reason_code(reason) when is_atom(reason), do: to_string(reason)
  defp reason_code({reason, _}) when is_atom(reason), do: to_string(reason)
  defp reason_code(_reason), do: "cancelled"

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_organization_manager, goal_id),
         do: GenServer.call(pid, message)
  end
end
