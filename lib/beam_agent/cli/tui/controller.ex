defmodule BeamAgent.CLI.TUI.Controller do
  @moduledoc false
  use GenServer

  alias BeamAgent.CLI.Config

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def submit(controller, prompt), do: GenServer.cast(controller, {:submit, prompt})
  def cancel(controller), do: GenServer.cast(controller, :cancel)

  def decide(controller, approval_id, decision),
    do: GenServer.cast(controller, {:decide, approval_id, decision})

  def command(controller, command), do: GenServer.cast(controller, {:command, command})

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      session_id: Keyword.fetch!(opts, :session_id),
      config: Keyword.fetch!(opts, :config),
      current: nil,
      compacting?: false
    }

    with :ok <- BeamAgent.subscribe(state.session_id),
         :ok <- BeamAgent.set_approval_handler(state.session_id, self()) do
      notify(state, {:controller_ready, self()})
      notify_context_stats(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:submit, prompt}, %{current: nil} = state) when is_binary(prompt) do
    owner = self()
    result_ref = make_ref()

    case Task.start(fn ->
           send(owner, {result_ref, BeamAgent.ask(state.session_id, prompt, :infinity)})
         end) do
      {:ok, pid} ->
        current = %{pid: pid, monitor: Process.monitor(pid), result_ref: result_ref}
        notify(state, {:turn_started, prompt})
        {:noreply, %{state | current: current}}

      {:error, reason} ->
        notify(state, {:turn_finished, {:error, {:turn_start_failed, reason}}})
        {:noreply, state}
    end
  end

  def handle_cast({:submit, _prompt}, state) do
    notify(state, {:notice, :warning, "A turn is already running"})
    {:noreply, state}
  end

  def handle_cast(:cancel, %{current: nil} = state) do
    notify(state, {:notice, :muted, "Nothing is running"})
    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    _ = BeamAgent.cancel(state.session_id)
    notify(state, :turn_cancelling)
    {:noreply, state}
  end

  def handle_cast({:decide, approval_id, decision}, state)
      when decision in [:allow_once, :deny] do
    case BeamAgent.respond_approval(state.session_id, approval_id, decision) do
      :ok -> notify(state, {:approval_resolved, approval_id, decision})
      {:error, reason} -> notify(state, {:notice, :error, format_error(reason)})
    end

    {:noreply, state}
  end

  def handle_cast({:command, command}, state) do
    {:noreply, run_command(command, state)}
  end

  @impl true
  def handle_info({:beam_agent_stream, event}, state) do
    notify(state, {:stream, event})
    {:noreply, state}
  end

  def handle_info({:beam_agent_approval, request}, state) do
    notify(state, {:approval_requested, request})
    {:noreply, state}
  end

  def handle_info({result_ref, result}, %{current: %{result_ref: result_ref} = current} = state) do
    Process.demonitor(current.monitor, [:flush])
    notify(state, {:turn_finished, result})
    notify_context_stats(state)
    {:noreply, %{state | current: nil}}
  end

  def handle_info({:context_compaction_result, result}, state) do
    case result do
      {:ok, :compacted, stats} ->
        notify(
          state,
          {:notice, :success,
           "Context compacted · #{stats.estimated_tokens}/#{stats.window_tokens} est. tokens"}
        )

      {:ok, :not_needed, stats} ->
        notify(
          state,
          {:notice, :muted,
           "Nothing to compact · #{stats.estimated_tokens}/#{stats.window_tokens} est. tokens"}
        )

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    notify_context_stats(state)
    {:noreply, %{state | compacting?: false}}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{current: %{monitor: monitor}} = state
      )
      when reason != :normal do
    notify(state, {:turn_finished, {:error, {:turn_task_exit, reason}}})
    {:noreply, %{state | current: nil}}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({_result_ref, _result}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.current do
      _ = BeamAgent.cancel(state.session_id)
      Process.demonitor(state.current.monitor, [:flush])
      if Process.alive?(state.current.pid), do: Process.exit(state.current.pid, :shutdown)
    end

    _ = BeamAgent.unsubscribe(state.session_id, self())
    :ok
  end

  defp run_command(:reload, state) do
    case BeamAgent.reload_context(state.session_id) do
      {:ok, context} ->
        notify(state, {:notice, :success, "Context reloaded · #{length(context.skills)} skills"})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:status, state) do
    with {:ok, path} <- BeamAgent.event_log_path(state.session_id),
         {:ok, context} <- BeamAgent.context_snapshot(state.session_id),
         {:ok, context_stats} <- BeamAgent.conversation_context_stats(state.session_id),
         {:ok, events} <- BeamAgent.events(state.session_id) do
      notify(state, {
        :panel,
        "Session status",
        [
          "provider  #{state.config["provider"]}",
          "profile   #{state.config["profile"]}",
          "model     #{state.config["model"] || "built-in"}",
          "session   #{state.session_id}",
          "workspace #{state.config["workspace_root"]}",
          "approval  #{state.config["approval_policy"]}",
          "project   #{String.slice(context.fingerprint, 0, 12)}",
          "context   #{context_stats.estimated_tokens}/#{context_stats.window_tokens} est. tokens (#{context_stats.utilization_percent}%)",
          "compacted #{context_stats.compaction_count} times",
          "events    #{length(events)}",
          "log       #{path}"
        ]
      })
    else
      {:error, reason} -> notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:compact, %{current: nil, compacting?: false} = state) do
    owner = self()

    case Task.start(fn ->
           send(owner, {:context_compaction_result, BeamAgent.compact_context(state.session_id)})
         end) do
      {:ok, _pid} ->
        notify(state, {:notice, :muted, "Compacting older completed turns…"})
        %{state | compacting?: true}

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command(:compact, state) do
    notify(state, {:notice, :warning, "Wait for the current operation before compacting"})
    state
  end

  defp run_command(:skills, state) do
    case BeamAgent.skills(state.session_id) do
      {:ok, []} ->
        notify(state, {:panel, "Skills", ["No project skills discovered"]})

      {:ok, skills} ->
        lines = Enum.map(skills, &"#{&1.name} · #{&1.description}")
        notify(state, {:panel, "Skills", lines})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:events, state) do
    with {:ok, events} <- BeamAgent.events(state.session_id),
         {:ok, path} <- BeamAgent.event_log_path(state.session_id) do
      notify(state, {:panel, "Event log", ["#{length(events)} durable events", path]})
    else
      {:error, reason} -> notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:sessions, state) do
    sessions =
      case File.ls(state.config["data_dir"]) do
        {:ok, entries} ->
          entries
          |> Enum.filter(
            &File.regular?(Path.join([state.config["data_dir"], &1, "events.jsonl"]))
          )
          |> Enum.sort()

        {:error, _reason} ->
          []
      end

    lines = if sessions == [], do: ["No durable sessions"], else: sessions
    notify(state, {:panel, "Sessions", lines})
    state
  end

  defp run_command(:new, %{current: nil} = state) do
    with {:ok, provider} <- Config.provider_atom(state.config["provider"]),
         {:ok, new_session_id} <- start_session(state.config, provider),
         :ok <- BeamAgent.subscribe(new_session_id),
         :ok <- BeamAgent.set_approval_handler(new_session_id, self()) do
      _ = BeamAgent.unsubscribe(state.session_id, self())
      _ = BeamAgent.stop_session(state.session_id)
      state = %{state | session_id: new_session_id}
      notify(state, {:session_changed, new_session_id})
      notify_context_stats(state)
      state
    else
      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command(:new, state) do
    notify(state, {:notice, :warning, "Cancel the running turn before starting a new session"})
    state
  end

  defp run_command(command, state) do
    notify(state, {:notice, :warning, "Unsupported command: #{command}"})
    state
  end

  defp start_session(config, provider) do
    BeamAgent.start_session(
      provider: provider,
      provider_options: Config.provider_options(config),
      provider_profile: config["profile"],
      data_dir: config["data_dir"],
      context_window_tokens: config["context_window_tokens"] || 32_000,
      compaction_threshold_percent: config["compaction_threshold_percent"] || 75,
      workspace_root: config["workspace_root"],
      approval_policy: String.to_existing_atom(config["approval_policy"]),
      approval_handler: self()
    )
  end

  defp notify_context_stats(state) do
    case BeamAgent.conversation_context_stats(state.session_id) do
      {:ok, stats} -> notify(state, {:context_stats, stats})
      {:error, _reason} -> :ok
    end
  end

  defp notify(state, message) do
    send(state.client, {:beam_agent_tui, message})
    :ok
  end

  defp format_error(reason), do: inspect(reason, pretty: true, limit: 8)
end
