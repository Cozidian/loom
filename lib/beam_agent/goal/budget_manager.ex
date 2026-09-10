defmodule BeamAgent.Goal.BudgetManager do
  @moduledoc "Goal-owned resource accounting, allocation, backpressure, and release."
  use GenServer

  alias BeamAgent.{Names, ResourceBudget}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_budget_manager, goal_id))
  end

  def reserve(goal_id, parent_worker_id, worker_id, requested \\ %{}, opts \\ []) do
    call(goal_id, {:reserve, parent_worker_id, worker_id, requested, opts}, :infinity)
  end

  def bind(goal_id, allocation_id, owner, opts \\ []) when is_pid(owner),
    do: call(goal_id, {:bind, allocation_id, owner, opts[:lifetime_owner]})

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
       queue: [],
       reservation_monitors: %{},
       warned: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:reserve, parent_worker_id, worker_id, requested, opts}, from, state) do
    request = %{
      parent_id: parent_worker_id,
      worker_id: worker_id,
      requested: requested,
      from: from,
      delegation_id: Keyword.get(opts, :delegation_id)
    }

    case reserve_request(state, request) do
      {:ok, allocation, state} ->
        {:reply, {:ok, ResourceBudget.public(allocation)}, state}

      {:error, :worker_concurrency_exhausted} = error ->
        # A non-root worker already occupies a slot. Do not let nested fan-out
        # wait forever for capacity held by its own ancestors.
        if Keyword.get(opts, :wait_for_capacity, false) and
             parent_worker_id == state.root_session_id and
             state.allocations[state.root_allocation_id].limits.concurrent_workers != 0 do
          monitor = Process.monitor(elem(from, 0))
          request = Map.put(request, :monitor, monitor)
          state = %{state | queue: state.queue ++ [request]}
          state = put_in(state.reservation_monitors[monitor], {:queued, worker_id})
          record_queue(state, :worker_queued, request)
          {:noreply, state}
        else
          {:reply, error, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:bind, allocation_id, owner, lifetime_owner}, _from, state) do
    case state.allocations[allocation_id] do
      nil ->
        {:reply, {:error, :unknown_budget_allocation}, state}

      %{status: :released} ->
        {:reply, {:error, :budget_allocation_released}, state}

      allocation ->
        state = clear_reservation_monitor(state, {:reserved, allocation_id})
        monitor = Process.monitor(owner)
        now = System.monotonic_time(:millisecond)
        allocation = %{allocation | status: :active} |> Map.put(:started_monotonic_ms, now)

        state =
          state
          |> put_in([:allocations, allocation_id], allocation)
          |> put_in([:monitors, monitor], allocation_id)
          |> put_in([:owners, allocation_id], owner)

        state =
          if is_pid(lifetime_owner) do
            reference = Process.monitor(lifetime_owner)
            put_in(state.reservation_monitors[reference], {:lifetime, allocation_id})
          else
            state
          end

        schedule_deadline(allocation)

        {:reply, :ok, state}
    end
  end

  def handle_call({:release, allocation_id, reason}, _from, state) do
    {reply, state} = release_allocation(state, allocation_id, reason)
    {:reply, reply, drain_queue(state)}
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

    {:reply,
     {:ok, %{goal_id: state.goal_id, allocations: allocations, queued: length(state.queue)}},
     state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        state = %{state | monitors: monitors}

        case Map.pop(state.reservation_monitors, monitor) do
          {nil, _monitors} ->
            {:noreply, state}

          {{:queued, worker_id}, reservation_monitors} ->
            {removed, queue} = Enum.split_with(state.queue, &(&1.worker_id == worker_id))
            Enum.each(removed, &cancel_queued(state, &1, :owner_down))
            {:noreply, %{state | queue: queue, reservation_monitors: reservation_monitors}}

          {{:reserved, allocation_id}, reservation_monitors} ->
            {_reply, state} =
              release_allocation(
                %{state | reservation_monitors: reservation_monitors},
                allocation_id,
                reason
              )

            {:noreply, drain_queue(state)}

          {{:lifetime, allocation_id}, reservation_monitors} ->
            stop_allocation_owner(state, allocation_id)
            {:noreply, %{state | reservation_monitors: reservation_monitors}}
        end

      {allocation_id, monitors} ->
        {_reply, state} = release_allocation(%{state | monitors: monitors}, allocation_id, reason)
        {:noreply, drain_queue(state)}
    end
  end

  def handle_info({:allocation_deadline, allocation_id}, state) do
    case {state.allocations[allocation_id], state.owners[allocation_id]} do
      {%{status: :active} = allocation, owner} when is_pid(owner) ->
        record(state, :budget_exhausted, allocation, %{"reason" => "budget_deadline_exceeded"})

        # Session supervisors trap exits, so an ordinary :shutdown signal from
        # this sibling does not terminate them. Stop through the OTP API in a
        # supervised cleanup task; never block the accounting mailbox on teardown.
        with {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id) do
          DynamicSupervisor.start_child(
            supervisor,
            {Task,
             fn ->
               _ = BeamAgent.Agent.cancel(allocation.worker_id)
               BeamAgent.stop_session(allocation.worker_id)
             end}
          )
        end

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

  defp reserve_request(state, request) do
    with {:ok, parent} <- fetch_worker_allocation(state, request.parent_id),
         :ok <- active?(parent),
         :ok <- within_wall_time?(parent),
         :ok <- available_worker_slot(state) do
      allocation =
        ResourceBudget.child_allocation(
          allocation_id(),
          request.worker_id,
          parent,
          ResourceBudget.remaining(parent),
          request.requested
        )
        |> Map.put(:delegation_id, request.delegation_id)
        |> Map.put(:started_monotonic_ms, System.monotonic_time(:millisecond))

      monitor = Process.monitor(elem(request.from, 0))

      state =
        state
        |> put_in([:allocations, allocation.allocation_id], allocation)
        |> put_in([:worker_allocations, request.worker_id], allocation.allocation_id)
        |> put_in([:reservation_monitors, monitor], {:reserved, allocation.allocation_id})

      record(state, :budget_allocated, allocation, %{})
      {:ok, allocation, state}
    end
  end

  defp drain_queue(%{queue: []} = state), do: state

  defp drain_queue(%{queue: [request | rest]} = state) do
    if Process.alive?(elem(request.from, 0)) do
      case reserve_request(state, request) do
        {:ok, allocation, state} ->
          state = clear_reservation_monitor(state, {:queued, request.worker_id})
          record_queue(state, :worker_dequeued, request)
          GenServer.reply(request.from, {:ok, ResourceBudget.public(allocation)})
          drain_queue(%{state | queue: rest})

        {:error, :worker_concurrency_exhausted} ->
          state

        {:error, _reason} = error ->
          GenServer.reply(request.from, error)
          state = clear_reservation_monitor(state, {:queued, request.worker_id})
          drain_queue(%{state | queue: rest})
      end
    else
      cancel_queued(state, request, :owner_down)
      state = clear_reservation_monitor(state, {:queued, request.worker_id})
      drain_queue(%{state | queue: rest})
    end
  end

  defp cancel_queued(state, request, reason) do
    if request.delegation_id do
      BeamAgent.Goal.DelegationManager.reject(state.goal_id, request.delegation_id, reason)
    end

    record_queue(state, :worker_queue_cancelled, request)
  end

  defp record_queue(state, type, request) do
    EventLog.append(state.root_session_id, type, %{
      "worker_id" => request.worker_id,
      "delegation_id" => request.delegation_id,
      "queue_depth" => length(state.queue)
    })
  end

  defp clear_reservation_monitor(state, value) do
    monitors =
      Map.reject(state.reservation_monitors, fn {reference, entry} ->
        if entry == value do
          Process.demonitor(reference, [:flush])
          true
        else
          false
        end
      end)

    %{state | reservation_monitors: monitors}
  end

  defp stop_allocation_owner(state, allocation_id) do
    with %{status: :active, worker_id: worker_id} <- state.allocations[allocation_id],
         {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id) do
      DynamicSupervisor.start_child(
        supervisor,
        {Task,
         fn ->
           if delegation_id = state.allocations[allocation_id][:delegation_id] do
             BeamAgent.Goal.DelegationManager.cancel(state.goal_id, delegation_id, :owner_exited)
           end

           BeamAgent.Agent.cancel(worker_id)
           BeamAgent.stop_session(worker_id)
         end}
      )
    end
  end

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
        state = clear_reservation_monitor(state, {:reserved, allocation_id})
        state = clear_reservation_monitor(state, {:lifetime, allocation_id})
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

  defp call(goal_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:goal_budget_manager, goal_id),
         do: GenServer.call(pid, message, timeout)
  end
end
