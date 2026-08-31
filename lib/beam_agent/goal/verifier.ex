defmodule BeamAgent.Goal.Verifier do
  @moduledoc """
  Runs one verification plan in a disposable, goal-supervised process.

  Verification is deterministic and capability-bounded: commands run through
  the same workspace sandbox as model-requested shell tools, but do not need an
  LLM or enter an agent conversation.
  """

  alias BeamAgent.{Agent, Goal, Names, OutcomeStore, VerificationPlan}
  alias BeamAgent.Session.EventLog
  alias BeamAgent.Tools.RunCommand

  def run(goal_id, plan \\ :auto, opts \\ []) when is_binary(goal_id) do
    with {:ok, goal} <- Goal.snapshot(goal_id),
         {:ok, workspace_root} <- verification_workspace(goal, opts),
         {:ok, plan} <- resolve_plan(workspace_root, plan),
         {:ok, supervisor} <- Names.pid(:goal_verification_supervisor, goal_id) do
      session_id = Keyword.get(opts, :session_id, goal.session_id)
      goal = Map.put(goal, :workspace_root, workspace_root)

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          execute(goal, session_id, plan, opts)
        end)

      await(task, VerificationPlan.timeout(plan))
    end
  end

  def cancel(goal_id) when is_binary(goal_id) do
    with {:ok, goal} <- Goal.snapshot(goal_id),
         {:ok, supervisor} <- Names.pid(:goal_verification_supervisor, goal_id) do
      supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} -> DynamicSupervisor.terminate_child(supervisor, pid) end)

      case append(goal.session_id, :verification_cancelled, %{}) do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_plan(workspace_root, :auto), do: VerificationPlan.load(workspace_root)
  defp resolve_plan(_workspace_root, %VerificationPlan{} = plan), do: {:ok, plan}
  defp resolve_plan(_workspace_root, attributes), do: VerificationPlan.new(attributes)

  defp verification_workspace(goal, opts) do
    case Keyword.get(opts, :worker_id) do
      nil ->
        {:ok, goal.workspace_root}

      worker_id when is_binary(worker_id) ->
        with {:ok, worker} <- Agent.construction_context(worker_id),
             true <- worker.goal_id == goal.goal_id,
             workspace when is_binary(workspace) <- worker.workspace_root do
          {:ok, workspace}
        else
          false -> {:error, :verification_worker_goal_mismatch}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :invalid_verification_workspace}
        end

      _other ->
        {:error, :invalid_verification_worker}
    end
  end

  defp execute(goal, session_id, plan, opts) do
    verification_id = new_id()

    with {:ok, _event} <-
           append(session_id, :verification_started, %{
             "verification_id" => verification_id,
             "source" => plan.source,
             "check_count" => length(plan.checks)
           }) do
      checks = Enum.map(plan.checks, &run_check(goal, session_id, verification_id, &1))
      required_failures = Enum.filter(checks, &(&1.required and &1.status != :passed))
      status = if required_failures == [], do: :passed, else: :failed
      passed = Enum.count(checks, &(&1.status == :passed))

      result = %{
        status: status,
        source: plan.source,
        summary: "#{passed}/#{length(checks)} checks passed",
        verification_id: verification_id,
        checks: checks
      }

      with {:ok, _event} <-
             append(session_id, :verification_finished, %{
               "verification_id" => verification_id,
               "status" => status,
               "check_count" => length(checks),
               "passed_count" => passed,
               "failed_count" => length(checks) - passed
             }),
           :ok <- maybe_attach(goal, session_id, result, opts),
           :ok <- maybe_report(session_id, result, opts) do
        {:ok, result}
      end
    end
  end

  defp run_check(goal, session_id, verification_id, check) do
    {:ok, _event} =
      append(session_id, :verification_check_started, %{
        "verification_id" => verification_id,
        "check_id" => check.id,
        "required" => check.required
      })

    started_at = System.monotonic_time(:millisecond)

    {status, exit_status, output, truncated} =
      case RunCommand.execute(
             %{
               "command" => check.command,
               "cwd" => check.cwd,
               "timeout_ms" => check.timeout_ms
             },
             %{workspace_root: goal.workspace_root}
           ) do
        {:ok, encoded} ->
          data = JSON.decode!(encoded)
          {:passed, data["status"], data["output"], data["truncated"]}

        {:error, {:command_failed, data}} ->
          {:failed, data.status, data.output, data.truncated}

        {:error, reason} ->
          {:failed, nil, inspect(reason), false}
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at

    result = %{
      id: check.id,
      status: status,
      required: check.required,
      exit_status: exit_status,
      duration_ms: duration_ms,
      output: output,
      truncated: truncated
    }

    {:ok, _event} =
      append(session_id, :verification_check_finished, %{
        "verification_id" => verification_id,
        "check_id" => check.id,
        "required" => check.required,
        "status" => status,
        "exit_status" => exit_status,
        "duration_ms" => duration_ms,
        "truncated" => truncated
      })

    result
  end

  defp attach_to_task(goal, _session_id, result, outcome_id) when is_binary(outcome_id),
    do: OutcomeStore.attach_verification(goal.project_id, outcome_id, result)

  defp attach_to_task(goal, session_id, result, nil) do
    with {:ok, outcomes} <- OutcomeStore.list(goal.project_id, kind: :task),
         %{id: outcome_id} <- Enum.find(outcomes, &(&1.session_id == session_id)) do
      OutcomeStore.attach_verification(goal.project_id, outcome_id, result)
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_attach(goal, session_id, result, opts) do
    if Keyword.get(opts, :attach, true),
      do: attach_to_task(goal, session_id, result, Keyword.get(opts, :outcome_id)),
      else: :ok
  end

  defp maybe_report(session_id, result, opts) do
    if Keyword.get(opts, :completion_report, true) do
      case append(session_id, :completion_report_generated, %{
             "verification_id" => result.verification_id,
             "status" => completion_status(result.status),
             "evidence_count" => length(result.checks),
             "passed_count" => Enum.count(result.checks, &(&1.status == :passed)),
             "failed_count" => Enum.count(result.checks, &(&1.status != :passed))
           }) do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp append(session_id, type, data), do: EventLog.append(session_id, type, data)

  defp completion_status(:passed), do: "verified"
  defp completion_status(:failed), do: "verification_failed"

  defp await(task, timeout) do
    Task.await(task, timeout)
  catch
    :exit, {:timeout, _details} ->
      _ = Task.shutdown(task, :brutal_kill)
      {:error, :verification_timeout}

    :exit, reason ->
      {:error, {:verification_worker_exit, reason}}
  end

  defp new_id do
    "verification-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
