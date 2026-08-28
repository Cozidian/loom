defmodule BeamAgent.CLITUITest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.TUI
  alias BeamAgent.CLI.Config
  alias BeamAgent.CLI.TUI.Controller

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
    assert Enum.any?(payload.entries, &(&1.content =~ "Agent constructed · Goal coordinator"))
    assert Enum.any?(payload.entries, &(&1.content =~ "Agent ready · Goal coordinator"))
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
  end

  test "controller completes a real echo turn through the generic client bridge", context do
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
    assert_receive {:beam_agent_tui, {:panel, title, lines}}
    assert title =~ "Goal events"
    assert hd(lines) =~ "cursor"
    assert Enum.any?(lines, &(&1 =~ "corr" and &1 =~ "cause"))

    Controller.command(controller, {:events, "category=model type=assistant_message limit=1"})
    assert_receive {:beam_agent_tui, {:panel, filtered_title, filtered_lines}}
    assert filtered_title =~ "1 results"
    assert Enum.at(filtered_lines, 1) =~ "category=model"
    assert Enum.at(filtered_lines, 1) =~ "type=assistant_message"
    assert List.last(filtered_lines) =~ "model/assistant_message"
    assert List.last(filtered_lines) =~ "redacted"

    Controller.command(controller, {:events, "help"})
    assert_receive {:beam_agent_tui, {:panel, "Event inspector filters", help_lines}}
    assert Enum.any?(help_lines, &(&1 =~ "worker=root|children"))

    Controller.command(controller, {:events, "limit=1000"})
    assert_receive {:beam_agent_tui, {:panel, "Invalid event filter", error_lines}}
    assert hd(error_lines) == "Invalid limit value: 1000"

    Controller.command(controller, :models)
    assert_receive {:beam_agent_tui, {:panel, models_title, model_lines}}
    assert models_title =~ "Model registry"
    assert Enum.any?(model_lines, &(&1 =~ "● echo · echo/provider default · local · unknown"))

    Controller.command(controller, :tree)
    assert_receive {:beam_agent_tui, {:panel, tree_title, tree_lines}}
    assert tree_title =~ "Goal tree"
    assert Enum.any?(tree_lines, &(&1 =~ "Goal" and &1 =~ "completed"))

    Controller.command(controller, {:models, "refresh"})
    assert_receive {:beam_agent_tui, {:notice, :muted, refresh_message}}
    assert refresh_message =~ "Checking 1 model endpoints"

    Controller.command(controller, :connect)
    assert_receive {:beam_agent_tui, {:provider_picker, providers}}
    assert [%{profile: "echo", provider: "echo", connected: true, active: true}] = providers

    Controller.command(controller, {:connect, "chatgpt"})

    assert_receive {:beam_agent_tui,
                    {:notice, :error, "ChatGPT login is available only for OpenAI profiles"}}
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
                     }}}

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

      assert {:ok, _answer} = BeamAgent.ask(context.session_id, "implement something")

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
  end

  defp collect_until_turn_finished(messages) do
    receive do
      {:beam_agent_tui, {:turn_finished, _result} = message} -> Enum.reverse([message | messages])
      {:beam_agent_tui, message} -> collect_until_turn_finished([message | messages])
    after
      2_000 -> flunk("timed out waiting for the TUI controller turn")
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
