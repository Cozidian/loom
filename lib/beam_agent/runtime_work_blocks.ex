defmodule BeamAgent.RuntimeWorkBlocks do
  @moduledoc "Pure semantic work-block projection over canonical runtime events."

  @read_tools ~w(read_file search_files list_files file_symbols file_diagnostics git_inspect)
  @write_tools ~w(apply_patch create_file edit_file run_command)
  @warning_types ~w(
    tool_denied capability_denied path_lease_denied model_response_failed
    verification_recovery_started implementation_review_recovery_started
    worker_stall_suspected tool_loop_stalled delegation_failed
  )

  def project(events) when is_list(events) do
    events
    |> Enum.filter(&durable?/1)
    |> Enum.sort_by(&sequence/1)
    |> Enum.reduce(%{blocks: %{}, active: %{}}, &fold/2)
    |> then(fn state ->
      state.blocks
      |> Map.values()
      |> Enum.sort_by(& &1.started_goal_seq)
      |> Enum.map(&finalize/1)
    end)
  end

  defp fold(event, state) do
    worker_id = worker_id(event)
    type = event_type(event)
    data = event_data(event)

    cond do
      not is_binary(worker_id) ->
        state

      type in ["goal_work_started", "turn_started", "delegation_started"] ->
        {state, id} = ensure_block(state, worker_id, event, type, data)
        update_block(state, id, &apply_event(&1, event, type, data))

      id = state.active[worker_id] ->
        state = update_block(state, id, &apply_event(&1, event, type, data))

        if terminal?(type) do
          update_in(state.active, &Map.delete(&1, worker_id))
        else
          state
        end

      true ->
        state
    end
  end

  defp ensure_block(state, worker_id, event, type, data) do
    case state.active[worker_id] do
      nil ->
        id = block_id(worker_id, event, type, data)
        block = new_block(id, worker_id, event)

        {%{
           state
           | blocks: Map.put(state.blocks, id, block),
             active: Map.put(state.active, worker_id, id)
         }, id}

      id ->
        {state, id}
    end
  end

  defp apply_event(block, event, type, data) do
    block = %{
      block
      | last_event_at: event_at(event) || block.last_event_at,
        last_goal_seq: sequence(event),
        event_ids: append_bounded(block.event_ids, event_id(event), 250)
    }

    block
    |> apply_phase(type, data)
    |> apply_counts(type, data)
    |> apply_terminal(type, data, event_at(event))
  end

  defp apply_phase(block, "goal_work_started", _data),
    do: phase(block, :starting, "Starting work")

  defp apply_phase(block, "turn_started", _data),
    do: phase(block, :investigating, "Investigating")

  defp apply_phase(block, "model_response_started", _data),
    do: phase(block, :thinking, "Model working")

  defp apply_phase(block, "tool_called", %{"name" => name}) when name in @read_tools,
    do: phase(block, :investigating, "Investigating")

  defp apply_phase(block, "tool_called", %{"name" => name}) when name in @write_tools,
    do: phase(block, :implementing, "Implementing")

  defp apply_phase(block, "tool_called", %{"name" => "spawn_subagent"}),
    do: phase(block, :delegating, "Delegating")

  defp apply_phase(block, "delegation_started", _data),
    do: phase(block, :delegated_work, "Background worker")

  defp apply_phase(block, "verification_started", _data),
    do: phase(block, :verifying, "Running verification")

  defp apply_phase(block, "implementation_review_started", _data),
    do: phase(block, :reviewing, "Reviewing changes")

  defp apply_phase(block, type, _data)
       when type in ["verification_recovery_started", "implementation_review_recovery_started"],
       do: phase(block, :repairing, "Repairing candidate")

  defp apply_phase(block, "tool_approval_requested", data),
    do: block |> phase(:awaiting_approval, "Waiting for approval") |> block(data["name"])

  defp apply_phase(block, "resource_queued", data),
    do: block |> phase(:queued, "Waiting for resources") |> block(data["resource_pool"])

  defp apply_phase(block, "worker_stall_suspected", _data),
    do: phase(block, :suspected_stalled, "Suspected stalled")

  defp apply_phase(block, "tool_loop_stalled", _data), do: phase(block, :stalled, "Stalled")

  defp apply_phase(block, "worker_progress_resumed", _data),
    do: phase(block, :executing, "Work resumed")

  defp apply_phase(block, _type, _data), do: block

  defp apply_counts(block, "model_response_started", _data),
    do: update_in(block.counts.model_calls, &(&1 + 1))

  defp apply_counts(block, "tool_called", data) do
    name = data["name"]
    path = get_in(data, ["arguments", "path"])

    block
    |> update_in([:counts, :tool_calls], &(&1 + 1))
    |> maybe_increment(:reads, name in @read_tools)
    |> maybe_increment(:writes, name in @write_tools)
    |> maybe_add_file(path)
  end

  defp apply_counts(block, "subagent_spawned", _data),
    do: update_in(block.counts.children, &(&1 + 1))

  defp apply_counts(block, "verification_check_finished", data) do
    status = data["status"]

    block
    |> update_in([:counts, :verification_checks], &(&1 + 1))
    |> maybe_increment(:verification_failures, status != "passed", [:counts])
  end

  defp apply_counts(block, type, _data) when type in @warning_types,
    do: update_in(block.counts.warnings, &(&1 + 1))

  defp apply_counts(block, _type, _data), do: block

  defp apply_terminal(block, "turn_finished", data, at) do
    state =
      case data["reason"] do
        reason when reason in ["error", :error] -> :failed
        reason when reason in ["cancelled", :cancelled] -> :cancelled
        _other -> :completed
      end

    %{block | state: state, phase: state, finished_at: at}
  end

  defp apply_terminal(block, "delegation_completed", _data, at),
    do: %{block | state: :completed, phase: :completed, finished_at: at}

  defp apply_terminal(block, "delegation_failed", _data, at),
    do: %{block | state: :failed, phase: :failed, finished_at: at}

  defp apply_terminal(block, "delegation_cancelled", _data, at),
    do: %{block | state: :cancelled, phase: :cancelled, finished_at: at}

  defp apply_terminal(block, _type, _data, _at), do: block

  defp finalize(block) do
    label =
      if block.state in [:completed, :failed, :cancelled],
        do: completed_label(block),
        else: block.label

    %{block | label: label, summary: summary(block), duration_ms: duration(block)}
  end

  defp summary(block) do
    parts =
      [
        count_label(block.counts.reads, "read"),
        count_label(block.counts.writes, "write"),
        count_label(block.counts.model_calls, "model call"),
        count_label(block.counts.children, "child"),
        count_label(block.counts.verification_checks, "check"),
        count_label(block.counts.warnings, "warning")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "No recorded activity", else: Enum.join(parts, " · ")
  end

  defp completed_label(%{state: :failed}), do: "Work failed"
  defp completed_label(%{state: :cancelled}), do: "Work cancelled"

  defp completed_label(%{phase: :completed, counts: %{writes: writes}}) when writes > 0,
    do: "Implemented changes"

  defp completed_label(%{phase: :completed, counts: %{verification_checks: checks}})
       when checks > 0,
       do: "Verified work"

  defp completed_label(_block), do: "Completed work"

  defp new_block(id, worker_id, event) do
    %{
      id: id,
      worker_id: worker_id,
      state: :active,
      phase: :starting,
      label: "Starting work",
      blocking_reason: nil,
      started_at: event_at(event),
      finished_at: nil,
      last_event_at: event_at(event),
      started_goal_seq: sequence(event),
      last_goal_seq: sequence(event),
      duration_ms: nil,
      counts: %{
        reads: 0,
        writes: 0,
        tool_calls: 0,
        model_calls: 0,
        children: 0,
        verification_checks: 0,
        verification_failures: 0,
        warnings: 0
      },
      files: [],
      event_ids: [],
      summary: ""
    }
  end

  defp phase(block, phase, label), do: %{block | phase: phase, label: label}
  defp block(block, nil), do: block
  defp block(block, reason), do: %{block | blocking_reason: to_string(reason)}

  defp maybe_increment(block, key, increment?, path \\ [:counts])
  defp maybe_increment(block, _key, false, _path), do: block
  defp maybe_increment(block, key, true, path), do: update_in(block, path ++ [key], &(&1 + 1))

  defp maybe_add_file(block, path) when is_binary(path),
    do: %{block | files: append_bounded(block.files, path, 50) |> Enum.uniq()}

  defp maybe_add_file(block, _path), do: block

  defp update_block(state, id, fun), do: update_in(state, [:blocks, id], fun)

  defp terminal?(type),
    do:
      type in [
        "turn_finished",
        "delegation_completed",
        "delegation_failed",
        "delegation_cancelled"
      ]

  defp block_id(worker_id, event, type, data) do
    suffix = data["turn"] || data["delegation_id"] || data["contract_id"] || sequence(event)
    "work-block:#{worker_id}:#{type}:#{suffix}"
  end

  defp duration(%{started_at: start, finished_at: finish, last_event_at: last_event})
       when is_binary(start) do
    finish = finish || last_event

    with true <- is_binary(finish),
         {:ok, started, _} <- DateTime.from_iso8601(start),
         {:ok, finished, _} <- DateTime.from_iso8601(finish) do
      max(DateTime.diff(finished, started, :millisecond), 0)
    else
      _other -> nil
    end
  end

  defp duration(_block), do: nil

  defp count_label(0, _label), do: nil
  defp count_label(1, label), do: "1 #{label}"
  defp count_label(count, label), do: "#{count} #{label}s"

  defp append_bounded(values, nil, _limit), do: values
  defp append_bounded(values, value, limit), do: Enum.take(values ++ [value], -limit)

  defp durable?(%{durability: :durable}), do: true
  defp durable?(%{"durability" => "durable"}), do: true
  defp durable?(_event), do: false

  defp sequence(event), do: event[:goal_seq] || event["goal_seq"] || 0
  defp event_id(event), do: event[:event_id] || event["event_id"]
  defp event_at(event), do: event[:at] || event["at"]

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
end
