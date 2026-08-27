defmodule BeamAgent.RuntimeEventQueryTest do
  use ExUnit.Case, async: false

  alias BeamAgent.RuntimeEventQuery

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-event-query-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{data_dir: root}
  end

  test "parses the complete inspector filter vocabulary without creating atoms" do
    assert {:ok, query} =
             RuntimeEventQuery.parse(
               "category=tool,model type=tool_called,tool_result worker=children " <>
                 "session=abc corr=command- cause=session- after=4 before=30 " <>
                 "redacted=true order=desc limit=12"
             )

    assert query.categories == [:tool, :model]
    assert query.types == ["tool_called", "tool_result"]
    assert query.worker == :children
    assert query.session == "abc"
    assert query.correlation == "command-"
    assert query.causation == "session-"
    assert query.after_cursor == 4
    assert query.before_cursor == 30
    assert query.redacted
    assert query.order == :desc
    assert query.limit == 12

    assert {:error, {:invalid_event_filter_value, "category", "unknown"}} =
             RuntimeEventQuery.parse("category=unknown")

    assert {:error, {:unknown_event_filter, "secret"}} =
             RuntimeEventQuery.parse("secret=value")

    assert {:error, {:invalid_event_filter_value, "limit", "101"}} =
             RuntimeEventQuery.parse("limit=101")
  end

  test "the goal inspector filters the public parent and child projection", context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :demo)

    assert {:ok, answer} =
             BeamAgent.ask(session_id, "Calculate 2 + 3 and delegate verification.")

    assert answer =~ "subagent reported"

    assert {:ok, tools} =
             BeamAgent.inspect_goal_events(
               session_id,
               "category=tool type=tool_called worker=root order=desc limit=1"
             )

    assert tools.total > tools.matched
    assert tools.matched == 2
    assert tools.returned == 1
    assert tools.events |> hd() |> get_in([:payload, :data, "name"]) == "spawn_subagent"
    assert hd(tools.events).visibility == :public
    assert hd(tools.events).redacted?

    assert {:ok, children} =
             BeamAgent.inspect_goal_events(session_id, "worker=children category=lifecycle")

    assert children.matched > 0
    assert Enum.all?(children.events, &(not &1.scope.root?))
    assert Enum.all?(children.events, &(&1.category == :lifecycle))

    child_session = children.events |> hd() |> get_in([:scope, :session_id])
    child_prefix = child_session |> String.replace_prefix("session-", "") |> String.slice(0, 6)

    assert {:ok, by_session} =
             BeamAgent.inspect_goal_events(session_id, "session=#{child_prefix} limit=100")

    assert by_session.matched > 0
    assert Enum.all?(by_session.events, &(&1.scope.session_id == child_session))
  end
end
