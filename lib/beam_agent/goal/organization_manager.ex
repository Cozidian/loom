defmodule BeamAgent.Goal.OrganizationManager do
  @moduledoc "Goal-owned state machine for temporary, dynamically formed worker organizations."
  use GenServer

  alias BeamAgent.{DecompositionPlan, ExecutionStrategy, Names}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_organization_manager, goal_id))
  end

  def create(goal_id, coordinator_id, %DecompositionPlan{} = plan, strategy, opts \\ []) do
    call(goal_id, {:create, coordinator_id, plan, strategy, opts})
  end

  def transition(goal_id, organization_id, task_id, status, metadata \\ %{}) do
    call(goal_id, {:transition, organization_id, task_id, status, metadata})
  end

  def cancel(goal_id, organization_id, reason \\ :cancelled) do
    call(goal_id, {:cancel, organization_id, reason})
  end

  def snapshot(goal_id, organization_id \\ :all),
    do: call(goal_id, {:snapshot, organization_id})

  def reconcile(goal_id, organization_id, statuses, results \\ %{})
      when is_map(statuses) and is_map(results),
      do: call(goal_id, {:reconcile, organization_id, statuses, results})

  @impl true
  def init(opts) do
    with {:ok, organizations} <- recover(opts) do
      {:ok,
       %{
         goal_id: Keyword.fetch!(opts, :goal_id),
         root_session_id: Keyword.fetch!(opts, :session_id),
         organizations: organizations
       }}
    end
  end

  @impl true
  def handle_call({:create, coordinator_id, plan, strategy, opts}, _from, state) do
    organization = %{
      id:
        Keyword.get_lazy(opts, :organization_id, fn ->
          "organization-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        end),
      goal_id: state.goal_id,
      coordinator_id: coordinator_id,
      plan_id: plan.id,
      strategy: strategy,
      status: :running,
      tasks: Map.new(plan.tasks, fn {id, task} -> {id, Map.put(task, :status, :pending)} end),
      created_at: DateTime.utc_now(),
      finished_at: nil
    }

    case state.organizations[organization.id] do
      nil ->
        state = put_in(state, [:organizations, organization.id], organization)

        record(state, :organization_formed, organization, %{
          task_count: map_size(plan.tasks),
          plan: DecompositionPlan.to_map(plan)
        })

        {:reply, {:ok, organization}, state}

      existing ->
        {:reply, {:ok, existing}, state}
    end
  end

  def handle_call({:reconcile, organization_id, statuses, results}, _from, state) do
    case state.organizations[organization_id] do
      nil ->
        {:reply, {:error, :unknown_organization}, state}

      organization ->
        tasks =
          Map.new(organization.tasks, fn {id, task} ->
            result = results[id] || %{}

            task =
              task
              |> Map.put(:status, Map.get(statuses, id, task.status))
              |> Map.merge(
                safe_metadata(%{
                  worker_id: result[:worker_id] || get_in(result, [:worker, :worker_id]),
                  delegation_id:
                    result[:delegation_id] || get_in(result, [:worker, :delegation_id]),
                  result_fingerprint: result[:result_fingerprint],
                  verification_status: get_in(result, [:verification, :status]),
                  attempts: result[:attempts]
                })
              )

            {id, task}
          end)

        organization = %{organization | tasks: tasks} |> finish_if_terminal()
        state = put_in(state, [:organizations, organization_id], organization)
        {:reply, {:ok, organization}, state}
    end
  end

  def handle_call({:transition, organization_id, task_id, status, metadata}, _from, state) do
    with %{tasks: tasks} = organization <- state.organizations[organization_id],
         %{status: current} = task <- tasks[task_id],
         :ok <- valid_transition(current, status) do
      task = task |> Map.put(:status, status) |> Map.merge(safe_metadata(metadata))
      tasks = Map.put(tasks, task_id, task)
      organization = %{organization | tasks: tasks} |> finish_if_terminal()
      state = put_in(state, [:organizations, organization_id], organization)

      event_metadata =
        metadata
        |> safe_metadata()
        |> Map.merge(%{
          task_id: task_id,
          task_status: status,
          worker_id: task[:worker_id]
        })

      record(state, :organization_task_transitioned, organization, event_metadata)

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
      pending: [:running, :failed, :cancelled, :blocked],
      running: [:completed, :failed, :cancelled],
      completed: [],
      failed: [],
      cancelled: [],
      blocked: []
    }

    if next in Map.fetch!(allowed, current), do: :ok, else: {:error, :invalid_task_transition}
  end

  defp safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      :worker_id,
      :delegation_id,
      :result_fingerprint,
      :verification_status,
      :attempt,
      :attempts,
      :maximum_attempts,
      :failure_code,
      :recovery_action
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_metadata(_metadata), do: %{}

  defp record(state, type, organization, extra) do
    data =
      Map.merge(
        %{
          "organization_id" => organization.id,
          "goal_id" => state.goal_id,
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

  defp recover(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, events} <- EventLog.read(data_dir, session_id) do
      organizations =
        events
        |> Enum.reduce(%{}, &recover_event/2)
        |> Map.new(fn {id, organization} ->
          {id, %{organization | goal_id: organization.goal_id || Keyword.fetch!(opts, :goal_id)}}
        end)

      {:ok, organizations}
    end
  end

  defp recover_event(%{"type" => "organization_formed", "data" => data}, organizations) do
    with id when is_binary(id) <- data["organization_id"],
         %{} = plan_data <- data["plan"],
         {:ok, plan} <- DecompositionPlan.new(plan_data) do
      organization = %{
        id: id,
        goal_id: data["goal_id"],
        coordinator_id: data["coordinator_id"],
        plan_id: data["plan_id"],
        strategy: ExecutionStrategy.resolve(data["strategy"] || "coordinate"),
        status: :running,
        tasks:
          Map.new(plan.tasks, fn {task_id, task} ->
            {task_id, Map.put(task, :status, :pending)}
          end),
        created_at: nil,
        finished_at: nil
      }

      Map.put(organizations, id, organization)
    else
      _legacy_or_invalid -> organizations
    end
  end

  defp recover_event(
         %{"type" => "organization_task_transitioned", "data" => data},
         organizations
       ) do
    update_recovered_task(organizations, data)
  end

  defp recover_event(%{"type" => "organization_finished", "data" => data}, organizations),
    do: update_recovered_status(organizations, data, data["organization_status"] || "failed")

  defp recover_event(%{"type" => "organization_cancelled", "data" => data}, organizations),
    do: update_recovered_status(organizations, data, "cancelled")

  defp recover_event(_event, organizations), do: organizations

  defp update_recovered_task(organizations, data) do
    with id when is_binary(id) <- data["organization_id"],
         task_id when is_binary(task_id) <- data["task_id"],
         %{tasks: tasks} = organization <- organizations[id],
         %{} = task <- tasks[task_id] do
      metadata =
        data
        |> atomize_known_metadata()
        |> Map.put(:status, status_atom(data["task_status"]))

      task = Map.merge(task, metadata)
      Map.put(organizations, id, %{organization | tasks: Map.put(tasks, task_id, task)})
    else
      _missing -> organizations
    end
  end

  defp update_recovered_status(organizations, data, status) do
    id = data["organization_id"]

    case organizations[id] do
      nil -> organizations
      organization -> Map.put(organizations, id, %{organization | status: status_atom(status)})
    end
  end

  defp atomize_known_metadata(data) do
    %{
      worker_id: data["worker_id"],
      delegation_id: data["delegation_id"],
      result_fingerprint: data["result_fingerprint"],
      verification_status: data["verification_status"],
      attempt: data["attempt"],
      attempts: data["attempts"],
      maximum_attempts: data["maximum_attempts"],
      failure_code: data["failure_code"],
      recovery_action: data["recovery_action"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp status_atom(value) when is_atom(value), do: value

  defp status_atom(value) when is_binary(value) do
    case value do
      "pending" -> :pending
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "cancelled" -> :cancelled
      "blocked" -> :blocked
      _other -> :failed
    end
  end

  defp status_atom(_value), do: :failed

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_organization_manager, goal_id),
         do: GenServer.call(pid, message)
  end
end
