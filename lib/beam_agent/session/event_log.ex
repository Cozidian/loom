defmodule BeamAgent.Session.EventLog do
  @moduledoc "A session-owned, synchronous append-only JSONL event log."
  use GenServer

  alias BeamAgent.Names
  alias BeamAgent.Goal.EventHub
  alias BeamAgent.Session.{FileReference, StreamHub}

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:event_log, id))
  end

  def append(session_id, type, data, metadata \\ []) when is_map(data) and is_list(metadata) do
    with {:ok, pid} <- Names.pid(:event_log, session_id) do
      GenServer.call(pid, {:append, type, data, metadata})
    end
  end

  def events(session_id) do
    with {:ok, pid} <- Names.pid(:event_log, session_id) do
      GenServer.call(pid, :events)
    end
  end

  def messages(session_id) do
    with {:ok, events} <- events(session_id) do
      {:ok, messages_from_events(events)}
    end
  end

  def messages_from_events(events) when is_list(events),
    do: Enum.flat_map(events, &to_message/1)

  def path(session_id) do
    with {:ok, pid} <- Names.pid(:event_log, session_id) do
      GenServer.call(pid, :path)
    end
  end

  def read(data_dir, session_id)
      when is_binary(data_dir) and is_binary(session_id) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, session_id) do
      data_dir
      |> Path.join(session_id)
      |> Path.join("events.jsonl")
      |> load()
    else
      {:error, :invalid_session_id}
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    parent_session_id = Keyword.get(opts, :parent_session_id)
    project_id = Keyword.fetch!(opts, :project_id)
    goal_id = Keyword.fetch!(opts, :goal_id)
    data_dir = Keyword.fetch!(opts, :data_dir)
    directory = Path.join(data_dir, session_id)
    path = Path.join(directory, "events.jsonl")

    with :ok <- File.mkdir_p(directory),
         {:ok, events} <- load(path),
         {:ok, io} <- File.open(path, [:append, :binary, :utf8]) do
      state = %{
        session_id: session_id,
        goal_id: goal_id,
        path: path,
        io: io,
        events: events,
        correlation_id: restored_correlation(events)
      }

      initialize_log(
        state,
        parent_session_id,
        Keyword.fetch!(opts, :workspace_root),
        project_id,
        goal_id,
        Keyword.get(opts, :correlation_id),
        Keyword.get(opts, :causation_id)
      )
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append, type, data, metadata}, _from, state) do
    case persist(state, type, data, metadata) do
      {:ok, event, next} -> {:reply, {:ok, event}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:events, _from, state), do: {:reply, {:ok, state.events}, state}
  def handle_call(:path, _from, state), do: {:reply, {:ok, state.path}, state}

  @impl true
  def terminate(_reason, state), do: File.close(state.io)

  defp persist(state, type, data, metadata \\ []) do
    with {:ok, goal_seq} <- EventHub.next_sequence(state.goal_id) do
      persist_reserved(state, type, data, metadata, goal_seq)
    end
  end

  defp persist_reserved(state, type, data, metadata, goal_seq) do
    correlation_id = metadata_value(metadata, :correlation_id, state.correlation_id)
    causation_id = metadata_value(metadata, :causation_id, last_event_id(state.events))

    event = %{
      "seq" => length(state.events),
      "goal_seq" => goal_seq,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "session_id" => state.session_id,
      "type" => to_string(type),
      "correlation_id" => correlation_id,
      "causation_id" => causation_id,
      "data" => stringify_keys(data)
    }

    encoded = JSON.encode!(event)

    case write_event(state.io, encoded) do
      :ok ->
        StreamHub.publish_event(state.session_id, event)

        next_correlation =
          if to_string(type) in [
               "turn_finished",
               "turn_cancelled",
               "turn_worker_failed",
               "command_failed"
             ],
             do: nil,
             else: correlation_id

        {:ok, event, %{state | events: state.events ++ [event], correlation_id: next_correlation}}

      {:error, reason} ->
        _ = EventHub.abandon_sequence(state.goal_id, goal_seq)
        {:error, reason}
    end
  rescue
    error ->
      _ = EventHub.abandon_sequence(state.goal_id, goal_seq)
      {:error, {:invalid_event, Exception.message(error)}}
  end

  defp write_event(io, encoded) do
    with :ok <- IO.binwrite(io, [encoded, "\n"]), :ok <- :file.sync(io), do: :ok
  end

  defp load(path) do
    case File.read(path) do
      {:ok, ""} -> {:ok, []}
      {:ok, contents} -> decode_events(contents)
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_events(contents) do
    lines = String.split(contents, "\n", trim: true)

    with {:ok, events} <- decode_lines(lines),
         :ok <- validate_sequence(events) do
      {:ok, events}
    end
  end

  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case JSON.decode(line) do
        {:ok, event} when is_map(event) -> {:cont, {:ok, acc ++ [event]}}
        {:ok, _other} -> {:halt, {:error, :invalid_event_envelope}}
        {:error, reason} -> {:halt, {:error, {:corrupt_event_log, reason}}}
      end
    end)
  end

  defp validate_sequence(events) do
    if Enum.with_index(events) |> Enum.all?(fn {event, index} -> event["seq"] == index end) do
      :ok
    else
      {:error, :non_contiguous_event_sequence}
    end
  end

  defp initialize_log(
         %{events: []} = state,
         parent_session_id,
         workspace_root,
         project_id,
         goal_id,
         correlation_id,
         causation_id
       ) do
    metadata = [correlation_id: correlation_id, causation_id: causation_id]

    case persist(
           state,
           :session_started,
           %{
             "parent_session_id" => parent_session_id,
             "workspace_root" => workspace_root,
             "project_id" => project_id,
             "goal_id" => goal_id
           },
           metadata
         ) do
      {:ok, _event, state} -> {:ok, state}
      {:error, reason} -> close_and_stop(state, reason)
    end
  end

  defp initialize_log(
         state,
         _parent_session_id,
         workspace_root,
         project_id,
         goal_id,
         _correlation_id,
         _causation_id
       ) do
    with {:ok, state} <- ensure_workspace_binding(state, workspace_root),
         {:ok, state} <- ensure_goal_binding(state, project_id, goal_id) do
      {:ok, state}
    else
      {:error, reason} -> close_and_stop(state, reason)
    end
  end

  defp ensure_workspace_binding(state, workspace_root) do
    case bound_workspace(state.events) do
      nil ->
        case persist(state, :workspace_bound, %{
               "workspace_root" => workspace_root,
               "reason" => "legacy_session"
             }) do
          {:ok, _event, state} -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end

      ^workspace_root ->
        {:ok, state}

      existing ->
        {:error, {:workspace_mismatch, existing, workspace_root}}
    end
  end

  defp ensure_goal_binding(state, project_id, goal_id) do
    case bound_goal(state.events) do
      nil ->
        case persist(state, :goal_bound, %{
               "project_id" => project_id,
               "goal_id" => goal_id,
               "reason" => "legacy_session"
             }) do
          {:ok, _event, state} -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end

      {^project_id, ^goal_id} ->
        {:ok, state}

      {existing_project_id, existing_goal_id} ->
        {:error, {:goal_mismatch, existing_project_id, existing_goal_id, project_id, goal_id}}
    end
  end

  defp bound_workspace(events) do
    Enum.find_value(events, fn
      %{"type" => type, "data" => %{"workspace_root" => root}}
      when type in ["session_started", "workspace_bound"] and is_binary(root) ->
        root

      _event ->
        nil
    end)
  end

  defp bound_goal(events) do
    Enum.find_value(events, fn
      %{
        "type" => type,
        "data" => %{"project_id" => project_id, "goal_id" => goal_id}
      }
      when type in ["session_started", "goal_bound"] and is_binary(project_id) and
             is_binary(goal_id) ->
        {project_id, goal_id}

      _event ->
        nil
    end)
  end

  defp close_and_stop(state, reason) do
    _ = File.close(state.io)
    {:stop, reason}
  end

  defp to_message(%{"type" => "user_message", "data" => data}) do
    [
      %{
        role: :user,
        content:
          FileReference.render_prompt(data["content"] || "", data["file_references"] || []),
        attachments: data["attachments"] || []
      }
    ]
  end

  defp to_message(%{"type" => "assistant_message", "data" => data}) do
    [
      %{
        role: :assistant,
        content: data["content"],
        tool_calls: atomize_tool_calls(data["tool_calls"] || [])
      }
    ]
  end

  defp to_message(%{"type" => "tool_result", "data" => data}) do
    [
      %{
        role: :tool,
        tool_call_id: data["tool_call_id"],
        name: data["name"],
        content: data["content"],
        is_error: data["is_error"] || false,
        error: data["error"]
      }
    ]
  end

  defp to_message(%{"type" => "verification_feedback", "data" => data}) do
    [%{role: :user, content: data["content"] || "Verification failed; continue the task."}]
  end

  defp to_message(%{"type" => "review_feedback", "data" => data}) do
    [%{role: :user, content: data["content"] || "Review failed; continue the task."}]
  end

  defp to_message(_event), do: []

  defp atomize_tool_calls(calls) do
    Enum.map(calls, fn call ->
      %{id: call["id"], name: call["name"], arguments: call["arguments"]}
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  defp stringify_keys(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> stringify_keys()

  defp stringify_keys(nil), do: nil
  defp stringify_keys(true), do: true
  defp stringify_keys(false), do: false
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp metadata_value(metadata, key, default) do
    if Keyword.has_key?(metadata, key), do: Keyword.get(metadata, key), else: default
  end

  defp last_event_id([]), do: nil

  defp last_event_id(events) do
    event = List.last(events)
    "#{event["session_id"]}:#{event["seq"]}"
  end

  defp restored_correlation(events) do
    Enum.reduce(events, nil, fn event, correlation_id ->
      cond do
        event["type"] in [
          "turn_finished",
          "turn_cancelled",
          "turn_worker_failed",
          "command_failed"
        ] ->
          nil

        is_binary(event["correlation_id"]) ->
          event["correlation_id"]

        true ->
          correlation_id
      end
    end)
  end
end
