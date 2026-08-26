defmodule BeamAgent.CLI.TurnRunner do
  @moduledoc false

  def run(session_id, prompt, timeout, approval_fun) when is_function(approval_fun, 1) do
    owner = self()
    result_ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        send(owner, {result_ref, BeamAgent.ask(session_id, prompt, timeout)})
      end)

    task = %{pid: pid, monitor: Process.monitor(pid), result_ref: result_ref}
    deadline = System.monotonic_time(:millisecond) + timeout + 1_000
    await(task, deadline, approval_fun)
  end

  defp await(task, deadline, approval_fun) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, result} when ref == task.result_ref ->
        Process.demonitor(task.monitor, [:flush])
        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.monitor ->
        {:error, {:turn_task_exit, reason}}

      {:beam_agent_approval, request} ->
        decision = approval_decision(approval_fun, request)

        case BeamAgent.respond_approval(request.session_id, request.approval_id, decision) do
          :ok ->
            await(task, deadline, approval_fun)

          {:error, reason} ->
            stop(task)
            {:error, reason}
        end
    after
      remaining ->
        stop(task)
        {:error, :turn_timeout}
    end
  end

  defp stop(task) do
    Process.demonitor(task.monitor, [:flush])

    if Process.alive?(task.pid) do
      Process.exit(task.pid, :kill)
    end

    :ok
  end

  defp approval_decision(approval_fun, request) do
    case approval_fun.(request) do
      :allow_once -> :allow_once
      _ -> :deny
    end
  rescue
    _error -> :deny
  end
end
