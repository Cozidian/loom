defmodule BeamAgent.CodingUsabilityTest do
  use ExUnit.Case, async: false

  alias BeamAgent.Session.EventLog

  defmodule CodingProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :coding_usability_test

    def complete(messages, tools, _opts) do
      names = Enum.map(tools, & &1.name)
      send(Process.whereis(:coding_usability_observer), {:tool_surface, names})

      case Enum.count(messages, &(&1.role == :tool)) do
        0 -> call("first", "create_file", %{"path" => "first.txt", "content" => "first"})
        1 -> call("second", "create_file", %{"path" => "second.txt", "content" => "second"})
        _ -> {:ok, %{content: "Implemented the requested files.", tool_calls: []}}
      end
    end

    defp call(id, name, arguments),
      do: {:ok, %{content: nil, tool_calls: [%{id: id, name: name, arguments: arguments}]}}
  end

  defmodule RecoveryProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :coding_recovery_test

    def complete(_messages, _tools, opts) do
      for {id, recovery} <- [{"old", "replan"}, {"latest", opts[:recovery]}] do
        {:ok, _} =
          EventLog.append(opts[:session_id], :tool_called, %{
            "turn" => 1,
            "tool_call_id" => id,
            "name" => "delegate_tasks"
          })

        {:ok, _} =
          EventLog.append(opts[:session_id], :tool_result, %{
            "turn" => 1,
            "tool_call_id" => id,
            "is_error" => false,
            "content" =>
              JSON.encode!(%{
                status: if(recovery, do: "failed", else: "completed"),
                recovery: recovery && %{action: recovery},
                used_endpoint_ids: []
              })
          })
      end

      {:ok, %{content: "Worker results collected.", tool_calls: []}}
    end
  end

  defmodule RoutedProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :coding_routed_options_test

    def complete(_messages, _tools, opts) do
      send(Process.whereis(:coding_usability_observer), {:routed_options, opts})
      {:ok, %{content: "Investigation finished.", tool_calls: []}}
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(CodingProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(RecoveryProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(RoutedProvider)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "coding-usability-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(workspace, ".beam_agent"))

    File.write!(
      Path.join(workspace, ".beam_agent/verification.json"),
      JSON.encode!(%{
        version: 1,
        checks: [%{id: "written-file", command: "test -f second.txt"}]
      })
    )

    Process.register(self(), :coding_usability_observer)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: Path.join(root, "runtime")}
  end

  test "a Phoenix-sized request retains coding tools with multiple configured endpoints", ctx do
    {:ok, id} =
      start_session(ctx,
        model_strategy: :auto,
        model_endpoints:
          Enum.map(["primary", "secondary"], fn id ->
            %{id: id, provider: :coding_usability_test, provider_module: CodingProvider}
          end)
      )

    on_exit(fn -> BeamAgent.stop_session(id) end)

    assert {:ok, _answer} =
             BeamAgent.ask(id, "Implement a Phoenix web app frontend for this harness")

    assert_receive {:tool_surface, tools}
    assert "create_file" in tools
    assert "run_command" in tools
    assert "delegate_tasks" in tools
    assert File.read!(Path.join(ctx.workspace, "first.txt")) == "first"
    assert File.read!(Path.join(ctx.workspace, "second.txt")) == "second"
    {:ok, events} = BeamAgent.events(id)
    refute Enum.any?(events, &(&1["type"] == "model_completion_deferred"))
    {:ok, status} = BeamAgent.Goal.status(id)
    assert status.last_work.artifact.verification.status == :passed
  end

  test "a denied operation does not poison a later approved implementation", ctx do
    {:ok, id} = start_session(ctx, approval_policy: :ask, approval_handler: self())
    on_exit(fn -> BeamAgent.stop_session(id) end)
    task = Task.async(fn -> BeamAgent.ask(id, "Implement the requested files") end)

    assert_receive {:beam_agent_approval, first}, 5_000
    assert first.arguments["path"] == "first.txt"
    :ok = BeamAgent.respond_approval(id, first.approval_id, :deny)
    assert_receive {:beam_agent_approval, second}, 5_000
    assert second.arguments["path"] == "second.txt"
    :ok = BeamAgent.respond_approval(id, second.approval_id, :allow_once)
    assert {:ok, _answer} = Task.await(task, 10_000)
    refute File.exists?(Path.join(ctx.workspace, "first.txt"))
    assert File.read!(Path.join(ctx.workspace, "second.txt")) == "second"
  end

  test "successful replanning supersedes the older recovery decision", ctx do
    {:ok, id} = start_session(ctx, provider: :coding_recovery_test)
    on_exit(fn -> BeamAgent.stop_session(id) end)

    assert {:ok, "Worker results collected."} =
             BeamAgent.ask(id, "Investigate the actor lifecycle")

    {:ok, events} = BeamAgent.events(id)
    refute Enum.any?(events, &(&1["type"] == "model_completion_deferred"))
  end

  test "an explicitly assigned endpoint receives its own model and authentication options", ctx do
    {:ok, root} =
      start_session(ctx,
        provider: :echo,
        provider_profile: "primary",
        model_strategy: :auto,
        provider_options: [model: "primary-model", api_key: "primary-test-credential"],
        model_endpoints: [
          %{id: "primary", provider: :echo, model: "primary-model"},
          %{
            id: "secondary",
            provider: :coding_routed_options_test,
            provider_module: RoutedProvider,
            model: "secondary-model"
          }
        ]
      )

    on_exit(fn -> BeamAgent.stop_session(root) end)

    {:ok, child} =
      BeamAgent.spawn_subagent(root,
        provider: :echo,
        provider_profile: "primary",
        model_strategy: :auto,
        provider_options: [model: "primary-model", api_key: "primary-test-credential"],
        agent_proposal: %{
          goal: "Investigate actor lifecycle",
          template: "researcher",
          model_requirements: %{preferred_endpoint_id: "secondary"}
        }
      )

    assert {:ok, _} = BeamAgent.ask(child, "Inspect the actor lifecycle")
    assert_receive {:routed_options, opts}
    assert opts[:model] == "secondary-model"
    refute opts[:api_key]
  end

  test "a terminal failed organization cannot be reported as a completed turn", ctx do
    for action <- ["ask", "stop"] do
      {:ok, id} =
        start_session(ctx, provider: :coding_recovery_test, provider_options: [recovery: action])

      on_exit(fn -> BeamAgent.stop_session(id) end)

      assert {:error, {:implementation_blocked, :decomposition_failed, _}} =
               BeamAgent.ask(id, "Investigate the actor lifecycle")

      {:ok, events} = BeamAgent.events(id)

      refute Enum.any?(
               events,
               &(&1["type"] == "turn_finished" and &1["data"]["reason"] == "completed")
             )
    end
  end

  defp start_session(ctx, opts) do
    BeamAgent.start_session(
      Keyword.merge(
        [
          workspace_root: ctx.workspace,
          data_dir: ctx.data_dir,
          provider: :coding_usability_test,
          approval_policy: :auto,
          completion_review: :external
        ],
        opts
      )
    )
  end
end
