defmodule BeamAgent.ActorRuntimeTest do
  use ExUnit.Case, async: false

  defmodule SteeringProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :actor_steering_test

    @impl true
    def complete(messages, _tools, options) do
      cond do
        Enum.any?(messages, fn message ->
          message.role == :user && Map.get(message, :content, "") =~ "Live user steering"
        end) ->
          steering =
            messages
            |> Enum.filter(&(&1.role == :user))
            |> List.last()
            |> Map.fetch!(:content)

          send(options[:test_pid], {:steering_seen, steering})
          {:ok, %{content: "steering applied", tool_calls: []}}

        List.last(messages).role == :tool ->
          {:ok, %{content: "tool completed", tool_calls: []}}

        true ->
          send(options[:test_pid], {:provider_waiting, self()})
          receive do: (:continue -> :ok)

          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "search-before-steering",
                 name: "search_files",
                 arguments: %{"query" => "needle", "path" => "."}
               }
             ]
           }}
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(SteeringProvider)
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-actor-runtime-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "sample.txt"), "needle\n")

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "live steering enters the active actor mailbox before its next model decision", context do
    assert {:ok, goal_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :actor_steering_test,
               provider_options: [test_pid: self()],
               approval_policy: :auto
             )

    assert {:ok, runtime} = BeamAgent.Runtime.connect(goal_id)
    on_exit(fn -> BeamAgent.Runtime.disconnect(runtime) end)

    task = Task.async(fn -> BeamAgent.ask(goal_id, "inspect the workspace") end)
    assert_receive {:provider_waiting, provider_task}, 2_000
    assert :ok = BeamAgent.Runtime.steer(runtime, "focus on the sample file")
    assert_receive {:beam_agent_runtime, ^runtime, {:turn_steered, "focus on the sample file"}}
    send(provider_task, :continue)

    assert {:ok, "steering applied"} = Task.await(task, 5_000)
    assert_receive {:steering_seen, steering}
    assert steering =~ "focus on the sample file"

    assert {:ok, events} = BeamAgent.events(goal_id)
    assert Enum.any?(events, &(&1["type"] == "goal_steered"))
    assert Enum.count(events, &(&1["type"] == "model_route_selected")) == 1
    assert Enum.count(events, &(&1["type"] == "model_route_reused")) == 1
  end

  test "project path leases reject competing actors and release on actor death", context do
    assert {:ok, first} =
             BeamAgent.start_session(
               session_id: "lease-first",
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, second} =
             BeamAgent.start_session(
               session_id: "lease-second",
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    {:ok, goal} = BeamAgent.goal(first)
    manager = BeamAgent.Project.PathLeaseManager

    assert {:ok, %{owner: ^first}} =
             manager.acquire(goal.project_id, context.workspace, "sample.txt", first)

    assert {:error, {:path_leased, _path, ^first}} =
             manager.acquire(goal.project_id, context.workspace, "sample.txt", second)

    assert :ok = BeamAgent.stop_session(first)
    assert :ok = wait_until(fn -> BeamAgent.path_leases(goal.project_id) == {:ok, []} end)

    assert {:ok, %{owner: ^second}} =
             manager.acquire(goal.project_id, context.workspace, "sample.txt", second)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: {:error, :timeout}

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
