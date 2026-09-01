defmodule BeamAgent.AsyncDelegationTest do
  use ExUnit.Case, async: false

  defmodule ConcurrentProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :async_delegation_test

    @impl true
    def complete(messages, _tools, options) do
      if options[:parent_session_id] do
        Process.sleep(options[:delay_ms] || 200)
        prompt = messages |> Enum.reverse() |> Enum.find(&(&1.role == :user))
        {:ok, %{content: "finished: #{prompt.content}", tool_calls: []}}
      else
        {:ok, %{content: "root", tool_calls: []}}
      end
    end
  end

  defmodule QuietProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :progress_monitor_test

    @impl true
    def complete(_messages, _tools, _options) do
      Process.sleep(180)
      {:ok, %{content: "finished after quiet work", tool_calls: []}}
    end
  end

  defmodule BackgroundToolProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :background_tool_test

    @impl true
    def complete(messages, _tools, options) do
      if options[:parent_session_id] do
        Process.sleep(50)
        {:ok, %{content: "background evidence", tool_calls: []}}
      else
        case messages |> Enum.filter(&(&1.role == :tool)) |> List.last() do
          nil ->
            {:ok,
             %{
               content: nil,
               tool_calls: [
                 %{
                   id: "start-background",
                   name: "spawn_subagent",
                   arguments: %{
                     "prompt" => "collect independent evidence",
                     "background" => true
                   }
                 }
               ]
             }}

          %{name: "spawn_subagent", content: content} ->
            {:ok, handle} = JSON.decode(content)

            {:ok,
             %{
               content: nil,
               tool_calls: [
                 %{
                   id: "await-background",
                   name: "await_subagent",
                   arguments: %{"delegation_id" => handle["delegation_id"]}
                 }
               ]
             }}

          %{name: "await_subagent", content: content} ->
            {:ok, result} = JSON.decode(content)
            {:ok, %{content: "Collected: #{result["answer"]}", tool_calls: []}}
        end
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(ConcurrentProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(QuietProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(BackgroundToolProvider)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-async-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "background workers run concurrently and return through delegation handles", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               workspace_root: context.workspace,
               data_dir: context.data_dir,
               provider: :async_delegation_test,
               provider_options: [delay_ms: 250]
             )

    {:ok, first} = BeamAgent.spawn_worker(root_id, %{goal: "research first"})
    {:ok, second} = BeamAgent.spawn_worker(root_id, %{goal: "research second"})

    started = System.monotonic_time(:millisecond)
    assert :ok = BeamAgent.start_worker(first, "research first")
    assert :ok = BeamAgent.start_worker(second, "research second")

    assert {:ok, %{status: :running}} =
             BeamAgent.worker_status(root_id, first.delegation_id)

    assert {:ok, first_result} = BeamAgent.await_worker(first, 2_000)
    assert {:ok, second_result} = BeamAgent.await_worker(second, 2_000)
    elapsed = System.monotonic_time(:millisecond) - started

    assert first_result.content == "finished: research first"
    assert second_result.content == "finished: research second"
    assert elapsed < 450

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.count(events, &(&1["type"] == "delegation_started")) == 2
    assert Enum.count(events, &(&1["type"] == "delegation_completed")) == 2
  end

  test "an await timeout does not cancel the background worker", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               workspace_root: context.workspace,
               data_dir: context.data_dir,
               provider: :async_delegation_test,
               provider_options: [delay_ms: 150]
             )

    {:ok, handle} = BeamAgent.spawn_worker(root_id, %{goal: "finish later"})
    assert :ok = BeamAgent.start_worker(handle, "finish later")
    assert {:error, :await_timeout} = BeamAgent.await_worker(handle, 10)
    assert {:ok, result} = BeamAgent.await_worker(handle, 2_000)
    assert result.status == :completed
  end

  test "cancellation is terminal and cleans up the delegated session", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               workspace_root: context.workspace,
               data_dir: context.data_dir,
               provider: :async_delegation_test,
               provider_options: [delay_ms: 500]
             )

    {:ok, handle} = BeamAgent.spawn_worker(root_id, %{goal: "cancel this work"})
    assert :ok = BeamAgent.start_worker(handle, "cancel this work")
    assert :ok = BeamAgent.cancel_delegation(root_id, handle.delegation_id, :test_cancel)
    assert {:error, :cancelled} = BeamAgent.await_worker(handle, 100)

    eventually(fn -> BeamAgent.Names.pid(:agent, handle.worker_id) == {:error, :not_found} end)

    assert {:error, {:delegation_terminal, :cancelled}} =
             BeamAgent.cancel_delegation(root_id, handle.delegation_id, :again)
  end

  test "the goal progress monitor distinguishes suspected stalls from recovery", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               workspace_root: context.workspace,
               data_dir: context.data_dir,
               provider: :progress_monitor_test,
               progress_stall_after_ms: 40,
               progress_check_interval_ms: 20
             )

    task = Task.async(fn -> BeamAgent.ask(root_id, "do a quiet investigation") end)
    Process.sleep(90)

    assert {:ok, progress} = BeamAgent.Goal.ProgressMonitor.check_now(root_id)
    worker = Enum.find(progress.workers, &(&1.worker_id == root_id))
    assert worker.suspected_stalled

    assert {:ok, "finished after quiet work"} = Task.await(task, 2_000)
    Process.sleep(30)
    assert :ok = BeamAgent.sync_goal(root_id)

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "worker_stall_suspected"))
    assert Enum.any?(events, &(&1["type"] == "worker_progress_resumed"))

    assert {:ok, progress} = BeamAgent.progress(root_id)
    worker = Enum.find(progress.workers, &(&1.worker_id == root_id))
    refute worker.suspected_stalled
    assert worker.state == :completed
  end

  test "the model-facing background tools require a collected result before completion",
       context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               workspace_root: context.workspace,
               data_dir: context.data_dir,
               provider: :background_tool_test
             )

    assert {:ok, "Collected: background evidence"} =
             BeamAgent.ask(root_id, "implement the answer using independent background research")

    assert {:ok, events} = BeamAgent.events(root_id)

    assert Enum.map(
             Enum.filter(events, &(&1["type"] == "tool_called")),
             & &1["data"]["name"]
           ) == ["spawn_subagent", "await_subagent"]

    assert Enum.any?(events, &(&1["type"] == "delegation_started"))
    assert Enum.any?(events, &(&1["type"] == "delegation_completed"))
    refute Enum.any?(events, &(&1["type"] == "model_completion_deferred"))
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
