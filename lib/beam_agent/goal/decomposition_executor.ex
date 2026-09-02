defmodule BeamAgent.Goal.DecompositionExecutor do
  @moduledoc "Executes one durable task graph with bounded, evidence-led recovery."

  alias BeamAgent.{Agent, DecompositionPlan, FailureDecision, ModelRegistry}
  alias BeamAgent.Goal.{BudgetManager, OrganizationManager}

  @doc false
  def run(parent_session_id, plan, opts \\ []),
    do: BeamAgent.Goal.WorkRunManager.run(parent_session_id, plan, opts)

  def execute(
        parent_session_id,
        %DecompositionPlan{} = plan,
        organization_id,
        strategy,
        resume,
        opts,
        notify
      )
      when is_binary(parent_session_id) and is_map(resume) and is_function(notify, 1) do
    with {:ok, parent} <- Agent.construction_context(parent_session_id) do
      statuses = Map.get(resume, :statuses, initial_statuses(plan))
      results = Map.get(resume, :results, %{})
      attempts = Map.get(resume, :attempts, %{})
      failed_endpoints = Map.get(resume, :failed_endpoint_ids, %{})

      execute_waves(
        parent,
        plan,
        organization_id,
        strategy,
        statuses,
        results,
        attempts,
        failed_endpoints,
        opts,
        notify
      )
    end
  end

  defp execute_waves(
         parent,
         plan,
         organization_id,
         strategy,
         statuses,
         results,
         attempts,
         failed_endpoints,
         opts,
         notify
       ) do
    with {:ok, statuses, results} <-
           block_failed_dependencies(
             parent.goal_id,
             plan,
             organization_id,
             statuses,
             results,
             notify
           ) do
      ready = DecompositionPlan.ready(plan, statuses)

      cond do
        DecompositionPlan.terminal?(plan, statuses) ->
          finish(plan, organization_id, statuses, results, notify)

        ready == [] ->
          recovery =
            FailureDecision.graph([
              %{decision: FailureDecision.decide(:decomposition_deadlock)}
            ])

          with :ok <- notify.(%{type: :recovery_decided, recovery: recovery}) do
            {:error, :decomposition_deadlock}
          end

        true ->
          wave_results =
            ready
            |> Task.async_stream(
              fn task ->
                execute_task(
                  parent,
                  organization_id,
                  task,
                  strategy,
                  Map.get(attempts, task.id, 0),
                  Map.get(failed_endpoints, task.id, []),
                  opts,
                  notify
                )
              end,
              max_concurrency: max(1, strategy.maximum_parallelism),
              ordered: true,
              timeout: :infinity
            )
            |> Enum.zip(ready)

          {statuses, results, attempts, failed_endpoints} =
            Enum.reduce(
              wave_results,
              {statuses, results, attempts, failed_endpoints},
              &merge_wave_result/2
            )

          execute_waves(
            parent,
            plan,
            organization_id,
            strategy,
            statuses,
            results,
            attempts,
            failed_endpoints,
            opts,
            notify
          )
      end
    end
  end

  defp execute_task(
         parent,
         organization_id,
         task,
         strategy,
         completed_attempts,
         failed_endpoint_ids,
         opts,
         notify
       ) do
    maximum_attempts = task.maximum_attempts || strategy.maximum_attempts

    if completed_attempts >= maximum_attempts do
      reason = {:worker_restart_timeout, :attempt_interrupted}

      recovery =
        FailureDecision.decide(reason,
          attempt: completed_attempts,
          maximum_attempts: maximum_attempts
        )

      terminal_failure(
        parent.goal_id,
        organization_id,
        task,
        completed_attempts,
        maximum_attempts,
        nil,
        List.first(failed_endpoint_ids),
        nil,
        reason,
        recovery,
        failed_endpoint_ids,
        notify
      )
    else
      attempt_task(
        parent,
        organization_id,
        task,
        completed_attempts + 1,
        maximum_attempts,
        failed_endpoint_ids,
        opts,
        notify
      )
    end
  end

  defp attempt_task(
         parent,
         organization_id,
         task,
         attempt,
         maximum_attempts,
         failed_endpoint_ids,
         opts,
         notify
       ) do
    {proposal, selected_alternative} = proposal(task, parent, failed_endpoint_ids)
    spawn_opts = Keyword.get(opts, :worker_options, [])

    case BeamAgent.spawn_worker(parent.session_id, proposal, spawn_opts) do
      {:ok, handle} ->
        started = %{
          type: :attempt_started,
          task_id: task.id,
          attempt: attempt,
          maximum_attempts: maximum_attempts,
          worker_id: handle.worker_id,
          delegation_id: handle.delegation_id,
          endpoint_id: selected_alternative
        }

        with {:ok, _organization} <-
               transition_running(
                 parent.goal_id,
                 organization_id,
                 task.id,
                 handle,
                 attempt,
                 maximum_attempts
               ),
             :ok <- notify.(started) do
          try do
            run_worker(
              parent,
              organization_id,
              task,
              handle,
              attempt,
              maximum_attempts,
              failed_endpoint_ids,
              opts,
              notify
            )
          after
            # Attempt state and the delegation result are durable before the
            # temporary worker is reclaimed.
            _ = BeamAgent.stop_session(handle.worker_id)
          end
        else
          {:error, reason} ->
            _ = BeamAgent.cancel_worker(handle, reason)

            fail_attempt(
              parent,
              organization_id,
              task,
              attempt,
              maximum_attempts,
              failed_endpoint_ids,
              selected_alternative,
              nil,
              nil,
              reason,
              opts,
              notify
            )
        end

      {:error, reason} ->
        fail_attempt(
          parent,
          organization_id,
          task,
          attempt,
          maximum_attempts,
          failed_endpoint_ids,
          selected_alternative,
          nil,
          nil,
          reason,
          opts,
          notify
        )
    end
  end

  defp run_worker(
         parent,
         organization_id,
         task,
         handle,
         attempt,
         maximum_attempts,
         failed_endpoint_ids,
         opts,
         notify
       ) do
    case ask_worker(handle.worker_id, task.goal, Keyword.get(opts, :task_timeout, :infinity)) do
      {:ok, content} ->
        endpoint_id = worker_endpoint_id(handle.worker_id)
        verification = worker_verification(handle.worker_id)

        if verification.status == :failed do
          _ = BeamAgent.cancel_worker(handle, :verification_failed)

          fail_attempt(
            parent,
            organization_id,
            task,
            attempt,
            maximum_attempts,
            failed_endpoint_ids,
            endpoint_id,
            handle,
            verification,
            {:verification_failed, verification},
            opts,
            notify
          )
        else
          complete_attempt(
            parent.goal_id,
            organization_id,
            task,
            handle,
            content,
            endpoint_id,
            verification,
            attempt,
            maximum_attempts,
            notify
          )
        end

      {:error, reason} ->
        endpoint_id = worker_endpoint_id(handle.worker_id)
        verification = worker_verification(handle.worker_id)
        _ = BeamAgent.cancel_worker(handle, reason)

        fail_attempt(
          parent,
          organization_id,
          task,
          attempt,
          maximum_attempts,
          failed_endpoint_ids,
          endpoint_id,
          handle,
          verification,
          reason,
          opts,
          notify
        )
    end
  end

  defp complete_attempt(
         goal_id,
         organization_id,
         task,
         handle,
         content,
         endpoint_id,
         verification,
         attempt,
         maximum_attempts,
         notify
       ) do
    result_fingerprint = fingerprint(content)

    checkpoint = %{
      type: :attempt_finished,
      task_id: task.id,
      status: :completed,
      terminal: true,
      attempt: attempt,
      maximum_attempts: maximum_attempts,
      worker_id: handle.worker_id,
      delegation_id: handle.delegation_id,
      endpoint_id: endpoint_id,
      result_content: content,
      result_fingerprint: result_fingerprint,
      verification: verification,
      recovery: nil
    }

    with {:ok, result} <- BeamAgent.complete_worker(handle, content, verification),
         :ok <- notify.(checkpoint),
         {:ok, _organization} <-
           OrganizationManager.transition(goal_id, organization_id, task.id, :completed, %{
             worker_id: handle.worker_id,
             delegation_id: handle.delegation_id,
             result_fingerprint: result_fingerprint,
             verification_status: verification.status,
             attempts: attempt,
             maximum_attempts: maximum_attempts
           }) do
      {:completed,
       %{
         worker: handle,
         worker_id: handle.worker_id,
         delegation_id: handle.delegation_id,
         result: result,
         endpoint_id: endpoint_id,
         verification: verification,
         attempts: attempt,
         recovery: nil,
         result_fingerprint: result_fingerprint
       }, attempt, []}
    end
  end

  defp fail_attempt(
         parent,
         organization_id,
         task,
         attempt,
         maximum_attempts,
         failed_endpoint_ids,
         endpoint_id,
         handle,
         verification,
         reason,
         opts,
         notify
       ) do
    failed_endpoint_ids = remember_endpoint(failed_endpoint_ids, endpoint_id)
    alternative = alternative_endpoint(parent, task, failed_endpoint_ids)

    recovery =
      FailureDecision.decide(reason,
        attempt: attempt,
        maximum_attempts: maximum_attempts,
        alternative_endpoint?: not is_nil(alternative)
      )

    terminal = not recovery.retryable

    checkpoint = %{
      type: :attempt_finished,
      task_id: task.id,
      status: :failed,
      terminal: terminal,
      attempt: attempt,
      maximum_attempts: maximum_attempts,
      worker_id: handle && handle.worker_id,
      delegation_id: handle && handle.delegation_id,
      endpoint_id: endpoint_id,
      verification: verification || %{status: :unverified},
      error: inspect(reason),
      failure_code: recovery.reason_code,
      recovery: recovery
    }

    with :ok <- notify.(checkpoint) do
      if recovery.retryable do
        case BudgetManager.consume(parent.goal_id, parent.session_id, %{retries: 1}) do
          :ok ->
            retry_endpoints =
              if recovery.action == :rebind, do: failed_endpoint_ids, else: []

            attempt_task(
              parent,
              organization_id,
              task,
              attempt + 1,
              maximum_attempts,
              retry_endpoints,
              opts,
              notify
            )

          {:error, budget_reason} ->
            budget_recovery =
              FailureDecision.decide(budget_reason,
                attempt: attempt,
                maximum_attempts: maximum_attempts
              )

            terminal_failure(
              parent.goal_id,
              organization_id,
              task,
              attempt,
              maximum_attempts,
              handle,
              endpoint_id,
              verification,
              budget_reason,
              budget_recovery,
              failed_endpoint_ids,
              notify
            )
        end
      else
        _ =
          OrganizationManager.transition(parent.goal_id, organization_id, task.id, :failed, %{
            worker_id: handle && handle.worker_id,
            delegation_id: handle && handle.delegation_id,
            attempts: attempt,
            maximum_attempts: maximum_attempts,
            failure_code: recovery.reason_code,
            recovery_action: recovery.action
          })

        {:failed, failure_result(handle, endpoint_id, verification, reason, recovery, attempt),
         attempt, failed_endpoint_ids}
      end
    end
  end

  defp terminal_failure(
         goal_id,
         organization_id,
         task,
         attempt,
         maximum_attempts,
         handle,
         endpoint_id,
         verification,
         reason,
         recovery,
         failed_endpoint_ids,
         notify
       ) do
    checkpoint = %{
      type: :attempt_finished,
      task_id: task.id,
      status: :failed,
      terminal: true,
      attempt: attempt,
      maximum_attempts: maximum_attempts,
      worker_id: handle && handle.worker_id,
      delegation_id: handle && handle.delegation_id,
      endpoint_id: endpoint_id,
      verification: verification || %{status: :unverified},
      error: inspect(reason),
      failure_code: recovery.reason_code,
      recovery: recovery
    }

    with :ok <- notify.(checkpoint) do
      _ =
        OrganizationManager.transition(goal_id, organization_id, task.id, :failed, %{
          attempts: attempt,
          maximum_attempts: maximum_attempts,
          failure_code: recovery.reason_code,
          recovery_action: recovery.action
        })

      {:failed, failure_result(handle, endpoint_id, verification, reason, recovery, attempt),
       attempt, failed_endpoint_ids}
    end
  end

  defp merge_wave_result(
         {{:ok, {status, result, attempt, failed}}, task},
         {statuses, results, attempts, failed_endpoints}
       ) do
    {
      Map.put(statuses, task.id, status),
      Map.put(results, task.id, result),
      Map.put(attempts, task.id, attempt),
      Map.put(failed_endpoints, task.id, failed)
    }
  end

  defp merge_wave_result(
         {{:exit, reason}, task},
         _accumulator
       ) do
    exit({:task_execution_exit, task.id, reason})
  end

  defp merge_wave_result(
         {{:ok, {:error, reason}}, task},
         _accumulator
       ) do
    exit({:task_execution_failed, task.id, reason})
  end

  defp block_failed_dependencies(goal_id, plan, organization_id, statuses, results, notify) do
    Enum.reduce_while(
      DecompositionPlan.blocked(plan, statuses),
      {:ok, statuses, results},
      fn task, {:ok, status_acc, result_acc} ->
        failed_dependencies =
          Enum.filter(
            task.depends_on,
            &(Map.get(statuses, &1) in [:failed, :blocked, :cancelled])
          )

        recovery = %{
          version: 1,
          action: :replan,
          classification: :task_graph,
          reason_code: "dependency_failed",
          terminal: false
        }

        checkpoint = %{
          type: :task_blocked,
          task_id: task.id,
          status: :blocked,
          terminal: true,
          failed_dependencies: failed_dependencies,
          error: "dependency_failed",
          recovery: recovery
        }

        with :ok <- notify.(checkpoint),
             {:ok, _organization} <-
               OrganizationManager.transition(goal_id, organization_id, task.id, :blocked, %{
                 failure_code: "dependency_failed",
                 recovery_action: :replan
               }) do
          result = %{
            error: :dependency_failed,
            failed_dependencies: failed_dependencies,
            verification: %{status: :unverified},
            attempts: 0,
            recovery: recovery
          }

          {:cont,
           {:ok, Map.put(status_acc, task.id, :blocked), Map.put(result_acc, task.id, result)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp finish(plan, organization_id, statuses, results, notify) do
    status =
      if Enum.all?(statuses, fn {_id, task_status} -> task_status == :completed end),
        do: :completed,
        else: :failed

    recovery =
      if status == :completed do
        nil
      else
        results
        |> Map.values()
        |> Enum.filter(&(Map.get(&1, :recovery) != nil))
        |> FailureDecision.graph()
      end

    with :ok <- maybe_notify_recovery(notify, recovery) do
      {:ok,
       %{
         organization_id: organization_id,
         plan_id: plan.id,
         status: status,
         tasks: statuses,
         results: results,
         recovery: recovery
       }}
    end
  end

  defp maybe_notify_recovery(_notify, nil), do: :ok

  defp maybe_notify_recovery(notify, recovery),
    do: notify.(%{type: :recovery_decided, recovery: recovery})

  defp transition_running(goal_id, organization_id, task_id, handle, attempt, maximum_attempts) do
    case OrganizationManager.transition(goal_id, organization_id, task_id, :running, %{
           worker_id: handle.worker_id,
           delegation_id: handle.delegation_id,
           attempt: attempt,
           maximum_attempts: maximum_attempts
         }) do
      {:error, :invalid_task_transition} when attempt > 1 ->
        # The organization task remains running between attempts; attempt state
        # is carried by the work-run checkpoints.
        OrganizationManager.snapshot(goal_id, organization_id)

      other ->
        other
    end
  end

  defp proposal(task, parent, failed_endpoint_ids) do
    proposal =
      task
      |> Map.take([
        :goal,
        :role,
        :template,
        :instructions,
        :capabilities,
        :model_requirements,
        :verification_requirements,
        :completion_criteria
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case alternative_endpoint(parent, task, failed_endpoint_ids) do
      nil ->
        {proposal, preferred_endpoint(task)}

      endpoint_id ->
        requirements = Map.get(proposal, :model_requirements, %{})
        requirements = Map.put(requirements, :preferred_endpoint_id, endpoint_id)
        {Map.put(proposal, :model_requirements, requirements), endpoint_id}
    end
  end

  defp alternative_endpoint(_parent, _task, []), do: nil

  defp alternative_endpoint(parent, task, failed_endpoint_ids) do
    requirements = if is_map(task.model_requirements), do: task.model_requirements, else: %{}
    locality = value(requirements, :locality)
    privacy = value(requirements, :privacy)

    case ModelRegistry.list(parent.project_id) do
      {:ok, endpoints} ->
        endpoints
        |> Enum.reject(&(&1.id in failed_endpoint_ids))
        |> Enum.filter(&endpoint_allowed?(&1, locality, privacy))
        |> Enum.sort_by(& &1.id)
        |> List.first()
        |> then(&(&1 && &1.id))

      {:error, _reason} ->
        nil
    end
  end

  defp endpoint_allowed?(endpoint, locality, privacy) do
    endpoint_locality = endpoint.claims.locality

    locality_ok? =
      locality in [nil, :any, "any"] or to_string(endpoint_locality) == to_string(locality)

    privacy_ok? =
      privacy not in [:local, "local"] or
        (endpoint_locality == :local and endpoint.claims.privacy == :local)

    locality_ok? and privacy_ok?
  end

  defp preferred_endpoint(task) do
    requirements = if is_map(task.model_requirements), do: task.model_requirements, else: %{}
    value(requirements, :preferred_endpoint_id)
  end

  defp worker_endpoint_id(worker_id) do
    with {:ok, events} <- BeamAgent.events(worker_id),
         event when not is_nil(event) <-
           Enum.find(Enum.reverse(events), &(&1["type"] == "model_route_selected")) do
      event["data"]["selected_endpoint_id"]
    else
      _missing -> nil
    end
  end

  defp ask_worker(worker_id, goal, timeout) do
    BeamAgent.ask(worker_id, goal, timeout)
  catch
    :exit, {:timeout, _details} -> {:error, :model_timeout}
    :exit, {:noproc, _details} -> {:error, {:worker_restart_timeout, :not_found}}
    :exit, reason -> {:error, {:turn_process_exit, reason}}
  end

  defp worker_verification(worker_id) do
    with {:ok, events} <- BeamAgent.events(worker_id),
         event when not is_nil(event) <-
           Enum.find(Enum.reverse(events), &(&1["type"] == "verification_finished")) do
      data = event["data"]

      %{
        status: verification_status(data["status"]),
        verification_id: data["verification_id"],
        source: "worker_event",
        summary: "#{data["passed_count"] || 0}/#{data["check_count"] || 0} checks passed"
      }
    else
      _missing -> %{status: :unverified, source: "not_configured"}
    end
  end

  defp verification_status("passed"), do: :passed
  defp verification_status(:passed), do: :passed
  defp verification_status("failed"), do: :failed
  defp verification_status(:failed), do: :failed
  defp verification_status(_status), do: :unverified

  defp failure_result(handle, endpoint_id, verification, reason, recovery, attempt) do
    %{
      worker: handle,
      worker_id: handle && handle.worker_id,
      delegation_id: handle && handle.delegation_id,
      endpoint_id: endpoint_id,
      result: nil,
      verification: verification || %{status: :unverified},
      attempts: attempt,
      recovery: recovery,
      error: reason
    }
  end

  defp remember_endpoint(ids, nil), do: ids
  defp remember_endpoint(ids, endpoint_id), do: Enum.uniq([endpoint_id | ids])
  defp initial_statuses(plan), do: Map.new(plan.tasks, fn {id, _task} -> {id, :pending} end)
  defp value(map, key) when is_map(map), do: map[key] || map[to_string(key)]
  defp value(_value, _key), do: nil

  defp fingerprint(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
