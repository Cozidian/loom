defmodule BeamAgent.CLI.TUI do
  @moduledoc false

  alias BeamAgent.CLI.Config
  alias BeamAgent.CLI.TUI.Controller

  @commands ~w(connect auto status new sessions models skills reload compact verify events tree budget repository resources organizations worktrees)a

  def available?(override \\ nil)

  def available?(false), do: false

  def available?(_override) do
    System.get_env("BEAM_AGENT_NO_TUI") not in ["1", "true"] and
      System.get_env("TERM") not in [nil, "", "dumb"] and
      not is_nil(executable()) and tty?()
  end

  @doc false
  def executable do
    [
      System.get_env("BEAM_AGENT_TUI_BIN"),
      escript_sibling(),
      Path.expand("beam_agent_tui"),
      application_binary()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(&System.find_executable/1)
  end

  def run(session_id, config, config_path \\ Config.path()) do
    with executable when is_binary(executable) <- executable(),
         {:ok, port} <- open_port(executable),
         {:ok, controller} <-
           Controller.start_link(
             client: self(),
             session_id: session_id,
             config: config,
             config_path: config_path
           ),
         {:ok, bootstrap} <- Controller.bootstrap(controller) do
      Process.unlink(controller)
      monitor = Process.monitor(controller)

      try do
        :ok = send_packet(port, initial_payload(session_id, config, bootstrap))
        bridge_loop(port, controller, monitor)
      after
        Process.demonitor(monitor, [:flush])
        stop_controller(controller)
        close_port(port)
      end
    else
      nil -> {:error, :go_tui_not_built}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def initial_payload(session_id, config) do
    {:ok, identity} = BeamAgent.Agent.runtime_identity(session_id)
    {:ok, events} = BeamAgent.goal_events(identity.goal_id, view: :internal)
    {:ok, approval_policy} = BeamAgent.approval_policy(session_id)

    initial_payload(session_id, config, %{
      project_id: identity.project_id,
      goal_id: identity.goal_id,
      cursor: event_cursor(events),
      events: events,
      approval_policy: approval_policy
    })
  end

  @doc false
  def initial_payload(session_id, config, bootstrap) do
    %{
      type: "init",
      session_id: session_id,
      project_id: bootstrap.project_id,
      goal_id: bootstrap.goal_id,
      cursor: bootstrap.cursor,
      workspace: config["workspace_root"],
      provider: config["provider"],
      profile: config["profile"],
      model: config["model"] || "built-in",
      approval_mode: approval_mode(bootstrap, config),
      entries: history(bootstrap.events),
      context_stats: context_stats(session_id)
    }
  end

  @doc false
  def notification_payload({:turn_started, prompt}),
    do: %{type: "turn_started", prompt: prompt}

  def notification_payload(:turn_cancelling), do: %{type: "turn_cancelling"}

  def notification_payload({:turn_finished, {:ok, _answer}}),
    do: %{type: "turn_finished", ok: true}

  def notification_payload({:turn_finished, {:error, reason}}),
    do: %{type: "turn_finished", ok: false, error: format_error(reason)}

  def notification_payload({:stream, event}),
    do: %{type: "stream", event: json_safe(event)}

  def notification_payload({:approval_requested, request}),
    do: %{type: "approval_requested", approval: json_safe(request)}

  def notification_payload({:approval_resolved, approval_id, decision}) do
    %{
      type: "approval_resolved",
      approval_id: approval_id,
      decision: to_string(decision)
    }
  end

  def notification_payload({:notice, tone, message}),
    do: %{type: "notice", tone: to_string(tone), message: message}

  def notification_payload({:panel, title, lines}),
    do: %{type: "panel", title: title, lines: lines}

  def notification_payload({:provider_picker, providers}),
    do: %{type: "provider_picker", providers: json_safe(providers)}

  def notification_payload({:session_changed, session_id, config}) do
    %{
      type: "session_changed",
      session_id: session_id,
      provider: config["provider"],
      profile: config["profile"],
      model: config["model"] || "built-in"
    }
  end

  def notification_payload({:session_changed, session_id}),
    do: %{type: "session_changed", session_id: session_id}

  def notification_payload({:context_stats, stats}),
    do: %{type: "context_stats", stats: json_safe(stats)}

  def notification_payload({:approval_mode, policy}),
    do: %{type: "approval_mode", approval_mode: to_string(policy)}

  def notification_payload({:controller_ready, _controller}), do: nil
  def notification_payload(_message), do: nil

  defp bridge_loop(port, controller, monitor) do
    receive do
      {^port, {:data, data}} ->
        with {:ok, action} <- JSON.decode(data),
             :ok <- dispatch_action(action, controller) do
          bridge_loop(port, controller, monitor)
        else
          {:error, reason} ->
            _ = send_packet(port, %{type: "notice", tone: "error", message: format_error(reason)})
            bridge_loop(port, controller, monitor)
        end

      {:beam_agent_tui, message} ->
        if payload = notification_payload(message), do: send_packet(port, payload)
        bridge_loop(port, controller, monitor)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:go_tui_exit, status}}

      {^port, :eof} ->
        bridge_loop(port, controller, monitor)

      {:DOWN, ^monitor, :process, ^controller, :normal} ->
        :ok

      {:DOWN, ^monitor, :process, ^controller, reason} ->
        {:error, {:tui_controller_exit, reason}}
    end
  end

  defp dispatch_action(%{"type" => "submit", "prompt" => prompt}, controller)
       when is_binary(prompt) do
    Controller.submit(controller, prompt)
    :ok
  end

  defp dispatch_action(%{"type" => "cancel"}, controller) do
    Controller.cancel(controller)
    :ok
  end

  defp dispatch_action(
         %{"type" => "approval", "approval_id" => approval_id, "decision" => decision},
         controller
       )
       when decision in ["allow_once", "allow_always", "deny"] do
    Controller.decide(controller, approval_id, String.to_existing_atom(decision))
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "events", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:events, query})
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "models", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:models, query})
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "tree", "query" => _query},
         controller
       ) do
    Controller.command(controller, :tree)
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "connect", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:connect, query})
    :ok
  end

  defp dispatch_action(%{"type" => "command", "command" => command}, controller) do
    with {:ok, command} <- command_atom(command) do
      Controller.command(controller, command)
    end
  end

  defp dispatch_action(%{"type" => "exit"}, _controller), do: :ok
  defp dispatch_action(action, _controller), do: {:error, {:invalid_tui_action, action}}

  defp command_atom(command) when is_binary(command) do
    case Enum.find(@commands, &(Atom.to_string(&1) == command)) do
      nil -> {:error, {:unsupported_tui_command, command}}
      found -> {:ok, found}
    end
  end

  defp command_atom(command), do: {:error, {:unsupported_tui_command, command}}

  defp open_port(executable) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        :hide,
        {:packet, 4}
      ])

    {:ok, port}
  rescue
    error -> {:error, {:go_tui_start_failed, Exception.message(error)}}
  end

  defp send_packet(port, payload) do
    if Port.command(port, JSON.encode!(payload)) do
      :ok
    else
      {:error, :go_tui_closed}
    end
  rescue
    error -> {:error, {:go_tui_write_failed, Exception.message(error)}}
  end

  defp history(events), do: Enum.reduce(events, [], &history_event/2)

  defp event_cursor([]), do: 0
  defp event_cursor(events), do: List.last(events).goal_seq

  defp history_event(
         %{payload: %{type: "user_message", data: data}, scope: %{root?: true}},
         entries
       ) do
    entries ++ [%{kind: "user", content: data["content"]}]
  end

  defp history_event(
         %{payload: %{type: "assistant_message", data: data}, scope: %{root?: true}},
         entries
       ) do
    if is_binary(data["content"]) and data["content"] != "" do
      entries ++ [%{kind: "assistant", content: data["content"]}]
    else
      entries
    end
  end

  defp history_event(%{payload: %{type: "tool_called", data: data}, scope: scope}, entries) do
    entries ++
      [
        %{
          kind: "tool",
          id: tool_id(scope.session_id, data["tool_call_id"]),
          name: tool_name(scope, data["name"]),
          arguments: data["arguments"] || %{},
          status: "running",
          content: nil,
          error: false
        }
      ]
  end

  defp history_event(%{payload: %{type: "tool_result", data: data}, scope: scope}, entries) do
    id = tool_id(scope.session_id, data["tool_call_id"])

    case Enum.find_index(entries, &(&1.kind == "tool" and &1.id == id)) do
      nil ->
        entries

      index ->
        List.update_at(entries, index, fn entry ->
          Map.merge(entry, %{
            status: if(data["is_error"], do: "error", else: "done"),
            content: data["content"],
            error: data["is_error"] || false
          })
        end)
    end
  end

  defp history_event(event, entries) do
    case info_entry(event) do
      nil -> entries
      content -> entries ++ [%{kind: "info", content: content}]
    end
  end

  defp info_entry(%{
         payload: %{type: "session_started"},
         scope: %{root?: true, goal_id: goal_id}
       }),
       do: "Goal started · #{short_id(goal_id)}"

  defp info_entry(%{
         payload: %{type: "agent_started", data: data},
         scope: %{root?: true}
       }) do
    recovered = if data["recovered"], do: " · recovered", else: ""
    "Default model · #{data["provider"]}/#{data["model"] || "built-in"}#{recovered}"
  end

  defp info_entry(%{
         payload: %{type: "subagent_spawned", data: data}
       }),
       do: "Subagent spawned · #{short_id(data["child_session_id"])}"

  defp info_entry(%{payload: %{type: "agent_construction_requested", data: data}}) do
    requested = data["role_requested"] || data["template_requested"] || "dynamic specialist"
    "Agent requested · #{requested} · #{short_id(data["target_session_id"])}"
  end

  defp info_entry(%{payload: %{type: "agent_constructed", data: data}}),
    do:
      "Agent constructed · #{data["role"]} · #{data["authority"]} authority · #{short_id(data["target_session_id"])}"

  defp info_entry(%{
         payload: %{type: "agent_spec_applied", data: data},
         scope: %{session_id: session_id}
       }),
       do: "Agent ready · #{data["role"]} · #{short_id(session_id)}"

  defp info_entry(%{payload: %{type: "agent_construction_failed", data: data}}),
    do: "Agent construction failed · #{data["failure_code"]}"

  defp info_entry(%{
         payload: %{type: "agent_started", data: data},
         scope: %{root?: false, session_id: session_id}
       }),
       do:
         "Subagent default · #{short_id(session_id)} · #{data["provider"]}/#{data["model"] || "built-in"}"

  defp info_entry(%{
         payload: %{type: "turn_finished", data: data},
         scope: %{root?: false, session_id: session_id}
       }),
       do: "Subagent #{data["reason"]} · #{short_id(session_id)}"

  defp info_entry(%{
         payload: %{type: "model_response_failed"},
         scope: %{session_id: session_id}
       }),
       do: "Model response failed · #{short_id(session_id)}"

  defp info_entry(%{payload: %{type: "approval_policy_changed", data: data}}),
    do: "Approval policy · #{data["from"]} → #{data["to"]}"

  defp info_entry(%{payload: %{type: "tool_loop_stalled", data: data}}),
    do: "Repeated tool result ×#{data["repetitions"]} · switching to answer-only"

  defp info_entry(%{payload: %{type: "model_route_selected", data: data}}) do
    selected = data["selected_endpoint_id"] || "deterministic"
    "Model routed · #{selected} · #{data["reason"]}#{routing_evidence_suffix(data)}"
  end

  defp info_entry(%{payload: %{type: "task_outcome_recorded", data: data}}),
    do: outcome_label("Task outcome", data)

  defp info_entry(%{payload: %{type: "verification_attached", data: data}}),
    do: outcome_label("Verification", data)

  defp info_entry(%{payload: %{type: "verification_started", data: data}}),
    do: "Verification started · #{data["check_count"]} checks · #{data["source"]}"

  defp info_entry(%{payload: %{type: "verification_check_started", data: data}}),
    do: "Verifying · #{data["check_id"]}"

  defp info_entry(%{payload: %{type: "verification_check_finished", data: data}}),
    do: "Verification check · #{data["check_id"]} · #{data["status"]} · #{data["duration_ms"]} ms"

  defp info_entry(%{payload: %{type: "verification_finished", data: data}}),
    do: "Verification #{data["status"]} · #{data["passed_count"]}/#{data["check_count"]} checks"

  defp info_entry(%{payload: %{type: "verification_cancelled"}}),
    do: "Verification cancelled"

  defp info_entry(%{payload: %{type: "completion_report_generated", data: data}}),
    do: "Completion · #{data["status"]} · #{data["evidence_count"] || 0} evidence items"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in [
              "delegation_requested",
              "delegation_accepted",
              "delegation_progressed",
              "delegation_completed",
              "delegation_rejected",
              "delegation_cancelled"
            ],
       do: "Delegation #{event_verb(type)} · #{short_id(data["worker_id"])}"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in [
              "organization_formed",
              "organization_task_transitioned",
              "organization_finished",
              "organization_cancelled"
            ],
       do:
         "Organization #{event_verb(type)} · #{short_id(data["organization_id"])}#{optional_suffix(data["task_status"])}"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in [
              "budget_allocated",
              "budget_warning",
              "budget_exhausted",
              "budget_released"
            ],
       do: "Budget #{event_verb(type)} · #{short_id(data["worker_id"])}"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in [
              "resource_queued",
              "resource_granted",
              "resource_released",
              "resource_reclaimed"
            ],
       do: "Resource #{event_verb(type)} · #{data["resource_pool"]}"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in [
              "capability_requested",
              "capability_request_approved",
              "capability_request_denied",
              "capability_lease_issued",
              "capability_lease_revoked"
            ],
       do: "Capability #{event_verb(type)} · #{short_id(data["worker_id"])}"

  defp info_entry(%{payload: %{type: "repository_updated", data: data}}),
    do:
      "Repository updated · +#{data["added_count"]} ~#{data["changed_count"]} -#{data["removed_count"]}"

  defp info_entry(%{payload: %{type: "file_changed", data: data}}),
    do: "File #{data["change"]} · #{data["path"]}"

  defp info_entry(%{payload: %{type: "test_run_finished", data: data}}),
    do: "Tests #{data["status"]} · exit #{data["exit_status"] || "unknown"}"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in ["worktree_created", "worktree_inspected", "worktree_reclaimed"],
       do: "Worktree #{event_verb(type)} · #{short_id(data["worktree_id"])}"

  defp info_entry(%{payload: %{type: type, data: data}})
       when type in [
              "race_started",
              "race_candidate_completed",
              "race_winner_selected",
              "race_collapsed",
              "race_inconclusive"
            ],
       do:
         "Race #{event_verb(type)} · #{short_id(data["race_id"])}#{optional_suffix(data["winner_id"])}"

  defp info_entry(%{payload: %{type: type}})
       when type in [
              "user_message",
              "assistant_message",
              "tool_called",
              "tool_result",
              "model_response_checkpoint"
            ],
       do: nil

  defp info_entry(%{payload: %{type: type}}) when is_binary(type),
    do: "Runtime · #{type |> String.replace("_", " ") |> String.capitalize()}"

  defp info_entry(%{payload: %{type: type}}) when is_atom(type),
    do: info_entry(%{payload: %{type: to_string(type)}})

  defp info_entry(_event), do: nil

  defp outcome_label(label, data) do
    status = data["status"] || get_in(data, ["verification", "status"])
    verification = get_in(data, ["verification", "status"])

    [label, status, if(label == "Task outcome", do: verification)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp routing_evidence_suffix(%{"evidence" => %{"state" => "ready"} = evidence}),
    do: " · #{evidence["mode"] || "shadow"} prefers #{evidence["recommended_endpoint_id"]}"

  defp routing_evidence_suffix(%{"evidence" => %{"state" => "insufficient_evidence"} = evidence}) do
    " · evidence warming #{evidence["best_verified_samples"] || 0}/#{evidence["minimum_verified_samples"] || 5} verified"
  end

  defp routing_evidence_suffix(%{"evidence" => %{"state" => "unavailable"}}),
    do: " · evidence unavailable"

  defp routing_evidence_suffix(_data), do: ""

  defp event_verb(type), do: type |> String.split("_") |> List.last()
  defp optional_suffix(nil), do: ""
  defp optional_suffix(value), do: " · #{value}"

  defp tool_id(session_id, tool_call_id), do: "#{session_id}:#{tool_call_id}"

  defp tool_name(%{root?: true}, name), do: name
  defp tool_name(%{session_id: session_id}, name), do: "#{short_id(session_id)} · #{name}"

  defp short_id("session-" <> suffix), do: String.slice(suffix, 0, 8)
  defp short_id(id), do: String.slice(to_string(id), 0, 8)

  defp context_stats(session_id) do
    case BeamAgent.conversation_context_stats(session_id) do
      {:ok, stats} -> json_safe(stats)
      {:error, _reason} -> nil
    end
  end

  defp approval_mode(%{approval_policy: policy}, _config), do: to_string(policy)

  defp approval_mode(_bootstrap, config),
    do: config["approval_policy"] |> Config.approval_policy_atom() |> to_string()

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(true), do: true
  defp json_safe(false), do: false
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  defp tty? do
    match?({:ok, _columns}, :io.columns(:standard_io)) and
      match?({:ok, _rows}, :io.rows(:standard_io))
  end

  defp escript_sibling do
    case :escript.script_name() do
      name when is_list(name) and name != [] ->
        name |> List.to_string() |> Path.expand() |> Path.dirname() |> Path.join("beam_agent_tui")

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp application_binary do
    Application.app_dir(:beam_agent, "priv/beam_agent_tui")
  rescue
    _error -> nil
  end

  defp stop_controller(controller) do
    if Process.alive?(controller), do: GenServer.stop(controller, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp format_error(reason), do: inspect(reason, pretty: true, limit: 8)
end
