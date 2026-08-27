defmodule BeamAgent.Goal.Verifier do
  @moduledoc """
  Runs one verification plan in a disposable, goal-supervised process.

  Verification is deterministic and capability-bounded: commands run through
  the same workspace sandbox as model-requested shell tools, but do not need an
  LLM or enter an agent conversation.
  """

  alias BeamAgent.{Goal, Names, OutcomeStore, VerificationPlan}
  alias BeamAgent.Session.EventLog
  alias BeamAgent.Tools.RunCommand

  def run(goal_id, plan \\ :auto) when is_binary(goal_id) do
    with {:ok, goal} <- Goal.snapshot(goal_id),
         {:ok, plan} <- resolve_plan(goal.workspace_root, plan),
         {:ok, supervisor} <- Names.pid(:goal_verification_supervisor, goal_id) do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          execute(goal, plan)
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

      case append(goal, :verification_cancelled, %{}) do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_plan(workspace_root, :auto), do: VerificationPlan.load(workspace_root)
  defp resolve_plan(_workspace_root, %VerificationPlan{} = plan), do: {:ok, plan}
  defp resolve_plan(_workspace_root, attributes), do: VerificationPlan.new(attributes)

  defp execute(goal, plan) do
    verification_id = new_id()

    with {:ok, _event} <-
           append(goal, :verification_started, %{
             "verification_id" => verification_id,
             "source" => plan.source,
             "check_count" => length(plan.checks)
           }) do
      checks = Enum.map(plan.checks, &run_check(goal, verification_id, &1))
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
             append(goal, :verification_finished, %{
               "verification_id" => verification_id,
               "status" => status,
               "check_count" => length(checks),
               "passed_count" => passed,
               "failed_count" => length(checks) - passed
             }),
           :ok <- attach_to_latest_task(goal, result) do
        {:ok, result}
      end
    end
  end

  defp run_check(goal, verification_id, check) do
    {:ok, _event} =
      append(goal, :verification_check_started, %{
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
      append(goal, :verification_check_finished, %{
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

  defp attach_to_latest_task(goal, result) do
    with {:ok, outcomes} <- OutcomeStore.list(goal.project_id, kind: :task),
         %{id: outcome_id} <- Enum.find(outcomes, &(&1.session_id == goal.session_id)) do
      OutcomeStore.attach_verification(goal.project_id, outcome_id, result)
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append(goal, type, data), do: EventLog.append(goal.session_id, type, data)

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
