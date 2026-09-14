defmodule BeamAgent.Diagnostics do
  @moduledoc "Bounded, metadata-only runtime incident recorder. Never requests process state or mailbox contents."
  use GenServer
  alias BeamAgent.Diagnostics.{Snapshot, Store}

  @table __MODULE__
  @history_bytes 1_500_000
  @progress_keys ~w(source owner_pid os_pid phase elapsed_ms received_bytes messages retained_text_bytes prefix_bytes text_mode text summary tool other)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def configure(opts), do: GenServer.call(__MODULE__, {:configure, opts})
  def status, do: GenServer.call(__MODULE__, :status)
  def enable(enabled), do: GenServer.call(__MODULE__, {:enable, enabled})
  def capture, do: GenServer.call(__MODULE__, :capture, 5_000)

  # One registry row per live process; updates are synchronous ETS operations,
  # not a second per-token mailbox that could itself grow without bound.
  def progress(fields) do
    data =
      fields
      |> Map.take(@progress_keys)
      |> Map.new(fn
        {:owner_pid, pid} when is_pid(pid) ->
          {:owner_pid, inspect(pid)}

        {key, value}
        when key in [:source, :phase, :text_mode] and
               value in [
                 :codex_client,
                 :codex_conversation,
                 :idle,
                 :active,
                 :completed,
                 :failed,
                 :pending,
                 :envelope,
                 :streaming
               ] ->
          {key, value}

        {key, value}
        when key not in [:owner_pid, :source, :phase, :text_mode] and is_integer(value) and
               value >= 0 ->
          {key, value}

        {key, _} ->
          {key, nil}
      end)

    data = Map.put(data, :updated_at_ms, System.monotonic_time(:millisecond))
    key = {:diagnostic_progress, self()}

    case Registry.update_value(BeamAgent.Registry, key, fn _ -> data end) do
      :error -> Registry.register(BeamAgent.Registry, key, data)
      _ -> :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # A fixed single slot coalesces simultaneous failures. Capture the exiting
  # process now; by the next sampling tick it may no longer exist.
  def incident({kind, limit_kind, limit})
      when kind in [:codex_turn_limit, :codex_transport_limit] and
             limit_kind in [:duration_ms, :bytes, :messages, :line_bytes] and is_integer(limit) do
    if :ets.lookup(@table, :enabled) == [{:enabled, true}] do
      incident = %{
        kind: kind,
        limit_kind: limit_kind,
        limit: limit,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        process: Snapshot.process(self()),
        progress: Snapshot.progress(self()),
        stack: Snapshot.stack(self())
      }

      :ets.insert(@table, {:incident, incident})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  def incident(_), do: :ok

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set])
    :ets.insert(@table, {:enabled, false})
    opts = Application.get_env(:beam_agent, :diagnostics_runtime, [])

    state = %{
      enabled: false,
      directory: nil,
      owner: nil,
      monitor: nil,
      history: [],
      previous: %{},
      offset: 0,
      job: nil,
      waiter: nil,
      interval_ms: 5_000,
      timer: nil,
      last_capture: nil,
      last_error: nil,
      last_auto: nil,
      previous_vm: nil,
      memory_threshold: 256 * 1_024 * 1_024,
      growth_threshold: 64 * 1_024 * 1_024,
      mailbox_threshold: 10_000
    }

    case configure_state(state, opts) do
      {:ok, state} -> {:ok, schedule(state)}
      _ -> {:ok, state}
    end
  end

  @impl true
  def handle_call({:configure, opts}, _, state) do
    if state.job do
      {:reply, {:error, :capture_in_progress}, state}
    else
      case configure_state(state, opts) do
        {:ok, next} ->
          Application.put_env(:beam_agent, :diagnostics_runtime, opts)
          {:reply, :ok, schedule(next)}

        error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(:status, _, state) do
    {:reply,
     {:ok,
      Map.take(state, [:enabled, :directory, :last_capture, :last_error, :interval_ms])
      |> Map.put(:samples, length(state.history))
      |> Map.put(:capturing, state.job != nil)}, state}
  end

  def handle_call({:enable, enabled}, _, state) when is_boolean(enabled) do
    if state.directory do
      :ets.insert(@table, {:enabled, enabled})
      if not enabled, do: :ets.delete(@table, :incident)

      opts =
        Application.get_env(:beam_agent, :diagnostics_runtime, [])
        |> Keyword.put(:enabled, enabled)

      Application.put_env(:beam_agent, :diagnostics_runtime, opts)
      # A stopped recorder must not save an in-flight automatic sample.
      {:reply, :ok, schedule(%{state | enabled: enabled})}
    else
      {:reply, {:error, :diagnostics_not_configured}, state}
    end
  end

  def handle_call(:capture, from, %{job: nil, directory: directory} = state)
      when is_binary(directory),
      do: {:noreply, start_sample(%{state | waiter: from})}

  def handle_call(:capture, _, %{directory: nil} = state),
    do: {:reply, {:error, :diagnostics_not_configured}, state}

  def handle_call(:capture, _, state), do: {:reply, {:error, :capture_in_progress}, state}

  @impl true
  def handle_info({:sample, tag}, %{timer: {_timer, tag}} = state) do
    state = %{state | timer: nil}

    if state.enabled and state.job == nil,
      do: {:noreply, start_sample(state)},
      else: {:noreply, schedule(state)}
  end

  def handle_info({ref, {sample, previous, offset}}, %{job: %{ref: ref} = job} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(job.timer)
    history = trim_history([JSON.encode!(sample) | state.history])

    incident =
      case :ets.lookup(@table, :incident) do
        [{:incident, item}] -> item
        _ -> nil
      end

    trigger =
      cond do
        state.waiter != nil -> %{kind: :manual, incident: incident}
        state.enabled and incident != nil -> incident
        state.enabled -> automatic_trigger(sample, state)
        true -> nil
      end

    now = System.monotonic_time(:millisecond)

    save? =
      trigger != nil and
        (state.waiter != nil or state.last_auto == nil or now - state.last_auto >= 60_000)

    result = if save?, do: Store.write(state.directory, history, trigger), else: nil
    if save? and incident, do: :ets.delete_object(@table, {:incident, incident})
    if state.waiter, do: GenServer.reply(state.waiter, result)

    state = %{
      state
      | history: history,
        previous: previous,
        offset: offset,
        job: nil,
        waiter: nil,
        previous_vm: sample.vm_memory.total
    }

    state =
      case result do
        {:ok, capture} -> %{state | last_capture: capture, last_error: nil, last_auto: now}
        {:error, _} -> %{state | last_error: :capture_write_failed, last_auto: now}
        _ -> state
      end

    {:noreply, schedule(state)}
  end

  def handle_info({:sample_timeout, ref}, %{job: %{ref: ref, pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, sample_failed(state, :sample_timeout)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{job: %{ref: ref}} = state),
    do: {:noreply, sample_failed(state, :sample_failed)}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    state = cancel_job(state, :owner_stopped)
    :ets.insert(@table, {:enabled, false})
    :ets.delete(@table, :incident)
    Application.delete_env(:beam_agent, :diagnostics_runtime)

    {:noreply,
     schedule(%{
       state
       | enabled: false,
         directory: nil,
         history: [],
         previous: %{},
         owner: nil,
         monitor: nil
     })}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.update(
      status,
      :state,
      %{},
      &Map.take(&1, [:enabled, :directory, :last_error, :last_capture])
    )
  end

  @impl true
  def terminate(_, state) do
    cancel_job(state, :recorder_stopped)
    :ok
  end

  defp cancel_job(%{job: nil} = state, _reason), do: state

  defp cancel_job(state, reason) do
    Process.exit(state.job.pid, :kill)
    sample_failed(state, reason)
  end

  defp start_sample(state) do
    previous = state.previous
    offset = state.offset

    task =
      Task.Supervisor.async_nolink(BeamAgent.DiagnosticsTasks, fn ->
        Snapshot.collect(previous, offset)
      end)

    timer = Process.send_after(self(), {:sample_timeout, task.ref}, 2_000)
    %{state | job: %{ref: task.ref, pid: task.pid, timer: timer}}
  end

  defp sample_failed(state, reason) do
    Process.cancel_timer(state.job.timer)
    Process.demonitor(state.job.ref, [:flush])
    if state.waiter, do: GenServer.reply(state.waiter, {:error, reason})
    schedule(%{state | job: nil, waiter: nil, last_error: reason})
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(elem(state.timer, 0))

    timer =
      if state.enabled and state.job == nil do
        tag = make_ref()
        {Process.send_after(self(), {:sample, tag}, state.interval_ms), tag}
      end

    %{state | timer: timer}
  end

  defp configure_state(state, opts) do
    with directory when is_binary(directory) <- opts[:directory],
         owner when is_pid(owner) <- opts[:owner],
         true <- Process.alive?(owner),
         :ok <- Store.prepare(directory) do
      if state.monitor, do: Process.demonitor(state.monitor, [:flush])
      enabled = Keyword.get(opts, :enabled, true) == true
      :ets.delete(@table, :incident)
      :ets.insert(@table, {:enabled, enabled})

      {:ok,
       %{
         state
         | directory: directory,
           owner: owner,
           monitor: Process.monitor(owner),
           enabled: enabled,
           history: [],
           previous: %{},
           previous_vm: nil,
           last_auto: nil,
           last_capture: nil,
           last_error: nil,
           interval_ms: positive(opts, :interval_ms, 5_000),
           memory_threshold: positive(opts, :memory_threshold, 256 * 1_024 * 1_024),
           growth_threshold: positive(opts, :growth_threshold, 64 * 1_024 * 1_024),
           mailbox_threshold: positive(opts, :mailbox_threshold, 10_000)
       }}
    else
      _ -> {:error, :diagnostics_not_configured}
    end
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp trim_history(history) do
    history
    |> Enum.take(24)
    |> Enum.reduce_while({[], 0}, fn sample, {items, bytes} ->
      if bytes + byte_size(sample) <= @history_bytes,
        do: {:cont, {[sample | items], bytes + byte_size(sample)}},
        else: {:halt, {items, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp automatic_trigger(sample, state) do
    cond do
      sample.vm_memory.total >= 1_073_741_824 ->
        %{kind: :vm_memory}

      Enum.any?(sample.os_processes, &(&1.rss_bytes >= 1_073_741_824)) ->
        %{kind: :os_memory}

      Enum.any?(sample.processes, &(&1.memory >= state.memory_threshold)) ->
        %{kind: :process_memory}

      Enum.any?(sample.processes, &(&1.message_queue_len >= state.mailbox_threshold)) ->
        %{kind: :mailbox_growth}

      state.previous_vm != nil and
          sample.vm_memory.total - state.previous_vm >= state.growth_threshold ->
        %{kind: :vm_memory_growth}

      true ->
        nil
    end
  end
end
