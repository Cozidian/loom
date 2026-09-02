defmodule BeamAgent.Goal.WorkRunManager do
  @moduledoc """
  Goal-owned durable authority for validated task-graph executions.

  A work run checkpoints its plan, attempts, terminal task results, and recovery
  decision in the root session event log. Logical graph nodes stay data; only
  the independently cancellable runner and workers become supervised processes.
  """
  use GenServer

  alias BeamAgent.{Agent, DecompositionPlan, ExecutionStrategy, Names}
  alias BeamAgent.Goal.{DecompositionExecutor, OrganizationManager}
  alias BeamAgent.Session.EventLog

  @resume_delay_ms 25

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_work_run_manager, goal_id))
  end

  def run(parent_session_id, plan, opts \\ []) when is_binary(parent_session_id) do
    with {:ok, parent} <- Agent.construction_context(parent_session_id) do
      call(parent.goal_id, {:run, parent_session_id, plan, opts}, :infinity)
    end
  end

  def checkpoint(goal_id, run_id, checkpoint) when is_map(checkpoint) do
    call(goal_id, {:checkpoint, run_id, checkpoint}, :infinity)
  end

  def snapshot(goal_id, run_id \\ :all), do: call(goal_id, {:snapshot, run_id})

  @impl true
  def init(opts) do
    with {:ok, runs} <- recover(opts) do
      state = %{
        goal_id: Keyword.fetch!(opts, :goal_id),
        root_session_id: Keyword.fetch!(opts, :session_id),
        runs: runs
      }

      if Enum.any?(runs, fn {_id, run} -> run.status == :running end),
        do: Process.send_after(self(), :resume_active_runs, @resume_delay_ms)

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:run, parent_session_id, plan_input, opts}, from, state) do
    with {:ok, plan} <- resolve_plan(plan_input),
         {:ok, parent} <- Agent.construction_context(parent_session_id),
         true <- parent.goal_id == state.goal_id,
         strategy <- resolve_strategy(Keyword.get(opts, :strategy), parent),
         run <- new_run(parent_session_id, plan, strategy, opts),
         {:ok, organization} <-
           OrganizationManager.create(
             state.goal_id,
             parent_session_id,
             plan,
             strategy,
             organization_id: run.organization_id
           ),
         run <- %{run | organization_id: organization.id},
         {:ok, _event} <- append_started(state, run) do
      run = %{run | waiters: [from]}
      state = put_in(state, [:runs, run.id], run)

      case start_runner(state, run.id) do
        {:ok, state} ->
          {:noreply, state}

        {:error, reason, state} ->
          run = %{state.runs[run.id] | waiters: []}
          Process.send_after(self(), :resume_active_runs, @resume_delay_ms)
          {:reply, {:error, reason}, put_in(state, [:runs, run.id], run)}
      end
    else
      false -> {:reply, {:error, :work_run_goal_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkpoint, run_id, checkpoint}, _from, state) do
    case state.runs[run_id] do
      nil ->
        {:reply, {:error, :unknown_work_run}, state}

      run ->
        with {:ok, event_type, event_data} <- checkpoint_event(run, checkpoint),
             {:ok, _event} <- EventLog.append(state.root_session_id, event_type, event_data) do
          run = apply_checkpoint(run, checkpoint)
          {:reply, :ok, put_in(state, [:runs, run_id], run)}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:snapshot, :all}, _from, state) do
    runs = state.runs |> Map.values() |> Enum.map(&public_run/1) |> Enum.sort_by(& &1.id)
    {:reply, {:ok, runs}, state}
  end

  def handle_call({:snapshot, run_id}, _from, state) do
    case state.runs[run_id] do
      nil -> {:reply, {:error, :unknown_work_run}, state}
      run -> {:reply, {:ok, public_run(run)}, state}
    end
  end

  @impl true
  def handle_info({:work_run_result, run_id, runner, result}, state) do
    case state.runs[run_id] do
      %{runner: %{pid: ^runner}} = run ->
        Process.demonitor(run.runner.monitor, [:flush])
        {status, recovery} = terminal_status(result)

        data = %{
          "work_run_id" => run.id,
          "organization_id" => run.organization_id,
          "plan_id" => run.plan.id,
          "status" => to_string(status),
          "recovery" => stringify(recovery)
        }

        case EventLog.append(state.root_session_id, :work_run_finished, data) do
          {:ok, _event} ->
            result = add_work_run(result, run.id, recovery)
            reply_waiters(run.waiters, result)

            run = %{
              run
              | status: status,
                recovery: recovery,
                result: result,
                waiters: [],
                runner: nil
            }

            {:noreply, put_in(state, [:runs, run_id], run)}

          {:error, reason} ->
            reply_waiters(run.waiters, {:error, {:work_run_persist_failed, reason}})
            run = %{run | status: :failed, waiters: [], runner: nil}
            {:noreply, put_in(state, [:runs, run_id], run)}
        end

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.runs, fn {_id, run} ->
           match?(%{monitor: ^monitor}, run.runner)
         end) do
      nil ->
        {:noreply, state}

      {run_id, run} ->
        run = %{run | runner: nil, interruptions: run.interruptions + 1}
        state = put_in(state, [:runs, run_id], run)

        _ =
          EventLog.append(state.root_session_id, :work_run_interrupted, %{
            "work_run_id" => run.id,
            "organization_id" => run.organization_id,
            "plan_id" => run.plan.id,
            "interruptions" => run.interruptions,
            "failure_code" => interruption_code(reason)
          })

        Process.send_after(self(), :resume_active_runs, @resume_delay_ms)
        {:noreply, state}
    end
  end

  def handle_info(:resume_active_runs, state) do
    {state, pending?} =
      Enum.reduce(state.runs, {state, false}, fn {run_id, run}, {acc, pending?} ->
        if run.status == :running and is_nil(run.runner) do
          case start_runner(acc, run_id) do
            {:ok, next} -> {next, pending?}
            {:error, _reason, next} -> {next, true}
          end
        else
          {acc, pending?}
        end
      end)

    if pending?, do: Process.send_after(self(), :resume_active_runs, @resume_delay_ms)
    {:noreply, state}
  end

  defp start_runner(state, run_id) do
    with {:ok, state} <- persist_recovered_interruption(state, run_id),
         run when not is_nil(run) <- state.runs[run_id],
         {:ok, _parent} <- Agent.construction_context(run.parent_session_id),
         {:ok, _organization} <-
           OrganizationManager.reconcile(
             state.goal_id,
             run.organization_id,
             run.task_statuses,
             run.results
           ),
         {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id) do
      manager = self()
      resume = resume_state(run)

      task = fn ->
        notify = &checkpoint(state.goal_id, run.id, &1)

        result =
          DecompositionExecutor.execute(
            run.parent_session_id,
            run.plan,
            run.organization_id,
            run.strategy,
            resume,
            run.opts,
            notify
          )

        send(manager, {:work_run_result, run.id, self(), result})
      end

      case DynamicSupervisor.start_child(supervisor, {Task, task}) do
        {:ok, pid} ->
          runner = %{pid: pid, monitor: Process.monitor(pid)}
          {:ok, put_in(state, [:runs, run_id, :runner], runner)}

        {:error, reason} ->
          {:error, {:work_run_start_failed, reason}, state}
      end
    else
      nil -> {:error, :unknown_work_run, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp persist_recovered_interruption(state, run_id) do
    run = state.runs[run_id]

    if run && run.recovered_interruption? do
      case EventLog.append(state.root_session_id, :work_run_interrupted, %{
             "work_run_id" => run.id,
             "organization_id" => run.organization_id,
             "plan_id" => run.plan.id,
             "interruptions" => run.interruptions,
             "failure_code" => "manager_recovered"
           }) do
        {:ok, _event} ->
          run = %{run | recovered_interruption?: false}
          {:ok, put_in(state, [:runs, run_id], run)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  defp append_started(state, run) do
    EventLog.append(state.root_session_id, :work_run_started, %{
      "work_run_id" => run.id,
      "organization_id" => run.organization_id,
      "plan_id" => run.plan.id,
      "parent_session_id" => run.parent_session_id,
      "strategy" => run.strategy.id,
      "maximum_attempts" => run.strategy.maximum_attempts,
      "maximum_parallelism" => run.strategy.maximum_parallelism,
      "plan" => DecompositionPlan.to_map(run.plan)
    })
  end

  defp checkpoint_event(run, %{type: :attempt_started} = checkpoint) do
    {:ok, :work_run_task_attempt_started, checkpoint_data(run, checkpoint)}
  end

  defp checkpoint_event(run, %{type: :attempt_finished} = checkpoint) do
    {:ok, :work_run_task_attempt_finished, checkpoint_data(run, checkpoint)}
  end

  defp checkpoint_event(run, %{type: :task_blocked} = checkpoint) do
    {:ok, :work_run_task_blocked, checkpoint_data(run, checkpoint)}
  end

  defp checkpoint_event(run, %{type: :recovery_decided} = checkpoint) do
    {:ok, :work_run_recovery_decided, checkpoint_data(run, checkpoint)}
  end

  defp checkpoint_event(_run, _checkpoint), do: {:error, :invalid_work_run_checkpoint}

  defp checkpoint_data(run, checkpoint) do
    checkpoint
    |> Map.delete(:type)
    |> stringify()
    |> Map.merge(%{
      "work_run_id" => run.id,
      "organization_id" => run.organization_id,
      "plan_id" => run.plan.id
    })
  end

  defp apply_checkpoint(run, %{type: :attempt_started, task_id: task_id, attempt: attempt}) do
    run
    |> put_in([:attempts, task_id], attempt)
    |> update_in([:failed_endpoint_ids, task_id], &(&1 || []))
  end

  defp apply_checkpoint(
         run,
         %{type: :attempt_finished, task_id: task_id, status: :completed} = checkpoint
       ) do
    result = checkpoint_result(checkpoint)

    run
    |> put_in([:task_statuses, task_id], :completed)
    |> put_in([:results, task_id], result)
  end

  defp apply_checkpoint(
         run,
         %{type: :attempt_finished, task_id: task_id, status: :failed, terminal: true} =
           checkpoint
       ) do
    result = checkpoint_result(checkpoint)

    run
    |> put_in([:task_statuses, task_id], :failed)
    |> put_in([:results, task_id], result)
    |> remember_failed_endpoint(task_id, checkpoint[:endpoint_id])
  end

  defp apply_checkpoint(
         run,
         %{type: :attempt_finished, task_id: task_id} = checkpoint
       ) do
    remember_failed_endpoint(run, task_id, checkpoint[:endpoint_id])
  end

  defp apply_checkpoint(run, %{type: :task_blocked, task_id: task_id} = checkpoint) do
    run
    |> put_in([:task_statuses, task_id], :blocked)
    |> put_in([:results, task_id], checkpoint_result(checkpoint))
  end

  defp apply_checkpoint(run, %{type: :recovery_decided, recovery: recovery}),
    do: %{run | recovery: recovery}

  defp apply_checkpoint(run, _checkpoint), do: run

  defp checkpoint_result(checkpoint) do
    %{
      worker_id: checkpoint[:worker_id],
      delegation_id: checkpoint[:delegation_id],
      endpoint_id: checkpoint[:endpoint_id],
      result: %{content: checkpoint[:result_content], verification: checkpoint[:verification]},
      verification: checkpoint[:verification] || %{status: :unverified},
      attempts: checkpoint[:attempt],
      recovery: checkpoint[:recovery],
      error: checkpoint[:error],
      result_fingerprint: checkpoint[:result_fingerprint]
    }
  end

  defp remember_failed_endpoint(run, _task_id, nil), do: run

  defp remember_failed_endpoint(run, task_id, endpoint_id) do
    update_in(run, [:failed_endpoint_ids, task_id], fn ids ->
      Enum.uniq([endpoint_id | ids || []])
    end)
  end

  defp terminal_status({:ok, %{status: :completed}}), do: {:completed, nil}
  defp terminal_status({:ok, %{recovery: recovery}}), do: {:failed, recovery}

  defp terminal_status({:error, reason}),
    do: {:failed, %{action: :stop, reason_code: code(reason)}}

  defp add_work_run({:ok, result}, run_id, recovery),
    do: {:ok, result |> Map.put(:work_run_id, run_id) |> Map.put(:recovery, recovery)}

  defp add_work_run({:error, _reason} = error, _run_id, _recovery), do: error

  defp new_run(parent_session_id, plan, strategy, opts) do
    %{
      id: "work-run-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      parent_session_id: parent_session_id,
      plan: plan,
      strategy: strategy,
      organization_id:
        "organization-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      status: :running,
      task_statuses: Map.new(plan.tasks, fn {id, _task} -> {id, :pending} end),
      results: %{},
      attempts: %{},
      failed_endpoint_ids: %{},
      recovery: nil,
      result: nil,
      opts: durable_opts(opts),
      waiters: [],
      runner: nil,
      interruptions: 0,
      recovered_interruption?: false
    }
  end

  defp resume_state(run) do
    %{
      statuses: run.task_statuses,
      results: run.results,
      attempts: run.attempts,
      failed_endpoint_ids: run.failed_endpoint_ids
    }
  end

  defp public_run(run) do
    %{
      id: run.id,
      parent_session_id: run.parent_session_id,
      plan_id: run.plan.id,
      organization_id: run.organization_id,
      strategy: run.strategy.id,
      status: run.status,
      tasks: run.task_statuses,
      attempts: run.attempts,
      recovery: run.recovery,
      interruptions: run.interruptions
    }
  end

  defp recover(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, events} <- EventLog.read(data_dir, session_id) do
      runs =
        events
        |> Enum.reduce(%{}, &recover_event/2)
        |> Map.new(fn {id, run} ->
          run =
            if run.status == :running do
              %{run | interruptions: run.interruptions + 1, recovered_interruption?: true}
            else
              run
            end

          {id, run}
        end)

      {:ok, runs}
    end
  end

  defp recover_event(%{"type" => "work_run_started", "data" => data}, runs) do
    with id when is_binary(id) <- data["work_run_id"],
         {:ok, plan} <- DecompositionPlan.new(data["plan"] || %{}) do
      strategy =
        ExecutionStrategy.resolve(data["strategy"] || "coordinate")
        |> Map.put(
          :maximum_attempts,
          positive_integer(data["maximum_attempts"], 1, 4)
        )
        |> Map.put(
          :maximum_parallelism,
          positive_integer(data["maximum_parallelism"], 1, 4)
        )

      run = %{
        id: id,
        parent_session_id: data["parent_session_id"],
        plan: plan,
        strategy: strategy,
        organization_id: data["organization_id"],
        status: :running,
        task_statuses: Map.new(plan.tasks, fn {task_id, _task} -> {task_id, :pending} end),
        results: %{},
        attempts: %{},
        failed_endpoint_ids: %{},
        recovery: nil,
        result: nil,
        opts: [],
        waiters: [],
        runner: nil,
        interruptions: 0,
        recovered_interruption?: false
      }

      Map.put(runs, id, run)
    else
      _invalid -> runs
    end
  end

  defp recover_event(%{"type" => "work_run_task_attempt_started", "data" => data}, runs) do
    update_recovered(runs, data, fn run ->
      put_in(run, [:attempts, data["task_id"]], data["attempt"] || 1)
    end)
  end

  defp recover_event(%{"type" => "work_run_task_attempt_finished", "data" => data}, runs) do
    update_recovered(runs, data, fn run ->
      task_id = data["task_id"]
      status = status_atom(data["status"])

      run =
        if status == :completed or (status == :failed and data["terminal"] == true) do
          run
          |> put_in([:task_statuses, task_id], status)
          |> put_in([:results, task_id], recovered_result(data))
        else
          run
        end

      if status == :completed,
        do: run,
        else: remember_failed_endpoint(run, task_id, data["endpoint_id"])
    end)
  end

  defp recover_event(%{"type" => "work_run_task_blocked", "data" => data}, runs) do
    update_recovered(runs, data, fn run ->
      task_id = data["task_id"]

      run
      |> put_in([:task_statuses, task_id], :blocked)
      |> put_in([:results, task_id], recovered_result(data))
    end)
  end

  defp recover_event(%{"type" => "work_run_recovery_decided", "data" => data}, runs) do
    update_recovered(runs, data, &%{&1 | recovery: atomize_recovery(data["recovery"])})
  end

  defp recover_event(%{"type" => "work_run_interrupted", "data" => data}, runs) do
    update_recovered(runs, data, &%{&1 | interruptions: data["interruptions"] || 1})
  end

  defp recover_event(%{"type" => "work_run_finished", "data" => data}, runs) do
    update_recovered(runs, data, fn run ->
      %{run | status: status_atom(data["status"]), recovery: atomize_recovery(data["recovery"])}
    end)
  end

  defp recover_event(_event, runs), do: runs

  defp update_recovered(runs, data, fun) do
    id = data["work_run_id"]

    case runs[id] do
      nil -> runs
      run -> Map.put(runs, id, fun.(run))
    end
  end

  defp recovered_result(data) do
    %{
      worker_id: data["worker_id"],
      delegation_id: data["delegation_id"],
      endpoint_id: data["endpoint_id"],
      result: %{content: data["result_content"], verification: data["verification"]},
      verification: atomize_verification(data["verification"]),
      attempts: data["attempt"],
      recovery: atomize_recovery(data["recovery"]),
      error: data["error"],
      result_fingerprint: data["result_fingerprint"]
    }
  end

  defp durable_opts(opts) do
    case Keyword.get(opts, :task_timeout, :infinity) do
      timeout when is_integer(timeout) and timeout > 0 -> [task_timeout: timeout]
      _other -> []
    end
  end

  defp resolve_plan(%DecompositionPlan{} = plan), do: {:ok, plan}
  defp resolve_plan(attributes), do: DecompositionPlan.new(attributes)

  defp resolve_strategy(%ExecutionStrategy{} = strategy, _parent), do: strategy
  defp resolve_strategy(id, _parent) when is_binary(id), do: ExecutionStrategy.resolve(id)

  defp resolve_strategy(_strategy, parent) do
    case parent.agent_spec.execution_strategy do
      %ExecutionStrategy{} = strategy -> strategy
      %{id: id} -> ExecutionStrategy.resolve(id)
      _other -> ExecutionStrategy.resolve("coordinate")
    end
  end

  defp atomize_recovery(nil), do: nil

  defp atomize_recovery(recovery) when is_map(recovery) do
    %{
      action: known_atom(recovery["action"] || recovery[:action]),
      classification: known_atom(recovery["classification"] || recovery[:classification]),
      reason_code: recovery["reason_code"] || recovery[:reason_code],
      failed_task_count: recovery["failed_task_count"] || recovery[:failed_task_count],
      terminal: map_value(recovery, "terminal", :terminal)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp atomize_verification(nil), do: %{status: :unverified}

  defp atomize_verification(verification) when is_map(verification) do
    verification
    |> Map.new(fn {key, value} -> {known_key(key), value} end)
    |> Map.update(:status, :unverified, &known_atom/1)
  end

  defp known_key("status"), do: :status
  defp known_key("verification_id"), do: :verification_id
  defp known_key("summary"), do: :summary
  defp known_key("source"), do: :source
  defp known_key(key), do: key

  defp known_atom(value) when is_atom(value), do: value

  defp known_atom(value) when is_binary(value) do
    case value do
      "retry_same" -> :retry_same
      "rebind" -> :rebind
      "repair" -> :repair
      "replan" -> :replan
      "ask" -> :ask
      "stop" -> :stop
      "transient_provider" -> :transient_provider
      "verification" -> :verification
      "worker_exit" -> :worker_exit
      "non_final" -> :non_final
      "plan" -> :plan
      "authority" -> :authority
      "budget" -> :budget
      "cancelled" -> :cancelled
      "runtime" -> :runtime
      "task_graph" -> :task_graph
      "passed" -> :passed
      "failed" -> :failed
      "not_configured" -> :not_configured
      "unverified" -> :unverified
      _other -> value
    end
  end

  defp status_atom(value) do
    case value do
      :running -> :running
      :completed -> :completed
      :failed -> :failed
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "blocked" -> :blocked
      _other -> :failed
    end
  end

  defp positive_integer(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp positive_integer(_value, minimum, _maximum), do: minimum

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp reply_waiters(waiters, result), do: Enum.each(waiters, &GenServer.reply(&1, result))
  defp map_value(map, string_key, atom_key), do: Map.get(map, string_key, Map.get(map, atom_key))

  defp call(goal_id, message, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:goal_work_run_manager, goal_id) do
      GenServer.call(pid, message, timeout)
    end
  catch
    :exit, {:noproc, _details} -> {:error, :work_run_manager_unavailable}
    :exit, {:normal, _details} -> {:error, :work_run_manager_unavailable}
    :exit, {:shutdown, _details} -> {:error, :work_run_manager_unavailable}
  end

  defp interruption_code(reason) when is_atom(reason), do: to_string(reason)
  defp interruption_code({reason, _}) when is_atom(reason), do: to_string(reason)
  defp interruption_code(_reason), do: "runner_exit"
  defp code(reason) when is_atom(reason), do: to_string(reason)
  defp code({reason, _}) when is_atom(reason), do: to_string(reason)
  defp code(_reason), do: "work_run_failed"
end
