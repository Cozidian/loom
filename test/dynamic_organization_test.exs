defmodule BeamAgent.DynamicOrganizationTest do
  use ExUnit.Case, async: false

  alias BeamAgent.DecompositionPlan

  defmodule SpeculativeProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :speculative_test

    @impl true
    def complete(messages, _tools, _options) do
      case Enum.find(Enum.reverse(messages), &(&1.role == :tool and &1.name == "create_file")) do
        nil ->
          {:ok,
           %{
             content: nil,
             tool_calls: [
               %{
                 id: "write-candidate",
                 name: "create_file",
                 arguments: %{"path" => "candidate.txt", "content" => "candidate\n"}
               }
             ]
           }}

        _tool_result ->
          {:ok, %{content: "implemented isolated candidate", tool_calls: []}}
      end
    end
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(SpeculativeProvider)
    :ok
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-organization-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "decomposition plans validate dependency graphs and expose deterministic waves" do
    assert {:ok, plan} =
             DecompositionPlan.new(%{
               tasks: [
                 %{id: "research", goal: "Find the relevant module"},
                 %{id: "review", goal: "Review the finding", depends_on: ["research"]}
               ]
             })

    assert Enum.map(DecompositionPlan.ready(plan, %{}), & &1.id) == ["research"]

    assert Enum.map(DecompositionPlan.ready(plan, %{"research" => :completed}), & &1.id) == [
             "review"
           ]

    assert {:error, :cyclic_task_dependencies} =
             DecompositionPlan.new(%{
               tasks: [
                 %{id: "a", goal: "A", depends_on: ["b"]},
                 %{id: "b", goal: "B", depends_on: ["a"]}
               ]
             })
  end

  test "decomposition rejects competing owners for one coherent implementation" do
    assert {:error, {:multiple_implementation_owners, ["api", "ui"]}} =
             DecompositionPlan.new(%{
               tasks: [
                 %{id: "api", goal: "Implement the API portion", template: "implementer"},
                 %{id: "ui", goal: "Implement the UI portion", template: "implementer"},
                 %{id: "review", goal: "Review the resulting implementation"}
               ]
             })

    assert {:ok, _plan} =
             DecompositionPlan.new(%{
               tasks: [
                 %{id: "research", goal: "Research the relevant modules"},
                 %{id: "implementation", goal: "Implement the complete coherent change"},
                 %{id: "review", goal: "Review the resulting implementation"}
               ]
             })

    assert {:ok, _plan} =
             DecompositionPlan.new(%{
               tasks: [
                 %{
                   id: "api",
                   goal: "Implement the API portion",
                   template: "implementer",
                   capabilities: %{paths: ["lib/api"]}
                 },
                 %{
                   id: "ui",
                   goal: "Implement the UI portion",
                   template: "implementer",
                   capabilities: %{paths: ["cmd/ui"]}
                 }
               ]
             })
  end

  test "a temporary worker organization executes dependencies and reclaims workers", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{concurrent_workers: 2}
             )

    assert {:ok, result} =
             BeamAgent.execute_decomposition(
               root_id,
               %{
                 tasks: [
                   %{id: "first", goal: "first bounded result"},
                   %{id: "second", goal: "second bounded result", depends_on: ["first"]}
                 ]
               },
               strategy: "coordinate",
               worker_options: [provider: :echo, data_dir: context.data_dir]
             )

    assert result.status == :completed
    assert result.tasks == %{"first" => :completed, "second" => :completed}
    assert result.results["first"].result.content =~ "first bounded result"
    assert result.results["second"].result.content =~ "second bounded result"

    first_worker = result.results["first"].worker.worker_id
    second_worker = result.results["second"].worker.worker_id
    assert {:error, :not_found} = BeamAgent.agent_pid(first_worker)
    assert {:error, :not_found} = BeamAgent.agent_pid(second_worker)

    assert {:ok, organization} =
             BeamAgent.worker_organizations(root_id, result.organization_id)

    assert organization.status == :completed
    assert Enum.all?(organization.tasks, fn {_id, task} -> task.status == :completed end)

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "organization_formed"))
    assert Enum.any?(events, &(&1["type"] == "organization_finished"))
  end

  test "tournament selects only deterministic consensus and never merges", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{concurrent_workers: 2}
             )

    candidates = [
      %{id: "a", goal: "return the same bounded answer"},
      %{id: "b", goal: "return the same bounded answer"}
    ]

    assert {:ok, tournament} =
             BeamAgent.tournament_workers(root_id, candidates,
               justification: "Two cheap independent checks reduce ambiguity",
               worker_options: [provider: :echo, data_dir: context.data_dir]
             )

    assert tournament.status == :selected,
           inspect(tournament, pretty: true, limit: :infinity)

    assert tournament.winner_id == "a"

    assert {:ok, events} = BeamAgent.events(root_id)
    selected = Enum.find(events, &(&1["type"] == "tournament_winner_selected"))
    collapsed = Enum.find(events, &(&1["type"] == "tournament_collapsed"))
    assert selected["data"]["winner_id"] == "a"
    assert collapsed["data"]["merged"] == false
  end

  test "speculative implementations use isolated worktrees and deterministic evidence", context do
    File.write!(Path.join(context.workspace, "README.md"), "base\n")
    {_output, 0} = System.cmd("git", ["init"], cd: context.workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["add", "README.md"], cd: context.workspace)

    {_output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Beam Agent",
          "-c",
          "user.email=beam@example.test",
          "commit",
          "-m",
          "base"
        ],
        cd: context.workspace,
        stderr_to_stdout: true
      )

    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :speculative_test,
               approval_policy: :auto,
               budget: %{concurrent_workers: 2}
             )

    passing_plan = %{
      source: "candidate-check",
      checks: [%{id: "diff", command: "git diff --check", required: true}]
    }

    failing_plan = %{
      source: "candidate-check",
      checks: [%{id: "reject", command: "false", required: true}]
    }

    candidates = [
      %{id: "passing", goal: "implement candidate", verification_plan: passing_plan},
      %{id: "failing", goal: "implement candidate", verification_plan: failing_plan}
    ]

    assert {:ok, race} =
             BeamAgent.speculate_implementations(root_id, candidates,
               justification: "Compare two isolated implementations",
               worker_options: [
                 provider: :speculative_test,
                 data_dir: context.data_dir,
                 approval_policy: :auto
               ]
             )

    assert race.status == :selected, inspect(race, pretty: true, limit: :infinity)
    assert race.winner_id == "passing"
    assert {:ok, passing} = race.results["passing"]
    assert {:ok, failing} = race.results["failing"]
    assert passing.verification.status == :passed
    assert failing.verification.status == :failed

    for {_id, {:ok, candidate}} <- race.results do
      assert File.dir?(candidate.worktree.path)
      assert candidate.worktree_evidence.changed_files == ["candidate.txt"]
    end

    assert File.read!(Path.join(context.workspace, "README.md")) == "base\n"
    refute File.exists?(Path.join(context.workspace, "candidate.txt"))

    {:ok, events} = BeamAgent.events(root_id)
    collapsed = Enum.find(events, &(&1["type"] == "tournament_collapsed"))
    assert collapsed["data"]["merged"] == false
    assert collapsed["data"]["retained_worktree_count"] == 2
  end
end
