defmodule BeamAgent.CLI.TUI.Controller do
  @moduledoc false
  use GenServer

  alias BeamAgent.CLI.Config
  alias BeamAgent.{Runtime, RuntimeEventQuery}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def bootstrap(controller), do: GenServer.call(controller, :bootstrap)

  def submit(controller, prompt), do: GenServer.cast(controller, {:submit, prompt})
  def cancel(controller), do: GenServer.cast(controller, :cancel)

  def decide(controller, approval_id, decision),
    do: GenServer.cast(controller, {:decide, approval_id, decision})

  def command(controller, command), do: GenServer.cast(controller, {:command, command})

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      runtime: nil,
      runtime_monitor: nil,
      session_id: Keyword.fetch!(opts, :session_id),
      project_id: nil,
      goal_id: nil,
      cursor: 0,
      bootstrap_events: [],
      config: Keyword.fetch!(opts, :config),
      approval_policy: :ask,
      auto_fallback: :ask,
      current: nil,
      verification: nil,
      compacting?: false
    }

    with {:ok, runtime} <-
           Runtime.connect(state.session_id, subscriber: self(), view: :internal),
         {:ok, subscription} <- Runtime.bootstrap(runtime) do
      state = %{
        state
        | runtime: runtime,
          runtime_monitor: Process.monitor(runtime),
          project_id: subscription.project_id,
          goal_id: subscription.goal_id,
          cursor: subscription.cursor,
          bootstrap_events: subscription.events,
          approval_policy: subscription.approval_policy,
          auto_fallback: auto_fallback(subscription.approval_policy, state.config)
      }

      notify(state, {:controller_ready, self()})
      notify(state, {:approval_mode, subscription.approval_policy})
      notify_context_stats(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:bootstrap, _from, state) do
    snapshot = %{
      project_id: state.project_id,
      goal_id: state.goal_id,
      cursor: state.cursor,
      events: state.bootstrap_events
    }

    {:reply, {:ok, snapshot}, %{state | bootstrap_events: []}}
  end

  @impl true
  def handle_cast({:submit, prompt}, %{current: nil, verification: nil} = state)
      when is_binary(prompt) do
    case Runtime.submit(state.runtime, prompt) do
      :ok ->
        {:noreply, %{state | current: :running}}

      {:error, reason} ->
        notify(state, {:turn_finished, {:error, reason}})
        {:noreply, state}
    end
  end

  def handle_cast({:submit, _prompt}, state) do
    notify(state, {:notice, :warning, "A turn is already running"})
    {:noreply, state}
  end

  def handle_cast(:cancel, %{verification: %{pid: pid, monitor: monitor}} = state) do
    _ = Runtime.cancel_verification(state.runtime)
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    Process.demonitor(monitor, [:flush])
    {:noreply, %{state | verification: nil}}
  end

  def handle_cast(:cancel, %{current: nil} = state) do
    notify(state, {:notice, :muted, "Nothing is running"})
    {:noreply, state}
  end

  def handle_cast(:cancel, state) do
    _ = Runtime.cancel(state.runtime)
    {:noreply, state}
  end

  def handle_cast({:decide, approval_id, decision}, state)
      when decision in [:allow_once, :allow_always, :deny] do
    case Runtime.respond_approval(state.runtime, approval_id, decision) do
      :ok -> :ok
      {:error, reason} -> notify(state, {:notice, :error, format_error(reason)})
    end

    {:noreply, state}
  end

  def handle_cast({:command, command}, state) do
    {:noreply, run_command(command, state)}
  end

  @impl true
  def handle_info({:beam_agent_runtime, runtime, {:event, event}}, %{runtime: runtime} = state) do
    notify(state, {:stream, event})

    cursor =
      case event do
        %{durability: :durable, goal_seq: goal_seq} when is_integer(goal_seq) ->
          max(state.cursor, goal_seq)

        _event ->
          state.cursor
      end

    {:noreply, %{state | cursor: cursor}}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:approval_requested, request}},
        %{runtime: runtime} = state
      ) do
    notify(state, {:approval_requested, request})
    {:noreply, state}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:turn_started, prompt}},
        %{runtime: runtime} = state
      ) do
    notify(state, {:turn_started, prompt})
    {:noreply, %{state | current: :running}}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:turn_finished, result}},
        %{runtime: runtime} = state
      ) do
    notify(state, {:turn_finished, result})
    notify_context_stats(state)
    {:noreply, %{state | current: nil}}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, :turn_cancelling},
        %{runtime: runtime} = state
      ) do
    notify(state, :turn_cancelling)
    {:noreply, state}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:approval_resolved, approval_id, decision}},
        %{runtime: runtime} = state
      ) do
    notify(state, {:approval_resolved, approval_id, decision})
    {:noreply, state}
  end

  def handle_info(
        {:beam_agent_runtime, runtime, {:approval_policy_changed, policy}},
        %{runtime: runtime} = state
      ) do
    {:noreply, %{state | approval_policy: policy}}
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

  def handle_info({:verification_result, ref, result}, %{verification: %{ref: ref}} = state) do
    Process.demonitor(state.verification.monitor, [:flush])

    case result do
      {:ok, %{status: :passed, summary: summary}} ->
        notify(state, {:notice, :success, "Verification passed · #{summary}"})

      {:ok, %{status: :failed, summary: summary}} ->
        notify(state, {:notice, :error, "Verification failed · #{summary}"})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    {:noreply, %{state | verification: nil}}
  end

  def handle_info({:verification_result, _ref, _result}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{verification: %{monitor: monitor, pid: pid}} = state
      ) do
    notify(state, {:notice, :error, "Verification process exited · #{format_error(reason)}"})
    {:noreply, %{state | verification: nil}}
  end

  def handle_info(
        {:DOWN, monitor, :process, runtime, reason},
        %{runtime_monitor: monitor, runtime: runtime} = state
      ) do
    {:stop, {:runtime_client_exit, reason}, state}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:beam_agent_runtime, _runtime, _notification}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.runtime_monitor, do: Process.demonitor(state.runtime_monitor, [:flush])
    if state.runtime, do: Runtime.disconnect(state.runtime)
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

  defp run_command(:auto, state) do
    next = if state.approval_policy == :auto, do: state.auto_fallback, else: :auto

    case Runtime.set_approval_policy(state.runtime, next) do
      :ok ->
        config = Map.put(state.config, "approval_policy", to_string(next))

        state = %{
          state
          | approval_policy: next,
            auto_fallback:
              if(next == :auto, do: state.approval_policy, else: state.auto_fallback),
            config: config
        }

        notify(state, {:approval_mode, next})

        if next == :auto do
          notify(state, {:notice, :warning, "Auto mode enabled · risky tools are approved"})
        else
          notify(
            state,
            {:notice, :success, "Auto mode disabled · restored #{state.approval_policy} policy"}
          )
        end

        state

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command(:status, state) do
    with {:ok, status} <- Runtime.status(state.runtime) do
      notify(state, {
        :panel,
        "Session status",
        [
          "provider  #{state.config["provider"]}",
          "profile   #{state.config["profile"]}",
          "model     #{state.config["model"] || "built-in"}",
          "session   #{state.session_id}",
          "workspace #{state.config["workspace_root"]}",
          "approval  #{state.approval_policy}",
          "routing   #{state.config["model_strategy"] || "manual"}",
          "project   #{state.project_id}",
          "goal      #{state.goal_id}",
          "snapshot  #{String.slice(status.context.fingerprint, 0, 12)}",
          "context   #{status.context_stats.estimated_tokens}/#{status.context_stats.window_tokens} est. tokens (#{status.context_stats.utilization_percent}%)",
          "compacted #{status.context_stats.compaction_count} times",
          "events    #{status.event_count}",
          "cursor    #{status.cursor}",
          "log       #{status.event_log_path}"
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

  defp run_command(:verify, %{current: nil, verification: nil} = state) do
    owner = self()
    ref = make_ref()

    case Task.start(fn ->
           send(owner, {:verification_result, ref, Runtime.verify(state.runtime)})
         end) do
      {:ok, pid} ->
        notify(state, {:notice, :muted, "Starting deterministic verification…"})
        %{state | verification: %{pid: pid, monitor: Process.monitor(pid), ref: ref}}

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command(:verify, state) do
    notify(state, {:notice, :warning, "Wait for the current operation before verifying"})
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

  defp run_command(:models, state), do: run_command({:models, ""}, state)

  defp run_command({:models, ""}, state) do
    case Runtime.models(state.runtime) do
      {:ok, endpoints} ->
        evidence =
          case Runtime.routing_evidence(state.runtime) do
            {:ok, evidence} -> evidence
            {:error, _reason} -> %{endpoints: []}
          end

        lines =
          if endpoints == [] do
            ["No model endpoints registered"]
          else
            Enum.map(
              endpoints,
              &format_model_endpoint(&1, state.config["profile"], evidence)
            )
          end

        notify(state, {:panel, "Model registry · #{length(endpoints)} endpoints", lines})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:models, "refresh"}, state) do
    case Runtime.refresh_models(state.runtime) do
      {:ok, endpoint_ids} ->
        notify(
          state,
          {:notice, :muted,
           "Checking #{length(endpoint_ids)} model endpoints · run /models to refresh status"}
        )

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:models, endpoint_id}, state) when is_binary(endpoint_id) do
    case Runtime.refresh_models(state.runtime, endpoint_id) do
      {:ok, [_endpoint_id]} ->
        notify(
          state,
          {:notice, :muted, "Checking #{endpoint_id} · run /models to refresh status"}
        )

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:events, state), do: run_command({:events, ""}, state)

  defp run_command(:tree, state) do
    with {:ok, tree} <- Runtime.goal_tree(state.runtime) do
      lines = BeamAgent.RuntimeGoalTree.render(tree)
      notify(state, {:panel, "Goal tree", lines})
    else
      {:error, reason} -> notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:budget, state) do
    case Runtime.budget(state.runtime) do
      {:ok, budget} ->
        lines =
          Enum.map(budget.allocations, fn allocation ->
            "#{short_id(allocation.worker_id)} · #{allocation.status} · #{format_usage(allocation.usage, allocation.limits)}"
          end)

        notify(state, {:panel, "Goal budget", lines})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:repository, state) do
    case Runtime.repository(state.runtime) do
      {:ok, repository} ->
        lines = [
          "generation #{repository.generation} · #{repository.file_count} files",
          "git #{repository.git.head || "unavailable"} · #{if(repository.git.dirty, do: "dirty", else: "clean")}",
          "refreshed #{repository.last_refreshed_at || "pending"}"
        ]

        notify(state, {:panel, "Repository intelligence", lines})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:resources, state) do
    case Runtime.resource_pools(state.runtime) do
      {:ok, pools} ->
        lines =
          pools
          |> Enum.sort_by(fn {name, _pool} -> name end)
          |> Enum.map(fn {name, pool} ->
            "#{name} · #{pool.active}/#{pool.limit} active · #{pool.queued} queued"
          end)

        notify(state, {:panel, "Resource scheduler", lines})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:organizations, state) do
    case Runtime.organizations(state.runtime) do
      {:ok, organizations} ->
        lines =
          Enum.map(organizations, fn organization ->
            "#{short_id(organization.id)} · #{organization.status} · #{map_size(organization.tasks)} tasks · #{strategy_id(organization.strategy)}"
          end)

        notify(
          state,
          {:panel, "Worker organizations", if(lines == [], do: ["None"], else: lines)}
        )

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command(:worktrees, state) do
    case Runtime.worktrees(state.runtime) do
      {:ok, worktrees} ->
        lines =
          Enum.map(
            worktrees,
            &"#{short_id(&1.id)} · #{&1.status} · #{short_id(&1.owner_worker_id)}"
          )

        notify(state, {:panel, "Git worktrees", if(lines == [], do: ["None"], else: lines)})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:events, "help"}, state) do
    notify(state, {:panel, "Event inspector filters", RuntimeEventQuery.usage()})
    state
  end

  defp run_command({:events, query}, state) when is_binary(query) do
    with {:ok, inspection} <- Runtime.inspect_events(state.runtime, query),
         {:ok, status} <- Runtime.status(state.runtime) do
      lines =
        [
          "#{inspection.matched}/#{inspection.total} matched · showing #{inspection.returned} · cursor #{inspection.cursor}",
          "filters #{Enum.join(inspection.filters, " · ")}",
          "root log #{status.event_log_path}",
          ""
        ] ++ Enum.map(inspection.events, &format_runtime_event/1)

      notify(state, {:panel, "Goal events · #{inspection.returned} results", lines})
    else
      {:error, :event_filter_help} ->
        notify(state, {:panel, "Event inspector filters", RuntimeEventQuery.usage()})

      {:error, reason} ->
        lines = [event_filter_error(reason), "" | RuntimeEventQuery.usage()]
        notify(state, {:panel, "Invalid event filter", lines})
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

  defp run_command(:new, %{current: nil, verification: nil} = state) do
    with {:ok, provider} <- Config.provider_atom(state.config["provider"]),
         {:ok, new_session_id} <- start_session(state.config, provider),
         {:ok, subscription} <-
           Runtime.reconnect(state.runtime, new_session_id, after: nil, view: :internal) do
      _ = BeamAgent.stop_session(state.session_id)

      state = %{
        state
        | session_id: new_session_id,
          project_id: subscription.project_id,
          goal_id: subscription.goal_id,
          cursor: subscription.cursor,
          bootstrap_events: [],
          approval_policy: subscription.approval_policy,
          current: nil
      }

      notify(state, {:session_changed, new_session_id})
      Enum.each(subscription.events, &notify(state, {:stream, &1}))
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
      approval_policy: Config.approval_policy_atom(config["approval_policy"]),
      model_strategy: Config.model_strategy_atom(config["model_strategy"]),
      approval_handler: self(),
      model_endpoints: config["model_endpoints"] || []
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

  defp auto_fallback(:auto, config) do
    case Config.approval_policy_atom(config["approval_policy"]) do
      :auto -> :ask
      policy -> policy
    end
  end

  defp auto_fallback(policy, _config), do: policy

  defp format_error(reason), do: inspect(reason, pretty: true, limit: 8)

  defp format_runtime_event(event) do
    time = event.at |> to_string() |> String.slice(11, 12)
    worker = if event.scope.root?, do: "root", else: "child"
    source = "#{worker} #{short_id(event.scope.session_id)}"
    type = to_string(event.payload.type)

    lineage =
      "corr #{short_id(event.correlation_id || "none")} · cause #{short_id(event.causation_id || "root")}"

    "##{event.goal_seq}  #{time}  #{source}  #{event.category}/#{type}#{event_detail(event)}#{redaction_detail(event)} · #{lineage}"
  end

  defp event_detail(%{payload: %{type: type, data: data}})
       when type in ["agent_started", :agent_started] do
    " · #{data["provider"] || data[:provider]}/#{data["model"] || data[:model] || "built-in"}"
  end

  defp event_detail(%{payload: %{type: type, data: data}})
       when type in ["tool_called", :tool_called] do
    " · #{data["name"] || data[:name]}"
  end

  defp event_detail(%{payload: %{type: type, data: data}})
       when type in ["tool_result", :tool_result] do
    status = if data["is_error"] || data[:is_error], do: "error", else: "ok"
    " · #{data["name"] || data[:name]} · #{status}"
  end

  defp event_detail(%{payload: %{type: type, data: data}})
       when type in ["turn_finished", :turn_finished] do
    case data["reason"] || data[:reason] do
      reason when is_binary(reason) or is_atom(reason) -> " · #{reason}"
      _redacted_or_missing -> ""
    end
  end

  defp event_detail(_event), do: ""

  defp redaction_detail(%{redacted?: true}), do: " · redacted"
  defp redaction_detail(_event), do: ""

  defp event_filter_error({:unknown_event_filter, key}), do: "Unknown filter: #{key}"

  defp event_filter_error({:invalid_event_filter_value, key, value}),
    do: "Invalid #{key} value: #{value}"

  defp event_filter_error({:invalid_event_filter, token}), do: "Invalid filter: #{token}"
  defp event_filter_error(reason), do: format_error(reason)

  defp format_model_endpoint(endpoint, active_profile, evidence) do
    marker = if endpoint.id == active_profile, do: "●", else: "○"
    model = endpoint.model || "provider default"
    capabilities = endpoint.claims.capabilities |> Enum.map(&to_string/1) |> Enum.join(",")
    empirical = Enum.find(evidence.endpoints, &(&1.endpoint_id == endpoint.id))

    "#{marker} #{endpoint.id} · #{endpoint.provider}/#{model} · #{endpoint.claims.locality} · #{endpoint.health.status} · #{capabilities}#{format_model_evidence(empirical)}"
  end

  defp format_model_evidence(nil), do: " · evidence 0 verified"

  defp format_model_evidence(evidence) do
    quality =
      case evidence.verified_pass_rate do
        rate when is_number(rate) -> " · #{round(rate * 100)}% verified pass"
        _unknown -> ""
      end

    latency =
      if is_number(evidence.average_latency_ms),
        do: " · #{evidence.average_latency_ms} ms avg",
        else: ""

    " · evidence #{evidence.verified_samples} verified/#{evidence.operational_samples} calls#{quality}#{latency}"
  end

  defp format_usage(usage, limits) do
    [:model_tokens, :wall_time_ms, :shell_commands, :test_runs]
    |> Enum.map(fn key -> "#{key}=#{usage[key] || 0}/#{limit_label(limits[key])}" end)
    |> Enum.join(" · ")
  end

  defp limit_label(:infinity), do: "∞"
  defp limit_label(value), do: to_string(value || 0)

  defp strategy_id(%{id: id}), do: id
  defp strategy_id(id), do: id

  defp short_id(id) do
    id = to_string(id)

    suffix =
      case String.split(id, "-", parts: 2) do
        [_prefix, suffix] -> suffix
        [id] -> id
      end

    String.slice(suffix, 0, 8)
  end
end
