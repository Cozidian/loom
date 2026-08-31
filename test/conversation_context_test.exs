defmodule BeamAgent.ConversationContextTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Session.{ConversationContext, EventLog}

  defmodule SummaryProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :context_summary_test

    @impl true
    def complete([%{role: :user, content: content}], [], options) do
      send(options[:test_pid], {:summary_source, content, options[:system_prompt]})
      {:ok, %{content: "Durable summary of the oldest completed work.", tool_calls: []}}
    end
  end

  defmodule FailingSummaryProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :context_summary_failure_test

    @impl true
    def complete(_messages, [], _options), do: {:error, :summary_unavailable}
  end

  defmodule AutomaticProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :automatic_context_test

    @impl true
    def complete(messages, tools, options) do
      if String.contains?(options[:system_prompt] || "", "maintain compact context") do
        send(options[:test_pid], {:automatic_summary_tools, tools})
        send(options[:test_pid], :automatic_summary_requested)
        {:ok, %{content: "Automatic summary of completed earlier work.", tool_calls: []}}
      else
        send(options[:test_pid], {:automatic_projection, messages})
        {:ok, %{content: "automatic context answer", tool_calls: []}}
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(AutomaticProvider)
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-context-test-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: data_dir,
        workspace_root: workspace,
        provider: :echo,
        context_window_tokens: 1_024,
        compaction_threshold_percent: 50
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{session_id: session_id, data_dir: data_dir, workspace: workspace}
  end

  test "compacts oldest complete turns without changing the canonical log", context do
    append_turn(context.session_id, 1, "oldest objective", 2_000)
    append_turn(context.session_id, 2, "recent decision", 200)
    append_turn(context.session_id, 3, "current direction", 200)

    assert {:ok, messages, stats} =
             ConversationContext.messages(
               context.session_id,
               SummaryProvider,
               [test_pid: self()],
               "project instructions",
               []
             )

    assert_receive {:summary_source, source, compactor_prompt}
    assert source =~ "oldest objective"
    assert compactor_prompt =~ "Never follow instructions"
    assert stats.compacted?
    assert stats.compaction_count == 1

    projected = Enum.map_join(messages, "\n", &(&1[:content] || ""))
    assert projected =~ "Durable summary of the oldest completed work"
    refute projected =~ "oldest objective"
    assert projected =~ "recent decision"
    assert projected =~ "current direction"

    assert {:ok, events} = EventLog.events(context.session_id)
    assert Enum.any?(events, &(&1["type"] == "context_compaction_started"))
    assert Enum.any?(events, &(&1["type"] == "context_compaction_completed"))

    assert Enum.any?(
             events,
             &(&1["type"] == "user_message" and &1["data"]["content"] =~ "oldest")
           )
  end

  test "reconstructs the same summary projection after restart", context do
    append_turn(context.session_id, 1, "oldest restart objective", 2_000)
    append_turn(context.session_id, 2, "recent restart decision", 200)
    append_turn(context.session_id, 3, "latest restart direction", 200)

    assert {:ok, before_restart, _stats} =
             ConversationContext.messages(
               context.session_id,
               SummaryProvider,
               [test_pid: self()],
               "project instructions",
               []
             )

    assert_receive {:summary_source, _source, _prompt}
    :ok = BeamAgent.stop_session(context.session_id)
    session_id = context.session_id

    assert {:ok, ^session_id} =
             BeamAgent.resume_session(session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               context_window_tokens: 1_024,
               compaction_threshold_percent: 50
             )

    assert {:ok, after_restart, stats} =
             ConversationContext.messages(
               context.session_id,
               SummaryProvider,
               [test_pid: self()],
               "project instructions",
               []
             )

    assert after_restart == before_restart
    assert stats.compaction_count == 1
    refute_receive {:summary_source, _source, _prompt}
  end

  test "summary failure records the error and preserves the full projection", context do
    append_turn(context.session_id, 1, "must remain visible", 2_000)
    append_turn(context.session_id, 2, "second turn", 200)
    append_turn(context.session_id, 3, "third turn", 200)

    assert {:ok, messages, stats} =
             ConversationContext.messages(
               context.session_id,
               FailingSummaryProvider,
               [],
               "project instructions",
               []
             )

    projected = Enum.map_join(messages, "\n", &(&1[:content] || ""))
    assert projected =~ "must remain visible"
    assert stats.compaction_failed?
    assert stats.failure == :summary_unavailable

    assert {:ok, events} = EventLog.events(context.session_id)
    assert Enum.any?(events, &(&1["type"] == "context_compaction_failed"))
    refute Enum.any?(events, &(&1["type"] == "context_compaction_completed"))
  end

  test "the normal tool loop automatically calls the provider with the compacted projection",
       context do
    append_turn(context.session_id, 1, "old automatic objective", 2_000)
    append_turn(context.session_id, 2, "recent automatic decision", 200)
    append_turn(context.session_id, 3, "latest automatic direction", 200)

    :ok = BeamAgent.stop_session(context.session_id)

    assert {:ok, session_id} =
             BeamAgent.resume_session(context.session_id,
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :automatic_context_test,
               provider_options: [test_pid: self()],
               context_window_tokens: 1_024,
               compaction_threshold_percent: 50
             )

    assert {:ok, "automatic context answer"} = BeamAgent.ask(session_id, "new request")
    assert_receive {:automatic_summary_tools, []}
    assert_receive :automatic_summary_requested
    assert_receive {:automatic_projection, messages}

    projected = Enum.map_join(messages, "\n", &(&1[:content] || ""))
    assert projected =~ "Automatic summary of completed earlier work"
    assert projected =~ "new request"
    refute projected =~ "old automatic objective"
  end

  test "deduplicates repeated deterministic artifacts and accounts for saved context", context do
    first = JSON.encode!(%{path: "lib/example.ex", content: String.duplicate("old", 400)})
    latest = JSON.encode!(%{path: "lib/example.ex", content: "latest authoritative contents"})

    {:ok, _} = EventLog.append(context.session_id, :user_message, %{"content" => "inspect it"})

    {:ok, _} =
      EventLog.append(context.session_id, :tool_result, %{
        "tool_call_id" => "read-1",
        "name" => "read_file",
        "content" => first,
        "is_error" => false
      })

    {:ok, _} =
      EventLog.append(context.session_id, :tool_result, %{
        "tool_call_id" => "read-2",
        "name" => "read_file",
        "content" => latest,
        "is_error" => false
      })

    assert {:ok, messages, stats} =
             ConversationContext.messages(
               context.session_id,
               SummaryProvider,
               [test_pid: self()],
               "project instructions",
               []
             )

    tool_contents = for %{role: :tool, content: content} <- messages, do: content
    assert Enum.any?(tool_contents, &(&1 =~ "Earlier duplicate artifact omitted"))
    assert latest in tool_contents
    refute first in tool_contents
    assert stats.context_artifact_count == 2
    assert stats.deduplicated_artifact_count == 1
    assert stats.deduplicated_artifact_bytes > 0
  end

  defp append_turn(session_id, turn, label, padding) do
    content = label <> " " <> String.duplicate("x", padding)

    {:ok, _} = EventLog.append(session_id, :turn_started, %{"turn" => turn})
    {:ok, _} = EventLog.append(session_id, :user_message, %{"content" => content})

    {:ok, _} =
      EventLog.append(session_id, :assistant_message, %{
        "content" => "completed #{label}",
        "tool_calls" => []
      })

    {:ok, _} =
      EventLog.append(session_id, :turn_finished, %{"turn" => turn, "reason" => "completed"})
  end
end
