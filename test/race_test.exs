defmodule BeamAgent.RaceTest do
  use ExUnit.Case, async: false

  alias BeamAgent.RacePolicy

  defmodule FastProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :race_fast_test

    def configuration,
      do: %{name: "race_fast_test", label: "Race fast", capabilities: [:text_generation]}

    def complete(_messages, _tools, _options) do
      Process.sleep(20)
      {:ok, %{content: "fast admissible answer", tool_calls: []}}
    end
  end

  defmodule SlowProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :race_slow_test

    def configuration,
      do: %{name: "race_slow_test", label: "Race slow", capabilities: [:text_generation]}

    def complete(_messages, _tools, _options) do
      Process.sleep(2_000)
      {:ok, %{content: "slow answer", tool_calls: []}}
    end
  end

  defmodule FailingProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :race_failing_test

    def configuration,
      do: %{name: "race_failing_test", label: "Race failing", capabilities: [:text_generation]}

    def complete(_messages, _tools, _options), do: {:error, :fast_failure}
  end

  defmodule InspectingProvider do
    @behaviour BeamAgent.LLMProvider
    def id, do: :race_inspecting_test

    def configuration,
      do: %{
        name: "race_inspecting_test",
        label: "Race inspecting",
        capabilities: [:text_generation]
      }

    def complete(_messages, tools, _options) do
      send(:persistent_term.get({__MODULE__, :owner}), {:race_tools, Enum.map(tools, & &1.name)})
      {:ok, %{content: "safe shared answer", tool_calls: []}}
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(FastProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(SlowProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(FailingProvider)
    :ok = BeamAgent.CapabilityCatalog.register_provider(InspectingProvider)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-speed-race-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    :persistent_term.put({InspectingProvider, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({InspectingProvider, :owner})
      File.rm_rf(root)
    end)

    %{workspace: workspace, data_dir: data_dir}
  end

  test "policy only opts into an explicit first-admissible provider race" do
    prompt = """
    Run a provider race with three independent candidates. The first admissible terminal result wins.

    User request:
    explain OTP briefly
    """

    assert {:race, plan} = RacePolicy.consider(prompt, %{parent_session_id: nil})
    assert length(plan.candidates) == 3
    assert Enum.all?(plan.candidates, &(&1.goal == "explain OTP briefly"))

    assert :skip =
             RacePolicy.consider("compare three candidates and pick the best", %{
               parent_session_id: nil
             })
  end

  test "first admissible result wins and the slower worker is cancelled", context do
    {:ok, session_id} = start_race_session(context, [FastProvider, SlowProvider])

    candidates = [
      %{id: "fast", goal: "answer", endpoint_id: "fast"},
      %{id: "slow", goal: "answer", endpoint_id: "slow"}
    ]

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, race} =
             BeamAgent.race_workers(session_id, candidates,
               justification: "Return the first admissible answer and cancel the slower lane"
             )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert race.status == :selected
    assert race.winner_id == "fast"
    assert {:ok, %{content: "fast admissible answer"}} = race.results["fast"]
    assert {:error, :cancelled_after_winner} = race.results["slow"]
    assert elapsed < 1_500

    {:ok, events} = BeamAgent.events(session_id)
    types = Enum.map(events, & &1["type"])
    winner_index = Enum.find_index(types, &(&1 == "race_winner_selected"))
    cancelled_index = Enum.find_index(types, &(&1 == "race_candidate_cancelled"))
    settled_index = Enum.find_index(types, &(&1 == "race_settled"))

    assert winner_index < cancelled_index
    assert cancelled_index < settled_index

    winner = Enum.at(events, winner_index)
    assert winner["data"]["selection_policy"] == "first_admissible"

    cancelled = Enum.at(events, cancelled_index)
    assert is_binary(cancelled["data"]["worker_id"])
    assert {:error, :not_found} = BeamAgent.agent_pid(cancelled["data"]["worker_id"])

    settlement = Enum.find(events, &(&1["type"] == "provider_auction_settled"))
    assert settlement["data"]["purpose"] == "provider_race"
    assert settlement["data"]["winner_endpoint_id"] == "fast"
  end

  test "a fast failure is rejected and cannot beat a later success", context do
    {:ok, session_id} = start_race_session(context, [FailingProvider, FastProvider])

    candidates = [
      %{id: "failure", goal: "answer", endpoint_id: "failure"},
      %{id: "success", goal: "answer", endpoint_id: "fast"}
    ]

    assert {:ok, race} =
             BeamAgent.race_workers(session_id, candidates,
               justification: "Only a successful admissible completion may win"
             )

    assert race.winner_id == "success"

    {:ok, events} = BeamAgent.events(session_id)
    rejected = Enum.find(events, &(&1["type"] == "race_candidate_rejected"))
    assert rejected["data"]["candidate_id"] == "failure"
  end

  test "verified races require worktree isolation", context do
    {:ok, session_id} = start_race_session(context, [FastProvider, SlowProvider])

    assert {:error, :verified_race_requires_worktree_isolation} =
             BeamAgent.race_workers(
               session_id,
               [%{id: "a", goal: "implement"}, %{id: "b", goal: "implement"}],
               justification: "Race verified implementations safely",
               verify_candidates: true
             )
  end

  test "shared-workspace race lanes receive read-only tools", context do
    {:ok, session_id} = start_race_session(context, [InspectingProvider, SlowProvider])

    assert {:ok, %{winner_id: "inspect"}} =
             BeamAgent.race_workers(
               session_id,
               [
                 %{id: "inspect", goal: "inspect and answer", endpoint_id: "inspect"},
                 %{id: "slow", goal: "inspect and answer", endpoint_id: "slow"}
               ],
               justification: "Race read-only answers without shared workspace mutations"
             )

    assert_receive {:race_tools, tools}
    assert "read_file" in tools
    refute "create_file" in tools
    refute "edit_file" in tools
    refute "apply_patch" in tools
    refute "run_command" in tools
  end

  defp start_race_session(context, providers) do
    endpoints =
      Enum.map(providers, fn provider ->
        id =
          case provider.id() do
            :race_fast_test -> "fast"
            :race_slow_test -> "slow"
            :race_failing_test -> "failure"
            :race_inspecting_test -> "inspect"
          end

        %{id: id, provider: provider.id(), provider_module: provider}
      end)

    [first | _] = endpoints

    BeamAgent.start_session(
      data_dir: context.data_dir,
      workspace_root: context.workspace,
      provider: first.provider,
      provider_profile: first.id,
      model_strategy: :auto,
      budget: %{concurrent_workers: 2},
      model_endpoints: endpoints
    )
  end
end
