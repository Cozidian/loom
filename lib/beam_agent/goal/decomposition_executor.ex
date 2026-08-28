defmodule BeamAgent.Goal.DecompositionExecutor do
  @moduledoc "Executes a validated decomposition in dependency waves with bounded concurrency."

  alias BeamAgent.{Agent, DecompositionPlan, ExecutionStrategy}
  alias BeamAgent.Goal.OrganizationManager

  def run(parent_session_id, plan, opts \\ []) when is_binary(parent_session_id) do
    with {:ok, plan} <- resolve_plan(plan),
         {:ok, parent} <- Agent.construction_context(parent_session_id) do
      strategy = resolve_strategy(Keyword.get(opts, :strategy), parent)

      with {:ok, organization} <-
             OrganizationManager.create(parent.goal_id, parent_session_id, plan, strategy) do
        statuses = Map.new(plan.tasks, fn {id, _task} -> {id, :pending} end)
        execute_waves(parent, plan, organization, strategy, statuses, %{}, opts)
      end
    end
  end

  defp execute_waves(parent, plan, organization, strategy, statuses, results, opts) do
    {statuses, organization} =
      block_failed_dependencies(parent.goal_id, plan, organization, statuses)

    cond do
      DecompositionPlan.terminal?(plan, statuses) ->
        {:ok,
         %{
           organization_id: organization.id,
           plan_id: plan.id,
           status: organization_status(statuses),
           tasks: statuses,
           results: results
         }}

      ready = DecompositionPlan.ready(plan, statuses) ->
        if ready == [] do
          _ = OrganizationManager.cancel(parent.goal_id, organization.id, :plan_deadlock)
          {:error, :decomposition_deadlock}
        else
          maximum_parallelism = max(1, strategy.maximum_parallelism)

          wave_results =
            ready
            |> Task.async_stream(
              &execute_task(parent, organization, &1, opts),
              max_concurrency: maximum_parallelism,
              ordered: true,
              timeout: Keyword.get(opts, :task_timeout, :infinity),
              on_timeout: :kill_task
            )
            |> Enum.zip(ready)

          {statuses, results} =
            Enum.reduce(wave_results, {statuses, results}, fn
              {{:ok, {:ok, result}}, task}, {status_acc, result_acc} ->
                {Map.put(status_acc, task.id, :completed), Map.put(result_acc, task.id, result)}

              {{:ok, {:error, reason}}, task}, {status_acc, result_acc} ->
                {Map.put(status_acc, task.id, :failed),
                 Map.put(result_acc, task.id, %{error: reason})}

              {{:exit, reason}, task}, {status_acc, result_acc} ->
                _ =
                  OrganizationManager.transition(
                    parent.goal_id,
                    organization.id,
                    task.id,
                    :failed
                  )

                {Map.put(status_acc, task.id, :failed),
                 Map.put(result_acc, task.id, %{error: reason})}
            end)

          {:ok, organization} =
            OrganizationManager.snapshot(parent.goal_id, organization.id)

          execute_waves(parent, plan, organization, strategy, statuses, results, opts)
        end
    end
  end

  defp execute_task(parent, organization, task, opts) do
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

    spawn_opts = Keyword.get(opts, :worker_options, [])

    case BeamAgent.spawn_worker(parent.session_id, proposal, spawn_opts) do
      {:ok, handle} ->
        _ =
          OrganizationManager.transition(parent.goal_id, organization.id, task.id, :running, %{
            worker_id: handle.worker_id,
            delegation_id: handle.delegation_id
          })

        try do
          case BeamAgent.ask(handle.worker_id, task.goal) do
            {:ok, content} ->
              verification = %{status: :unverified}

              with {:ok, result} <- BeamAgent.complete_worker(handle, content, verification),
                   {:ok, _organization} <-
                     OrganizationManager.transition(
                       parent.goal_id,
                       organization.id,
                       task.id,
                       :completed,
                       %{
                         worker_id: handle.worker_id,
                         delegation_id: handle.delegation_id,
                         result_fingerprint: fingerprint(content),
                         verification_status: :unverified
                       }
                     ) do
                {:ok, %{worker: handle, result: result}}
              end

            {:error, reason} ->
              _ = BeamAgent.cancel_worker(handle, reason)
              fail_task(parent.goal_id, organization.id, task.id, reason)
          end
        after
          # The parent delegation/result events are durable, so organization
          # workers can be reclaimed immediately after returning their result.
          _ = BeamAgent.stop_session(handle.worker_id)
        end

      {:error, reason} ->
        fail_task(parent.goal_id, organization.id, task.id, reason)
    end
  end

  defp fail_task(goal_id, organization_id, task_id, reason) do
    _ = OrganizationManager.transition(goal_id, organization_id, task_id, :failed)
    {:error, reason}
  end

  defp block_failed_dependencies(goal_id, plan, organization, statuses) do
    Enum.reduce(DecompositionPlan.blocked(plan, statuses), {statuses, organization}, fn task,
                                                                                        {acc, org} ->
      case OrganizationManager.transition(goal_id, org.id, task.id, :blocked) do
        {:ok, next_org} -> {Map.put(acc, task.id, :blocked), next_org}
        {:error, _reason} -> {acc, org}
      end
    end)
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

  defp organization_status(statuses) do
    if Enum.all?(statuses, fn {_id, status} -> status == :completed end),
      do: :completed,
      else: :failed
  end

  defp fingerprint(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
