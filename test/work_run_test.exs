defmodule BeamAgent.WorkRunTest do
  use ExUnit.Case, async: false

  alias BeamAgent.FailureDecision

  defmodule TransientProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :work_run_transient

    @impl true
    def configuration do
      %{
        name: "work_run_transient",
        label: "Work run transient provider",
        capabilities: [:text_generation],
        locality: :remote,
        privacy: :provider,
        cost_hint: :metered
      }
    end

    @impl true
    def complete(_messages, _tools, _options),
      do: {:error, {:provider_transport_error, :closed}}
  end

  defmodule SuccessProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :work_run_success

    @impl true
    def configuration do
      %{
        name: "work_run_success",
        label: "Work run success provider",
        capabilities: [:text_generation],
        locality: :remote,
        privacy: :provider,
        cost_hint: :metered
      }
    end

    @impl true
    def complete(_messages, _tools, _options),
      do: {:ok, %{content: "rebound result", tool_calls: []}}
  end

  defmodule BlockingProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :work_run_blocking

    @impl true
    def configuration do
      %{
        name: "work_run_blocking",
        label: "Work run blocking provider",
        capabilities: [:text_generation],
        locality: :local,
        privacy: :local,
        cost_hint: :free
      }
    end

    @impl true
    def complete(_messages, _tools, _options) do
      %{attempt: attempt, test: test} =
        Agent.get_and_update(BeamAgent.WorkRunTest.ProviderState, fn state ->
          next = %{state | attempt: state.attempt + 1}
          {next, next}
        end)

      if attempt == 1 do
        send(test, :blocking_attempt_started)

        receive do
          :release_blocking_attempt ->
            {:ok, %{content: "released result", tool_calls: []}}
        after
          30_000 -> {:error, :blocking_provider_timeout}
        end
      else
        {:ok, %{content: "resumed result", tool_calls: []}}
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(TransientProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(SuccessProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(BlockingProvider)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-work-run-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "transient provider failure rebinds once, consumes retry budget, and preserves evidence",
       context do
    assert {:ok, root_id} = start_routed_session(context, retries: 2)

    assert {:ok, result} =
             BeamAgent.execute_decomposition(
               root_id,
               %{
                 tasks: [
                   %{
                     id: "inspect",
                     goal: "Inspect the bounded work item",
                     maximum_attempts: 2,
                     model_requirements: %{
                       preferred_endpoint_id: "primary",
                       locality: "remote"
                     }
                   }
                 ]
               },
               strategy: "coordinate",
               worker_options: [data_dir: context.data_dir, model_strategy: :auto]
             )

    task = result.results["inspect"]
    assert result.status == :completed
    assert task.attempts == 2
    assert task.endpoint_id == "alternate"
    assert task.result.content == "rebound result"
    assert task.verification.status == :unverified

    assert {:ok, budget} = BeamAgent.budget(root_id)
    root_budget = Enum.find(budget.allocations, &(&1.worker_id == root_id))
    assert root_budget.usage.retries == 1

    assert {:ok, events} = BeamAgent.events(root_id)

    recovery =
      Enum.find(events, fn event ->
        event["type"] == "work_run_task_attempt_finished" and
          event["data"]["recovery"]["action"] == "rebind"
      end)

    assert recovery["data"]["failure_code"] == "provider_transport_error"
    assert Enum.any?(events, &(&1["type"] == "work_run_finished"))
  end

  test "exhausted task attempts produce a typed graph replan and block dependants", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :work_run_transient,
               provider_profile: "primary",
               model_strategy: :auto,
               budget: %{concurrent_workers: 2, retries: 2},
               model_endpoints: [
                 %{
                   id: "primary",
                   provider: :work_run_transient,
                   provider_module: TransientProvider
                 }
               ]
             )

    assert {:ok, result} =
             BeamAgent.execute_decomposition(
               root_id,
               %{
                 tasks: [
                   %{
                     id: "inspect",
                     goal: "Inspect the bounded work item",
                     maximum_attempts: 2,
                     model_requirements: %{preferred_endpoint_id: "primary"}
                   },
                   %{
                     id: "review",
                     goal: "Review the bounded result",
                     depends_on: ["inspect"]
                   }
                 ]
               },
               strategy: "coordinate",
               worker_options: [data_dir: context.data_dir, model_strategy: :auto]
             )

    assert result.status == :failed
    assert result.tasks == %{"inspect" => :failed, "review" => :blocked}
    assert result.results["inspect"].attempts == 2
    assert result.results["inspect"].recovery.action == :replan
    assert result.results["review"].recovery.reason_code == "dependency_failed"
    assert result.recovery.action == :replan
    assert result.recovery.classification == :task_graph
  end

  test "an interrupted active work run is recovered from its durable checkpoint", context do
    test_pid = self()

    start_supervised!(%{
      id: BeamAgent.WorkRunTest.ProviderState,
      start:
        {Agent, :start_link,
         [
           fn -> %{attempt: 0, test: test_pid} end,
           [name: BeamAgent.WorkRunTest.ProviderState]
         ]}
    })

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :work_run_blocking,
               provider_profile: "blocking",
               model_strategy: :auto,
               budget: %{concurrent_workers: 2},
               model_endpoints: [
                 %{
                   id: "blocking",
                   provider: :work_run_blocking,
                   provider_module: BlockingProvider
                 }
               ]
             )

    test = self()

    spawn(fn ->
      result =
        BeamAgent.execute_decomposition(
          root_id,
          %{tasks: [%{id: "resume", goal: "Run the interruptible work item"}]},
          strategy: "coordinate",
          worker_options: [data_dir: context.data_dir, model_strategy: :auto]
        )

      send(test, {:original_caller_result, result})
    end)

    assert_receive :blocking_attempt_started, 5_000

    assert {:ok, events} = BeamAgent.events(root_id)
    started = Enum.find(events, &(&1["type"] == "work_run_started"))
    run_id = started["data"]["work_run_id"]

    assert {:ok, manager} = BeamAgent.Names.pid(:goal_work_run_manager, root_id)
    Process.exit(manager, :kill)

    assert eventually(fn ->
             with {:ok, run} <- BeamAgent.work_runs(root_id, run_id) do
               run.status == :completed and run.attempts["resume"] == 2 and
                 run.interruptions >= 1
             else
               _other -> false
             end
           end)

    assert {:ok, events} = BeamAgent.events(root_id)

    assert Enum.any?(events, fn event ->
             event["type"] == "work_run_interrupted" and
               event["data"]["failure_code"] == "manager_recovered"
           end)

    assert Enum.any?(events, fn event ->
             event["type"] == "work_run_task_attempt_finished" and
               event["data"]["task_id"] == "resume" and event["data"]["attempt"] == 2 and
               event["data"]["status"] == "completed"
           end)
  end

  test "failure decisions distinguish retry, rebind, replan, ask, and stop" do
    assert FailureDecision.decide(:model_timeout,
             attempt: 1,
             maximum_attempts: 2,
             alternative_endpoint?: false
           ).action == :retry_same

    assert FailureDecision.decide(:model_timeout,
             attempt: 1,
             maximum_attempts: 2,
             alternative_endpoint?: true
           ).action == :rebind

    assert FailureDecision.decide(:model_timeout,
             attempt: 2,
             maximum_attempts: 2,
             alternative_endpoint?: true
           ).action == :replan

    assert FailureDecision.decide({:verification_failed, %{status: :failed}},
             attempt: 1,
             maximum_attempts: 2
           ).action == :repair

    assert FailureDecision.decide(:tool_denied).action == :ask
    assert FailureDecision.decide(:budget_exhausted).action == :stop
  end

  defp start_routed_session(context, budget) do
    BeamAgent.start_session(
      data_dir: context.data_dir,
      workspace_root: context.workspace,
      provider: :work_run_transient,
      provider_profile: "primary",
      model_strategy: :auto,
      budget: Map.new(budget) |> Map.put(:concurrent_workers, 2),
      model_endpoints: [
        %{
          id: "primary",
          provider: :work_run_transient,
          provider_module: TransientProvider
        },
        %{
          id: "alternate",
          provider: :work_run_success,
          provider_module: SuccessProvider
        }
      ]
    )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
