defmodule BeamAgent.RuntimeGoalTree do
  @moduledoc """
  Pure projection of a goal tree from canonical runtime events.

  Derives a nested worker tree for a goal from durable events only.
  No interface-owned domain state; the tree is a fold over goal_events/2.

  Each node carries only safe, observable metadata:
  - session/worker ID and parent relationship
  - root or subagent role
  - derived state: idle | running | completed | failed | cancelled
  - last actually routed endpoint/provider/model (when observed)
  - current or most recent tool name (when observed)
  - duration (derived from turn windows when timestamps available)
  - failure/restart counts (from failure and spawn events when available)

  Public view is enforced by callers; this module assumes already-projected
  safe events (no prompts, arguments, secrets, or raw model content).
  """

  @type state :: :idle | :running | :completed | :failed | :cancelled
  @type role :: :root | :subagent

  @type worker_node :: %{
          session_id: String.t(),
          worker_id: String.t(),
          parent_session_id: String.t() | nil,
          role: role(),
          state: state(),
          last_routed: map() | nil,
          last_tool: String.t() | nil,
          last_tool_state: state() | nil,
          duration_ms: non_neg_integer() | nil,
          failure_count: non_neg_integer(),
          restart_count: non_neg_integer(),
          children: [worker_node()]
        }

  @type tree :: %{root: worker_node() | nil, nodes: %{String.t() => worker_node()}}

  @doc """
  Project a flat list of runtime events (from goal_events/2 or inspect) into a tree.

  Events must be in goal_seq order for deterministic derivation. Only durable
  events are considered for structural state; ephemeral signals are ignored.
  """
  @spec project([map()]) :: tree()
  def project(events) when is_list(events) do
    ordered =
      events
      |> Enum.filter(&durable?/1)
      |> Enum.sort_by(&goal_sequence/1)

    nodes =
      Enum.reduce(ordered, %{}, fn event, acc ->
        update_nodes(acc, event)
      end)

    root =
      nodes
      |> Map.values()
      |> Enum.find(fn n -> n.role == :root end)

    %{root: root, nodes: nodes}
  end

  defp durable?(%{durability: :durable}), do: true
  defp durable?(%{"durability" => "durable"}), do: true
  defp durable?(_), do: false

  defp update_nodes(nodes, %{payload: %{type: type, data: data}} = event) do
    update_nodes(nodes, type, data, event)
  end

  defp update_nodes(nodes, %{payload: %{"type" => type, "data" => data}} = event) do
    update_nodes(nodes, type, data, event)
  end

  defp update_nodes(nodes, %{"payload" => %{"type" => type, "data" => data}} = event) do
    update_nodes(nodes, type, data, event)
  end

  defp update_nodes(nodes, _event), do: nodes

  defp update_nodes(nodes, "session_started", data, event) do
    session_id = scope_session_id(event)
    parent = data["parent_session_id"] || data[:parent_session_id]
    role = if parent in [nil, ""], do: :root, else: :subagent

    node =
      Map.get(nodes, session_id, new_node(session_id, parent, role))
      |> Map.put(:parent_session_id, parent)
      |> Map.put(:role, role)

    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "agent_started", data, event) do
    session_id = scope_session_id(event)

    routed = %{
      endpoint_id: data["endpoint_id"] || data[:endpoint_id],
      provider: data["provider"] || data[:provider],
      model: data["model"] || data[:model]
    }

    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))

    node =
      node
      |> Map.put(
        :last_routed,
        if(routed[:endpoint_id] || routed["endpoint_id"], do: routed, else: node.last_routed)
      )

    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "model_route_selected", data, event) do
    session_id = scope_session_id(event)

    routed = %{
      endpoint_id: data["selected_endpoint_id"] || data[:selected_endpoint_id],
      provider: data["provider"] || data[:provider],
      model: data["model"] || data[:model]
    }

    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))

    node =
      if routed.endpoint_id do
        Map.put(node, :last_routed, routed)
      else
        node
      end

    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "model_response_started", data, event) do
    session_id = scope_session_id(event)
    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))

    routed = %{
      endpoint_id:
        data["endpoint_id"] || data[:endpoint_id] || data["provider_profile"] ||
          data[:provider_profile] || routed_value(node.last_routed, :endpoint_id),
      provider: data["provider"] || data[:provider] || routed_value(node.last_routed, :provider),
      model: data["model"] || data[:model] || routed_value(node.last_routed, :model)
    }

    if Enum.any?(Map.values(routed), &present?/1) do
      Map.put(nodes, session_id, %{node | last_routed: routed})
    else
      nodes
    end
  end

  defp update_nodes(nodes, "tool_called", data, event) do
    session_id = scope_session_id(event)
    tool = data["name"] || data[:name]

    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))

    node =
      if tool do
        node
        |> Map.put(:last_tool, tool)
        |> Map.put(:last_tool_state, :running)
      else
        node
      end

    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "tool_result", data, event) do
    session_id = scope_session_id(event)
    tool = data["name"] || data[:name]
    failed? = data["is_error"] == true || data[:is_error] == true
    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))

    node =
      node
      |> maybe_put(:last_tool, tool)
      |> Map.put(:last_tool_state, if(failed?, do: :failed, else: :completed))

    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "turn_started", _data, event) do
    session_id = scope_session_id(event)
    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))
    node = %{node | state: :running, started_at: event_at(event)}
    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "turn_finished", data, event) do
    session_id = scope_session_id(event)
    state = turn_finished_state(data)

    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))

    finished_at = event_at(event)
    duration = compute_duration(node[:started_at], finished_at)

    node =
      node
      |> Map.put(:state, state)
      |> Map.put(:duration_ms, duration || node[:duration_ms])

    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "turn_cancelled", _data, event) do
    session_id = scope_session_id(event)
    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))
    node = %{node | state: :cancelled}
    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "turn_worker_failed", _data, event) do
    session_id = scope_session_id(event)
    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))
    node = %{node | state: :failed, failure_count: (node.failure_count || 0) + 1}
    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "command_failed", _data, event) do
    session_id = scope_session_id(event)
    node = Map.get(nodes, session_id, new_node(session_id, nil, role_from_scope(event)))
    node = %{node | failure_count: (node.failure_count || 0) + 1}
    Map.put(nodes, session_id, node)
  end

  defp update_nodes(nodes, "subagent_spawned", data, event) do
    child_id = data["child_session_id"] || data[:child_session_id]

    if child_id do
      parent_session_id = scope_session_id(event)
      node = Map.get(nodes, child_id, new_node(child_id, parent_session_id, :subagent))

      node =
        node
        |> Map.put(:role, :subagent)
        |> maybe_put_parent(parent_session_id)

      Map.put(nodes, child_id, node)
    else
      nodes
    end
  end

  defp update_nodes(nodes, _type, _data, _event), do: nodes

  defp new_node(session_id, parent, role) do
    %{
      session_id: session_id,
      worker_id: session_id,
      parent_session_id: parent,
      role: role,
      state: :idle,
      last_routed: nil,
      last_tool: nil,
      last_tool_state: nil,
      duration_ms: nil,
      failure_count: 0,
      restart_count: 0,
      children: [],
      started_at: nil
    }
  end

  defp scope_session_id(%{scope: %{session_id: sid}}), do: sid
  defp scope_session_id(%{"scope" => %{"session_id" => sid}}), do: sid
  defp scope_session_id(_), do: nil

  defp goal_sequence(event), do: event[:goal_seq] || event["goal_seq"] || 0

  defp role_from_scope(%{scope: %{root?: true}}), do: :root
  defp role_from_scope(%{"scope" => %{"root?" => true}}), do: :root
  defp role_from_scope(_), do: :subagent

  defp event_at(%{at: at}) when is_binary(at), do: at
  defp event_at(%{"at" => at}) when is_binary(at), do: at
  defp event_at(_), do: nil

  defp compute_duration(nil, _), do: nil
  defp compute_duration(_, nil), do: nil

  defp compute_duration(start, finish) when is_binary(start) and is_binary(finish) do
    with {:ok, s, _} <- DateTime.from_iso8601(start),
         {:ok, f, _} <- DateTime.from_iso8601(finish) do
      max(0, DateTime.diff(f, s, :millisecond))
    else
      _ -> nil
    end
  end

  defp compute_duration(_, _), do: nil

  defp routed_value(nil, _key), do: nil
  defp routed_value(routed, key), do: routed[key] || routed[to_string(key)]

  defp present?(value), do: not is_nil(value) and value != ""

  defp maybe_put(node, _key, nil), do: node
  defp maybe_put(node, key, value), do: Map.put(node, key, value)

  defp maybe_put_parent(%{parent_session_id: parent} = node, parent_session_id)
       when parent in [nil, ""] and is_binary(parent_session_id),
       do: %{node | parent_session_id: parent_session_id}

  defp maybe_put_parent(node, _parent_session_id), do: node

  defp turn_finished_state(data) do
    reason = data["reason"] || data[:reason]
    error = data["error"] || data[:error]

    cond do
      reason in ["error", :error] -> :failed
      reason in ["cancelled", :cancelled] -> :cancelled
      reason in ["completed", :completed] -> :completed
      not is_nil(error) -> :failed
      true -> :completed
    end
  end

  @doc """
  Render a compact nested tree for display (TUI panel or terminal).

  Example:
      Goal session-abcd · completed
      └── Subagent session-efgh · completed · ollama/qwen3:8b
          └── add · completed
  """
  @spec render(tree()) :: [String.t()]
  def render(%{root: nil}), do: ["No active goal tree"]

  def render(%{root: root}) do
    header = "Goal #{short(root.session_id)} · #{root.state}"

    header =
      case root.last_routed do
        %{provider: p, model: m} when is_binary(p) and is_binary(m) and m != "" ->
          header <> " · #{p}/#{m}"

        _ ->
          header
      end

    [header | render_entries(root, "")]
  end

  defp render_node(node, prefix, is_last) do
    connector = if is_last, do: "└── ", else: "├── "
    line = prefix <> connector <> node_label(node)

    child_prefix = prefix <> if is_last, do: "    ", else: "│   "
    [line | render_entries(node, child_prefix)]
  end

  defp render_entries(node, prefix) do
    entries =
      Enum.map(node.children, &{:node, &1}) ++
        if node.last_tool do
          [{:tool, node.last_tool, node.last_tool_state || :running}]
        else
          []
        end

    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      last_child = idx == length(entries) - 1

      case entry do
        {:node, child} ->
          render_node(child, prefix, last_child)

        {:tool, name, state} ->
          child_connector = if last_child, do: "└── ", else: "├── "
          [prefix <> child_connector <> "#{name} · #{state}"]
      end
    end)
  end

  defp node_label(node) do
    base =
      case node.role do
        :root -> "Goal #{short(node.session_id)} · #{node.state}"
        :subagent -> "Subagent #{short(node.session_id)} · #{node.state}"
      end

    routed =
      case node.last_routed do
        %{provider: p, model: m} when is_binary(p) and p != "" and is_binary(m) ->
          " · #{p}/#{m || "default"}"

        %{endpoint_id: eid} when is_binary(eid) and eid != "" ->
          " · #{eid}"

        _ ->
          ""
      end

    base <> routed
  end

  defp short(id) when is_binary(id) do
    id
    |> String.replace_prefix("session-", "")
    |> String.slice(0, 8)
  end

  defp short(id), do: to_string(id)

  @doc """
  Build a nested tree structure (children populated) from the flat node map.

  Call after project/1 when you need the recursive shape for rendering or
  external consumers. Pure and deterministic given the node map.
  """
  @spec nest(tree()) :: tree()
  def nest(%{nodes: nodes} = tree) when is_map(nodes) do
    by_parent =
      nodes
      |> Map.values()
      |> Enum.group_by(& &1.parent_session_id)

    nested_nodes =
      Enum.into(nodes, %{}, fn {sid, _node} ->
        {sid, build_nested_node(sid, nodes, by_parent, MapSet.new())}
      end)

    root =
      nested_nodes
      |> Map.values()
      |> Enum.find(fn n -> n.role == :root end)

    %{tree | nodes: nested_nodes, root: root}
  end

  def nest(tree), do: tree

  defp build_nested_node(session_id, nodes, by_parent, ancestors) do
    node = Map.fetch!(nodes, session_id)

    if MapSet.member?(ancestors, session_id) do
      %{node | children: []}
    else
      ancestors = MapSet.put(ancestors, session_id)

      children =
        (by_parent[session_id] || [])
        |> Enum.reject(&(&1.session_id == session_id))
        |> Enum.sort_by(& &1.session_id)
        |> Enum.map(&build_nested_node(&1.session_id, nodes, by_parent, ancestors))

      %{node | children: children}
    end
  end
end
