defmodule BeamAgent.CLITUITest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.TUI
  alias BeamAgent.CLI.TUI.Controller

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-tui-test-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    config = %{
      "provider" => "echo",
      "profile" => "echo",
      "model" => nil,
      "workspace_root" => workspace,
      "data_dir" => data_dir,
      "approval_policy" => "ask",
      "context_window_tokens" => 32_000,
      "compaction_threshold_percent" => 75
    }

    {:ok, session_id} =
      BeamAgent.start_session(
        provider: :echo,
        data_dir: data_dir,
        workspace_root: workspace,
        approval_handler: self()
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{config: config, session_id: session_id}
  end

  test "initial bridge payload projects durable history", context do
    assert {:ok, "echo(1): hello"} = BeamAgent.ask(context.session_id, "hello")

    payload = TUI.initial_payload(context.session_id, context.config)

    assert payload.type == "init"
    assert payload.session_id == context.session_id
    assert payload.workspace == context.config["workspace_root"]
    assert payload.profile == "echo"
    assert payload.model == "built-in"
    assert Enum.map(payload.entries, & &1.kind) == ["user", "assistant"]
    assert List.last(payload.entries).content == "echo(1): hello"
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
        config: context.config
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)

    assert_receive {:beam_agent_tui, {:controller_ready, ^controller}}
    assert_receive {:beam_agent_tui, {:context_stats, _stats}}

    Controller.submit(controller, "hello")

    assert_receive {:beam_agent_tui, {:turn_started, "hello"}}

    messages = collect_until_turn_finished([])

    assert Enum.any?(messages, fn
             {:stream,
              %{
                type: :durable_event,
                event: %{
                  "type" => "assistant_message",
                  "data" => %{"content" => "echo(1): hello"}
                }
              }} ->
               true

             _message ->
               false
           end)

    assert Enum.any?(messages, &match?({:turn_finished, {:ok, "echo(1): hello"}}, &1))
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
end
