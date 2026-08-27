defmodule BeamAgent.RuntimeGoalTreeTest do
  use ExUnit.Case, async: true

  alias BeamAgent.{RuntimeEventView, RuntimeGoalTree}

  defp rt_event(goal_seq, type, data, scope_overrides \\ %{}) do
    scope =
      Map.merge(
        %{project_id: "p", goal_id: "g", session_id: "g", worker_id: "g", root?: true},
        scope_overrides
      )

    %{
      type: :runtime_event,
      version: 1,
      event_id: "e-#{goal_seq}",
      goal_seq: goal_seq,
      at: "2026-01-01T00:00:#{String.pad_leading(to_string(goal_seq), 2, "0")}Z",
      durability: :durable,
      scope: scope,
      payload: %{type: type, data: data}
    }
  end

  test "projects a root-only goal with completed state" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "agent_started", %{"provider" => "echo", "model" => nil}),
      rt_event(3, "turn_started", %{}),
      rt_event(4, "turn_finished", %{"reason" => "completed"})
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()

    assert tree.root
    assert tree.root.role == :root
    assert tree.root.state == :completed
    assert tree.root.session_id == "g"
    assert tree.root.parent_session_id in [nil, ""]
    assert tree.root.children == []
    assert is_nil(tree.root.last_routed) or tree.root.last_routed == %{}
  end

  test "projects a goal with a completed subagent and routed model" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "agent_started", %{"provider" => "echo", "model" => "default"}),
      rt_event(3, "turn_started", %{}),
      rt_event(4, "subagent_spawned", %{"child_session_id" => "child-1"}),
      rt_event(
        5,
        "session_started",
        %{"parent_session_id" => "g"},
        %{session_id: "child-1", root?: false}
      ),
      rt_event(
        6,
        "model_route_selected",
        %{"selected_endpoint_id" => "ollama/qwen", "provider" => "ollama", "model" => "qwen3:8b"},
        %{session_id: "child-1", root?: false}
      ),
      rt_event(7, "turn_started", %{}, %{session_id: "child-1", root?: false}),
      rt_event(8, "tool_called", %{"name" => "add"}, %{session_id: "child-1", root?: false}),
      rt_event(9, "turn_finished", %{"reason" => "completed"}, %{
        session_id: "child-1",
        root?: false
      }),
      rt_event(10, "turn_finished", %{"reason" => "completed"})
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()

    assert tree.root.state == :completed
    assert length(tree.root.children) == 1

    child = hd(tree.root.children)
    assert child.session_id == "child-1"
    assert child.role == :subagent
    assert child.state == :completed
    assert child.last_routed.provider == "ollama"
    assert child.last_routed.model == "qwen3:8b"
    assert child.last_tool == "add"
    assert child.children == []
  end

  test "derives running, failed, and cancelled states" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "turn_started", %{}),
      # still running (no finish)
      rt_event(3, "subagent_spawned", %{"child_session_id" => "c1"}),
      rt_event(4, "session_started", %{"parent_session_id" => "g"}, %{
        session_id: "c1",
        root?: false
      }),
      rt_event(5, "turn_started", %{}, %{session_id: "c1", root?: false}),
      rt_event(6, "turn_worker_failed", %{}, %{session_id: "c1", root?: false}),
      rt_event(7, "turn_cancelled", %{}, %{session_id: "g", root?: true})
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()

    assert tree.root.state == :cancelled
    child = hd(tree.root.children)
    assert child.state == :failed
    assert child.failure_count >= 1
  end

  test "prefers actually routed model over inherited default" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "agent_started", %{"provider" => "echo", "model" => "inherited"}),
      rt_event(3, "model_route_selected", %{
        "selected_endpoint_id" => "local"
      }),
      rt_event(4, "model_response_started", %{
        "provider_profile" => "local",
        "provider" => "ollama",
        "model" => "llama3"
      }),
      rt_event(5, "turn_finished", %{"reason" => "completed"})
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()
    routed = tree.root.last_routed
    assert routed.endpoint_id == "local"
    assert routed.provider == "ollama"
    assert routed.model == "llama3"
  end

  test "derives terminal state from fail-closed public events" do
    completed =
      rt_event(1, "turn_finished", %{"reason" => "completed"})
      |> RuntimeEventView.project(:public)

    failed =
      rt_event(2, "turn_finished", %{"reason" => "error", "error" => "private detail"})
      |> RuntimeEventView.project(:public)

    assert completed.payload.data["reason"]["redacted"]
    assert failed.payload.data["error"]["redacted"]

    completed_tree =
      [rt_event(0, "session_started", %{"parent_session_id" => nil}), completed]
      |> RuntimeGoalTree.project()
      |> RuntimeGoalTree.nest()

    failed_tree =
      [rt_event(0, "session_started", %{"parent_session_id" => nil}), failed]
      |> RuntimeGoalTree.project()
      |> RuntimeGoalTree.nest()

    assert completed_tree.root.state == :completed
    assert failed_tree.root.state == :failed
  end

  test "safe public projection does not leak prompts or arguments" do
    # Projection receives already-public events; assert it never copies raw content fields
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "tool_called", %{"name" => "run", "arguments" => %{"secret" => "x"}})
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()
    # last_tool is the safe name only
    assert tree.root.last_tool == "run"
    # no arguments surface in the node
    refute Map.has_key?(tree.root, :arguments)
  end

  test "render produces compact nested form" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "turn_finished", %{"reason" => "completed"}),
      rt_event(3, "subagent_spawned", %{"child_session_id" => "efgh"}),
      rt_event(4, "session_started", %{"parent_session_id" => "g"}, %{
        session_id: "efgh",
        root?: false
      }),
      rt_event(
        5,
        "model_route_selected",
        %{"selected_endpoint_id" => "ollama/qwen3:8b"},
        %{session_id: "efgh", root?: false}
      ),
      rt_event(6, "tool_called", %{"name" => "add"}, %{session_id: "efgh", root?: false}),
      rt_event(7, "tool_result", %{"name" => "add", "is_error" => false}, %{
        session_id: "efgh",
        root?: false
      }),
      rt_event(8, "turn_finished", %{"reason" => "completed"}, %{
        session_id: "efgh",
        root?: false
      })
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()
    lines = RuntimeGoalTree.render(tree)

    assert lines == [
             "Goal g · completed",
             "└── Subagent efgh · completed · ollama/qwen3:8b",
             "    └── add · completed"
           ]
  end

  test "renders dynamically constructed worker roles when specs are observable" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "agent_spec_applied", %{
        "spec_id" => "agent-spec-root",
        "role" => "Goal coordinator"
      }),
      rt_event(3, "subagent_spawned", %{
        "child_session_id" => "dynamic-child",
        "spec_id" => "agent-spec-child",
        "role" => "Elixir debugging specialist"
      }),
      rt_event(4, "session_started", %{"parent_session_id" => "g"}, %{
        session_id: "dynamic-child",
        root?: false
      }),
      rt_event(
        5,
        "agent_spec_applied",
        %{"spec_id" => "agent-spec-child", "role" => "Elixir debugging specialist"},
        %{session_id: "dynamic-child", root?: false}
      )
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()

    assert RuntimeGoalTree.render(tree) == [
             "Goal g · idle · Goal coordinator",
             "└── Elixir debugging specialist dynamic- · idle"
           ]
  end

  test "nests and renders descendants recursively" do
    events = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "subagent_spawned", %{"child_session_id" => "child"}),
      rt_event(3, "session_started", %{"parent_session_id" => "g"}, %{
        session_id: "child",
        root?: false
      }),
      rt_event(4, "subagent_spawned", %{"child_session_id" => "grandchild"}, %{
        session_id: "child",
        root?: false
      }),
      rt_event(5, "session_started", %{"parent_session_id" => "child"}, %{
        session_id: "grandchild",
        root?: false
      }),
      rt_event(6, "turn_finished", %{"reason" => "completed"}, %{
        session_id: "grandchild",
        root?: false
      })
    ]

    tree = RuntimeGoalTree.project(events) |> RuntimeGoalTree.nest()
    child = hd(tree.root.children)
    grandchild = hd(child.children)

    assert child.session_id == "child"
    assert grandchild.session_id == "grandchild"
    assert grandchild.state == :completed
    assert Enum.any?(RuntimeGoalTree.render(tree), &(&1 =~ "Subagent grandchi · completed"))
  end

  test "replay from events produces identical tree to live observation (idempotent fold)" do
    base = [
      rt_event(1, "session_started", %{"parent_session_id" => nil}),
      rt_event(2, "subagent_spawned", %{"child_session_id" => "c1"}),
      rt_event(3, "session_started", %{"parent_session_id" => "g"}, %{
        session_id: "c1",
        root?: false
      }),
      rt_event(4, "turn_finished", %{"reason" => "completed"}, %{session_id: "c1", root?: false}),
      rt_event(5, "turn_finished", %{"reason" => "completed"})
    ]

    live_tree = RuntimeGoalTree.project(base) |> RuntimeGoalTree.nest()

    replayed_events =
      base
      |> JSON.encode!()
      |> JSON.decode!()
      |> Enum.reverse()

    replayed_tree = RuntimeGoalTree.project(replayed_events) |> RuntimeGoalTree.nest()

    assert replayed_tree == live_tree
  end
end
