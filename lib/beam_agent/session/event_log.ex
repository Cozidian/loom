defmodule BeamAgent.Session.EventLog do
  @moduledoc "A session-owned, synchronous append-only JSONL event log."
  use GenServer

  alias BeamAgent.Names
  alias BeamAgent.Session.StreamHub

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:event_log, id))
  end

  def append(session_id, type, data) when is_map(data) do
    with {:ok, pid} <- Names.pid(:event_log, session_id) do
      GenServer.call(pid, {:append, type, data})
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

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    parent_session_id = Keyword.get(opts, :parent_session_id)
    data_dir = Keyword.fetch!(opts, :data_dir)
    directory = Path.join(data_dir, session_id)
    path = Path.join(directory, "events.jsonl")

    with :ok <- File.mkdir_p(directory),
         {:ok, events} <- load(path),
         {:ok, io} <- File.open(path, [:append, :binary, :utf8]) do
      state = %{session_id: session_id, path: path, io: io, events: events}
      initialize_log(state, parent_session_id, Keyword.fetch!(opts, :workspace_root))
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append, type, data}, _from, state) do
    case persist(state, type, data) do
      {:ok, event, next} -> {:reply, {:ok, event}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:events, _from, state), do: {:reply, {:ok, state.events}, state}
  def handle_call(:path, _from, state), do: {:reply, {:ok, state.path}, state}

  @impl true
  def terminate(_reason, state), do: File.close(state.io)

  defp persist(state, type, data) do
    event = %{
      "seq" => length(state.events),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "session_id" => state.session_id,
      "type" => to_string(type),
      "data" => stringify_keys(data)
    }

    try do
      encoded = JSON.encode!(event)

      with :ok <- IO.binwrite(state.io, [encoded, "\n"]),
           :ok <- :file.sync(state.io) do
        StreamHub.publish_event(state.session_id, event)
        {:ok, event, %{state | events: state.events ++ [event]}}
      end
    rescue
      error -> {:error, {:invalid_event, Exception.message(error)}}
    end
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

  defp initialize_log(%{events: []} = state, parent_session_id, workspace_root) do
    case persist(state, :session_started, %{
           "parent_session_id" => parent_session_id,
           "workspace_root" => workspace_root
         }) do
      {:ok, _event, state} -> {:ok, state}
      {:error, reason} -> close_and_stop(state, reason)
    end
  end

  defp initialize_log(state, _parent_session_id, workspace_root) do
    case bound_workspace(state.events) do
      nil ->
        case persist(state, :workspace_bound, %{
               "workspace_root" => workspace_root,
               "reason" => "legacy_session"
             }) do
          {:ok, _event, state} -> {:ok, state}
          {:error, reason} -> close_and_stop(state, reason)
        end

      ^workspace_root ->
        {:ok, state}

      existing ->
        close_and_stop(state, {:workspace_mismatch, existing, workspace_root})
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

  defp close_and_stop(state, reason) do
    _ = File.close(state.io)
    {:stop, reason}
  end

  defp to_message(%{"type" => "user_message", "data" => data}) do
    [%{role: :user, content: data["content"]}]
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
end
