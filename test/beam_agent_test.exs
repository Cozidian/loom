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

  defmodule ProgressThenWorkingProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :progress_then_working_test

    @impl true
    def complete(messages, _tools, options) do
      if pid = options[:test_pid],
        do: send(pid, {:progress_system_prompt, options[:system_prompt]})

      case Enum.count(messages, &(&1.role == :assistant)) do
        0 ->
          {:ok,
           %{
             content: "I'll start by locating the implementation before changing anything.",
             tool_calls: []
           }}

        1 ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "recovery-create",
                 name: "create_file",
                 arguments: %{
                   "path" => "completion-guard.txt",
                   "content" => "implemented"
                 }
               }
             ]
           }}

        _ ->
          {:ok, %{content: "Implemented and verified the requested change.", tool_calls: []}}
      end
    end
  end

  defmodule EmptyThenAnswerProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :empty_then_answer_test

    @impl true
    def complete(messages, _tools, _options) do
      if Enum.any?(messages, &(&1.role == :assistant)) do
        {:ok, %{content: "Recovered after the empty response.", tool_calls: []}}
      else
        {:ok, %{content: nil, tool_calls: []}}
      end
    end
  end

  defmodule AlwaysEmptyProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :always_empty_test

    @impl true
    def complete(_messages, _tools, _options), do: {:ok, %{content: nil, tool_calls: []}}
  end

  defmodule ClaimsWorkWithoutToolsProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :claims_work_without_tools_test

    @impl true
    def complete(_messages, tools, options) do
      if pid = options[:test_pid] || Process.whereis(:beam_agent_claims_tool_surface_test) do
        send(pid, {:claims_system_prompt, options[:system_prompt]})
        send(pid, {:claims_tools, Enum.map(tools, & &1.name)})
      end

      {:ok, %{content: "Implemented the requested change.", tool_calls: []}}
    end
  end

  defmodule DirectWorkerClaimsProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :direct_worker_claims_test

    @impl true
    def complete(_messages, tools, options) do
      if pid = options[:test_pid] || Process.whereis(:beam_agent_direct_worker_test_observer) do
        send(pid, {:direct_worker_system_prompt, options[:system_prompt]})
        send(pid, {:direct_worker_tools, Enum.map(tools, & &1.name)})
      end

      {:ok, %{content: "Implemented the requested change.", tool_calls: []}}
    end
  end

  defmodule NoopImplementationProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :noop_implementation_test

    @impl true
    def complete(messages, _tools, options) do
      turn = options[:beam_turn]

      case List.last(messages) do
        %{role: :user} ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "noop-read-#{turn}",
                 name: "read_file",
                 arguments: %{"path" => "stable.txt"}
               }
             ]
           }}

        %{role: :tool, name: "read_file"} ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "noop-edit-#{turn}",
                 name: "edit_file",
                 arguments: %{
                   "path" => "stable.txt",
                   "old_text" => "unchanged",
                   "new_text" => "unchanged"
                 }
               }
             ]
           }}

        _other ->
          {:ok, %{content: "Implemented the requested change.", tool_calls: []}}
      end
    end
  end

  defmodule ReadOnlyBlockerProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :read_only_blocker_test

    @impl true
    def complete(_messages, _tools, options) do
      send(options[:test_pid], {:read_only_system_prompt, options[:system_prompt]})

      {:ok,
       %{
         content: "Blocked: this worker has no source-write or delegation capability.",
         tool_calls: []
       }}
    end
  end

  defmodule ExecuteOnlyTool do
    @behaviour BeamAgent.Tool

    @impl true
    def name, do: "execute_only_test_tool"

    @impl true
    def description, do: "Exercise execution-only completion semantics."

    @impl true
    def input_schema, do: %{type: "object", properties: %{}}

    @impl true
    def access, do: :execute

    @impl true
    def execute(_arguments, _context), do: {:ok, "executed"}
  end

  defmodule ExecuteThenClaimsProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :execute_then_claims_test

    @impl true
    def complete(messages, _tools, _options) do
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, %{content: "Implemented the requested change.", tool_calls: []}}
      else
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{id: "execute-only-call", name: "execute_only_test_tool", arguments: %{}}
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
    assert {:error, :not_found} = BeamAgent.agent_pid(child_id)
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

    assert Enum.any?(events, &(&1["type"] == "turn_finished"))

    assert Enum.any?(events, fn event ->
             event["type"] == "turn_finished" and event["data"]["reason"] == "completed"
           end)
  end

  test "future-intent responses continue the same implementation turn instead of completing" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(ProgressThenWorkingProvider)
    root = data_dir()
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, ".beam_agent"))

    File.write!(
      Path.join(root, ".beam_agent/verification.json"),
      JSON.encode!(%{
        version: 1,
        checks: [%{id: "completion-guard", command: "test -f completion-guard.txt"}]
      })
    )

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: root,
        workspace_root: root,
        provider: :progress_then_working_test,
        provider_options: [test_pid: self()],
        approval_policy: :auto,
        completion_review: :external
      )

    assert {:ok, "Implemented and verified the requested change."} =
             BeamAgent.ask(id, "implement the requested feature")

    assert {:ok, events} = BeamAgent.events(id)

    assert %{"data" => %{"completion_reason" => "future_intent", "attempt" => 1}} =
             Enum.find(events, &(&1["type"] == "model_completion_deferred"))

    assert_receive {:progress_system_prompt, initial_prompt}
    assert initial_prompt =~ "# Current turn execution contract"
    assert initial_prompt =~ "Task type: implementation"
    assert initial_prompt =~ "create_file"

    assert_receive {:progress_system_prompt, recovery_prompt}
    assert recovery_prompt =~ "described future work instead of performing"
    assert recovery_prompt =~ "Never claim a step completed"

    assert Enum.count(events, &(&1["type"] == "tool_called")) == 1
    assert Enum.count(events, &(&1["type"] == "turn_finished")) == 1
    assert File.read!(Path.join(root, "completion-guard.txt")) == "implemented"

    assert {:ok, goal_status} = BeamAgent.Goal.status(id)
    assert goal_status.last_work.artifact.kind == :workspace_patch
    assert goal_status.last_work.artifact.changed_files == ["completion-guard.txt"]
    assert goal_status.last_work.artifact.verification.status == :passed

    {:ok, goal} = BeamAgent.goal(id)

    assert {:ok, stored_artifact} =
             BeamAgent.Project.ContextStore.fetch(
               goal.project_id,
               goal_status.last_work.artifact.id
             )

    assert stored_artifact.kind == "work_artifact"

    assert Enum.any?(events, fn event ->
             event["type"] == "step_finished" and
               event["data"]["reason"] == "non_final_response"
           end)
  end

  test "an empty provider response is retried before the turn can complete" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(EmptyThenAnswerProvider)
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :empty_then_answer_test)

    assert {:ok, "Recovered after the empty response."} = BeamAgent.ask(id, "hello")
    assert {:ok, events} = BeamAgent.events(id)

    assert %{"data" => %{"completion_reason" => "empty_response", "attempt" => 1}} =
             Enum.find(events, &(&1["type"] == "model_completion_deferred"))

    assert Enum.count(events, &(&1["type"] == "turn_finished")) == 1
  end

  test "repeated empty responses fail rather than recording false completion" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(AlwaysEmptyProvider)
    {:ok, id} = BeamAgent.start_session(data_dir: data_dir(), provider: :always_empty_test)

    assert {:error, {:non_final_model_response, :empty_response, 2}} =
             BeamAgent.ask(id, "hello")

    assert {:ok, events} = BeamAgent.events(id)
    assert Enum.count(events, &(&1["type"] == "model_completion_deferred")) == 2
    assert Enum.count(events, &(&1["type"] == "model_completion_rejected")) == 1

    refute Enum.any?(events, fn event ->
             event["type"] == "turn_finished" and event["data"]["reason"] == "completed"
           end)
  end

  test "implementation claims without a successful action tool cannot complete" do
    :ok = register_provider_once(ClaimsWorkWithoutToolsProvider)

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :claims_work_without_tools_test,
        provider_options: [test_pid: self()]
      )

    assert {:error, {:non_final_model_response, :action_not_started, 2}} =
             BeamAgent.ask(id, "implement the requested feature")

    assert {:ok, events} = BeamAgent.events(id)

    assert Enum.count(events, fn event ->
             event["type"] == "model_completion_deferred" and
               event["data"]["completion_reason"] == "action_not_started"
           end) == 2

    assert_receive {:claims_system_prompt, _initial_prompt}
    assert_receive {:claims_system_prompt, recovery_prompt}
    assert recovery_prompt =~ "Read-only investigation has already been recorded"
    assert recovery_prompt =~ "Your next response must invoke one of these tools"
    assert recovery_prompt =~ "create_file"
    assert recovery_prompt =~ "Do not perform another read-only round"

    refute Enum.any?(events, fn event ->
             event["type"] == "turn_finished" and event["data"]["reason"] == "completed"
           end)
  end

  test "a prior string-encoded model error does not crash implementation completion" do
    :ok = register_provider_once(ClaimsWorkWithoutToolsProvider)

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :claims_work_without_tools_test,
        provider_options: [test_pid: self()]
      )

    error =
      inspect(%BeamAgent.ModelError{
        request_id: "model-request-prior-failure",
        endpoint_id: "openai-codex",
        provider: :openai,
        code: :codex_app_server_error,
        retryable: false,
        cause: {:codex_app_server_error, %{"error" => %{"message" => "out of credits"}}}
      })

    assert {:ok, _} =
             BeamAgent.Session.EventLog.append(id, :model_response_failed, %{"error" => error})

    assert {:error, {:non_final_model_response, :action_not_started, 2}} =
             BeamAgent.ask(id, "implement the requested feature")
  end

  test "explicit multi-provider implementation cannot silently fall back to one direct worker" do
    :ok = register_provider_once(ClaimsWorkWithoutToolsProvider)
    Process.register(self(), :beam_agent_claims_tool_surface_test)

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :claims_work_without_tools_test,
        provider_profile: "primary",
        provider_options: [test_pid: self()],
        model_strategy: :auto,
        model_endpoints: [
          %{
            id: "primary",
            provider: :claims_work_without_tools_test,
            provider_module: ClaimsWorkWithoutToolsProvider
          },
          %{
            id: "secondary",
            provider: :claims_work_without_tools_test,
            provider_module: ClaimsWorkWithoutToolsProvider
          }
        ]
      )

    assert {:error, {:non_final_model_response, :decomposition_required, 2}} =
             BeamAgent.ask(id, "Implement this using different providers for coding and tests")

    assert_receive {:claims_tools, initial_tools}
    assert "list_models" in initial_tools
    assert "delegate_tasks" in initial_tools
    assert "read_file" in initial_tools
    refute "apply_patch" in initial_tools
    refute "run_command" in initial_tools
    refute "spawn_subagent" in initial_tools

    assert {:ok, events} = BeamAgent.events(id)
    decision = Enum.find(events, &(&1["type"] == "work_planning_decided"))
    observation = Enum.find(events, &(&1["type"] == "semantic_planning_observed"))
    assert decision["data"]["mode"] == "required"
    assert observation["data"]["model_choice"] == "direct"
    refute observation["data"]["agreed"]

    assert Enum.count(events, fn event ->
             event["type"] == "model_completion_deferred" and
               event["data"]["completion_reason"] == "decomposition_required"
           end) == 2
  end

  test "implementation workers receive a direct-work completion contract" do
    :ok = register_provider_once(DirectWorkerClaimsProvider)
    Process.register(self(), :beam_agent_direct_worker_test_observer)

    {:ok, root_id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :direct_worker_claims_test,
        provider_options: [test_pid: self()]
      )

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(root_id,
               agent_proposal: %{
                 goal: "Implement the requested bounded change",
                 template: "implementer"
               },
               provider_options: [test_pid: self()]
             )

    assert {:error, {:non_final_model_response, :action_not_started, 2}} =
             BeamAgent.ask(child_id, "implement the requested bounded change")

    assert_receive {:direct_worker_system_prompt, direct_prompt}
    assert direct_prompt =~ "This is a bounded implementation worker"
    assert direct_prompt =~ "Perform the delegated change directly"
    assert direct_prompt =~ "Delegation and read-only investigation"
    assert direct_prompt =~ "source-write tool"
    refute direct_prompt =~ "spawn_subagent"
    refute direct_prompt =~ "delegate_tasks"
  end

  test "delegated implementation leaves retain write tools when their own prompt is substantial" do
    :ok = register_provider_once(DirectWorkerClaimsProvider)
    Process.register(self(), :beam_agent_direct_worker_test_observer)

    {:ok, root_id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :direct_worker_claims_test,
        provider_options: [test_pid: self()],
        model_strategy: :auto,
        model_endpoints: [
          %{
            id: "primary",
            provider: :direct_worker_claims_test,
            provider_module: DirectWorkerClaimsProvider
          },
          %{
            id: "secondary",
            provider: :direct_worker_claims_test,
            provider_module: DirectWorkerClaimsProvider
          }
        ]
      )

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(root_id,
               agent_proposal: %{
                 goal:
                   "Build an end-to-end Phoenix web version and integrate it with the runtime",
                 template: "implementer"
               },
               provider_options: [test_pid: self()]
             )

    assert {:error, {:non_final_model_response, :action_not_started, 2}} =
             BeamAgent.ask(
               child_id,
               "Build an end-to-end Phoenix web version and integrate it with the runtime"
             )

    assert_receive {:direct_worker_tools, tools}
    assert "create_file" in tools
    assert "apply_patch" in tools
    refute "delegate_tasks" in tools

    assert {:ok, events} = BeamAgent.events(child_id)
    decision = Enum.find(events, &(&1["type"] == "work_planning_decided"))
    assert decision["data"]["mode"] == "advisory"
  end

  test "an implementation cannot complete with a successful no-op edit" do
    :ok = register_provider_once(NoopImplementationProvider)
    root = data_dir()
    File.mkdir_p!(root)
    File.write!(Path.join(root, "stable.txt"), "unchanged")

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: root,
        workspace_root: root,
        provider: :noop_implementation_test,
        approval_policy: :auto,
        completion_review: :external
      )

    assert {:error, {:non_final_model_response, :action_not_started, 2}} =
             BeamAgent.ask(id, "implement the requested change")

    assert File.read!(Path.join(root, "stable.txt")) == "unchanged"
    assert {:ok, goal} = BeamAgent.Goal.status(id)
    assert goal.last_work.status == :failed
    assert goal.last_work.artifact.changed_files == []

    assert {:ok, events} = BeamAgent.events(id)

    assert Enum.any?(events, fn event ->
             event["type"] == "goal_work_finished" and event["data"]["status"] == "failed"
           end)
  end

  test "constructed evidence workers can report on implementation without being forced to write" do
    {:ok, root_id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :echo
      )

    assert {:ok, child_id} =
             BeamAgent.spawn_subagent(root_id,
               agent_proposal: %{
                 goal: "Review the implementation without changing the workspace",
                 template: "researcher"
               }
             )

    assert {:ok, content} =
             BeamAgent.ask(
               child_id,
               "Inspect the implementation contract and report the evidence. Do not edit files."
             )

    assert content =~ "Inspect the implementation contract"

    assert {:ok, events} = BeamAgent.events(child_id)
    refute Enum.any?(events, &(&1["type"] == "model_completion_deferred"))
  end

  defp register_provider_once(module) do
    case BeamAgent.CapabilityCatalog.register_provider(module) do
      :ok -> :ok
      {:error, :duplicate_provider} -> :ok
    end
  end

  test "read-only workers can report an honest implementation blocker" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(ReadOnlyBlockerProvider)

    capabilities = %{
      tools: ["read_file", "search_files"],
      paths: :all,
      commands: [],
      hosts: [],
      mcp_servers: [],
      model_classes: :all
    }

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :read_only_blocker_test,
        provider_options: [test_pid: self()],
        capabilities: capabilities
      )

    assert {:error,
            {:implementation_blocked, :missing_action_authority,
             "Blocked: this worker has no source-write or delegation capability."}} =
             BeamAgent.ask(id, "implement the requested feature")

    assert_receive {:read_only_system_prompt, system_prompt}
    assert system_prompt =~ "This worker has no"
    assert system_prompt =~ "must not claim that implementation occurred"

    assert {:ok, events} = BeamAgent.events(id)
    refute Enum.any?(events, &(&1["type"] == "model_completion_deferred"))

    assert Enum.any?(events, fn event ->
             event["type"] == "goal_work_finished" and event["data"]["status"] == "failed"
           end)
  end

  test "execution-only tools do not prove that implementation occurred" do
    :ok = BeamAgent.CapabilityCatalog.register_provider(ExecuteThenClaimsProvider)
    :ok = BeamAgent.CapabilityCatalog.register_tool(ExecuteOnlyTool)

    {:ok, id} =
      BeamAgent.start_session(
        data_dir: data_dir(),
        provider: :execute_then_claims_test,
        approval_policy: :auto
      )

    assert {:error, {:non_final_model_response, :action_not_started, 2}} =
             BeamAgent.ask(id, "implement the requested feature")

    assert {:ok, events} = BeamAgent.events(id)
    assert Enum.count(events, &(&1["type"] == "tool_called")) == 1

    assert Enum.any?(events, fn event ->
             event["type"] == "tool_result" and
               event["data"]["name"] == "execute_only_test_tool" and
               event["data"]["is_error"] == false
           end)

    refute Enum.any?(events, fn event ->
             event["type"] == "turn_finished" and event["data"]["reason"] == "completed"
           end)
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
