defmodule BeamAgentTest do
  use ExUnit.Case, async: false

  defmodule SlowProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :slow_test

    @impl true
    def complete(_messages, _tools, _options) do
      Process.sleep(5_000)
      {:ok, %{content: "too late", tool_calls: []}}
    end
  end

  defmodule LongToolLoopProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :long_tool_loop_test

    @impl true
    def complete(messages, _tools, _options) do
      completed_steps = Enum.count(messages, &(&1.role == :tool))

      if completed_steps < 12 do
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{
               id: "long-loop-#{completed_steps}",
               name: "add",
               arguments: %{"a" => completed_steps, "b" => 1}
             }
           ]
         }}
      else
        {:ok, %{content: "finished after #{completed_steps} tool steps", tool_calls: []}}
      end
    end
  end

  defmodule RepeatedToolProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :repeated_tool_test

    @impl true
    def complete(messages, tools, _options) do
      completed_steps = Enum.count(messages, &(&1.role == :tool))

      if tools == [] do
        {:ok, %{content: "The answer is 4.", tool_calls: []}}
      else
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{
               id: "repeated-add-#{completed_steps}",
               name: "add",
               arguments: %{"a" => 2, "b" => 2}
             }
           ]
         }}
      end
    end
  end

  defp data_dir do
    path = Path.join(System.tmp_dir!(), "beam-agent-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "creates a session and drives a multi-step tool and subagent loop" do
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :demo)

    assert {:ok, answer} =
             BeamAgent.ask(id, "Calculate 2 + 3 and ask a subagent to verify it.")

    assert answer =~ "The calculation returned 5"
    assert answer =~ "subagent reported"

    assert {:ok, events} = BeamAgent.events(id)
    assert Enum.map(events, & &1["seq"]) == Enum.to_list(0..(length(events) - 1))
    assert Enum.count(events, &(&1["type"] == "tool_called")) == 2
    assert hd(events)["data"]["parent_session_id"] == nil

    first_assistant = Enum.find(events, &(&1["type"] == "assistant_message"))
    assert first_assistant["data"]["content"] == nil

    first_tool_result = Enum.find(events, &(&1["type"] == "tool_result"))
    assert first_tool_result["data"]["is_error"] == false

    spawn_event = Enum.find(events, &(&1["type"] == "subagent_spawned"))
    child_id = spawn_event["data"]["child_session_id"]

    assert {:ok, child_events} = BeamAgent.events(child_id)
    assert hd(child_events)["data"]["parent_session_id"] == id
    assert Enum.any?(child_events, &(&1["type"] == "assistant_message"))
  end

  test "tool loops continue until the provider finishes rather than hitting a step ceiling" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(LongToolLoopProvider)
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :long_tool_loop_test)

    assert {:ok, "finished after 12 tool steps"} = BeamAgent.ask(id, "keep investigating")
    assert {:ok, events} = BeamAgent.events(id)
    assert Enum.count(events, &(&1["type"] == "tool_called")) == 12
    refute Enum.any?(events, &(&1["data"]["reason"] == ":max_steps_exceeded"))
  end

  test "identical tool calls and results switch to an answer-only recovery step" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(RepeatedToolProvider)
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :repeated_tool_test)

    assert {:ok, "The answer is 4."} = BeamAgent.ask(id, "what is 2 + 2?")
    assert {:ok, events} = BeamAgent.events(id)
    assert Enum.count(events, &(&1["type"] == "tool_called")) == 3

    assert %{"data" => %{"repetitions" => 3, "calls" => [call]}} =
             Enum.find(events, &(&1["type"] == "tool_loop_stalled"))

    assert call == %{"name" => "add", "arguments" => %{"a" => 2, "b" => 2}}

    assert Enum.any?(events, fn event ->
             event["type"] == "step_started" and event["data"]["step"] == 4 and
               event["data"]["tools_enabled"] == false
           end)

    assert List.last(events)["type"] == "turn_finished"
    assert List.last(events)["data"]["reason"] == "completed"
  end

  test "restarts a crashed agent and reconstructs model history from durable events" do
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :echo)
    assert {:ok, "echo(1): first"} = BeamAgent.ask(id, "first")
    {:ok, old_pid} = BeamAgent.agent_pid(id)

    Process.exit(old_pid, :kill)
    new_pid = wait_for_new_pid(:agent, id, old_pid)
    assert new_pid != old_pid

    assert {:ok, "echo(2): second"} = BeamAgent.ask(id, "second")
    {:ok, events} = BeamAgent.events(id)

    assert Enum.count(events, &(&1["type"] == "agent_started")) == 2

    assert events
           |> Enum.filter(&(&1["type"] == "agent_started"))
           |> List.last()
           |> get_in(["data", "recovered"])
  end

  test "event-log dependency loss rebuilds downstream processes and reloads the JSONL log" do
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :echo)
    assert {:ok, _} = BeamAgent.ask(id, "before log crash")
    {:ok, old_log} = BeamAgent.event_log_pid(id)
    {:ok, old_agent} = BeamAgent.agent_pid(id)

    Process.exit(old_log, :kill)
    new_log = wait_for_new_pid(:event_log, id, old_log)
    new_agent = wait_for_new_pid(:agent, id, old_agent)

    assert new_log != old_log
    assert new_agent != old_agent
    assert {:ok, "echo(2): after log crash"} = BeamAgent.ask(id, "after log crash")
  end

  test "tool-policy dependency loss rebuilds the agent while preserving durable history" do
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :echo)
    assert {:ok, "echo(1): before policy crash"} = BeamAgent.ask(id, "before policy crash")
    {:ok, old_policy} = BeamAgent.tool_policy_pid(id)
    {:ok, old_agent} = BeamAgent.agent_pid(id)

    Process.exit(old_policy, :kill)
    new_policy = wait_for_new_pid(:tool_policy, id, old_policy)
    new_agent = wait_for_new_pid(:agent, id, old_agent)

    assert new_policy != old_policy
    assert new_agent != old_agent
    assert {:ok, "echo(2): after policy crash"} = BeamAgent.ask(id, "after policy crash")
  end

  test "agent lifecycle events retain the selected provider profile" do
    {:ok, id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :echo,
        provider_profile: "local-test",
        provider_options: [model: "built-in"]
      )

    {:ok, events} = BeamAgent.events(id)
    started = Enum.find(events, &(&1["type"] == "agent_started"))
    assert started["data"]["provider"] == "echo"
    assert started["data"]["provider_profile"] == "local-test"
    assert started["data"]["model"] == "built-in"
  end

  test "a stopped session can resume from its append-only log" do
    root = data_dir()
    id = "durable-resume"

    {:ok, ^id} = BeamAgent.start_session(session_id: id, data_dir: root, provider: :echo)
    assert {:ok, "echo(1): before stop"} = BeamAgent.ask(id, "before stop")
    :ok = BeamAgent.stop_session(id)
    wait_until_missing(:agent, id)

    {:ok, ^id} = BeamAgent.resume_session(id, data_dir: root, provider: :echo)
    assert {:ok, "echo(2): after resume"} = BeamAgent.ask(id, "after resume")

    {:ok, path} = BeamAgent.event_log_path(id)
    assert File.exists?(path)
    assert File.read!(path) |> String.split("\n", trim: true) |> length() > 10
  end

  test "capabilities are discoverable without a shared plugin context" do
    assert BeamAgent.CapabilityCatalog.provider(:demo) == {:ok, BeamAgent.Providers.Demo}
    assert BeamAgent.CapabilityCatalog.tool("add") == {:ok, BeamAgent.Tools.Add}
    assert "spawn_subagent" in Enum.map(BeamAgent.CapabilityCatalog.tool_schemas(), & &1.name)
    assert "read_file" in Enum.map(BeamAgent.CapabilityCatalog.tool_schemas(), & &1.name)
    assert "edit_file" in Enum.map(BeamAgent.CapabilityCatalog.tool_schemas(), & &1.name)
    assert "run_command" in Enum.map(BeamAgent.CapabilityCatalog.tool_schemas(), & &1.name)
    assert "read_skill" in Enum.map(BeamAgent.CapabilityCatalog.tool_schemas(), & &1.name)
  end

  test "an in-flight turn is cancellable through the agent mailbox" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(SlowProvider)
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :slow_test)

    caller = Task.async(fn -> BeamAgent.ask(id, "wait", 10_000) end)
    wait_for_status(id, :running)

    assert :ok = BeamAgent.cancel(id)
    assert Task.await(caller) == {:error, :cancelled}
    assert BeamAgent.Agent.status(id) == {:ok, :idle}

    {:ok, events} = BeamAgent.events(id)
    assert Enum.any?(events, &(&1["type"] == "turn_cancelled"))
  end

  defp wait_for_new_pid(kind, id, old_pid, attempts \\ 100)

  defp wait_for_new_pid(_kind, _id, _old_pid, 0), do: flunk("process was not restarted")

  defp wait_for_new_pid(kind, id, old_pid, attempts) do
    case BeamAgent.Names.pid(kind, id) do
      {:ok, pid} when pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_new_pid(kind, id, old_pid, attempts - 1)
    end
  end

  defp wait_until_missing(kind, id, attempts \\ 100)
  defp wait_until_missing(_kind, _id, 0), do: flunk("process did not stop")

  defp wait_until_missing(kind, id, attempts) do
    case BeamAgent.Names.pid(kind, id) do
      {:error, :not_found} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_missing(kind, id, attempts - 1)
    end
  end

  defp wait_for_status(id, expected, attempts \\ 100)
  defp wait_for_status(_id, _expected, 0), do: flunk("agent did not reach expected status")

  defp wait_for_status(id, expected, attempts) do
    case BeamAgent.Agent.status(id) do
      {:ok, ^expected} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_status(id, expected, attempts - 1)
    end
  end
end
