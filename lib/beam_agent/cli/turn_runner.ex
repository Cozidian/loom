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
    deadline = deadline(timeout)
    await(task, deadline, approval_fun)
  end

  def run_live(session_id, prompt, timeout, approval_fun, event_fun)
      when is_function(approval_fun, 1) and is_function(event_fun, 1) do
    with :ok <- BeamAgent.subscribe(session_id) do
      try do
        owner = self()
        result_ref = make_ref()

        {:ok, pid} =
          Task.start(fn ->
            send(owner, {result_ref, BeamAgent.ask(session_id, prompt, timeout)})
          end)

        task = %{
          pid: pid,
          monitor: Process.monitor(pid),
          result_ref: result_ref,
          session_id: session_id
        }

        deadline = deadline(timeout)
        meta = %{streamed_text?: false, live_tool_events?: false}

        case await_live(task, deadline, approval_fun, event_fun, meta) do
          {{:ok, answer}, meta} -> {:ok, answer, meta}
          {{:error, reason}, meta} -> {:error, reason, meta}
        end
      after
        _ = BeamAgent.unsubscribe(session_id)
        flush_stream_messages()
      end
    end
  end

  defp await(task, deadline, approval_fun) do
    remaining = remaining(deadline)

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

  defp await_live(task, deadline, approval_fun, event_fun, meta) do
    remaining = remaining(deadline)

    receive do
      {ref, result} when ref == task.result_ref ->
        Process.demonitor(task.monitor, [:flush])
        _ = BeamAgent.sync_stream(result_session_id(task))
        {meta, _count} = drain_live_events(event_fun, meta, 0)
        {result, meta}

      {:DOWN, ref, :process, _pid, reason} when ref == task.monitor ->
        {{:error, {:turn_task_exit, reason}}, meta}

      {:beam_agent_approval, request} ->
        decision = approval_decision(approval_fun, request)

        case BeamAgent.respond_approval(request.session_id, request.approval_id, decision) do
          :ok ->
            await_live(task, deadline, approval_fun, event_fun, meta)

          {:error, reason} ->
            stop(task)
            {{:error, reason}, meta}
        end

      {:beam_agent_stream, event} ->
        safely_render(event_fun, event)
        await_live(task, deadline, approval_fun, event_fun, update_meta(meta, event))
    after
      remaining ->
        stop(task)
        {{:error, :turn_timeout}, meta}
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

  defp safely_render(event_fun, event) do
    event_fun.(event)
    :ok
  rescue
    _error -> :ok
  end

  defp update_meta(meta, %{type: :text_delta, delta: delta}) when delta != "",
    do: %{meta | streamed_text?: true}

  defp update_meta(meta, %{
         type: :durable_event,
         event: %{"type" => type}
       })
       when type in ["tool_called", "tool_result"],
       do: %{meta | live_tool_events?: true}

  defp update_meta(meta, _event), do: meta

  defp drain_live_events(event_fun, meta, count) do
    receive do
      {:beam_agent_stream, event} ->
        safely_render(event_fun, event)
        drain_live_events(event_fun, update_meta(meta, event), count + 1)
    after
      0 -> {meta, count}
    end
  end

  defp result_session_id(%{session_id: session_id}), do: session_id

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout + 1_000

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp flush_stream_messages do
    receive do
      {:beam_agent_stream, _event} -> flush_stream_messages()
    after
      0 -> :ok
    end
  end
end
