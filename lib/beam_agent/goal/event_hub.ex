defmodule BeamAgent.Goal.EventHub do
  @moduledoc "Goal-owned replay and live fan-out for parent and child runtime events."
  use GenServer

  alias BeamAgent.{Names, RuntimeEvent, RuntimeEventQuery, RuntimeEventView}
  alias BeamAgent.Session.EventLog

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal_event_hub, goal_id))
  end

  def subscribe(goal_id), do: subscribe(goal_id, self(), [])

  def subscribe(goal_id, subscriber) when is_pid(subscriber),
    do: subscribe(goal_id, subscriber, [])

  def subscribe(goal_id, opts) when is_list(opts), do: subscribe(goal_id, self(), opts)

  def subscribe(goal_id, subscriber, opts) when is_pid(subscriber) and is_list(opts) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, {:subscribe, subscriber, Keyword.get(opts, :view, :public)})
    end
  end

  def subscribe_from(goal_id), do: subscribe_from(goal_id, self(), nil, [])

  def subscribe_from(goal_id, subscriber) when is_pid(subscriber),
    do: subscribe_from(goal_id, subscriber, nil, [])

  def subscribe_from(goal_id, subscriber, after_cursor),
    do: subscribe_from(goal_id, subscriber, after_cursor, [])

  def subscribe_from(goal_id, subscriber, after_cursor, opts)
      when is_pid(subscriber) and is_list(opts) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(
        pid,
        {:subscribe_from, subscriber, after_cursor, Keyword.get(opts, :view, :public)}
      )
    end
  end

  def unsubscribe(goal_id, subscriber \\ self()) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, {:unsubscribe, subscriber})
    end
  end

  def register_session(goal_id, session_id) do
    with {:ok, events} <- EventLog.events(session_id),
         {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, {:register_session, session_id, events})
    end
  end

  def publish(goal_id, session_id, event) do
    case Names.pid(:goal_event_hub, goal_id) do
      {:ok, pid} -> GenServer.cast(pid, {:publish, session_id, event})
      {:error, :not_found} -> :ok
    end
  end

  def events(goal_id, opts \\ []) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, {:events, opts})
    end
  end

  def session_events(session_id, opts \\ []) do
    BeamAgent.Registry
    |> Registry.select([
      {{{:goal_event_hub, :"$1"}, :"$2", :"$3"}, [], [:"$1"]}
    ])
    |> Enum.find_value({:error, :not_found}, fn goal_id ->
      case events(goal_id, Keyword.put(opts, :view, :internal)) do
        {:ok, runtime_events} ->
          session_events =
            runtime_events
            |> Enum.filter(
              &(get_in(&1, [:scope, :session_id]) == session_id and &1.durability == :durable)
            )
            |> Enum.map(&canonical_event/1)
            |> Enum.sort_by(&(&1["seq"] || 0))

          if session_events == [], do: nil, else: {:ok, session_events}

        _other ->
          nil
      end
    end)
  end

  defp canonical_event(runtime_event) do
    %{
      "at" => runtime_event.at,
      "causation_id" => runtime_event.causation_id,
      "correlation_id" => runtime_event.correlation_id,
      "data" => runtime_event.payload.data,
      "goal_seq" => runtime_event.goal_seq,
      "seq" => runtime_event.payload.seq,
      "session_id" => runtime_event.scope.session_id,
      "type" => to_string(runtime_event.payload.type)
    }
  end

  def inspect_events(goal_id, query, opts \\ []) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, {:inspect_events, query, Keyword.get(opts, :view, :public)})
    end
  end

  def sync(goal_id) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, :sync)
    end
  end

  def goal_tree(goal_id) do
    with {:ok, events} <- events(goal_id, view: :public) do
      tree = events |> BeamAgent.RuntimeGoalTree.project() |> BeamAgent.RuntimeGoalTree.nest()
      {:ok, tree}
    end
  end

  def work_blocks(goal_id) do
    with {:ok, events} <- events(goal_id, view: :public) do
      {:ok, BeamAgent.RuntimeWorkBlocks.project(events)}
    end
  end

  def next_sequence(goal_id) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, :next_sequence)
    end
  end

  def abandon_sequence(goal_id, goal_seq) when is_integer(goal_seq) do
    with {:ok, pid} <- Names.pid(:goal_event_hub, goal_id) do
      GenServer.call(pid, {:abandon_sequence, goal_seq})
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       project_id: Keyword.fetch!(opts, :project_id),
       goal_id: Keyword.fetch!(opts, :goal_id),
       data_dir: Keyword.fetch!(opts, :data_dir),
       subscribers: %{},
       events: %{},
       next_seq: 0,
       cursor: 0,
       settled: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:subscribe, subscriber, view}, _from, state)
      when is_pid(subscriber) and view in [:public, :internal] do
    {:reply, :ok, monitor_subscriber(state, subscriber, view)}
  end

  def handle_call({:subscribe, _subscriber, _view}, _from, state),
    do: {:reply, {:error, :invalid_event_view}, state}

  def handle_call({:subscribe_from, subscriber, after_cursor, view}, _from, state)
      when is_pid(subscriber) and (is_nil(after_cursor) or is_integer(after_cursor)) and
             view in [:public, :internal] do
    state = monitor_subscriber(state, subscriber, view)
    replay = replay_events(state, after_cursor, :all, view)
    {:reply, {:ok, %{events: replay, cursor: state.cursor}}, state}
  end

  def handle_call({:subscribe_from, _subscriber, after_cursor, view}, _from, state) do
    error =
      if valid_cursor?(after_cursor) and not RuntimeEventView.valid_view?(view),
        do: :invalid_event_view,
        else: :invalid_cursor

    {:reply, {:error, error}, state}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    {:reply, :ok, remove_subscriber(state, subscriber)}
  end

  def handle_call({:register_session, session_id, events}, _from, state) do
    sessions = collect_session_events(state.data_dir, session_id, events, MapSet.new())
    {state, added} = merge_sessions(state, sessions)
    Enum.each(added, &broadcast(state, &1))
    {:reply, :ok, state}
  end

  def handle_call({:events, opts}, _from, state) when is_list(opts) do
    after_cursor = Keyword.get(opts, :after)
    limit = Keyword.get(opts, :limit, :all)
    view = Keyword.get(opts, :view, :public)

    if valid_cursor?(after_cursor) and valid_limit?(limit) and RuntimeEventView.valid_view?(view) do
      {:reply, {:ok, replay_events(state, after_cursor, limit, view)}, state}
    else
      {:reply, {:error, :invalid_replay_options}, state}
    end
  end

  def handle_call({:inspect_events, query, view}, _from, state)
      when is_binary(query) and view in [:public, :internal] do
    with {:ok, query} <- RuntimeEventQuery.parse(query) do
      events = replay_events(state, nil, :all, view)
      result = events |> RuntimeEventQuery.run(query) |> Map.put(:cursor, state.cursor)
      {:reply, {:ok, result}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:inspect_events, _query, _view}, _from, state),
    do: {:reply, {:error, :invalid_event_inspection}, state}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call(:next_sequence, _from, state) do
    goal_seq = state.next_seq + 1
    {:reply, {:ok, goal_seq}, %{state | next_seq: goal_seq}}
  end

  def handle_call({:abandon_sequence, goal_seq}, _from, state) do
    {:reply, :ok, settle_sequence(state, goal_seq)}
  end

  @impl true
  def handle_cast({:publish, session_id, %{type: :durable_event, event: event}}, state) do
    runtime_event = RuntimeEvent.durable(state.project_id, state.goal_id, session_id, event)
    {state, added?} = put_durable(state, runtime_event)
    if added?, do: broadcast(state, runtime_event)
    {:noreply, state}
  end

  def handle_cast({:publish, session_id, event}, state) do
    runtime_event =
      state.project_id
      |> RuntimeEvent.ephemeral(state.goal_id, session_id, event)
      |> Map.put(:cursor, state.cursor)

    broadcast(state, runtime_event)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, subscriber, _reason}, state) do
    case Map.fetch(state.subscribers, subscriber) do
      {:ok, %{monitor: ^monitor}} -> {:noreply, remove_subscriber(state, subscriber)}
      _other -> {:noreply, state}
    end
  end

  defp collect_session_events(data_dir, session_id, events, seen) do
    if MapSet.member?(seen, session_id) do
      []
    else
      seen = MapSet.put(seen, session_id)

      children =
        events
        |> Enum.flat_map(fn
          %{
            "type" => "subagent_spawned",
            "data" => %{"child_session_id" => child_session_id}
          }
          when is_binary(child_session_id) ->
            case EventLog.read(data_dir, child_session_id) do
              {:ok, child_events} ->
                collect_session_events(data_dir, child_session_id, child_events, seen)

              {:error, _reason} ->
                []
            end

          _event ->
            []
        end)

      [{session_id, events} | children]
    end
  end

  defp merge_sessions(state, sessions) do
    runtime_events =
      Enum.flat_map(sessions, fn {session_id, events} ->
        Enum.map(events, fn event ->
          RuntimeEvent.durable(state.project_id, state.goal_id, session_id, event)
        end)
      end)

    persisted_max =
      runtime_events
      |> Enum.map(& &1.goal_seq)
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.max(fn -> state.next_seq end)

    initial_load? = map_size(state.events) == 0

    state =
      if initial_load? do
        %{state | next_seq: max(state.next_seq, persisted_max), cursor: persisted_max}
      else
        %{state | next_seq: max(state.next_seq, persisted_max)}
      end

    runtime_events
    |> Enum.sort_by(&{&1.at, &1.event_id})
    |> Enum.reduce({state, []}, fn runtime_event, {state, added} ->
      runtime_event = ensure_goal_sequence(runtime_event)

      case put_durable(state, runtime_event) do
        {state, true} -> {state, added ++ [runtime_event]}
        {state, false} -> {state, added}
      end
    end)
  end

  defp put_durable(state, event) do
    if Map.has_key?(state.events, event.event_id) do
      {state, false}
    else
      state = %{
        state
        | events: Map.put(state.events, event.event_id, event)
      }

      {settle_sequence(state, event.goal_seq), true}
    end
  end

  defp broadcast(state, event) do
    Enum.each(state.subscribers, fn {subscriber, %{view: view}} ->
      send(subscriber, {:beam_agent_runtime_event, RuntimeEventView.project(event, view)})
    end)
  end

  defp monitor_subscriber(state, subscriber, view) do
    state = remove_subscriber(state, subscriber)
    monitor = Process.monitor(subscriber)
    put_in(state.subscribers[subscriber], %{monitor: monitor, view: view})
  end

  defp replay_events(state, after_cursor, limit, view) do
    events =
      state.events
      |> Map.values()
      |> Enum.sort_by(&event_order/1)
      |> Enum.filter(fn event -> is_nil(after_cursor) or event.goal_seq > after_cursor end)

    case limit do
      :all -> events
      limit when is_integer(limit) and limit >= 0 -> Enum.take(events, -limit)
    end
    |> Enum.map(&RuntimeEventView.project(&1, view))
  end

  defp event_order(%{goal_seq: goal_seq, at: at, event_id: event_id}) when goal_seq < 0,
    do: {0, at, event_id}

  defp event_order(%{goal_seq: goal_seq}), do: {1, goal_seq}

  defp ensure_goal_sequence(%{goal_seq: goal_seq} = event) when is_integer(goal_seq), do: event

  defp ensure_goal_sequence(event) do
    <<number::unsigned-big-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, event.event_id)

    %{event | goal_seq: -(number + 1)}
  end

  defp settle_sequence(state, goal_seq) when is_integer(goal_seq) and goal_seq > state.cursor do
    advance_cursor(%{state | settled: MapSet.put(state.settled, goal_seq)})
  end

  defp settle_sequence(state, _goal_seq), do: state

  defp advance_cursor(state) do
    next = state.cursor + 1

    if MapSet.member?(state.settled, next) do
      advance_cursor(%{
        state
        | cursor: next,
          settled: MapSet.delete(state.settled, next)
      })
    else
      state
    end
  end

  defp valid_cursor?(cursor), do: is_nil(cursor) or is_integer(cursor)
  defp valid_limit?(:all), do: true
  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0

  defp remove_subscriber(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _subscribers} ->
        state

      {%{monitor: monitor}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers}
    end
  end
end
