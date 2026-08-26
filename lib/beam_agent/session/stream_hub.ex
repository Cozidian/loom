defmodule BeamAgent.Session.StreamHub do
  @moduledoc """
  Session-owned fan-out for live model and durable harness events.

  Model deltas are delivered immediately to monitored subscribers. They are
  checkpointed to the event log in small batches so the durable path never
  performs an fsync for every token.
  """
  use GenServer

  alias BeamAgent.Names
  alias BeamAgent.Session.EventLog

  @checkpoint_interval_ms 250
  @checkpoint_size 32

  def start_link(opts) do
    id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:stream_hub, id))
  end

  def subscribe(session_id, subscriber \\ self()) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.call(pid, {:subscribe, subscriber})
    end
  end

  def unsubscribe(session_id, subscriber \\ self()) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.call(pid, {:unsubscribe, subscriber})
    end
  end

  def begin_response(session_id, metadata) when is_map(metadata) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.call(pid, {:begin_response, metadata})
    end
  end

  def emit(session_id, response_id, event) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.cast(pid, {:emit, response_id, event})
      :ok
    end
  end

  def finish_response(session_id, response_id, metadata \\ %{}) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.call(pid, {:finish_response, response_id, metadata})
    end
  end

  def fail_response(session_id, response_id, reason) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.call(pid, {:fail_response, response_id, reason})
    end
  end

  def publish_event(session_id, event) do
    case Names.pid(:stream_hub, session_id) do
      {:ok, pid} -> GenServer.cast(pid, {:durable_event, event})
      {:error, :not_found} -> :ok
    end
  end

  def sync(session_id) do
    with {:ok, pid} <- Names.pid(:stream_hub, session_id) do
      GenServer.call(pid, :sync)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      subscribers: %{},
      responses: %{}
    }

    send(self(), :recover_interrupted_responses)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) when is_pid(subscriber) do
    state = remove_subscriber(state, subscriber)
    monitor = Process.monitor(subscriber)
    {:reply, :ok, put_in(state.subscribers[subscriber], monitor)}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    {:reply, :ok, remove_subscriber(state, subscriber)}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  def handle_call({:begin_response, metadata}, {owner, _tag}, state) do
    response_id = new_response_id()
    data = Map.put(metadata, "response_id", response_id)

    case EventLog.append(state.session_id, :model_response_started, data) do
      {:ok, _event} ->
        response = %{pending: [], timer: nil, owner: owner, monitor: Process.monitor(owner)}
        {:reply, {:ok, response_id}, put_in(state.responses[response_id], response)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finish_response, response_id, metadata}, _from, state) do
    with {:ok, state} <- flush_response(state, response_id),
         {:ok, _event} <-
           EventLog.append(
             state.session_id,
             :model_response_finished,
             Map.put(metadata, "response_id", response_id)
           ) do
      broadcast(state, %{type: :response_finished, response_id: response_id})
      {:reply, :ok, drop_response(state, response_id)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fail_response, response_id, reason}, _from, state) do
    with {:ok, state} <- flush_response(state, response_id),
         {:ok, _event} <-
           EventLog.append(state.session_id, :model_response_failed, %{
             "response_id" => response_id,
             "error" => inspect(reason)
           }) do
      broadcast(state, %{type: :response_failed, response_id: response_id, error: reason})
      {:reply, :ok, drop_response(state, response_id)}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:emit, response_id, event}, state) do
    case Map.fetch(state.responses, response_id) do
      {:ok, response} ->
        normalized = normalize_live_event(response_id, event)
        broadcast(state, normalized)

        response = %{response | pending: response.pending ++ [checkpoint_event(normalized)]}
        state = put_in(state.responses[response_id], response)

        if length(response.pending) >= @checkpoint_size do
          {:ok, state} = flush_response(state, response_id)
          {:noreply, state}
        else
          {:noreply, schedule_checkpoint(state, response_id)}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:durable_event, event}, state) do
    broadcast(state, %{type: :durable_event, event: event})
    {:noreply, state}
  end

  @impl true
  def handle_info({:checkpoint, response_id}, state) do
    case flush_response(state, response_id) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> {:noreply, clear_timer(state, response_id)}
    end
  end

  def handle_info({:DOWN, monitor, :process, subscriber, _reason}, state) do
    state = handle_subscriber_down(state, subscriber, monitor)
    state = handle_response_owner_down(state, subscriber, monitor)

    {:noreply, state}
  end

  def handle_info(:recover_interrupted_responses, state) do
    case EventLog.events(state.session_id) do
      {:ok, events} ->
        events
        |> interrupted_response_ids()
        |> Enum.each(fn response_id ->
          _ =
            EventLog.append(state.session_id, :model_response_failed, %{
              "response_id" => response_id,
              "error" => "stream_hub_restarted"
            })
        end)

      {:error, _reason} ->
        :ok
    end

    {:noreply, state}
  end

  defp schedule_checkpoint(state, response_id) do
    case get_in(state.responses, [response_id, :timer]) do
      nil ->
        put_in(
          state.responses[response_id].timer,
          Process.send_after(self(), {:checkpoint, response_id}, @checkpoint_interval_ms)
        )

      _timer ->
        state
    end
  end

  defp flush_response(state, response_id) do
    case Map.fetch(state.responses, response_id) do
      {:ok, %{pending: []}} ->
        {:ok, clear_timer(state, response_id)}

      {:ok, response} ->
        case EventLog.append(state.session_id, :model_response_checkpoint, %{
               "response_id" => response_id,
               "events" => response.pending
             }) do
          {:ok, _event} ->
            state = clear_timer(state, response_id)
            {:ok, put_in(state.responses[response_id].pending, [])}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :unknown_response}
    end
  end

  defp clear_timer(state, response_id) do
    case get_in(state.responses, [response_id, :timer]) do
      nil ->
        state

      timer ->
        Process.cancel_timer(timer)
        put_in(state.responses[response_id].timer, nil)
    end
  end

  defp drop_response(state, response_id) do
    state = clear_timer(state, response_id)

    case Map.get(state.responses, response_id) do
      %{monitor: monitor} -> Process.demonitor(monitor, [:flush])
      _response -> :ok
    end

    %{state | responses: Map.delete(state.responses, response_id)}
  end

  defp handle_subscriber_down(state, subscriber, monitor) do
    case Map.fetch(state.subscribers, subscriber) do
      {:ok, ^monitor} -> %{state | subscribers: Map.delete(state.subscribers, subscriber)}
      _other -> state
    end
  end

  defp handle_response_owner_down(state, owner, monitor) do
    case Enum.find(state.responses, fn {_id, response} ->
           response.owner == owner and response.monitor == monitor
         end) do
      {response_id, _response} ->
        case flush_response(state, response_id) do
          {:ok, state} ->
            _ =
              EventLog.append(state.session_id, :model_response_failed, %{
                "response_id" => response_id,
                "error" => "response_owner_down"
              })

            broadcast(state, %{
              type: :response_failed,
              response_id: response_id,
              error: :response_owner_down
            })

            drop_response(state, response_id)

          {:error, _reason} ->
            drop_response(state, response_id)
        end

      nil ->
        state
    end
  end

  defp broadcast(state, event) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:beam_agent_stream, event}))
  end

  defp remove_subscriber(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _subscribers} ->
        state

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp normalize_live_event(response_id, {:text_delta, delta}) when is_binary(delta),
    do: %{type: :text_delta, response_id: response_id, delta: delta}

  defp normalize_live_event(response_id, {:tool_call_delta, delta}) when is_map(delta),
    do: %{type: :tool_call_delta, response_id: response_id, delta: delta}

  defp normalize_live_event(response_id, {:usage, usage}) when is_map(usage),
    do: %{type: :usage, response_id: response_id, usage: usage}

  defp normalize_live_event(response_id, event),
    do: %{type: :provider_event, response_id: response_id, event: inspect(event)}

  defp checkpoint_event(%{type: :text_delta, delta: delta}),
    do: %{"type" => "text_delta", "delta" => delta}

  defp checkpoint_event(%{type: :tool_call_delta, delta: delta}),
    do: %{"type" => "tool_call_delta", "delta" => delta}

  defp checkpoint_event(%{type: :usage, usage: usage}),
    do: %{"type" => "usage", "usage" => usage}

  defp checkpoint_event(event), do: %{"type" => "provider_event", "event" => inspect(event)}

  defp interrupted_response_ids(events) do
    Enum.reduce(events, MapSet.new(), fn event, open ->
      case event do
        %{"type" => "model_response_started", "data" => %{"response_id" => id}} ->
          MapSet.put(open, id)

        %{"type" => type, "data" => %{"response_id" => id}}
        when type in ["model_response_finished", "model_response_failed"] ->
          MapSet.delete(open, id)

        _event ->
          open
      end
    end)
  end

  defp new_response_id do
    suffix = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
    "response-#{suffix}"
  end
end
