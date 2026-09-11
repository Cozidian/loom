defmodule BeamAgent.CLITUITest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.TUI
  alias BeamAgent.CLI.Config
  alias BeamAgent.CLI.TUI.Controller
  alias BeamAgent.RuntimeEventQuery

  defmodule FakeCodexAppServer do
    def account do
      {:ok, %{"account" => %{"type" => "chatgpt", "planType" => "plus"}}}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-tui-test-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    config_path = Path.join(root, "config.json")
    {:ok, echo_profile} = Config.profile("echo", nil, nil, nil)

    stored_config =
      Config.defaults()
      |> Map.put("active_profile", "echo")
      |> Map.put("profiles", %{"echo" => echo_profile})
      |> Map.put("data_dir", data_dir)

    {:ok, ^config_path} = Config.write(stored_config, config_path)
    {:ok, config} = Config.runtime(stored_config, "echo")

    config =
      config
      |> Map.put("workspace_root", workspace)
      |> Map.put("model_endpoints", Config.model_endpoints(stored_config, config))

    {:ok, session_id} =
      BeamAgent.start_session(
        provider: :echo,
        data_dir: data_dir,
        workspace_root: workspace,
        approval_handler: self()
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{config: config, config_path: config_path, session_id: session_id}
  end

  test "initial bridge payload projects durable history", context do
    assert {:ok, "echo(1): hello"} = BeamAgent.ask(context.session_id, "hello")

    payload = TUI.initial_payload(context.session_id, context.config)

    assert payload.type == "init"
    assert payload.session_id == context.session_id
    assert payload.cursor > 0
    assert payload.workspace == context.config["workspace_root"]
    assert payload.profile == "echo"
    assert payload.model == "built-in"
    assert payload.approval_mode == "ask"

    assert Enum.count(payload.entries, &(&1.kind == "user")) == 1
    assert Enum.count(payload.entries, &(&1.kind == "assistant")) == 1
    assert Enum.any?(payload.entries, &(&1.content == "Runtime · Turn started"))
    assert Enum.any?(payload.entries, &(&1.content == "Runtime · Turn finished"))

    assert hd(payload.entries).content =~ "Goal started"
    assert Enum.any?(payload.entries, &(&1.content =~ "Agent constructed · Primary goal worker"))
    assert Enum.any?(payload.entries, &(&1.content =~ "Agent ready · Primary goal worker"))
    assert Enum.any?(payload.entries, &(&1.content =~ "Goal executing · general"))
    assert Enum.any?(payload.entries, &(&1.content =~ "Goal completed · answer"))
    assert Enum.find(payload.entries, &(&1.kind == "assistant")).content == "echo(1): hello"

    assert Enum.any?(
             payload.entries,
             &(&1.content == "Task outcome · completed · unverified")
           )

    assert Enum.any?(
             payload.entries,
             &(&1.content == "Completion · unverified · 0 evidence items")
           )

    assert is_map(payload.context_stats)
    assert payload.attachments == []
  end

  test "mission panel starts explicitly and observes changes made by another runtime client",
       context do
    workspace = context.config["workspace_root"]
    System.cmd("git", ["init", "-q"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "Documentation fixture")
    System.cmd("git", ["add", "README.md"], cd: workspace)

    controller =
      start_supervised!(
        {Controller,
         client: self(),
         session_id: context.session_id,
         config: context.config,
         config_path: context.config_path}
      )

    Controller.command(controller, :mission)

    assert_receive {:beam_agent_tui, {:mission_panel, %{mission_actions: ["start"]} = panel}},
                   2_000

    assert TUI.notification_payload({:mission_panel, panel}).type == "panel"
    assert Enum.any?(panel.lines, &String.contains?(&1, "provider allowance"))
    Controller.command(controller, {:mission, "start"})

    assert_receive {:beam_agent_tui, {:mission_panel, %{mission_actions: ["pause", "stop"]}}},
                   2_000

    {:ok, other} = BeamAgent.Runtime.connect(context.session_id)
    on_exit(fn -> BeamAgent.Runtime.disconnect(other) end)
    assert :ok = BeamAgent.Runtime.documentation_mission(other, "pause")

    assert_receive {:beam_agent_tui, {:mission_update, %{mission_actions: ["resume", "stop"]}}},
                   2_000

    Controller.command(controller, {:mission, "start"})
    assert_receive {:beam_agent_tui, {:notice, :error, message}}, 2_000
    assert message =~ "mission_already_configured"

    assert {:ok, %{"status" => "paused", "attempts" => 0}} =
             BeamAgent.Runtime.documentation_mission(other, "status")

    Controller.command(controller, {:mission, "stop"})

    assert_receive {:beam_agent_tui, {:mission_panel, %{mission_actions: ["resume", "delete"]}}},
                   2_000

    assert {:ok, %{"status" => "stopped"}} =
             BeamAgent.Runtime.documentation_mission(other, "status")

    Controller.command(controller, {:mission, "delete"})
    assert_receive {:beam_agent_tui, {:mission_panel, %{mission_actions: ["start"]}}}, 2_000

    assert {:ok, %{"status" => "disabled"}} =
             BeamAgent.Runtime.documentation_mission(other, "status")
  end

  test "web submission is visible as a live turn in a TUI on the same session", context do
    {:ok, controller} =
      Controller.start_link(
        client: self(),
        session_id: context.session_id,
        config: context.config,
        config_path: context.config_path
      )

    {:ok, web} =
      BeamAgent.ControlPlane.start_link(session_id: context.session_id, conversation: true)

    on_exit(fn ->
      for pid <- [web, controller], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, _} = Controller.bootstrap(controller)
    assert :ok = BeamAgent.ControlPlane.submit(web, "hello from the browser")
    assert_receive {:beam_agent_tui, {:turn_started, "hello from the browser"}}, 3_000
    messages = collect_until_turn_finished([])

    assert Enum.any?(messages, fn
             {:stream,
              %{
                payload: %{
                  type: "assistant_message",
                  data: %{"content" => "echo(1): hello from the browser"}
                }
              }} ->
               true

             _ ->
               false
           end)

    assert :sys.get_state(controller).current == nil
    {:ok, conversation} = BeamAgent.ControlPlane.conversation(web)
    assert List.last(conversation.messages).content == "echo(1): hello from the browser"
  end

  test "initial bridge payload restores durable draft attachments", context do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )

    assert {:ok, attachment} =
             BeamAgent.import_attachment(context.session_id, %{
               content: png,
               provenance: "clipboard"
             })

    payload = TUI.initial_payload(context.session_id, context.config)
    assert [%{"id" => id, "mime_type" => "image/png"}] = payload.attachments
    assert id == attachment.id
  end

  test "initial bridge payload supplies repository-indexed file suggestions", context do
    File.mkdir_p!(Path.join(context.config["workspace_root"], "lib/nested"))
    File.write!(Path.join(context.config["workspace_root"], "README.md"), "hello\n")

    File.write!(
      Path.join(context.config["workspace_root"], "lib/nested/worker.ex"),
      "defmodule Nested.Worker do\nend\n"
    )

    {:ok, identity} = BeamAgent.Agent.runtime_identity(context.session_id)
    assert {:ok, _snapshot} = BeamAgent.refresh_repository(identity.project_id)

    payload = TUI.initial_payload(context.session_id, context.config)

    assert payload.workspace_files == ["README.md", "lib/nested/worker.ex"]
  end

  test "initial bridge payload groups durable provider race events for visual replay", context do
    {:ok, _} =
      BeamAgent.Session.EventLog.append(context.session_id, :provider_auction_started, %{
        "auction_id" => "auction-1",
        "purpose" => "provider_race",
        "eligible_count" => 2,
        "requested_awards" => 2
      })

    {:ok, _} =
      BeamAgent.Session.EventLog.append(context.session_id, :provider_bid_submitted, %{
        "auction_id" => "auction-1",
        "id" => "bid-1",
        "endpoint_id" => "codex",
        "score" => 90,
        "confidence" => 0.8
      })

    {:ok, _} =
      BeamAgent.Session.EventLog.append(context.session_id, :race_started, %{
        "race_id" => "race-1",
        "provider_auction_id" => "auction-1",
        "candidate_count" => 2,
        "provider_count" => 2
      })

    payload = TUI.initial_payload(context.session_id, context.config)
    race_types = Enum.map(payload.competition_events, &get_in(&1, ["payload", "type"]))

    assert race_types == [
             "provider_auction_started",
             "provider_bid_submitted",
             "race_started"
           ]

    refute Enum.any?(
             payload.entries,
             &String.starts_with?(Map.get(&1, :content, ""), "Provider market")
           )

    refute Enum.any?(payload.entries, &String.starts_with?(Map.get(&1, :content, ""), "Bid ·"))

    refute Enum.any?(
             payload.entries,
             &String.starts_with?(Map.get(&1, :content, ""), "Provider race")
           )
  end

  test "replayed image-only messages render a safe attachment summary", context do
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      )

    assert {:ok, attachment} =
             BeamAgent.import_attachment(context.session_id, %{
               content: png,
               name: "screen.png",
               provenance: "clipboard"
             })

    assert {:ok, _event} =
             BeamAgent.Session.EventLog.append(context.session_id, :user_message, %{
               "content" => "",
               "attachments" => [attachment]
             })

    payload = TUI.initial_payload(context.session_id, context.config)
    user = Enum.find(payload.entries, &(&1.kind == "user"))
    assert user.content == "[image: screen.png · 1x1]"
    assert payload.attachments == []
  end

  test "bridge notifications are JSON-safe and preserve approval semantics", context do
    request = %{
      approval_id: "approval-1",
      session_id: context.session_id,
      tool: "run_command",
      access: :execute,
      arguments: %{"command" => "mix test"}
    }

    payload = TUI.notification_payload({:approval_requested, request})
    encoded = JSON.encode!(payload)
    assert {:ok, decoded} = JSON.decode(encoded)
    assert decoded["type"] == "approval_requested"
    assert decoded["approval"]["access"] == "execute"
    assert decoded["approval"]["arguments"] == %{"command" => "mix test"}

    nil_payload =
      TUI.notification_payload({
        :stream,
        %{
          type: :runtime_event,
          durability: :durable,
          payload: %{type: "assistant_message", data: %{"content" => nil}}
        }
      })

    assert nil_payload
           |> JSON.encode!()
           |> JSON.decode!()
           |> get_in(["event", "payload", "data", "content"]) ==
             nil

    boolean_payload =
      TUI.notification_payload({
        :stream,
        %{
          type: :runtime_event,
          scope: %{root?: true},
          payload: %{type: "tool_result", data: %{"is_error" => false}}
        }
      })

    decoded_boolean_payload = boolean_payload |> JSON.encode!() |> JSON.decode!()
    assert get_in(decoded_boolean_payload, ["event", "scope", "root?"]) == true
    assert get_in(decoded_boolean_payload, ["event", "payload", "data", "is_error"]) == false

    assert TUI.notification_payload({:approval_resolved, "approval-1", :deny}) == %{
             type: "approval_resolved",
             approval_id: "approval-1",
             decision: "deny"
           }

    assert TUI.notification_payload({:approval_failed, "approval-1", :unknown_approval}) == %{
             type: "approval_failed",
             approval_id: "approval-1",
             error: ":unknown_approval"
           }

    assert TUI.notification_payload({:approvals_reconciled, [request]}) == %{
             type: "approval_snapshot",
             approvals: [
               %{
                 "access" => "execute",
                 "approval_id" => "approval-1",
                 "arguments" => %{"command" => "mix test"},
                 "session_id" => context.session_id,
                 "tool" => "run_command"
               }
             ]
           }

    assert TUI.notification_payload(
             {:work_projection,
              %{
                work_blocks: [%{id: "block-1", state: :active}],
                progress: %{critical_worker_id: context.session_id}
              }}
           ) == %{
             "work_blocks" => [%{"id" => "block-1", "state" => "active"}],
             "progress" => %{"critical_worker_id" => context.session_id},
             type: "work_projection"
           }
  end

  test "initial history explains why a non-final model response was continued", context do
    {:ok, _event} =
      BeamAgent.Session.EventLog.append(context.session_id, :model_completion_deferred, %{
        "turn" => 1,
        "step" => 1,
        "completion_reason" => "future_intent",
        "attempt" => 1,
        "maximum_attempts" => 2
      })

    payload = TUI.initial_payload(context.session_id, context.config)

    assert Enum.any?(
             payload.entries,
             &(&1.content == "Agent continuing · work was only announced · 1/2")
           )
  end

  test "controller completes a real echo turn through the generic client bridge", context do
    {:ok, controller} =
      Controller.start_link(
        client: self(),
        session_id: context.session_id,
        config: context.config,
        config_path: context.config_path,
        codex_app_server: FakeCodexAppServer
      )

    on_exit(fn ->
      if Process.alive?(controller) do
        try do
          GenServer.stop(controller)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
    assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
    assert_receive {:beam_agent_tui, {:context_stats, _stats}}

    assert {:ok, bootstrap} = Controller.bootstrap(controller)
    assert bootstrap.cursor > 0
    assert bootstrap.events != []
    assert Enum.all?(bootstrap.events, &(&1.goal_seq <= bootstrap.cursor))

    Controller.submit(controller, "hello")

    assert_receive {:beam_agent_tui, {:turn_started, "hello"}}

    messages = collect_until_turn_finished([])

    assert Enum.any?(messages, fn
             {:stream,
              %{
                type: :runtime_event,
                durability: :durable,
                payload: %{
                  type: "assistant_message",
                  data: %{"content" => "echo(1): hello"}
                },
                scope: %{root?: true}
              }} ->
               true

             _message ->
               false
           end)

    assert Enum.any?(messages, &match?({:turn_finished, {:ok, "echo(1): hello"}}, &1))

    Controller.command(controller, :events)
    assert_receive {:beam_agent_tui, {:events, payload}}
    assert payload.cursor > 0
    assert payload.total > 0
    assert payload.available_categories == RuntimeEventQuery.categories()
    assert Enum.all?(payload.events, &Map.has_key?(&1, :correlation_id))

    Controller.command(controller, {:events, "category=model type=assistant_message limit=1"})
    assert_receive {:beam_agent_tui, {:events, filtered}}
    assert filtered.returned == 1
    assert Enum.any?(filtered.filters, &(&1 =~ "category=model"))
    assert Enum.any?(filtered.filters, &(&1 =~ "type=assistant_message"))
    assert [event] = filtered.events
    assert event.category == :model
    assert event.payload.type == "assistant_message"
    assert event.redacted? == true

    Controller.command(controller, {:events, "help"})
    assert_receive {:beam_agent_tui, {:panel, "Event inspector filters", help_lines}}
    assert Enum.any?(help_lines, &(&1 =~ "worker=root|children"))

    Controller.command(controller, {:events, "limit=1000"})
    assert_receive {:beam_agent_tui, {:panel, "Invalid event filter", error_lines}}
    assert hd(error_lines) == "Invalid limit value: 1000"

    Controller.command(controller, :models)
    assert_receive {:beam_agent_tui, {:models, models_payload}}
    assert models_payload.active_profile == "echo"
    assert [%{id: "echo", provider: :echo}] = models_payload.endpoints
    assert models_payload.session_settings.approval_mode == "ask"

    Controller.command(controller, :tree)
    assert_receive {:beam_agent_tui, {:tree, tree_payload}}
    assert tree_payload.root.state == :completed
    assert tree_payload.summary.worker_count >= 1

    Controller.command(controller, {:models, "refresh"})
    assert_receive {:beam_agent_tui, {:notice, :muted, refresh_message}}
    assert refresh_message =~ "Checking 1 model endpoints"

    Controller.command(controller, :connect)
    assert_receive {:beam_agent_tui, {:provider_picker, providers}}, 1_000
    assert [%{profile: "echo", provider: "echo", connected: true, active: true}] = providers

    Controller.command(controller, {:connect, "chatgpt"})

    assert_receive {:beam_agent_tui,
                    {:notice, :error, "ChatGPT login is available only for OpenAI profiles"}}
  end

  test "files command reports changed files and gracefully empty in_context", context do
    workspace = context.config["workspace_root"]
    System.cmd("git", ["init", "-q"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test"], cd: workspace)
    File.write!(Path.join(workspace, "a.txt"), "one\n")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-q", "-m", "init"], cd: workspace)
    File.write!(Path.join(workspace, "a.txt"), "one\ntwo\n")

    {:ok, controller} =
      Controller.start_link(
        client: self(),
        session_id: context.session_id,
        config: context.config,
        config_path: context.config_path
      )

    on_exit(fn -> stop_if_alive(controller) end)

    assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
    assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
    assert_receive {:beam_agent_tui, {:context_stats, _stats}}

    Controller.command(controller, {:files, ""})
    assert_receive {:beam_agent_tui, {:files, payload}}
    assert payload.in_context == []
    assert [%{path: "a.txt", insertions: 1, status: "modified"}] = payload.changed

    Controller.command(controller, {:files, "a.txt"})
    assert_receive {:beam_agent_tui, {:diff, diff}}
    assert diff.path == "a.txt"
    assert [%{header: header}] = diff.hunks
    assert header =~ "@@"
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  test "resume command reconnects the runtime to a different existing session", context do
    {:ok, other_session_id} =
      BeamAgent.start_session(
        provider: :echo,
        data_dir: context.config["data_dir"],
        workspace_root: context.config["workspace_root"],
        approval_handler: self()
      )

    assert {:ok, "echo(1): hi there"} = BeamAgent.ask(other_session_id, "hi there")

    {:ok, controller} =
      Controller.start_link(
        client: self(),
        session_id: context.session_id,
        config: context.config,
        config_path: context.config_path
      )

    on_exit(fn -> stop_if_alive(controller) end)

    assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
    assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
    assert_receive {:beam_agent_tui, {:context_stats, _stats}}

    Controller.command(controller, {:resume, other_session_id})
    assert_receive {:beam_agent_tui, {:session_changed, ^other_session_id, _config, _attachments}}

    collect_until_message(fn
      {:stream,
       %{
         payload: %{type: "assistant_message", data: %{"content" => "echo(1): hi there"}},
         scope: %{root?: true}
       }} ->
        true

      _message ->
        false
    end)
  end

  test "controller toggles visible session auto mode", context do
    {:ok, controller} =
      Controller.start_link(
        client: self(),
        session_id: context.session_id,
        config: context.config,
        config_path: context.config_path
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)

    assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
    assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
    assert_receive {:beam_agent_tui, {:context_stats, _stats}}

    Controller.command(controller, :auto)
    assert_receive {:beam_agent_tui, {:approval_mode, :auto}}
    assert_receive {:beam_agent_tui, {:notice, :warning, message}}
    assert message =~ "Auto mode enabled"
    assert {:ok, :auto} = BeamAgent.approval_policy(context.session_id)

    Controller.command(controller, :auto)
    assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
    assert_receive {:beam_agent_tui, {:notice, :success, message}}
    assert message =~ "Auto mode disabled"
    assert {:ok, :ask} = BeamAgent.approval_policy(context.session_id)
  end

  test "provider picker links an existing ChatGPT session and activates OpenAI", context do
    config_path = context.config_path
    {:ok, stored} = Config.load(config_path)

    {:ok, openai_profile} =
      Config.profile("openai", "gpt-5.4", "https://api.openai.com/v1", "OPENAI_API_KEY")

    {:ok, stored} = Config.put_profile(stored, "openai-chatgpt", openai_profile)
    {:ok, ^config_path} = Config.write(stored, config_path)

    {:ok, controller} =
      Controller.start_link(
        client: self(),
        session_id: context.session_id,
        config: context.config,
        config_path: context.config_path,
        codex_app_server: FakeCodexAppServer
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)

    assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
    assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
    assert_receive {:beam_agent_tui, {:context_stats, _stats}}

    Controller.command(controller, :connect)
    assert_receive {:beam_agent_tui, {:provider_picker, providers}}

    assert %{status: "ChatGPT available", connected: false} =
             Enum.find(providers, &(&1.profile == "openai-chatgpt"))

    Controller.command(controller, {:connect, "profile:openai-chatgpt"})

    assert_receive {:beam_agent_tui,
                    {:notice, :success, "Connected openai-chatgpt through ChatGPT"}}

    assert_receive {:beam_agent_tui,
                    {:session_changed, new_session_id,
                     %{
                       "provider" => "openai",
                       "profile" => "openai-chatgpt",
                       "model" => "gpt-5.4"
                     }, _attachments}}

    assert new_session_id != context.session_id
    assert {:ok, config} = Config.load(context.config_path)
    assert config["active_profile"] == "openai-chatgpt"

    assert get_in(config, ["profiles", "openai-chatgpt", "auth"]) == %{
             "type" => "chatgpt",
             "transport" => "codex_app_server"
           }
  end

  @tag :darwin
  test "controller runs verification and streams check progress", context do
    if :os.type() != {:unix, :darwin} do
      :ok
    else
      verification_dir = Path.join(context.config["workspace_root"], ".beam_agent")
      File.mkdir_p!(verification_dir)

      File.write!(
        Path.join(verification_dir, "verification.json"),
        JSON.encode!(%{
          version: 1,
          checks: [%{id: "tui-pass", command: "printf verified", timeout_ms: 5_000}]
        })
      )

      assert {:ok, _answer} = BeamAgent.ask(context.session_id, "hello")

      {:ok, controller} =
        Controller.start_link(
          client: self(),
          session_id: context.session_id,
          config: context.config,
          config_path: context.config_path
        )

      on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)

      assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
      assert_receive {:beam_agent_tui, {:approval_mode, :ask}}
      assert_receive {:beam_agent_tui, {:context_stats, _stats}}

      Controller.command(controller, :verify)
      messages = collect_until_verification_finished([])

      assert Enum.any?(messages, fn
               {:stream, %{payload: %{type: "verification_started"}}} -> true
               _message -> false
             end)

      assert Enum.any?(messages, fn
               {:stream,
                %{
                  payload: %{
                    type: "verification_check_finished",
                    data: %{"check_id" => "tui-pass", "status" => "passed"}
                  }
                }} ->
                 true

               _message ->
                 false
             end)
    end
  end

  test "no-tui always disables takeover and an explicit Go executable is discoverable" do
    previous = System.get_env("BEAM_AGENT_TUI_BIN")
    executable = System.find_executable("sh")
    System.put_env("BEAM_AGENT_TUI_BIN", executable)

    on_exit(fn ->
      if previous,
        do: System.put_env("BEAM_AGENT_TUI_BIN", previous),
        else: System.delete_env("BEAM_AGENT_TUI_BIN")
    end)

    refute TUI.available?(false)
    assert TUI.executable() == executable

    System.put_env("BEAM_AGENT_TUI_BIN", Path.relative_to(executable, File.cwd!(), force: true))
    assert TUI.executable() == executable

    System.put_env("BEAM_AGENT_TUI_BIN", "./missing-explicit-frontend")
    assert TUI.executable() == nil
  end

  defp collect_until_turn_finished(messages) do
    receive do
      {:beam_agent_tui, {:turn_finished, _result} = message} -> Enum.reverse([message | messages])
      {:beam_agent_tui, message} -> collect_until_turn_finished([message | messages])
    after
      2_000 -> flunk("timed out waiting for the TUI controller turn")
    end
  end

  defp collect_until_message(match_fun) do
    receive do
      {:beam_agent_tui, message} ->
        unless match_fun.(message), do: collect_until_message(match_fun)
    after
      2_000 -> flunk("timed out waiting for a matching TUI controller message")
    end
  end

  defp collect_until_verification_finished(messages) do
    receive do
      {:beam_agent_tui, {:notice, :success, "Verification passed" <> _rest} = message} ->
        Enum.reverse([message | messages])

      {:beam_agent_tui, message} ->
        collect_until_verification_finished([message | messages])
    after
      6_000 -> flunk("timed out waiting for the TUI controller verification")
    end
  end
end
