defmodule BeamAgent.CLI.TUI.Controller do
  @moduledoc false
  use GenServer

  alias BeamAgent.CLI.Config
  alias BeamAgent.{Providers, Runtime, RuntimeEventQuery}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def bootstrap(controller), do: GenServer.call(controller, :bootstrap)

  def submit(controller, prompt, attachment_ids \\ []),
    do: GenServer.cast(controller, {:submit, prompt, attachment_ids})

  def import_attachment(controller, attrs),
    do: GenServer.cast(controller, {:import_attachment, attrs})

  def delete_attachment(controller, attachment_id),
    do: GenServer.cast(controller, {:delete_attachment, attachment_id})

  def cancel(controller), do: GenServer.cast(controller, :cancel)

  def decide(controller, approval_id, decision),
    do: GenServer.cast(controller, {:decide, approval_id, decision})

  def command(controller, command), do: GenServer.cast(controller, {:command, command})
  def settings(controller, request), do: GenServer.cast(controller, {:settings, request})

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      client_monitor: Process.monitor(Keyword.fetch!(opts, :client)),
      runtime: nil,
      runtime_monitor: nil,
      session_id: Keyword.fetch!(opts, :session_id),
      project_id: nil,
      goal_id: nil,
      cursor: 0,
      bootstrap_events: [],
      bootstrap_approvals: [],
      config: Keyword.fetch!(opts, :config),
      config_path: Keyword.get(opts, :config_path, Config.path()),
      codex_app_server: Keyword.get(opts, :codex_app_server, BeamAgent.CodexAppServer),
      approval_policy: :ask,
      auto_fallback: :ask,
      current: nil,
      verification: nil,
      compacting?: false,
      auth_session: nil,
      auth_target_profile: nil,
      settings_task: nil,
      work_projection_timer: nil
    }

    with {:ok, runtime} <-
           Runtime.connect(state.session_id, subscriber: self(), view: :internal),
         :ok <- BeamAgent.Auth.subscribe(),
         {:ok, subscription} <- Runtime.bootstrap(runtime) do
      state = %{
        state
        | runtime: runtime,
          current: if(subscription.running?, do: :observing, else: nil),
          runtime_monitor: Process.monitor(runtime),
          project_id: subscription.project_id,
          goal_id: subscription.goal_id,
          cursor: subscription.cursor,
          bootstrap_events: subscription.events,
          bootstrap_approvals: subscription.pending_approvals,
          approval_policy: subscription.approval_policy,
          auto_fallback: auto_fallback(subscription.approval_policy, state.config)
      }

      notify(state, {:controller_ready, self()})
      if state.current == :observing, do: notify(state, {:turn_started, ""})
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
      events: state.bootstrap_events,
      pending_approvals: state.bootstrap_approvals
    }

    {:reply, {:ok, snapshot}, %{state | bootstrap_events: [], bootstrap_approvals: []}}
  end

  @impl true
  def handle_cast(
        {:submit, prompt, attachment_ids},
        %{current: nil, verification: nil, settings_task: nil} = state
      )
      when is_binary(prompt) and is_list(attachment_ids) do
    case Runtime.submit(state.runtime, prompt, attachment_ids) do
      :ok ->
        {:noreply, %{state | current: :running}}

      {:error, reason} ->
        notify(state, {:turn_finished, {:error, reason}})
        {:noreply, state}
    end
  end

  def handle_cast({:submit, _prompt, _attachment_ids}, state) do
    notify(state, {:notice, :warning, "A turn is already running"})
    {:noreply, state}
  end

  def handle_cast({:import_attachment, attrs}, state) do
    case Runtime.import_attachment(state.runtime, attrs) do
      {:ok, attachment} -> notify(state, {:attachment_imported, attachment})
      {:error, reason} -> notify(state, {:attachment_failed, reason})
    end

    {:noreply, state}
  end

  def handle_cast({:delete_attachment, attachment_id}, state) do
    case Runtime.delete_attachment(state.runtime, attachment_id) do
      :ok -> notify(state, {:attachment_deleted, attachment_id})
      {:error, reason} -> notify(state, {:attachment_failed, reason})
    end

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
      :ok ->
        :ok

      {:error, reason} ->
        notify(state, {:approval_failed, approval_id, reason})
        notify(state, {:notice, :error, format_error(reason)})
    end

    {:noreply, state}
  end

  def handle_cast({:command, command}, state) do
    {:noreply, run_command(command, state)}
  end

  def handle_cast({:settings, _request}, %{settings_task: task} = state) when not is_nil(task) do
    notify(state, {:settings_failed, "A settings request is already running"})
    {:noreply, state}
  end

  def handle_cast({:settings, request}, state) when is_map(request) do
    if request["action"] in ["list", "catalog"] or
         (state.current == nil and state.verification == nil and not state.compacting? and
            state.auth_session == nil) do
      owner = self()
      ref = make_ref()

      {:ok, pid} =
        Task.start(fn ->
          result =
            case request["action"] do
              "list" ->
                BeamAgent.CLI.ProviderManager.snapshot(state)

              "catalog" ->
                BeamAgent.CLI.ProviderManager.catalog(state, request["profile"])

              "refresh_catalog" ->
                with :ok <- Runtime.refresh_model_catalog(state.runtime),
                     :ok <- BeamAgent.ModelRegistry.await_catalog(state.project_id),
                     do: BeamAgent.CLI.ProviderManager.catalog(state, nil)

              _ ->
                BeamAgent.CLI.ProviderManager.prepare(state, request)
            end

          send(owner, {:settings_result, ref, result})
        end)

      timer = Process.send_after(self(), {:settings_timeout, ref}, 20_000)

      {:noreply,
       %{
         state
         | settings_task: %{
             pid: pid,
             monitor: Process.monitor(pid),
             ref: ref,
             timer: timer,
             action: request["action"]
           }
       }}
    else
      notify(
        state,
        {:settings_failed,
         "Finish or cancel active work/login before changing providers or models"}
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:settings_result, ref, result}, %{settings_task: %{ref: ref} = task} = state) do
    Process.cancel_timer(task.timer)
    Process.demonitor(task.monitor, [:flush])
    state = %{state | settings_task: nil}

    case {task.action, result} do
      {"list", {:ok, payload}} ->
        notify(state, {:provider_settings, payload})
        {:noreply, state}

      {action, {:ok, payload}} when action in ["catalog", "refresh_catalog"] ->
        notify(state, {:model_catalog, payload})
        {:noreply, state}

      {_, {:ok, prepared}} ->
        case BeamAgent.CLI.ProviderManager.commit(state, prepared) do
          {:ok, config} ->
            state = %{state | config: config}

            notify(
              state,
              {:settings_applied, Map.take(config, ~w(profile model model_strategy team_mode))}
            )

            if task.action in ["lock", "automatic"] do
              case BeamAgent.CLI.ProviderManager.catalog(state, nil) do
                {:ok, payload} -> notify(state, {:model_catalog, payload})
                {:error, reason} -> notify(state, {:settings_failed, format_error(reason)})
              end
            else
              case BeamAgent.CLI.ProviderManager.snapshot(state) do
                {:ok, payload} -> notify(state, {:provider_settings, payload})
                {:error, reason} -> notify(state, {:settings_failed, format_error(reason)})
              end
            end

            {:noreply, state}

          {:error, reason} ->
            notify(state, {:settings_failed, format_error(reason)})
            {:noreply, state}
        end

      {_, {:error, reason}} ->
        notify(state, {:settings_failed, format_error(reason)})
        {:noreply, state}
    end
  end

  def handle_info({:settings_timeout, ref}, %{settings_task: %{ref: ref} = task} = state) do
    Process.exit(task.pid, :kill)
    Process.demonitor(task.monitor, [:flush])
    notify(state, {:settings_failed, "Provider discovery timed out; settings were not changed"})
    {:noreply, %{state | settings_task: nil}}
  end

  def handle_info({:settings_result, _, _}, state), do: {:noreply, state}
  def handle_info({:settings_timeout, _}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _, reason},
        %{settings_task: %{monitor: monitor} = task} = state
      ) do
    Process.cancel_timer(task.timer)
    notify(state, {:settings_failed, "Settings request failed: #{inspect(reason, limit: 3)}"})
    {:noreply, %{state | settings_task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{client_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:beam_agent_runtime, runtime, {:event, event}}, %{runtime: runtime} = state) do
    state = observe_shared_turn(state, event)
    notify(state, {:stream, event})

    if to_string(event.payload[:type] || event.payload["type"] || "") in [
         "documentation_mission_state",
         "documentation_mission_report"
       ] do
      send(self(), :refresh_documentation_mission)
    end

    state = schedule_work_projection(state, event)

    cursor =
      case event do
        %{durability: :durable, goal_seq: goal_seq} when is_integer(goal_seq) ->
          max(state.cursor, goal_seq)

        _event ->
          state.cursor
      end

    {:noreply, %{state | cursor: cursor}}
  end

  def handle_info(:refresh_work_projection, state) do
    payload = %{
      work_blocks: soft_fetch(fn -> Runtime.work_blocks(state.runtime) end) || [],
      progress: soft_fetch(fn -> Runtime.progress(state.runtime) end)
    }

    notify(state, {:work_projection, payload})
    {:noreply, %{state | work_projection_timer: nil}}
  end

  def handle_info(:refresh_documentation_mission, state) do
    case Runtime.documentation_mission(state.runtime, "status") do
      {:ok, status} -> notify(state, {:mission_update, mission_panel(status)})
      _ -> :ok
    end

    {:noreply, state}
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
        {:beam_agent_runtime, runtime, {:turn_steered, message}},
        %{runtime: runtime} = state
      ) do
    notify(state, {:turn_steered, message})
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
        {:beam_agent_runtime, runtime, {:approvals_reconciled, approvals}},
        %{runtime: runtime} = state
      ) do
    notify(state, {:approvals_reconciled, approvals})
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
        {:beam_agent_auth, session, %{type: :auth_user_action_required, data: action}},
        %{auth_session: session} = state
      ) do
    _ = open_browser(action.verification_uri_complete || action.verification_uri)

    action_lines =
      if action.user_code,
        do: ["Enter code: #{action.user_code}", ""],
        else: ["Complete sign-in in the browser.", ""]

    notify(state, {
      :panel,
      "Provider login",
      [
        "Open #{action.verification_uri}"
      ] ++
        action_lines ++
        [
          "BeamAgent will keep waiting until the provider completes or expires this code."
        ]
    })

    {:noreply, state}
  end

  def handle_info(
        {:beam_agent_auth, session, %{type: :auth_completed}},
        %{auth_session: session} = state
      ) do
    case BeamAgent.Auth.await(session) do
      {:ok, result} ->
        case persist_authentication(state, result) do
          {:ok, state} ->
            notify(state, {:notice, :success, "Provider login completed"})
            state = %{state | auth_session: nil, auth_target_profile: nil}
            {:noreply, if(state.current == nil, do: run_command(:new, state), else: state)}

          {:error, reason} ->
            notify(state, {:notice, :error, format_error(reason)})
            {:noreply, %{state | auth_session: nil, auth_target_profile: nil}}
        end

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        {:noreply, %{state | auth_session: nil, auth_target_profile: nil}}
    end
  end

  def handle_info(
        {:beam_agent_auth, session, %{type: :auth_failed, data: data}},
        %{auth_session: session} = state
      ) do
    notify(state, {:notice, :error, "Provider login failed · #{data.reason}"})
    {:noreply, %{state | auth_session: nil, auth_target_profile: nil}}
  end

  def handle_info(
        {:beam_agent_auth, _broker, %{type: :auth_token_refreshed, data: data}},
        state
      ) do
    notify(state, {
      :notice,
      :muted,
      "Provider credential refreshed · #{data.provider || state.config["provider"]}"
    })

    {:noreply, state}
  end

  def handle_info({:beam_agent_auth, _session, _event}, state), do: {:noreply, state}

  def handle_info({:codex_app_server, _client, _event}, state), do: {:noreply, state}

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
    if state.settings_task do
      Process.cancel_timer(state.settings_task.timer)
      Process.exit(state.settings_task.pid, :kill)
    end

    if state.runtime_monitor, do: Process.demonitor(state.runtime_monitor, [:flush])
    if state.runtime, do: Runtime.disconnect(state.runtime)

    if is_pid(state.auth_session) and Process.alive?(state.auth_session),
      do: BeamAgent.Auth.cancel(state.auth_session)

    :ok
  end

  # A different client can submit to this same runtime. Its caller-specific
  # notifications do not reach us, but the canonical lifecycle events do.
  defp observe_shared_turn(%{current: nil} = state, %{
         durability: :durable,
         scope: %{root?: true},
         payload: %{type: "user_message", data: data}
       }) do
    notify(state, {:turn_started, data["content"] || ""})
    %{state | current: :observing}
  end

  defp observe_shared_turn(%{current: :observing} = state, %{
         durability: :durable,
         scope: %{root?: true},
         payload: %{type: "turn_finished", data: data}
       }) do
    result =
      if data["reason"] == "completed",
        do: {:ok, ""},
        else: {:error, data["reason"] || :work_stopped}

    notify(state, {:turn_finished, result})
    %{state | current: nil}
  end

  defp observe_shared_turn(state, _), do: state

  defp run_command(_command, %{settings_task: task} = state) when not is_nil(task) do
    notify(state, {:notice, :warning, "Wait for the settings request to finish"})
    state
  end

  defp run_command(:providers, state) do
    settings(self(), %{"action" => "list"})
    state
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

  defp run_command(:connect, %{auth_session: session} = state) when is_pid(session) do
    notify(state, {:notice, :warning, "Provider login is already in progress"})
    state
  end

  defp run_command({:connect, "chatgpt"}, %{config: %{"provider" => "openai"}} = state) do
    connect_chatgpt_profile(state, state.config["profile"])
  end

  defp run_command({:connect, "chatgpt"}, state) do
    notify(state, {:notice, :error, "ChatGPT login is available only for OpenAI profiles"})
    state
  end

  defp run_command(:connect, state) do
    case provider_picker(state) do
      {:ok, providers} ->
        notify(state, {:provider_picker, providers})
        state

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command({:connect, "profile:" <> profile}, state) do
    connect_profile(state, profile)
  end

  defp run_command({:connect, query}, state) do
    notify(state, {:notice, :warning, "Unsupported provider selection: #{query}"})
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
          "phase     #{status.goal_phase}",
          "work      #{format_work_contract(status.work_contract)}",
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

  defp run_command({:steer, ""}, state) do
    notify(state, {:notice, :warning, "Usage: /steer MESSAGE"})
    state
  end

  defp run_command({:steer, message}, %{current: :running} = state) do
    case Runtime.steer(state.runtime, message) do
      :ok ->
        state

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command({:steer, _message}, state) do
    notify(state, {:notice, :warning, "Nothing is running to steer"})
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

  defp run_command(:mission, state), do: run_command({:mission, "status"}, state)
  defp run_command({:mission, ""}, state), do: run_command(:mission, state)

  defp run_command({:mission, action}, state)
       when action in ["start", "status", "pause", "resume", "dismiss", "stop", "delete"] do
    case Runtime.documentation_mission(state.runtime, action) do
      result when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) ->
        case Runtime.documentation_mission(state.runtime, "status") do
          {:ok, status} ->
            notify(state, {:mission_panel, mission_panel(status)})

          {:error, reason} ->
            notify(state, {:notice, :error, "Mission unavailable: #{inspect(reason)}"})
        end

      {:error, reason} ->
        notify(state, {:notice, :error, "Mission action not accepted: #{inspect(reason)}"})
    end

    state
  end

  defp run_command({:mission, _}, state) do
    notify(
      state,
      {:notice, :error, "Use /mission [start|status|pause|resume|dismiss|stop|delete]"}
    )

    state
  end

  defp run_command({:race, ""}, state) do
    notify(state, {:notice, :warning, "Usage: /race GOAL"})
    state
  end

  defp run_command({:race, _query}, %{current: current} = state) when not is_nil(current) do
    notify(state, {:notice, :warning, "A turn is already running"})
    state
  end

  defp run_command({:race, query}, state) when is_binary(query) do
    provider_count =
      case Runtime.models(state.runtime) do
        {:ok, endpoints} -> endpoints |> length() |> min(3) |> max(2)
        {:error, _reason} -> 2
      end

    count = if provider_count == 3, do: "three", else: "two"

    prompt =
      """
      Run a provider race with #{count} independent candidates for exactly the same request. The first admissible terminal result wins; cancel all other candidates immediately.

      User request:
      #{query}
      """
      |> String.trim()

    case Runtime.submit(state.runtime, prompt, []) do
      :ok ->
        %{state | current: :running}

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command({:tournament, ""}, state) do
    notify(state, {:notice, :warning, "Usage: /tournament GOAL"})
    state
  end

  defp run_command({:tournament, _query}, %{current: current} = state)
       when not is_nil(current) do
    notify(state, {:notice, :warning, "A turn is already running"})
    state
  end

  defp run_command({:tournament, query}, state) when is_binary(query) do
    provider_count =
      case Runtime.models(state.runtime) do
        {:ok, endpoints} -> endpoints |> length() |> min(3) |> max(2)
        {:error, _reason} -> 2
      end

    count = if provider_count == 3, do: "three", else: "two"

    prompt =
      """
      Run a provider tournament with #{count} competing independent candidates for exactly the same request. Keep only the single winner selected by quality evidence and do not merge their answers.

      User request:
      #{query}
      """
      |> String.trim()

    case Runtime.submit(state.runtime, prompt, []) do
      :ok ->
        %{state | current: :running}

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command({:models, ""}, state) do
    case Runtime.models(state.runtime) do
      {:ok, endpoints} ->
        evidence =
          case Runtime.routing_evidence(state.runtime) do
            {:ok, evidence} -> evidence
            {:error, _reason} -> %{endpoints: []}
          end

        payload = %{
          active_profile: state.config["profile"],
          endpoints: endpoints,
          evidence: evidence,
          market: latest_provider_market(state.goal_id),
          session_settings: model_session_settings(state)
        }

        payload =
          case BeamAgent.CLI.ProviderManager.catalog(state, nil) do
            {:ok, catalog} -> Map.merge(payload, catalog)
            _ -> payload
          end

        notify(state, {:models, payload})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:models, "refresh"}, state) do
    :ok = Runtime.refresh_model_catalog(state.runtime)

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
      payload = %{
        root: tree.root,
        nodes: tree.nodes,
        summary: tree_summary(tree),
        budget: soft_fetch(fn -> Runtime.budget(state.runtime) end),
        resource_pools: soft_fetch(fn -> Runtime.resource_pools(state.runtime) end),
        workspace_diff: soft_fetch(fn -> Runtime.diff_summary(state.runtime) end),
        work_blocks: soft_fetch(fn -> Runtime.work_blocks(state.runtime) end) || [],
        progress: soft_fetch(fn -> Runtime.progress(state.runtime) end)
      }

      notify(state, {:tree, payload})
    else
      {:error, reason} -> notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:cancel_worker, worker_id}, state) do
    with {:ok, identity} <- BeamAgent.Agent.runtime_identity(worker_id),
         true <- identity.goal_id == state.goal_id,
         :ok <- BeamAgent.cancel(worker_id) do
      notify(state, {:notice, :success, "Cancelling worker #{short_id(worker_id)}"})
    else
      false -> notify(state, {:notice, :error, "Worker is outside the active goal"})
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
    case {Runtime.resource_pools(state.runtime), Runtime.path_leases(state.runtime)} do
      {{:ok, pools}, {:ok, leases}} ->
        pool_lines =
          pools
          |> Enum.sort_by(fn {name, _pool} -> name end)
          |> Enum.map(fn {name, pool} ->
            "#{name} · #{pool.active}/#{pool.limit} active · #{pool.queued} queued"
          end)

        lease_lines =
          Enum.map(leases, fn lease ->
            "write lease · #{short_id(lease.owner)} · #{lease.path}"
          end)

        lines =
          pool_lines ++ if(lease_lines == [], do: ["write leases · none"], else: lease_lines)

        notify(state, {:panel, "Resource scheduler", lines})

      {{:error, reason}, _leases} ->
        notify(state, {:notice, :error, format_error(reason)})

      {_pools, {:error, reason}} ->
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
    case Runtime.inspect_events(state.runtime, query) do
      {:ok, inspection} ->
        payload = %{
          matched: inspection.matched,
          total: inspection.total,
          returned: inspection.returned,
          cursor: inspection.cursor,
          filters: inspection.filters,
          available_categories: RuntimeEventQuery.categories(),
          events: inspection.events
        }

        notify(state, {:events, payload})

      {:error, :event_filter_help} ->
        notify(state, {:panel, "Event inspector filters", RuntimeEventQuery.usage()})

      {:error, reason} ->
        lines = [event_filter_error(reason), "" | RuntimeEventQuery.usage()]
        notify(state, {:panel, "Invalid event filter", lines})
    end

    state
  end

  defp run_command(:sessions, state), do: run_command({:sessions, ""}, state)

  defp run_command({:sessions, ""}, state) do
    case Runtime.sessions(state.runtime) do
      {:ok, sessions} ->
        decorated = Enum.map(sessions, &Map.put(&1, :status, session_status(&1, state)))
        notify(state, {:sessions, %{sessions: decorated}})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:sessions, session_id}, state) when is_binary(session_id) do
    case Runtime.session_detail(state.runtime, session_id) do
      {:ok, detail} ->
        notify(state, {:session_detail, detail})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  @read_only_tool_names ~w(read_file file_diagnostics file_symbols)

  defp run_command(:files, state), do: run_command({:files, ""}, state)

  defp run_command({:files, ""}, state) do
    case Runtime.diff(state.runtime, hunks?: false) do
      {:ok, diff} ->
        changed_paths = MapSet.new(diff.changed_files, & &1.path)

        payload = %{
          branch: diff.branch,
          changed: diff.changed_files,
          in_context: in_context_files(state, changed_paths)
        }

        notify(state, {:files, payload})

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:files, path}, state) when is_binary(path) do
    case Runtime.diff(state.runtime, path: path, hunks?: true) do
      {:ok, %{files: files}} ->
        case Map.get(files, path) do
          nil ->
            notify(state, {:notice, :warning, "No diff for #{path}"})

          file ->
            notify(state, {:diff, Map.put(file, :path, path)})
        end

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
    end

    state
  end

  defp run_command({:resume, session_id}, %{current: nil, verification: nil} = state)
       when is_binary(session_id) do
    with {:ok, subscription} <-
           Runtime.reconnect(state.runtime, session_id, after: nil, view: :internal) do
      _ = BeamAgent.stop_session(state.session_id)

      state = %{
        state
        | session_id: session_id,
          project_id: subscription.project_id,
          goal_id: subscription.goal_id,
          cursor: subscription.cursor,
          bootstrap_events: [],
          approval_policy: subscription.approval_policy,
          current: nil
      }

      notify(
        state,
        {:session_changed, session_id, state.config, subscription.attachments}
      )

      Enum.each(subscription.events, &notify(state, {:stream, &1}))
      notify_context_stats(state)
      state
    else
      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp run_command({:resume, _session_id}, state) do
    notify(state, {:notice, :warning, "Cancel the running turn before resuming another session"})
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

      notify(
        state,
        {:session_changed, new_session_id, state.config, subscription.attachments}
      )

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

  defp provider_picker(state) do
    with {:ok, config} <- Config.load(state.config_path) do
      chatgpt_available? = chatgpt_account?(state)

      providers =
        Enum.map(Config.profiles(config), fn {profile, provider_config} ->
          %{
            profile: profile,
            provider: provider_config["provider"],
            model: provider_config["model"] || "provider default",
            auth: auth_label(provider_config),
            status: profile_status(provider_config, chatgpt_available?),
            connected: profile_connected?(provider_config, chatgpt_available?),
            active: profile == config["active_profile"]
          }
        end)

      {:ok, providers}
    end
  end

  defp connect_profile(%{current: current} = state, _profile) when not is_nil(current) do
    notify(state, {:notice, :warning, "Cancel the running turn before changing providers"})
    state
  end

  defp connect_profile(state, profile) do
    with {:ok, config} <- Config.load(state.config_path),
         {:ok, runtime} <- Config.runtime(config, profile) do
      cond do
        runtime["provider"] == "openai" and get_in(runtime, ["auth", "type"]) != "api_key" ->
          connect_chatgpt_profile(state, profile)

        profile_ready?(runtime) ->
          activate_profile(state, config, profile)

        true ->
          notify(state, {
            :panel,
            "Connect #{profile}",
            [
              "#{runtime["provider"]} requires an API key.",
              "",
              "Run `beam_agent auth login #{profile} --api-key`, then open `/connect` again."
            ]
          })

          state
      end
    else
      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp connect_chatgpt_profile(state, profile) do
    with {:ok, config} <- Config.load(state.config_path),
         {:ok, %{"provider" => "openai"}} <- Config.runtime(config, profile) do
      state = %{state | auth_target_profile: profile}

      if chatgpt_account?(state) do
        result = %{
          auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
          credential_reference: nil
        }

        case persist_authentication(state, result) do
          {:ok, state} ->
            notify(state, {:notice, :success, "Connected #{profile} through ChatGPT"})
            run_command(:new, %{state | auth_target_profile: nil})

          {:error, reason} ->
            notify(state, {:notice, :error, format_error(reason)})
            %{state | auth_target_profile: nil}
        end
      else
        start_chatgpt_login(state, profile)
      end
    else
      {:ok, _runtime} ->
        notify(state, {:notice, :error, "ChatGPT login is available only for OpenAI profiles"})
        state

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp start_chatgpt_login(state, profile) do
    case BeamAgent.Auth.start_chatgpt_login(profile, :openai, owner: self()) do
      {:ok, session} ->
        notify(state, {:notice, :muted, "Starting ChatGPT login…"})
        %{state | auth_session: session, auth_target_profile: profile}

      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        %{state | auth_target_profile: nil}
    end
  end

  defp activate_profile(state, config, profile) do
    with {:ok, config} <- Config.use_profile(config, profile),
         {:ok, _path} <- Config.write(config, state.config_path),
         {:ok, state} <- apply_runtime_profile(state, config, profile) do
      notify(state, {:notice, :success, "Using provider profile #{profile}"})
      run_command(:new, state)
    else
      {:error, reason} ->
        notify(state, {:notice, :error, format_error(reason)})
        state
    end
  end

  defp chatgpt_account?(state) do
    match?(
      {:ok, %{"account" => %{"type" => "chatgpt"}}},
      state.codex_app_server.account()
    )
  end

  defp auth_label(%{"auth" => %{"type" => "chatgpt"}}), do: "ChatGPT subscription"
  defp auth_label(%{"auth" => %{"type" => "api_key"}}), do: "API key"
  defp auth_label(%{"auth" => %{"type" => "device_code"}}), do: "Browser code"
  defp auth_label(%{"provider" => "openai"}), do: "ChatGPT or API key"
  defp auth_label(%{"api_key_env" => env}) when is_binary(env), do: "API key"
  defp auth_label(_profile), do: "Local"

  defp profile_status(%{"auth" => %{"type" => "chatgpt"}}, true), do: "connected"
  defp profile_status(%{"provider" => "openai"}, true), do: "ChatGPT available"

  defp profile_status(profile, _chatgpt_available?) do
    if profile_ready?(profile), do: "ready", else: "API key required"
  end

  defp profile_connected?(%{"auth" => %{"type" => "chatgpt"}}, available?), do: available?
  defp profile_connected?(profile, _available?), do: profile_ready?(profile)

  defp profile_ready?(%{"credential_ref" => reference})
       when is_binary(reference) and reference != "",
       do: true

  defp profile_ready?(%{"api_key_env" => environment})
       when is_binary(environment) and environment != "",
       do: present?(System.get_env(environment))

  defp profile_ready?(profile) do
    case Providers.fetch(profile["provider"]) do
      {:ok, provider} -> is_nil(provider[:default_api_key_env])
      {:error, _reason} -> false
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

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
      team_mode: Config.team_mode_atom(config["team_mode"]),
      approval_handler: self(),
      model_endpoints: config["model_endpoints"] || []
    )
  end

  defp persist_authentication(state, result) do
    auth = Map.get(result, :auth) || state.config["auth"]
    profile = state.auth_target_profile || state.config["profile"]

    with {:ok, config} <- Config.load(state.config_path),
         {:ok, config} <-
           Config.put_profile_auth(
             config,
             profile,
             result.credential_reference,
             auth
           ),
         {:ok, config} <- Config.use_profile(config, profile),
         {:ok, _path} <- Config.write(config, state.config_path),
         {:ok, state} <- apply_runtime_profile(state, config, profile) do
      {:ok, state}
    end
  end

  defp apply_runtime_profile(state, config, profile) do
    with {:ok, runtime} <- Config.runtime(config, profile) do
      runtime =
        state.config
        |> Map.merge(runtime)
        |> Map.put("model_endpoints", Config.model_endpoints(config, runtime))

      {:ok, %{state | config: runtime}}
    end
  end

  defp open_browser(url) do
    executable =
      case :os.type() do
        {:unix, :darwin} -> System.find_executable("open")
        _ -> System.find_executable("xdg-open")
      end

    if executable do
      Task.start(fn -> System.cmd(executable, [url], stderr_to_stdout: true) end)
      :ok
    else
      {:error, :browser_launcher_unavailable}
    end
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

  defp format_error(reason), do: BeamAgent.CLI.ErrorFormatter.format(reason)

  defp soft_fetch(fun) do
    case fun.() do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp in_context_files(state, changed_paths) do
    case Runtime.inspect_events(
           state.runtime,
           "category=tool type=tool_called order=desc limit=100"
         ) do
      {:ok, inspection} ->
        inspection.events
        |> Enum.filter(&(tool_call_name(&1.payload.data) in @read_only_tool_names))
        |> Enum.map(&tool_call_path(&1.payload.data))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(changed_paths, &1))
        |> Enum.map(&%{path: &1, tag: "auto"})

      {:error, _reason} ->
        []
    end
  end

  defp tool_call_name(data), do: data["name"] || data[:name]

  defp tool_call_path(data) do
    (data["arguments"] || data[:arguments] || %{})
    |> then(&(&1["path"] || &1[:path]))
  end

  defp tree_summary(tree) do
    nodes = Map.values(tree.nodes)

    %{
      worker_count: length(nodes),
      running_count: Enum.count(nodes, &(&1.state == :running)),
      completed_count: Enum.count(nodes, &(&1.state == :completed)),
      failed_count: Enum.count(nodes, &(&1.state == :failed)),
      restart_count: Enum.reduce(nodes, 0, &(&2 + (&1.restart_count || 0)))
    }
  end

  defp session_status(%{session_id: session_id}, %{session_id: session_id}), do: "current"

  defp session_status(%{session_id: session_id}, _state) do
    case BeamAgent.agent_pid(session_id) do
      {:ok, _pid} -> "active"
      {:error, _reason} -> "idle"
    end
  end

  defp event_filter_error({:unknown_event_filter, key}), do: "Unknown filter: #{key}"

  defp event_filter_error({:invalid_event_filter_value, key, value}),
    do: "Invalid #{key} value: #{value}"

  defp event_filter_error({:invalid_event_filter, token}), do: "Invalid filter: #{token}"
  defp event_filter_error(reason), do: format_error(reason)

  defp format_usage(usage, limits) do
    [:model_tokens, :wall_time_ms, :shell_commands, :test_runs]
    |> Enum.map(fn key -> "#{key}=#{usage[key] || 0}/#{limit_label(limits[key])}" end)
    |> Enum.join(" · ")
  end

  defp mission_panel(status) do
    actions = status["available_actions"] || []

    shortcuts = %{
      "start" => "s",
      "pause" => "p",
      "resume" => "r",
      "dismiss" => "d",
      "stop" => "x",
      "delete" => "X"
    }

    controls = Enum.map_join(actions, " · ", &"#{shortcuts[&1]} #{&1}")
    report = status["report"] || %{}

    %{
      title: "BACKGROUND / DOCUMENTATION",
      mission_actions: actions,
      lines: [
        "#{status["status"]} · #{status["attempts"] || 0}/#{status["max_assessments"] || 3} assessments",
        "Read-only advice · selected session model · may consume provider allowance",
        "Tracks future Git changes: #{Enum.join(status["paths"] || ["lib", "src", "test", "docs", "README.md"], ", ")}",
        "Quiet #{status["quiet_seconds"] || 60}s · cooldown #{status["cooldown_seconds"] || 300}s · owner must stay running",
        "ION keys: #{controls} · f refresh · Esc close",
        "Both TUIs: /mission #{Enum.join(actions ++ ["status"], " | ")}",
        "Stop cancels observer + fix agents. Delete removes configuration/report, keeps history/worktrees.",
        "#{status["reason"] || ""}",
        "#{report["status"] || "No report yet"}",
        report["content"] || "Suggestions are not applied automatically."
      ]
    }
  end

  defp limit_label(:infinity), do: "∞"
  defp limit_label(value), do: to_string(value || 0)

  defp strategy_id(%{id: id}), do: id
  defp strategy_id(id), do: id

  defp format_work_contract(nil), do: "idle"

  defp format_work_contract(contract) do
    "#{contract.kind} → #{contract.worker_kind} → #{contract.expected_artifact}"
  end

  defp schedule_work_projection(%{work_projection_timer: nil} = state, event) do
    if Map.get(event, :durability) == :durable or Map.get(event, "durability") == "durable" do
      %{state | work_projection_timer: Process.send_after(self(), :refresh_work_projection, 120)}
    else
      state
    end
  end

  defp schedule_work_projection(state, _event), do: state

  defp short_id(id) do
    id = to_string(id)

    suffix =
      case String.split(id, "-", parts: 2) do
        [_prefix, suffix] -> suffix
        [id] -> id
      end

    String.slice(suffix, 0, 8)
  end

  defp model_session_settings(state) do
    token_budget =
      case Runtime.status(state.runtime) do
        {:ok, status} -> status.context_stats.window_tokens
        {:error, _reason} -> nil
      end

    mcp_server_count =
      case Runtime.mcp_servers(state.runtime) do
        {:ok, servers} -> length(servers)
        {:error, _reason} -> nil
      end

    %{
      approval_mode: to_string(state.approval_policy),
      token_budget: token_budget,
      mcp_server_count: mcp_server_count
    }
  end

  defp latest_provider_market(goal_id) do
    case BeamAgent.provider_market(goal_id) do
      {:ok, market} -> market
      :not_found -> nil
      {:error, _reason} -> nil
    end
  end
end
