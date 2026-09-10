defmodule BeamAgent.Goal.WorkArtifact do
  @moduledoc "Evidence artifact produced at a Goal work boundary."

  alias BeamAgent.Goal.WorkspaceSnapshot
  alias BeamAgent.Project.ContextStore
  alias BeamAgent.Session.EventLog

  @write_tools MapSet.new(["apply_patch", "create_file", "edit_file", "fill_document"])

  def build(goal, contract, result, started_event_id \\ nil, baseline \\ nil) do
    with {:ok, events} <- EventLog.events(goal.session_id) do
      events = Enum.filter(events, &(&1["seq"] >= start_seq(started_event_id)))
      successful_calls = successful_calls(events)
      {workspace_delta, authoritative?} = workspace_delta(goal.project_id, baseline)

      changed_files =
        if(authoritative?,
          do: workspace_delta.changed_files,
          else: changed_files(events, successful_calls)
        )
        |> Enum.uniq()
        |> Enum.sort()

      artifact = %{
        id: "work-artifact:#{contract.id}",
        version: 1,
        contract_id: contract.id,
        kind: contract.expected_artifact,
        status: status(result),
        changed_files: changed_files,
        workspace_delta: workspace_delta,
        mutation_sources: mutation_sources(events, successful_calls),
        verification: latest_verification(events),
        result_fingerprint: fingerprint(result),
        observed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      persist(goal.project_id, artifact)
      {:ok, artifact}
    end
  end

  defp workspace_delta(_project_id, nil), do: {WorkspaceSnapshot.empty_delta(), false}

  defp workspace_delta(project_id, baseline) do
    case WorkspaceSnapshot.capture(project_id,
           workspace_root: baseline.workspace_root,
           exclude: baseline.excluded_roots,
           data_dir: baseline.runtime_data_root
         ) do
      {:ok, current} -> {WorkspaceSnapshot.delta(baseline, current), true}
      {:error, _reason} -> {WorkspaceSnapshot.empty_delta(), false}
    end
  end

  defp successful_calls(events) do
    events
    |> Enum.filter(fn event ->
      event["type"] == "tool_result" and event["data"]["is_error"] == false
    end)
    |> MapSet.new(& &1["data"]["tool_call_id"])
  end

  defp changed_files(events, successful_calls) do
    events
    |> Enum.filter(fn event ->
      event["type"] == "tool_called" and
        event["data"]["name"] in @write_tools and
        MapSet.member?(successful_calls, event["data"]["tool_call_id"])
    end)
    |> Enum.map(&get_in(&1, ["data", "arguments", "path"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp mutation_sources(events, successful_calls) do
    events
    |> Enum.filter(fn event ->
      event["type"] == "tool_called" and
        MapSet.member?(successful_calls, event["data"]["tool_call_id"])
    end)
    |> Enum.map(&get_in(&1, ["data", "name"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp latest_verification(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(%{status: :unverified, checks: []}, fn event ->
      if event["type"] == "verification_finished" do
        %{
          id: event["data"]["verification_id"],
          status: atom_status(event["data"]["status"]),
          passed_count: event["data"]["passed_count"],
          failed_count: event["data"]["failed_count"]
        }
      end
    end)
  end

  defp persist(project_id, artifact) do
    _ =
      ContextStore.put(project_id, %{
        id: artifact.id,
        kind: "work_artifact",
        source: artifact.contract_id,
        source_version: System.system_time(:millisecond),
        content: JSON.encode!(stringify(artifact)),
        metadata: %{status: artifact.status, kind: artifact.kind}
      })

    :ok
  end

  defp status({:ok, _result}), do: :completed
  defp status({:error, :cancelled}), do: :cancelled
  defp status({:error, _reason}), do: :failed

  defp atom_status("passed"), do: :passed
  defp atom_status("failed"), do: :failed
  defp atom_status(status), do: status

  defp fingerprint(result) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(result))
    |> Base.encode16(case: :lower)
  end

  defp start_seq(event_id) when is_binary(event_id) do
    case event_id |> String.split(":") |> List.last() |> Integer.parse() do
      {seq, ""} -> seq
      _other -> 0
    end
  end

  defp start_seq(_event_id), do: 0

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
end
