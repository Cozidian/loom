defmodule BeamAgent.Goal.ProgressMonitor do
  @moduledoc "Goal-owned worker activity and evidence-based stall supervision."
  use GenServer

  alias BeamAgent.Goal.EventHub
  alias BeamAgent.Names
  alias BeamAgent.Session.EventLog

  @default_stall_after_ms 60_000
  @default_check_interval_ms 5_000

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_progress_monitor, goal_id))
  end

  def snapshot(goal_id), do: call(goal_id, :snapshot)
  def check_now(goal_id), do: call(goal_id, :check_now)

  @impl true
  def init(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)

    state = %{
      goal_id: goal_id,
      root_session_id: Keyword.fetch!(opts, :session_id),
      workers: %{},
      stall_after_ms: Keyword.get(opts, :progress_stall_after_ms, @default_stall_after_ms),
      check_interval_ms:
        Keyword.get(opts, :progress_check_interval_ms, @default_check_interval_ms)
    }

    with {:ok, %{events: events}} <-
           EventHub.subscribe_from(goal_id, self(), nil, view: :internal) do
      state = Enum.reduce(events, state, &apply_event(&2, &1, false))
      schedule_check(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, {:ok, public_snapshot(state)}, state}

  def handle_call(:check_now, _from, state) do
    state = detect_stalls(state)
    {:reply, {:ok, public_snapshot(state)}, state}
  end

  @impl true
  def handle_info({:beam_agent_runtime_event, event}, state),
    do: {:noreply, apply_event(state, event, true)}

  def handle_info(:check_progress, state) do
    state = detect_stalls(state)
    schedule_check(state)
    {:noreply, state}
  end

  defp apply_event(state, event, emit_recovery?) do
    type = event_type(event)

    if type in ["worker_stall_suspected", "worker_progress_resumed"] do
      apply_monitor_event(state, event)
    else
      worker_id = worker_id(event)

      if is_binary(worker_id) do
        now = monotonic_ms()
        previous = Map.get(state.workers, worker_id, new_worker(worker_id, event_at(event), now))
        worker = transition(previous, type, event_data(event), event_at(event), now)
        state = put_in(state, [:workers, worker_id], worker)

        if emit_recovery? and previous.suspected_stalled and meaningful?(type) do
          _ =
            EventLog.append(state.root_session_id, :worker_progress_resumed, %{
              "worker_id" => worker_id,
              "phase" => to_string(worker.phase),
              "stalled_for_ms" => max(now - previous.last_signal_monotonic, 0)
            })

          put_in(state, [:workers, worker_id, :suspected_stalled], false)
        else
          state
        end
      else
        state
      end
    end
  end

  defp apply_monitor_event(state, event) do
    data = event_data(event)
    worker_id = data["worker_id"] || data[:worker_id]

    case state.workers[worker_id] do
      nil ->
        state

      worker ->
        suspected = event_type(event) == "worker_stall_suspected"
        put_in(state, [:workers, worker_id], %{worker | suspected_stalled: suspected})
    end
  end

  defp transition(worker, type, data, at, now) do
    {state, phase, blocker} = phase(type, data, worker)
    meaningful = meaningful?(type)

    worker
    |> Map.put(:state, state)
    |> Map.put(:phase, phase)
    |> Map.put(:blocking_reason, blocker)
    |> Map.put(:last_signal_at, at || worker.last_signal_at)
    |> Map.put(:last_signal_monotonic, now)
    |> maybe_progress(meaningful, at, now)
    |> maybe_finish(state, at)
  end

  defp phase("turn_started", _data, _worker), do: {:active, :starting, nil}
  defp phase("model_response_started", _data, _worker), do: {:active, :model_inference, nil}
  defp phase("tool_called", data, _worker), do: {:active, :tool_execution, data["name"]}
  defp phase("tool_result", _data, _worker), do: {:active, :executing, nil}
  defp phase("delegation_started", _data, _worker), do: {:active, :delegated_work, nil}
  defp phase("delegation_progressed", _data, _worker), do: {:active, :delegated_work, nil}
  defp phase("verification_started", _data, _worker), do: {:active, :verification, nil}

  defp phase("verification_check_started", data, _worker),
    do: {:active, :verification, data["check_id"]}

  defp phase("implementation_review_started", _data, _worker), do: {:active, :review, nil}

  defp phase(type, _data, _worker)
       when type in ["verification_recovery_started", "implementation_review_recovery_started"],
       do: {:active, :repairing, nil}

  defp phase("tool_approval_requested", data, _worker),
    do: {:waiting, :awaiting_approval, data["name"] || data["tool"]}

  defp phase("resource_queued", data, _worker),
    do: {:waiting, :queued, data["resource_pool"]}

  defp phase("budget_exhausted", _data, _worker), do: {:blocked, :blocked, :budget_exhausted}
  defp phase("tool_loop_stalled", _data, _worker), do: {:stalled, :stalled, :repeated_tool_loop}
  defp phase("turn_finished", data, _worker), do: terminal_phase(data["reason"])
  defp phase("delegation_completed", _data, _worker), do: {:completed, :completed, nil}
  defp phase("delegation_failed", _data, _worker), do: {:failed, :failed, nil}
  defp phase("delegation_cancelled", _data, _worker), do: {:cancelled, :cancelled, nil}
  defp phase(_type, _data, worker), do: {worker.state, worker.phase, worker.blocking_reason}

  defp terminal_phase(reason) when reason in ["error", :error], do: {:failed, :failed, nil}

  defp terminal_phase(reason) when reason in ["cancelled", :cancelled],
    do: {:cancelled, :cancelled, nil}

  defp terminal_phase(_reason), do: {:completed, :completed, nil}

  defp meaningful?(type) do
    type in [
      "turn_started",
      "model_response_finished",
      "tool_called",
      "tool_result",
      "delegation_started",
      "delegation_progressed",
      "delegation_completed",
      "verification_started",
      "verification_check_finished",
      "implementation_review_started",
      "implementation_review_finished",
      "repository_updated",
      "turn_finished"
    ]
  end

  defp maybe_progress(worker, true, at, now),
    do: %{worker | last_progress_at: at || worker.last_progress_at, last_progress_monotonic: now}

  defp maybe_progress(worker, false, _at, _now), do: worker

  defp maybe_finish(worker, state, at) when state in [:completed, :failed, :cancelled],
    do: %{worker | finished_at: at, suspected_stalled: false}

  defp maybe_finish(worker, _state, _at), do: worker

  defp detect_stalls(state) do
    now = monotonic_ms()

    Enum.reduce(state.workers, state, fn {worker_id, worker}, acc ->
      elapsed = now - worker.last_signal_monotonic

      if worker.state == :active and not worker.suspected_stalled and
           elapsed >= state.stall_after_ms do
        _ =
          EventLog.append(state.root_session_id, :worker_stall_suspected, %{
            "worker_id" => worker_id,
            "phase" => to_string(worker.phase),
            "last_signal_at" => worker.last_signal_at,
            "last_progress_at" => worker.last_progress_at,
            "silent_for_ms" => elapsed
          })

        put_in(acc, [:workers, worker_id, :suspected_stalled], true)
      else
        acc
      end
    end)
  end

  defp new_worker(worker_id, at, now) do
    %{
      worker_id: worker_id,
      state: :idle,
      phase: :idle,
      blocking_reason: nil,
      started_at: at,
      finished_at: nil,
      last_signal_at: at,
      last_signal_monotonic: now,
      last_progress_at: at,
      last_progress_monotonic: now,
      suspected_stalled: false
    }
  end

  defp public_snapshot(state) do
    workers =
      state.workers
      |> Map.values()
      |> Enum.sort_by(& &1.worker_id)
      |> Enum.map(&Map.drop(&1, [:last_signal_monotonic, :last_progress_monotonic]))

    counts = Enum.frequencies_by(workers, & &1.state)
    critical = critical_worker(workers)

    %{
      goal_id: state.goal_id,
      workers: workers,
      critical_worker_id: critical && critical.worker_id,
      critical_reason: critical && critical_reason(critical),
      summary: %{
        active: Map.get(counts, :active, 0),
        waiting: Map.get(counts, :waiting, 0),
        blocked: Map.get(counts, :blocked, 0),
        stalled: Map.get(counts, :stalled, 0) + Enum.count(workers, & &1.suspected_stalled)
      }
    }
  end

  defp critical_worker(workers) do
    workers
    |> Enum.reject(&(&1.state in [:idle, :completed, :failed, :cancelled]))
    |> Enum.sort_by(fn worker ->
      priority =
        cond do
          worker.state == :stalled or worker.suspected_stalled -> 0
          worker.state == :blocked -> 1
          worker.state == :waiting -> 2
          true -> 3
        end

      {priority, worker.started_at || "", worker.worker_id}
    end)
    |> List.first()
  end

  defp critical_reason(%{suspected_stalled: true}), do: "suspected stalled"
  defp critical_reason(%{blocking_reason: reason}) when not is_nil(reason), do: to_string(reason)
  defp critical_reason(worker), do: worker.phase |> to_string() |> String.replace("_", " ")

  defp event_type(%{payload: %{type: type}}), do: to_string(type)
  defp event_type(%{"payload" => %{"type" => type}}), do: to_string(type)
  defp event_type(_event), do: "unknown"

  defp event_data(%{payload: %{data: data}}) when is_map(data), do: data
  defp event_data(%{"payload" => %{"data" => data}}) when is_map(data), do: data
  defp event_data(_event), do: %{}

  defp worker_id(event) do
    data = event_data(event)

    data["worker_id"] || data[:worker_id] || get_in(event, [:scope, :worker_id]) ||
      get_in(event, ["scope", "worker_id"])
  end

  defp event_at(%{at: at}), do: at
  defp event_at(%{"at" => at}), do: at
  defp event_at(_event), do: nil

  defp schedule_check(state),
    do: Process.send_after(self(), :check_progress, state.check_interval_ms)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp call(goal_id, message) do
    with {:ok, pid} <- Names.pid(:goal_progress_monitor, goal_id),
         do: GenServer.call(pid, message)
  end
end
