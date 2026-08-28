defmodule BeamAgent.RacePolicyTest do
  use ExUnit.Case, async: false

  alias BeamAgent.RacePolicy

  defmodule DivergentProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :race_divergent_test

    @impl true
    def complete(messages, _tools, _options) do
      last = messages |> Enum.filter(&(&1.role == :user)) |> List.last()
      marker = :erlang.unique_integer([:positive])

      {:ok, %{content: "divergent-#{marker}: #{last && last.content}", tool_calls: []}}
    end
  end

  @race_joke """
  I need exactly one knock-knock joke for a wedding toast. Independently produce three competing versions of the same joke (clean, punny, slightly chaotic), then keep only the single winner. Do not merge them into a list, and do not write a “best of three.” Justify the winner as the one that is actually a valid knock-knock joke and safe to say at a wedding.
  """

  @list_joke "give me 10 jokes"

  @room_joke """
  Run a joke writers' room. Do not write any source jokes yourself. Delegate four different jobs, then assemble the final set:
  1. a dad-joke specialist: 3 programming groaners
  2. a one-liner specialist: 3 jokes, max 12 words, no puns
  3. an anti-joke specialist: 3 literal, deliberately unfunny replies
  4. a comedy editor who writes nothing original and only ranks, cuts, and formats the other three

  Keep the writers independent; the editor depends on all three.
  """

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(DivergentProvider)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-race-policy-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "a compete-and-pick-one joke goal is a race with labeled candidates" do
    assert {:race, plan} = RacePolicy.consider(@race_joke, %{parent_session_id: nil})
    assert length(plan.candidates) == 3
    assert Enum.map(plan.candidates, & &1.id) == ["candidate-1", "candidate-2", "candidate-3"]
    assert Enum.map(plan.candidates, & &1.role) == [
             "Race candidate (clean)",
             "Race candidate (punny)",
             "Race candidate (slightly chaotic)"
           ]

    assert Enum.all?(plan.candidates, &(&1.goal == @race_joke))
    assert plan.justification =~ "never merge"
    assert plan.reason =~ "never merge"
  end

  test "a list of jokes is not a race" do
    assert :skip = RacePolicy.consider(@list_joke, %{parent_session_id: nil})
  end

  test "heterogeneous joke specialists are not a race" do
    assert :skip = RacePolicy.consider(@room_joke, %{parent_session_id: nil})
  end

  test "child workers cannot start a nested race" do
    assert :skip =
             RacePolicy.consider(@race_joke, %{parent_session_id: "parent-session"})
  end

  test "root chat turns run a race and return the consensus winner", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{concurrent_workers: 4}
             )

    assert {:ok, answer} = BeamAgent.ask(root_id, @race_joke)
    assert answer =~ "echo(1):"

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "race_started"))
    assert Enum.any?(events, &(&1["type"] == "race_winner_selected"))
    assert Enum.any?(events, &(&1["type"] == "race_collapsed"))

    collapsed = Enum.find(events, &(&1["type"] == "race_collapsed"))
    assert collapsed["data"]["merged"] == false
    refute Enum.any?(events, &(&1["type"] == "race_inconclusive"))
  end

  test "ordinary chat does not start a race", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, answer} = BeamAgent.ask(root_id, @list_joke)
    assert answer =~ "echo(1):"

    assert {:ok, events} = BeamAgent.events(root_id)
    refute Enum.any?(events, &(&1["type"] == "race_started"))
  end

  test "a worker budget of one skips the race", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{concurrent_workers: 1}
             )

    assert {:ok, _answer} = BeamAgent.ask(root_id, @race_joke)
    assert {:ok, events} = BeamAgent.events(root_id)
    refute Enum.any?(events, &(&1["type"] == "race_started"))
  end

  test "inconclusive races ask the parent to pick one candidate and never merge", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :race_divergent_test,
               budget: %{concurrent_workers: 4}
             )

    assert {:ok, answer} = BeamAgent.ask(root_id, @race_joke)
    assert answer =~ "Pick exactly one candidate"
    assert answer =~ "Do not merge"

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "race_started"))
    assert Enum.any?(events, &(&1["type"] == "race_inconclusive"))
    refute Enum.any?(events, &(&1["type"] == "race_winner_selected"))

    judgment =
      events
      |> Enum.filter(&(&1["type"] == "user_message"))
      |> List.last()

    assert judgment["data"]["content"] =~ "could not select a winner"
    assert judgment["data"]["content"] =~ "candidate-1"
    assert judgment["data"]["content"] =~ "candidate-2"
    assert judgment["data"]["content"] =~ "candidate-3"
  end

  test "a writers' room prompt does not start a race from chat", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, _answer} = BeamAgent.ask(root_id, @room_joke)
    assert {:ok, events} = BeamAgent.events(root_id)
    refute Enum.any?(events, &(&1["type"] == "race_started"))
  end
end
