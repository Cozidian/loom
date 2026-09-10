defmodule BeamAgent.ControlPlane do
  @moduledoc """
  Runtime-client-backed state for a live web control plane.

  This process is deliberately an observer/controller, never the owner of a
  goal. It can be stopped or replaced without affecting autonomous work and is
  suitable as the backing process for LiveView or another web transport.
  """
  use GenServer

  alias BeamAgent.Runtime

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def snapshot(control_plane), do: GenServer.call(control_plane, :snapshot, 30_000)
  def conversation(control_plane), do: GenServer.call(control_plane, :conversation)
  def identity(control_plane), do: GenServer.call(control_plane, :identity)
  def submit(control_plane, prompt), do: GenServer.call(control_plane, {:submit, prompt})
  def cancel(control_plane), do: GenServer.call(control_plane, :cancel)

  def approval(control_plane, approval_id, decision),
    do: GenServer.call(control_plane, {:approval, approval_id, decision})

  def verify(control_plane), do: GenServer.call(control_plane, :verify, 180_000)
  def render_html(control_plane), do: GenServer.call(control_plane, :render_html, 30_000)

  def dispatch(control_plane, request),
    do: GenServer.call(control_plane, {:dispatch, request}, 180_000)

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    owner_view? = Keyword.get(opts, :conversation, false)

    with {:ok, runtime} <-
           Runtime.connect(session_id,
             subscriber: self(),
             view: if(owner_view?, do: :internal, else: :public)
           ),
         {:ok, bootstrap} <- Runtime.bootstrap(runtime) do
      {:ok,
       %{
         runtime: runtime,
         session_id: session_id,
         cursor: bootstrap.cursor,
         owner_view?: owner_view?,
         conversation:
           Enum.reduce(
             bootstrap.events,
             BeamAgent.ControlPlane.Conversation.new(),
             &BeamAgent.ControlPlane.Conversation.consume/2
           ),
         pending_approvals: %{},
         recent_events:
           bootstrap.events
           |> Enum.take(-500)
           |> Enum.map(&BeamAgent.RuntimeEventView.project(&1, :public))
       }}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:identity, _from, state),
    do: {:reply, {:ok, %{session_id: state.session_id}}, state}

  def handle_call(:conversation, _from, %{owner_view?: true} = state),
    do: {:reply, {:ok, Map.put(state.conversation, :session_id, state.session_id)}, state}

  def handle_call(:conversation, _from, state),
    do: {:reply, {:error, :conversation_not_enabled}, state}

  def handle_call({:submit, prompt}, _from, state),
    do: {:reply, Runtime.submit(state.runtime, prompt), state}

  def handle_call(:cancel, _from, state), do: {:reply, Runtime.cancel(state.runtime), state}

  def handle_call({:approval, approval_id, decision}, _from, state) do
    result = Runtime.respond_approval(state.runtime, approval_id, decision)

    state =
      if result == :ok,
        do: update_in(state, [:pending_approvals], &Map.delete(&1, approval_id)),
        else: state

    {:reply, result, state}
  end

  def handle_call(:verify, _from, state), do: {:reply, Runtime.verify(state.runtime), state}

  def handle_call({:dispatch, request}, _from, state),
    do: {:reply, BeamAgent.Runtime.JSONProtocol.dispatch(state.runtime, request), state}

  def handle_call(:render_html, _from, state) do
    case build_snapshot(state) do
      {:ok, snapshot} -> {:reply, {:ok, html(snapshot)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:beam_agent_runtime, runtime, {:event, event}}, %{runtime: runtime} = state) do
    cursor =
      if is_integer(event.goal_seq), do: max(state.cursor, event.goal_seq), else: state.cursor

    events =
      Enum.take(state.recent_events ++ [BeamAgent.RuntimeEventView.project(event, :public)], -500)

    conversation = BeamAgent.ControlPlane.Conversation.consume(event, state.conversation)
    {:noreply, %{state | cursor: cursor, recent_events: events, conversation: conversation}}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:approval_requested, request}},
        %{runtime: runtime} = state
      ) do
    {:noreply, put_in(state, [:pending_approvals, request.approval_id], request)}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:approval_resolved, approval_id, _decision}},
        %{runtime: runtime} = state
      ) do
    {:noreply, update_in(state, [:pending_approvals], &Map.delete(&1, approval_id))}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:approvals_reconciled, approvals}},
        %{runtime: runtime} = state
      ) do
    pending = Map.new(approvals, &{&1.approval_id, &1})
    {:noreply, %{state | pending_approvals: pending}}
  end

  def handle_info({:beam_agent_runtime, _runtime, _message}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Runtime.disconnect(state.runtime)
    :ok
  end

  defp build_snapshot(state) do
    with {:ok, status} <- Runtime.status(state.runtime),
         {:ok, tree} <- Runtime.goal_tree(state.runtime),
         {:ok, budget} <- Runtime.budget(state.runtime),
         {:ok, models} <- Runtime.models(state.runtime),
         {:ok, resources} <- Runtime.resource_pools(state.runtime),
         {:ok, repository} <- Runtime.repository(state.runtime),
         {:ok, delegations} <- Runtime.delegations(state.runtime),
         {:ok, organizations} <- Runtime.organizations(state.runtime),
         {:ok, worktrees} <- Runtime.worktrees(state.runtime) do
      {:ok,
       %{
         version: 1,
         session_id: state.session_id,
         cursor: state.cursor,
         status: status,
         tree: tree,
         budget: budget,
         models: models,
         resources: resources,
         repository: Map.drop(repository, [:files]),
         delegations: delegations,
         organizations: organizations,
         worktrees: worktrees,
         pending_approvals: Map.values(state.pending_approvals),
         recent_events: state.recent_events
       }}
    end
  end

  defp html(snapshot) do
    tree = BeamAgent.RuntimeGoalTree.render(snapshot.tree) |> Enum.join("\n") |> escape()
    status = escape(to_string(snapshot.status.agent_status))
    session = escape(snapshot.session_id)

    """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>BeamAgent #{session}</title>
    <style>
    body{font-family:ui-monospace,monospace;background:#202329;color:#cdd6f4;margin:2rem}
    header{display:flex;justify-content:space-between;color:#89dceb}pre{padding:1rem;border:1px solid #45475a}
    .grid{display:grid;grid-template-columns:2fr 1fr;gap:1rem}.card{border:1px solid #45475a;padding:1rem}
    </style></head><body><header><strong>BEAM AGENT</strong><span>#{status}</span></header>
    <p>session #{session} · cursor #{snapshot.cursor}</p><div class="grid"><section class="card">
    <h2>Goal tree</h2><pre>#{tree}</pre></section><aside class="card"><h2>Runtime</h2>
    <p>models #{length(snapshot.models)}</p><p>files #{snapshot.repository.file_count}</p>
    <p>approvals #{length(snapshot.pending_approvals)}</p></aside></div></body></html>
    """
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
