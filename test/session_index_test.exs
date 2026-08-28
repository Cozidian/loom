defmodule BeamAgent.SessionIndexTest do
  use ExUnit.Case, async: false

  alias BeamAgent.SessionIndex

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-session-index-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir}
  end

  defp write_session(data_dir, session_id, events) do
    directory = Path.join(data_dir, session_id)
    File.mkdir_p!(directory)

    contents =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} ->
        event
        |> Map.put_new("seq", index)
        |> Map.put_new("goal_seq", index + 100)
        |> Map.put_new("session_id", session_id)
        |> Map.put_new("data", %{})
        |> JSON.encode!()
      end)
      |> Enum.join("\n")

    File.write!(Path.join(directory, "events.jsonl"), contents <> "\n")
    directory
  end

  defp started(parent, workspace_root \\ "/tmp/workspace") do
    %{
      "type" => "session_started",
      "at" => "2026-08-28T09:00:00.000000Z",
      "data" => %{"parent_session_id" => parent, "workspace_root" => workspace_root}
    }
  end

  test "list returns root sessions newest first and skips subagent logs", %{data_dir: data_dir} do
    older = write_session(data_dir, "session-old", [started(nil, "/tmp/old")])
    newer = write_session(data_dir, "session-new", [started(nil, "/tmp/new")])
    write_session(data_dir, "session-child", [started("session-old")])

    File.touch!(Path.join(older, "events.jsonl"), 1_700_000_000)
    File.touch!(Path.join(newer, "events.jsonl"), 1_800_000_000)

    assert {:ok, sessions} = SessionIndex.list(data_dir)
    assert Enum.map(sessions, & &1.session_id) == ["session-new", "session-old"]

    assert [%{workspace_root: "/tmp/new", mtime: 1_800_000_000}, %{workspace_root: "/tmp/old"}] =
             sessions
  end

  test "list ignores directories without an event log", %{data_dir: data_dir} do
    write_session(data_dir, "session-real", [started(nil)])
    File.mkdir_p!(Path.join(data_dir, "projects"))
    File.write!(Path.join(data_dir, "stray.txt"), "not a session")

    assert {:ok, [%{session_id: "session-real"}]} = SessionIndex.list(data_dir)
  end

  test "list honours the limit option", %{data_dir: data_dir} do
    for index <- 1..5 do
      directory = write_session(data_dir, "session-#{index}", [started(nil)])
      File.touch!(Path.join(directory, "events.jsonl"), 1_700_000_000 + index)
    end

    assert {:ok, sessions} = SessionIndex.list(data_dir, limit: 2)
    assert Enum.map(sessions, & &1.session_id) == ["session-5", "session-4"]
  end

  test "list reports an error for a missing data directory" do
    assert {:error, :enoent} = SessionIndex.list("/nonexistent/beam-agent-data-dir")
  end

  test "summarize folds turns, tokens and identity out of the log", %{data_dir: data_dir} do
    write_session(data_dir, "session-main", [
      started(nil),
      %{
        "type" => "agent_started",
        "at" => "2026-08-28T09:00:01.000000Z",
        "data" => %{"provider" => "open_ai", "model" => "gpt-5"}
      },
      %{
        "type" => "user_message",
        "at" => "2026-08-28T09:00:02.000000Z",
        "data" => %{"content" => "First question"}
      },
      %{
        "type" => "model_response_finished",
        "at" => "2026-08-28T09:00:03.000000Z",
        "data" => %{"usage" => %{"total_tokens" => 120}}
      },
      %{
        "type" => "user_message",
        "at" => "2026-08-28T09:00:04.000000Z",
        "data" => %{"content" => "Second question"}
      },
      %{
        "type" => "model_response_finished",
        "at" => "2026-08-28T09:00:05.000000Z",
        "data" => %{"usage" => %{"total_tokens" => 80}}
      },
      %{
        "type" => "turn_finished",
        "at" => "2026-08-28T09:00:06.000000Z",
        "goal_seq" => 999,
        "data" => %{}
      }
    ])

    assert {:ok, summary} = SessionIndex.summarize(data_dir, "session-main")
    assert summary.session_id == "session-main"
    assert summary.provider == "open_ai"
    assert summary.model == "gpt-5"
    assert summary.turn_count == 2
    assert summary.total_tokens == 200
    assert summary.last_active_at == "2026-08-28T09:00:06.000000Z"
    assert summary.last_seq == 999
    assert summary.goal_preview == "First question"
  end

  test "summarize tolerates absent usage totals", %{data_dir: data_dir} do
    write_session(data_dir, "session-demo", [
      started(nil),
      %{
        "type" => "model_response_finished",
        "at" => "2026-08-28T09:00:01.000000Z",
        "data" => %{"usage" => %{"total_tokens" => nil}}
      },
      %{"type" => "model_response_finished", "at" => "2026-08-28T09:00:02.000000Z", "data" => %{}}
    ])

    assert {:ok, summary} = SessionIndex.summarize(data_dir, "session-demo")
    assert summary.total_tokens == 0
    assert summary.turn_count == 0
    assert summary.provider == nil
    assert summary.goal_preview == nil
  end

  test "summarize truncates a long goal preview", %{data_dir: data_dir} do
    content = String.duplicate("a", 200)

    write_session(data_dir, "session-long", [
      started(nil),
      %{
        "type" => "user_message",
        "at" => "2026-08-28T09:00:01.000000Z",
        "data" => %{"content" => content}
      }
    ])

    assert {:ok, summary} = SessionIndex.summarize(data_dir, "session-long")
    assert summary.goal_preview == String.duplicate("a", 120) <> "…"
  end

  test "summarize rejects unknown and unsafe session ids", %{data_dir: data_dir} do
    assert {:error, :session_not_found} = SessionIndex.summarize(data_dir, "session-missing")
    assert {:error, :invalid_session_id} = SessionIndex.summarize(data_dir, "../escape")
    assert {:error, :invalid_session_id} = SessionIndex.summarize(data_dir, "a/b")
  end

  test "the index sees sessions written by a live run" do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-session-index-live-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(data_dir) end)

    {:ok, session_id} = BeamAgent.start_session(data_dir: data_dir, provider: :demo)
    {:ok, _answer} = BeamAgent.ask(session_id, "Calculate 2 + 3 and delegate verification.")

    assert {:ok, sessions} = BeamAgent.sessions(data_dir)
    assert Enum.map(sessions, & &1.session_id) == [session_id]

    assert {:ok, summary} = BeamAgent.session_detail(data_dir, session_id)
    assert summary.provider == "demo"
    assert summary.turn_count >= 1
    assert summary.goal_preview =~ "2 + 3"
    assert is_integer(summary.last_seq)
  end
end
