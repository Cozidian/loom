defmodule BeamAgent.CLI.TUI do
  @moduledoc false

  alias BeamAgent.CLI.Config
  alias BeamAgent.CLI.TUI.Controller

  @commands ~w(connect providers auto status new sessions models tournament race skills reload compact verify steer events tree budget repository resources organizations worktrees files resume)a
  @competition_event_types ~w(tournament_started tournament_candidate_started tournament_candidate_completed tournament_judgment_requested tournament_winner_selected tournament_collapsed tournament_inconclusive tournament_judgment_unresolved race_started race_candidate_started race_candidate_completed race_candidate_rejected race_candidate_cancelled race_winner_selected race_settled race_inconclusive)
  @competition_activity_types ~w(model_response_started model_response_failed tool_called tool_result verification_started verification_finished)

  def available?(override \\ nil, frontend \\ nil)

  def available?(false, _frontend), do: false

  def available?(_override, frontend) do
    System.get_env("BEAM_AGENT_NO_TUI") not in ["1", "true"] and
      System.get_env("TERM") not in [nil, "", "dumb"] and
      not is_nil(executable(frontend)) and tty?()
  end

  @doc false
  def executable(frontend \\ nil)

  def executable(frontend) when frontend in ["rust", "go"] do
    binaries(if(frontend == "rust", do: "beam_agent_ion", else: "beam_agent_tui"))
    |> Enum.find_value(&System.find_executable/1)
  end

  def executable(nil) do
    case System.get_env("BEAM_AGENT_TUI_BIN") do
      override when is_binary(override) and override != "" ->
        path = if String.contains?(override, "/"), do: Path.expand(override), else: override
        System.find_executable(path)

      _ ->
        (binaries("beam_agent_ion") ++ binaries("beam_agent_tui"))
        |> Enum.find_value(&System.find_executable/1)
    end
  end

  def run(session_id, config, config_path \\ Config.path()) do
    with executable when is_binary(executable) <- executable(config["frontend"]),
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
      nil -> {:error, :tui_not_built}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def serve_socket(socket, session_id, config, config_path) do
    with {:ok, controller} <-
           Controller.start_link(
             client: self(),
             session_id: session_id,
             config: config,
             config_path: config_path
           ),
         {:ok, bootstrap} <- Controller.bootstrap(controller) do
      try do
        :ok = :gen_tcp.send(socket, JSON.encode!(initial_payload(session_id, config, bootstrap)))
        :ok = :inet.setopts(socket, active: :once)
        socket_loop(socket, controller)
      after
        stop_controller(controller)
      end
    end
  end

  def attach(record, frontend \\ nil) do
    id = record["session_id"]

    with true <- available?(true, frontend),
         {:ok, socket} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             record["tui_port"],
             [:binary, packet: 4, packet_size: 16_777_216, active: false],
             2000
           ) do
      try do
        with :ok <- :gen_tcp.send(socket, JSON.encode!(%{token: record["token"]})),
             {:ok, bytes} <- :gen_tcp.recv(socket, 0, 10_000),
             {:ok, %{"type" => "init", "session_id" => ^id} = initial} <- JSON.decode(bytes),
             {:ok, port} <- open_port(executable(frontend)) do
          try do
            :ok = send_packet(port, initial)
            :ok = :inet.setopts(socket, active: :once)
            relay_loop(socket, port)
          after
            close_port(port)
          end
        else
          _ -> {:error, :live_attachment_failed}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      false -> {:error, :interactive_tui_required}
      error -> error
    end
  end

  defp socket_loop(socket, controller) do
    receive do
      {:tcp, ^socket, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"type" => "command", "command" => command}} when command in ["new", "resume"] ->
            :gen_tcp.send(
              socket,
              JSON.encode!(%{
                type: "notice",
                tone: "warning",
                message:
                  "This is a live attachment. Exit and use beam_agent attach SESSION_ID to change sessions."
              })
            )

          {:ok, action} when is_map(action) ->
            case dispatch_action(action, controller) do
              {:error, _} ->
                :gen_tcp.send(
                  socket,
                  JSON.encode!(%{
                    type: "notice",
                    tone: "error",
                    message: "Action rejected by runtime"
                  })
                )

              _ ->
                :ok
            end

          _ ->
            :ok
        end

        :inet.setopts(socket, active: :once)
        socket_loop(socket, controller)

      {:beam_agent_tui, message} ->
        if payload = notification_payload(message),
          do: :gen_tcp.send(socket, JSON.encode!(payload))

        socket_loop(socket, controller)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _} ->
        :ok
    end
  end

  defp relay_loop(socket, port) do
    receive do
      {:tcp, ^socket, bytes} ->
        Port.command(port, bytes)
        :inet.setopts(socket, active: :once)
        relay_loop(socket, port)

      {^port, {:data, bytes}} ->
        :gen_tcp.send(socket, bytes)
        relay_loop(socket, port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _}} ->
        {:error, :tui_stopped}

      {:tcp_closed, ^socket} ->
        {:error, :runtime_disconnected}

      {:tcp_error, ^socket, _} ->
        {:error, :runtime_disconnected}
    end
  end

  @doc false
  def initial_payload(session_id, config) do
    {:ok, identity} = BeamAgent.Agent.runtime_identity(session_id)
    {:ok, events} = BeamAgent.goal_events(identity.goal_id, view: :internal)
    {:ok, approval_policy} = BeamAgent.approval_policy(session_id)
    pending_approvals = goal_pending_approvals(identity.goal_id)

    initial_payload(session_id, config, %{
      project_id: identity.project_id,
      goal_id: identity.goal_id,
      cursor: event_cursor(events),
      events: events,
      pending_approvals: pending_approvals,
      approval_policy: approval_policy,
      attachments: draft_attachments(session_id)
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
      model_strategy: config["model_strategy"],
      team_mode:
        config["team_mode"] || if(config["model_strategy"] == "auto", do: "auto", else: "solo"),
      approval_mode: approval_mode(bootstrap, config),
      approvals: json_safe(Map.get(bootstrap, :pending_approvals, [])),
      attachments: json_safe(Map.get(bootstrap, :attachments, [])),
      workspace_files: repository_files(bootstrap.project_id),
      entries: history(bootstrap.events),
      competition_events: bootstrap.events |> competition_history() |> json_safe(),
      work_blocks: safe_work_blocks(bootstrap.goal_id),
      progress: safe_progress(bootstrap.goal_id),
      context_stats: context_stats(session_id)
    }
  end

  defp repository_files(project_id) do
    case BeamAgent.repository(project_id) do
      {:ok, %{file_count: 0}} -> refresh_repository_files(project_id)
      {:ok, %{files: files}} when is_map(files) -> sorted_file_paths(files)
      {:error, _reason} -> []
    end
  end

  defp refresh_repository_files(project_id) do
    case BeamAgent.refresh_repository(project_id) do
      {:ok, %{files: files}} when is_map(files) -> sorted_file_paths(files)
      {:error, _reason} -> []
    end
  end

  defp sorted_file_paths(files), do: files |> Map.keys() |> Enum.sort()

  defp safe_work_blocks(goal_id) do
    case BeamAgent.work_blocks(goal_id) do
      {:ok, blocks} -> json_safe(blocks)
      _other -> []
    end
  end

  defp safe_progress(goal_id) do
    case BeamAgent.progress(goal_id) do
      {:ok, progress} -> json_safe(progress)
      _other -> nil
    end
  end

  defp goal_pending_approvals(goal_id) do
    case BeamAgent.goal_sessions(goal_id) do
      {:ok, session_ids} ->
        Enum.flat_map(session_ids, fn session_id ->
          case BeamAgent.pending_approvals(session_id) do
            {:ok, approvals} -> approvals
            {:error, _reason} -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc false
  def notification_payload({:turn_started, prompt}),
    do: %{type: "turn_started", prompt: prompt}

  def notification_payload(:turn_cancelling), do: %{type: "turn_cancelling"}

  def notification_payload({:turn_steered, message}),
    do: %{type: "notice", tone: "success", message: "Steering queued · #{message}"}

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

  def notification_payload({:approval_failed, approval_id, reason}) do
    %{
      type: "approval_failed",
      approval_id: approval_id,
      error: format_error(reason)
    }
  end

  def notification_payload({:approvals_reconciled, approvals}) do
    %{
      type: "approval_snapshot",
      approvals: json_safe(approvals)
    }
  end

  def notification_payload({:notice, tone, message}),
    do: %{type: "notice", tone: to_string(tone), message: message}

  def notification_payload({:panel, title, lines}),
    do: %{type: "panel", title: title, lines: lines}

  def notification_payload({:provider_picker, providers}),
    do: %{type: "provider_picker", providers: json_safe(providers)}

  def notification_payload({:attachment_imported, attachment}),
    do: %{type: "attachment_imported", attachment: json_safe(attachment)}

  def notification_payload({:attachment_deleted, attachment_id}),
    do: %{type: "attachment_deleted", attachment_id: attachment_id}

  def notification_payload({:attachment_failed, reason}),
    do: %{type: "attachment_failed", error: format_error(reason)}

  def notification_payload({:tree, payload}),
    do: Map.put(json_safe(payload), :type, "tree")

  def notification_payload({:work_projection, payload}),
    do: Map.put(json_safe(payload), :type, "work_projection")

  def notification_payload({:events, payload}),
    do: Map.put(json_safe(payload), :type, "events")

  def notification_payload({:models, payload}),
    do: Map.put(json_safe(payload), :type, "models")

  def notification_payload({:provider_settings, payload}),
    do: Map.put(json_safe(payload), :type, "provider_settings")

  def notification_payload({:model_catalog, payload}),
    do: Map.put(json_safe(payload), :type, "model_catalog")

  def notification_payload({:settings_applied, payload}),
    do: Map.put(json_safe(payload), :type, "settings_applied")

  def notification_payload({:settings_failed, message}),
    do: %{type: "settings_failed", message: message}

  def notification_payload({:files, payload}),
    do: Map.put(json_safe(payload), :type, "files")

  def notification_payload({:diff, payload}),
    do: Map.put(json_safe(payload), :type, "diff")

  def notification_payload({:sessions, payload}),
    do: Map.put(json_safe(payload), :type, "sessions")

  def notification_payload({:session_detail, payload}),
    do: Map.put(json_safe(payload), :type, "session_detail")

  def notification_payload({:session_changed, session_id, config, attachments}) do
    %{
      type: "session_changed",
      team_mode: config["team_mode"],
      session_id: session_id,
      provider: config["provider"],
      profile: config["profile"],
      model: config["model"] || "built-in",
      attachments: json_safe(attachments)
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

  defp draft_attachments(session_id) do
    case BeamAgent.draft_attachments(session_id) do
      {:ok, attachments} -> attachments
      {:error, _reason} -> []
    end
  end

  defp bridge_loop(port, controller, monitor) do
    receive do
      {:desk_disconnected, _status} ->
        :ok =
          send_packet(port, %{
            type: "notice",
            tone: "warning",
            message: "Desk stopped. This terminal session is still available."
          })

        bridge_loop(port, controller, monitor)

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

  defp dispatch_action(
         %{"type" => "submit", "prompt" => prompt, "attachments" => attachments},
         controller
       )
       when is_binary(prompt) and is_list(attachments) do
    attachment_ids = Enum.map(attachments, & &1["id"])
    Controller.submit(controller, prompt, attachment_ids)
    :ok
  end

  defp dispatch_action(%{"type" => "provider_settings", "action" => action} = request, controller)
       when action in ["list", "catalog", "select", "save", "delete"] do
    Controller.settings(controller, Map.delete(request, "type"))
    :ok
  end

  defp dispatch_action(%{"type" => "submit", "prompt" => prompt}, controller)
       when is_binary(prompt) do
    Controller.submit(controller, prompt, [])
    :ok
  end

  defp dispatch_action(
         %{
           "type" => "attachment_import",
           "data" => encoded,
           "mime_type" => mime_type,
           "name" => name,
           "provenance" => provenance
         },
         controller
       )
       when is_binary(encoded) and is_binary(mime_type) and is_binary(name) and
              is_binary(provenance) do
    with {:ok, content} <- Base.decode64(encoded) do
      Controller.import_attachment(controller, %{
        content: content,
        mime_type: mime_type,
        name: name,
        provenance: provenance
      })

      :ok
    else
      :error -> {:error, :invalid_attachment_encoding}
    end
  end

  defp dispatch_action(
         %{"type" => "attachment_delete", "attachment_id" => attachment_id},
         controller
       )
       when is_binary(attachment_id) do
    Controller.delete_attachment(controller, attachment_id)
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
         %{"type" => "command", "command" => "steer", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:steer, query})
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
         %{"type" => "command", "command" => "race", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:race, query})
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "tournament", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:tournament, query})
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
         %{"type" => "command", "command" => "cancel_worker", "query" => worker_id},
         controller
       )
       when is_binary(worker_id) and worker_id != "" do
    Controller.command(controller, {:cancel_worker, worker_id})
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "files", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:files, query})
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "resume", "query" => session_id},
         controller
       )
       when is_binary(session_id) and session_id != "" do
    Controller.command(controller, {:resume, session_id})
    :ok
  end

  defp dispatch_action(
         %{"type" => "command", "command" => "sessions", "query" => query},
         controller
       )
       when is_binary(query) do
    Controller.command(controller, {:sessions, query})
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

  defp history(events) do
    race_context = race_context(events)

    Enum.reduce(events, [], fn event, entries ->
      if race_ui_event?(event, race_context) do
        maybe_append_race_anchor(event, entries)
      else
        history_event(event, entries)
      end
    end)
  end

  defp maybe_append_race_anchor(
         %{payload: %{type: type, data: %{"auction_id" => auction_id}}},
         entries
       )
       when type in ["provider_auction_started", :provider_auction_started] do
    entries ++ [%{kind: "race", id: auction_id}]
  end

  defp maybe_append_race_anchor(_event, entries), do: entries

  defp competition_history(events) do
    race_context = race_context(events)
    Enum.filter(events, &race_ui_event?(&1, race_context))
  end

  defp race_context(events) do
    Enum.reduce(events, %{auctions: MapSet.new(), workers: MapSet.new()}, fn event, context ->
      type = to_string(event.payload.type)
      data = event.payload.data

      context =
        if type in [
             "provider_auction_started",
             "provider_auction_awarded",
             "provider_auction_settled"
           ] and
             data["purpose"] in ["provider_race", "provider_tournament"] do
          auction_id = data["auction_id"] || data["provider_auction_id"]

          if is_binary(auction_id),
            do: update_in(context.auctions, &MapSet.put(&1, auction_id)),
            else: context
        else
          context
        end

      if type in [
           "race_candidate_started",
           "race_candidate_completed",
           "tournament_candidate_started",
           "tournament_candidate_completed"
         ] and
           is_binary(data["worker_id"]) do
        update_in(context.workers, &MapSet.put(&1, data["worker_id"]))
      else
        context
      end
    end)
  end

  defp race_ui_event?(event, context) do
    type = to_string(event.payload.type)
    data = event.payload.data
    auction_id = data["auction_id"] || data["provider_auction_id"]

    type in @competition_event_types or
      (type in ~w(provider_auction_started provider_bid_submitted provider_auction_awarded provider_auction_settled) and
         MapSet.member?(context.auctions, auction_id)) or
      (type in @competition_activity_types and
         MapSet.member?(context.workers, event.scope.session_id))
  end

  defp event_cursor([]), do: 0
  defp event_cursor(events), do: List.last(events).goal_seq

  defp history_event(
         %{payload: %{type: "user_message", data: data}, scope: %{root?: true}},
         entries
       ) do
    entries ++ [%{kind: "user", content: user_history_content(data)}]
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

  defp user_history_content(data) do
    prompt = if is_binary(data["content"]), do: data["content"], else: ""

    images =
      Enum.map(data["attachments"] || [], fn attachment ->
        name = attachment["name"] || "image"
        width = attachment["width"] || "?"
        height = attachment["height"] || "?"
        "[image: #{name} · #{width}x#{height}]"
      end)

    [prompt | images]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp info_entry(%{
         payload: %{type: "session_started"},
         scope: %{root?: true, goal_id: goal_id}
       }),
       do: "Goal started · #{short_id(goal_id)}"

  defp info_entry(%{payload: %{type: "goal_work_started", data: data}}) do
    contract = data["work_contract"] || %{}

    "Goal executing · #{contract["kind"] || "work"} → #{contract["worker_kind"] || "worker"} → #{contract["expected_artifact"] || "result"}"
  end

  defp info_entry(%{payload: %{type: "goal_work_finished", data: data}}) do
    changed = data["changed_files"] || []

    "Goal #{data["status"]} · #{data["expected_artifact"]} · #{length(changed)} changed files"
  end

  defp info_entry(%{payload: %{type: "goal_steered"}}),
    do: "Live steering queued for active worker"

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

  defp info_entry(%{payload: %{type: "work_planning_decided", data: data}}),
    do: "Work plan · #{data["mode"]} · #{data["reason"]}"

  defp info_entry(%{payload: %{type: "semantic_planning_observed", data: data}}),
    do: "Model plan · #{data["model_choice"]} · runtime #{data["runtime_mode"]}"

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

  defp info_entry(%{payload: %{type: "model_completion_deferred", data: data}}),
    do:
      "Agent continuing · #{completion_reason(data["completion_reason"])} · #{data["attempt"]}/#{data["maximum_attempts"]}"

  defp info_entry(%{payload: %{type: "model_completion_rejected", data: data}}),
    do: "Agent response rejected · #{completion_reason(data["completion_reason"])}"

  defp info_entry(%{payload: %{type: "approval_policy_changed", data: data}}),
    do: "Approval policy · #{data["from"]} → #{data["to"]}"

  defp info_entry(%{payload: %{type: "tool_approval_orphaned", data: data}}),
    do: "Approval stopped · #{short_id(data["approval_id"])} · worker policy restarted"

  defp info_entry(%{payload: %{type: "tool_loop_stalled", data: data}}),
    do: "Repeated tool result ×#{data["repetitions"]} · switching to answer-only"

  defp info_entry(%{payload: %{type: "model_route_selected", data: data}}) do
    selected = data["selected_endpoint_id"] || "deterministic"
    "Model routed · #{selected} · #{data["reason"]}#{routing_evidence_suffix(data)}"
  end

  defp info_entry(%{payload: %{type: "model_route_reused", data: data}}),
    do: "Model lease reused · #{data["selected_endpoint_id"] || "deterministic"}"

  defp info_entry(%{payload: %{type: "provider_auction_started", data: data}}),
    do:
      "Provider market opened · #{data["eligible_count"]} eligible · #{data["requested_awards"]} lease#{plural(data["requested_awards"])}"

  defp info_entry(%{payload: %{type: "provider_bid_submitted", data: data}}) do
    latency =
      if data["estimated_latency_ms"], do: " · ~#{data["estimated_latency_ms"]} ms", else: ""

    "Bid · #{data["endpoint_id"]} · score #{data["score"]} · #{confidence_percent(data["confidence"])} confidence#{latency} · #{data["cost_tier"]}"
  end

  defp info_entry(%{payload: %{type: "provider_auction_awarded", data: data}}) do
    endpoints = Enum.map_join(data["awards"] || [], ", ", & &1["endpoint_id"])
    "Provider lease awarded · #{endpoints}"
  end

  defp info_entry(%{payload: %{type: "provider_auction_settled", data: data}}) do
    winner = data["winner_endpoint_id"] || "no deterministic winner"
    "Provider market settled · #{data["status"]} · #{winner}"
  end

  defp info_entry(%{payload: %{type: "race_started", data: data}}),
    do:
      "Provider race started · #{data["provider_count"]} providers · #{data["candidate_count"]} candidates"

  defp info_entry(%{payload: %{type: "tournament_started", data: data}}),
    do:
      "Provider tournament started · #{data["provider_count"]} providers · #{data["candidate_count"]} candidates"

  defp info_entry(%{payload: %{type: "race_candidate_started", data: data}}),
    do: "Candidate #{data["candidate_id"]} · #{data["endpoint_id"]} started"

  defp info_entry(%{payload: %{type: "race_candidate_completed", data: data}}),
    do:
      "Candidate #{data["candidate_id"]} · #{data["endpoint_id"]} · #{data["verification_status"]}"

  defp info_entry(%{payload: %{type: "race_candidate_cancelled", data: data}}),
    do: "Race lane #{data["candidate_id"]} cancelled after winner"

  defp info_entry(%{payload: %{type: "race_winner_selected", data: data}}),
    do: "Race winner · #{data["winner_endpoint_id"]} · #{data["winner_id"]}"

  defp info_entry(%{payload: %{type: "race_inconclusive"}}),
    do: "Provider race needs independent judgment"

  defp info_entry(%{payload: %{type: "tournament_winner_selected", data: data}}),
    do: "Tournament winner · #{data["winner_endpoint_id"]} · #{data["winner_id"]}"

  defp info_entry(%{payload: %{type: "tournament_inconclusive"}}),
    do: "Provider tournament needs independent judgment"

  defp info_entry(%{payload: %{type: "tournament_judgment_requested"}}),
    do: "Parent judge comparing tournament candidates"

  defp info_entry(%{payload: %{type: "tournament_judgment_unresolved"}}),
    do: "Parent judgment did not identify one candidate"

  defp info_entry(%{payload: %{type: "path_lease_denied", data: data}}),
    do: "Write lease conflict · #{data["path"]}"

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

  defp info_entry(%{payload: %{type: "verification_recovery_started", data: data}}),
    do:
      "Verification rejected candidate · repairing · #{data["attempt"]}/#{data["maximum_attempts"]}"

  defp info_entry(%{payload: %{type: "implementation_review_started"}}),
    do: "Independent implementation review started"

  defp info_entry(%{payload: %{type: "implementation_review_finished", data: data}}),
    do: "Independent review · #{data["status"]}"

  defp info_entry(%{
         payload: %{type: "implementation_review_recovery_started", data: data}
       }),
       do: "Review requested fixes · repairing · #{data["attempt"]}/#{data["maximum_attempts"]}"

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
              "race_candidate_started",
              "race_candidate_completed",
              "race_winner_selected",
              "race_collapsed",
              "race_inconclusive",
              "race_settled",
              "race_candidate_rejected",
              "race_candidate_cancelled",
              "tournament_started",
              "tournament_candidate_started",
              "tournament_candidate_completed",
              "tournament_judgment_requested",
              "tournament_winner_selected",
              "tournament_collapsed",
              "tournament_inconclusive",
              "tournament_judgment_unresolved"
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

  defp completion_reason("empty_response"), do: "empty model response"
  defp completion_reason("future_intent"), do: "work was only announced"
  defp completion_reason("action_not_started"), do: "no successful repository action was taken"

  defp completion_reason("decomposition_required"),
    do: "required provider decomposition was not run"

  defp completion_reason(reason), do: reason || "non-final response"

  defp routing_evidence_suffix(%{"evidence" => %{"state" => "ready"} = evidence}),
    do: " · #{evidence["mode"] || "shadow"} prefers #{evidence["recommended_endpoint_id"]}"

  defp routing_evidence_suffix(%{"evidence" => %{"state" => "insufficient_evidence"} = evidence}) do
    " · evidence warming #{evidence["best_verified_samples"] || 0}/#{evidence["minimum_verified_samples"] || 5} verified"
  end

  defp routing_evidence_suffix(%{"evidence" => %{"state" => "unavailable"}}),
    do: " · evidence unavailable"

  defp routing_evidence_suffix(_data), do: ""

  defp confidence_percent(value) when is_number(value), do: "#{round(value * 100)}%"
  defp confidence_percent(_value), do: "unknown"
  defp plural(1), do: ""
  defp plural(_value), do: "s"

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

  defp binaries(name) do
    [escript_sibling(name), Path.expand("../../../" <> name, __DIR__), application_binary(name)]
    |> Enum.reject(&is_nil/1)
  end

  defp escript_sibling(binary) do
    case :escript.script_name() do
      name when is_list(name) and name != [] ->
        name |> List.to_string() |> Path.expand() |> Path.dirname() |> Path.join(binary)

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp application_binary(name) do
    Application.app_dir(:beam_agent, "priv/" <> name)
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

  defp format_error(reason), do: BeamAgent.CLI.ErrorFormatter.format(reason)
end
