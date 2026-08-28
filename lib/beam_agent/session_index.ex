defmodule BeamAgent.SessionIndex do
  @moduledoc """
  Two-phase index over the durable session logs in a data directory.

  `list/2` is the cheap phase: it stats each session directory and peeks only the
  first line of its log, so listing stays proportional to the number of sessions
  rather than to their length. `summarize/2` is the expensive phase and is
  bounded to a single session.
  """

  @preview_length 120

  @type entry :: %{session_id: String.t(), workspace_root: String.t() | nil, mtime: integer()}

  @doc """
  Lists root sessions, most recently written first.

  Sessions whose first event carries a `parent_session_id` are subagent logs and
  are excluded.
  """
  @spec list(String.t(), keyword()) :: {:ok, [entry()]} | {:error, term()}
  def list(data_dir, opts \\ []) when is_binary(data_dir) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, entries} <- File.ls(data_dir) do
      {:ok,
       entries
       |> Enum.flat_map(&root_session(data_dir, &1))
       |> Enum.sort_by(& &1.mtime, :desc)
       |> Enum.take(limit)}
    end
  end

  @doc """
  Folds one session's event log into a summary.

  `total_tokens` covers only this session's own model responses. Subagent worker
  usage is deliberately excluded: attributing it would mean walking every sibling
  directory's parent chain, which is exactly the cost `list/2` is designed to
  avoid.
  """
  @spec summarize(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def summarize(data_dir, session_id) when is_binary(data_dir) and is_binary(session_id) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, session_id) do
      path = log_path(data_dir, session_id)

      if File.regular?(path),
        do: {:ok, fold(path, session_id)},
        else: {:error, :session_not_found}
    else
      {:error, :invalid_session_id}
    end
  end

  defp fold(path, session_id) do
    path
    |> File.stream!()
    |> Stream.map(&JSON.decode!/1)
    |> Enum.reduce(
      %{
        session_id: session_id,
        provider: nil,
        model: nil,
        turn_count: 0,
        total_tokens: 0,
        last_active_at: nil,
        last_seq: nil,
        goal_preview: nil
      },
      &accumulate/2
    )
  end

  defp accumulate(event, summary) do
    summary
    |> Map.put(:last_active_at, event["at"] || summary.last_active_at)
    |> Map.put(:last_seq, event["goal_seq"] || event["seq"] || summary.last_seq)
    |> accumulate(event["type"], event["data"] || %{})
  end

  defp accumulate(summary, "user_message", data) do
    %{
      summary
      | turn_count: summary.turn_count + 1,
        goal_preview: summary.goal_preview || preview(data["content"])
    }
  end

  defp accumulate(summary, "agent_started", data) do
    %{
      summary
      | provider: data["provider"] || summary.provider,
        model: data["model"] || summary.model
    }
  end

  defp accumulate(summary, "model_response_finished", data) do
    usage = data["usage"] || %{}
    total = usage["total_tokens"]

    if is_number(total),
      do: %{summary | total_tokens: summary.total_tokens + total},
      else: summary
  end

  defp accumulate(summary, _type, _data), do: summary

  defp preview(content) when is_binary(content) do
    if String.length(content) > @preview_length,
      do: String.slice(content, 0, @preview_length) <> "…",
      else: content
  end

  defp preview(_content), do: nil

  defp root_session(data_dir, session_id) do
    path = log_path(data_dir, session_id)

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        data = first_event_data(path)

        if is_nil(data["parent_session_id"]),
          do: [%{session_id: session_id, workspace_root: data["workspace_root"], mtime: mtime}],
          else: []

      _other ->
        []
    end
  end

  defp first_event_data(path) do
    file = File.open!(path, [:read, :binary])

    try do
      with line when is_binary(line) <- IO.read(file, :line),
           {:ok, %{"data" => data}} when is_map(data) <- JSON.decode(line) do
        data
      else
        _other -> %{}
      end
    after
      File.close(file)
    end
  end

  defp log_path(data_dir, session_id), do: Path.join([data_dir, session_id, "events.jsonl"])
end
