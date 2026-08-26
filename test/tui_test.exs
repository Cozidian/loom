defmodule BeamAgent.CLITUITest do
  use ExUnit.Case, async: false

  alias BeamAgent.CLI.TUI
  alias BeamAgent.CLI.TUI.App
  alias TermUI.{Event, Runtime}
  alias TermUI.Renderer.DisplayWidth

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
      "max_steps" => 5,
      "timeout_ms" => 2_000,
      "approval_policy" => "ask"
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

  test "the screen model edits and submits a multiline composer", context do
    state = App.init(session_id: context.session_id, config: context.config)
    state = %{state | controller: self()}

    {state, []} = App.update({:insert, "hello"}, state)
    {state, []} = App.update(:newline, state)
    {state, []} = App.update({:insert, "world"}, state)
    assert state.input == "hello\nworld"

    {state, []} = App.update(:enter, state)

    assert_receive {_gen_cast, {:submit, "hello\nworld"}}
    assert state.input == ""
    assert state.status == :running
    assert List.last(state.entries).kind == :user

    assert {:msg, :newline} =
             App.event_to_msg(Event.key("o", char: "o", modifiers: [:ctrl]), state)
  end

  test "streamed and durable assistant events do not duplicate the final answer", context do
    state = App.init(session_id: context.session_id, config: context.config)

    {state, []} =
      App.update(
        {:stream, %{type: :text_delta, response_id: "response-1", delta: "hello"}},
        state
      )

    {state, []} =
      App.update(
        {:stream,
         %{
           type: :durable_event,
           event: %{
             "type" => "assistant_message",
             "data" => %{"content" => "hello", "tool_calls" => []}
           }
         }},
        state
      )

    assert Enum.count(state.entries, &(&1.kind == :assistant)) == 1
    assert List.last(state.entries).content == "hello"
  end

  test "approval overlay is fail-closed and responds through the controller", context do
    request = %{
      approval_id: "approval-1",
      session_id: context.session_id,
      tool: "run_command",
      access: :execute,
      arguments: %{"command" => "mix test"}
    }

    state = App.init(session_id: context.session_id, config: context.config)
    state = %{state | controller: self()}
    {state, []} = App.update({:approval_requested, request}, state)
    assert state.approval.choice == :deny

    {state, []} = App.update(:escape, state)
    assert state.approval == nil
    assert_receive {_gen_cast, {:decide, "approval-1", :deny}}
  end

  test "runtime processes keyboard input and a controller completes a real echo turn", context do
    {:ok, runtime} =
      Runtime.start_link(
        root: App,
        session_id: context.session_id,
        config: context.config,
        skip_terminal: true,
        render_interval: 10
      )

    {:ok, controller} =
      BeamAgent.CLI.TUI.Controller.start_link(
        runtime: runtime,
        session_id: context.session_id,
        config: context.config
      )

    on_exit(fn ->
      if Process.alive?(controller), do: GenServer.stop(controller)
      if Process.alive?(runtime), do: Runtime.shutdown(runtime)
    end)

    Enum.each(String.graphemes("hello"), fn char ->
      Runtime.send_event(runtime, Event.key(char, char: char))
    end)

    Runtime.send_event(runtime, Event.key(:enter))

    assert eventually(fn ->
             Runtime.sync(runtime)
             state = Runtime.get_state(runtime).root_state

             state.status == :idle and
               Enum.any?(
                 state.entries,
                 &(&1.kind == :assistant and &1.content == "echo(1): hello")
               )
           end)
  end

  test "render tree fills the configured screen and no-tui always disables takeover", context do
    state =
      App.init(
        session_id: context.session_id,
        config: context.config,
        width: 72,
        height: 22
      )

    tree = App.view(state)

    assert state.width == 72
    assert state.height == 22
    assert tree.type == :stack
    assert tree.direction == :vertical
    assert length(tree.children) == 22
    refute TUI.available?(false)
  end

  test "conversation rendering is top-aligned, terminal-native, and markdown-aware", context do
    state = App.init(session_id: context.session_id, config: context.config)

    state = %{
      state
      | width: 84,
        height: 26,
        entries: [
          %{kind: :user, content: "hi", id: 1},
          %{
            kind: :tool,
            name: "read_file",
            arguments: %{"path" => "README.md"},
            status: :done,
            content: "# BeamAgent",
            error?: false,
            id: "tool-1"
          },
          %{
            kind: :assistant,
            content:
              "I am **BeamAgent**, an OTP-native agent working with the session/supervision model.",
            streaming?: false,
            id: 2
          }
        ]
    }

    tree = App.view(state)
    lines = Enum.map(tree.children, & &1.content)
    rendered = Enum.join(lines, "\n")

    assert Enum.find_index(lines, &String.contains?(&1, "YOU")) < 8
    assert rendered =~ "└─ ✓  read_file  README.md"
    assert rendered =~ "I am BeamAgent"
    assert rendered =~ "session/supervision"
    refute rendered =~ "**BeamAgent**"
    assert Enum.all?(tree.children, &is_nil(&1.style.bg))
  end

  test "command selection stays inside its modal border", context do
    state =
      App.init(session_id: context.session_id, config: context.config, width: 120, height: 24)

    {state, []} = App.update(:toggle_palette, state)
    lines = App.view(state).children
    top_index = Enum.find_index(lines, &String.contains?(&1.content, "Command palette"))
    top = Enum.at(lines, top_index)
    selected = Enum.at(lines, top_index + 1)

    assert DisplayWidth.width(String.trim_trailing(selected.content)) ==
             DisplayWidth.width(String.trim_trailing(top.content))

    refute :reverse in selected.style.attrs
    assert selected.content |> String.trim_trailing() |> String.ends_with?("│")
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
