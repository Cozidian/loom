defmodule BeamAgent.Goal.BudgetManager do
  @moduledoc "Goal-owned resource accounting, allocation, backpressure, and release."
  use GenServer

  alias BeamAgent.{Names, ResourceBudget}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_budget_manager, goal_id))
  end

  def reserve(goal_id, parent_worker_id, worker_id, requested \\ %{}) do
    call(goal_id, {:reserve, parent_worker_id, worker_id, requested})
  end

  def bind(goal_id, allocation_id, owner) when is_pid(owner),
    do: call(goal_id, {:bind, allocation_id, owner})

  def release(goal_id, allocation_id, reason \\ :released),
    do: call(goal_id, {:release, allocation_id, reason})

  def check(goal_id, worker_id, consumption),
    do: call(goal_id, {:check, worker_id, consumption})

  def consume(goal_id, worker_id, consumption),
    do: call(goal_id, {:consume, worker_id, consumption})

  def snapshot(goal_id), do: call(goal_id, :snapshot)

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :agent_spec).resources
    now = System.monotonic_time(:millisecond)

    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       root_session_id: Keyword.fetch!(opts, :session_id),
       root_allocation_id: root.allocation_id,
       allocations: %{root.allocation_id => Map.put(root, :started_monotonic_ms, now)},
       worker_allocations: %{root.worker_id => root.allocation_id},
       monitors: %{},
       owners: %{},
       warned: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:reserve, parent_worker_id, worker_id, requested}, _from, state) do
    with {:ok, parent} <- fetch_worker_allocation(state, parent_worker_id),
         :ok <- available_worker_slot(state),
         remaining <- ResourceBudget.remaining(parent),
         allocation_id <- allocation_id(),
         allocation <-
           ResourceBudget.child_allocation(
             allocation_id,
             worker_id,
             parent,
             remaining,
             requested
           ) do
      state =
        state
        |> put_in([:allocations, allocation_id], allocation)
        |> put_in([:worker_allocations, worker_id], allocation_id)

      record(state, :budget_allocated, allocation, %{})
      {:reply, {:ok, ResourceBudget.public(allocation)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:bind, allocation_id, owner}, _from, state) do
    case state.allocations[allocation_id] do
      nil ->
        {:reply, {:error, :unknown_budget_allocation}, state}

      allocation ->
        monitor = Process.monitor(owner)
        now = System.monotonic_time(:millisecond)
        allocation = %{allocation | status: :active} |> Map.put(:started_monotonic_ms, now)

        state =
          state
          |> put_in([:allocations, allocation_id], allocation)
          |> put_in([:monitors, monitor], allocation_id)
          |> put_in([:owners, allocation_id], owner)

        schedule_deadline(allocation)

        {:reply, :ok, state}
    end
  end

  def handle_call({:release, allocation_id, reason}, _from, state) do
    {reply, state} = release_allocation(state, allocation_id, reason)
    {:reply, reply, state}
  end

  def handle_call({:check, worker_id, consumption}, _from, state) do
    {:reply, authorize_consumption(state, worker_id, consumption), state}
  end

  def handle_call({:consume, worker_id, consumption}, _from, state) do
    case authorize_consumption(state, worker_id, consumption) do
      :ok ->
        allocation_id = state.worker_allocations[worker_id]

        state =
          allocation_chain(state, allocation_id)
          |> Enum.reduce(state, fn id, acc ->
            put_in(
              acc,
              [:allocations, id],
              ResourceBudget.consume(acc.allocations[id], consumption)
            )
          end)

        allocation = state.allocations[allocation_id]
        record(state, :budget_consumed, allocation, %{"consumption" => consumption})
        state = maybe_warn(state, allocation)
        {:reply, :ok, state}

      {:error, reason} = error ->
        record_failure(state, worker_id, reason)
        {:reply, error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    allocations =
      state.allocations
      |> Map.values()
      |> Enum.map(&ResourceBudget.public/1)
      |> Enum.sort_by(& &1.allocation_id)

    {:reply, {:ok, %{goal_id: state.goal_id, allocations: allocations}}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {allocation_id, monitors} ->
        {_reply, state} = release_allocation(%{state | monitors: monitors}, allocation_id, reason)
        {:noreply, state}
    end
  end

  def handle_info({:allocation_deadline, allocation_id}, state) do
    case {state.allocations[allocation_id], state.owners[allocation_id]} do
      {%{status: :active} = allocation, owner} when is_pid(owner) ->
        record(state, :budget_exhausted, allocation, %{"reason" => "budget_deadline_exceeded"})
        Process.exit(owner, :shutdown)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp authorize_consumption(state, worker_id, consumption)
       when is_map(consumption) do
    with {:ok, allocation} <- fetch_worker_allocation(state, worker_id) do
      allocation_chain(state, allocation.allocation_id)
      |> Enum.reduce_while(:ok, fn id, :ok ->
        current = state.allocations[id]

        with :ok <- active?(current),
             :ok <- within_wall_time?(current),
             true <- ResourceBudget.within?(current, consumption) do
          {:cont, :ok}
        else
          false -> {:halt, {:error, :budget_exhausted}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_consumption(_state, _worker_id, _consumption),
    do: {:error, :invalid_budget_consumption}

  defp fetch_worker_allocation(state, worker_id) do
    case state.worker_allocations[worker_id] do
      nil -> {:error, :unknown_worker_budget}
      allocation_id -> {:ok, state.allocations[allocation_id]}
    end
  end

  defp active?(%{status: status}) when status in [:active, :reserved], do: :ok
  defp active?(_allocation), do: {:error, :budget_allocation_released}

  defp within_wall_time?(allocation) do
    case allocation.limits.wall_time_ms do
      :infinity ->
        :ok

      limit ->
        elapsed = System.monotonic_time(:millisecond) - allocation.started_monotonic_ms
        if elapsed <= limit, do: :ok, else: {:error, :budget_deadline_exceeded}
    end
  end

  defp available_worker_slot(state) do
    root = state.allocations[state.root_allocation_id]

    active =
      Enum.count(state.allocations, fn {id, allocation} ->
        id != state.root_allocation_id and allocation.status in [:active, :reserved]
      end)

    case root.limits.concurrent_workers do
      :infinity -> :ok
      limit when active < limit -> :ok
      _limit -> {:error, :worker_concurrency_exhausted}
    end
  end

  defp release_allocation(state, allocation_id, reason) do
    case state.allocations[allocation_id] do
      nil ->
        {{:error, :unknown_budget_allocation}, state}

      %{parent_allocation_id: nil} ->
        {{:error, :root_budget_not_releasable}, state}

      %{status: :released} ->
        {:ok, state}

      allocation ->
        allocation = %{allocation | status: :released}
        record(state, :budget_released, allocation, %{"reason" => inspect(reason)})

        state =
          state
          |> put_in([:allocations, allocation_id], allocation)
          |> update_in([:owners], &Map.delete(&1, allocation_id))

        {:ok, state}
    end
  end

  defp maybe_warn(state, allocation) do
    exhausted =
      Enum.find(allocation.limits, fn {key, limit} ->
        limit != :infinity and limit > 0 and allocation.usage[key] / limit >= 0.8
      end)

    case exhausted do
      {resource, _limit} ->
        warning = {allocation.allocation_id, resource}

        if MapSet.member?(state.warned, warning) do
          state
        else
          record(state, :budget_warning, allocation, %{"resource" => to_string(resource)})
          %{state | warned: MapSet.put(state.warned, warning)}
        end

      nil ->
        state
    end
  end

  defp record_failure(state, worker_id, reason) do
    allocation =
      case fetch_worker_allocation(state, worker_id) do
        {:ok, value} -> value
        _error -> %{allocation_id: nil, worker_id: worker_id}
      end

    record(state, :budget_exhausted, allocation, %{"reason" => to_string(reason)})
  end

  defp record(state, type, allocation, extra) do
    data =
      Map.merge(
        %{
          "allocation_id" => allocation.allocation_id,
          "worker_id" => allocation.worker_id
        },
        extra
      )

    _ = EventLog.append(state.root_session_id, type, data)
    :ok
  end

  defp allocation_id do
    "budget-" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp schedule_deadline(%{limits: %{wall_time_ms: :infinity}}), do: :ok

  defp schedule_deadline(%{allocation_id: allocation_id, limits: %{wall_time_ms: milliseconds}}) do
    Process.send_after(self(), {:allocation_deadline, allocation_id}, max(milliseconds, 1))
    :ok
  end

  defp allocation_chain(state, allocation_id) do
    Stream.unfold(allocation_id, fn
      nil -> nil
      id -> {id, state.allocations[id].parent_allocation_id}
    end)
    |> Enum.to_list()
  end

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_budget_manager, goal_id), do: GenServer.call(pid, message)
  end
end
