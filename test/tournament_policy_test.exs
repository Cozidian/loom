defmodule BeamAgent.TournamentPolicyTest do
  use ExUnit.Case, async: false

  alias BeamAgent.TournamentPolicy

  defmodule DivergentProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :race_divergent_test

    @impl true
    def complete(messages, _tools, _options) do
      last = messages |> Enum.filter(&(&1.role == :user)) |> List.last()

      if last && String.contains?(last.content, "Candidates:") do
        [winner] =
          Regex.run(
            ~r/- candidate-2:\n(?<winner>[\s\S]+?)(?=\n\n- candidate-3:)/u,
            last.content,
            capture: ["winner"]
          )

        {:ok, %{content: String.trim(winner), tool_calls: []}}
      else
        marker = :erlang.unique_integer([:positive])
        {:ok, %{content: "divergent-#{marker}: #{last && last.content}", tool_calls: []}}
      end
    end
  end

  defmodule RiskyProbe do
    @behaviour BeamAgent.Tool

    @impl true
    def name, do: "race_risky_probe"

    @impl true
    def description, do: "A fast write-classified probe for race approval inheritance tests"

    @impl true
    def input_schema, do: %{type: "object", properties: %{}}

    @impl true
    def access, do: :write

    @impl true
    def execute(_arguments, _context), do: {:ok, "probe complete"}
  end

  defmodule RiskyProvider do
    @behaviour BeamAgent.LLMProvider

    @impl true
    def id, do: :race_risky_test

    @impl true
    def complete(messages, tools, options) do
      owner = :persistent_term.get({__MODULE__, :owner})

      send(
        owner,
        {:race_visible_tools, options[:system_prompt], Enum.map(tools, & &1.name)}
      )

      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, %{content: "race risky tool complete", tool_calls: []}}
      else
        {:ok,
         %{
           content: nil,
           tool_calls: [%{id: "race-probe", name: "race_risky_probe", arguments: %{}}]
         }}
      end
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
    :ok = BeamAgent.CapabilityCatalog.register_provider(RiskyProvider)
    :ok = BeamAgent.CapabilityCatalog.register_tool(RiskyProbe)
    :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "beam-agent-race-policy-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    :persistent_term.put({RiskyProvider, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({RiskyProvider, :owner})
      File.rm_rf(root)
    end)

    %{workspace: workspace, data_dir: data_dir}
  end

  test "a compete-and-pick-one joke goal is a tournament with labeled candidates" do
    prompt = String.replace(@race_joke, "competing versions", "tournament candidates")
    assert {:tournament, plan} = TournamentPolicy.consider(prompt, %{parent_session_id: nil})
    assert length(plan.candidates) == 3
    assert Enum.map(plan.candidates, & &1.id) == ["candidate-1", "candidate-2", "candidate-3"]

    assert Enum.map(plan.candidates, & &1.role) == [
             "Tournament candidate (clean)",
             "Tournament candidate (punny)",
             "Tournament candidate (slightly chaotic)"
           ]

    assert Enum.all?(plan.candidates, &(&1.goal == prompt))
    assert plan.justification =~ "never merge"
    assert plan.reason =~ "never merge"
  end

  test "a list of jokes is not a tournament" do
    assert :skip = TournamentPolicy.consider(@list_joke, %{parent_session_id: nil})
  end

  test "an explicit tournament wrapper gives candidates only the actual user request" do
    prompt = """
    Run a provider tournament with three competing independent candidates for exactly the same request. Keep only the single winner and do not merge their answers.

    User request:
    i need a joke that works for all age groups
    """

    assert {:tournament, plan} = TournamentPolicy.consider(prompt, %{parent_session_id: nil})

    assert Enum.all?(
             plan.candidates,
             &(&1.goal == "i need a joke that works for all age groups")
           )

    assert Enum.all?(plan.candidates, fn candidate ->
             Enum.any?(candidate.instructions, &String.contains?(&1, "Do not delegate"))
           end)
  end

  test "heterogeneous joke specialists are not a tournament" do
    assert :skip = TournamentPolicy.consider(@room_joke, %{parent_session_id: nil})
  end

  test "child workers cannot start a nested tournament" do
    assert :skip =
             TournamentPolicy.consider(
               String.replace(@race_joke, "competing versions", "tournament candidates"),
               %{parent_session_id: "parent-session"}
             )
  end

  test "root chat turns run a tournament and return the consensus winner", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{concurrent_workers: 4}
             )

    assert {:ok, answer} =
             BeamAgent.ask(
               root_id,
               String.replace(@race_joke, "competing versions", "tournament candidates")
             )

    assert answer =~ "echo(1):"

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "tournament_started"))
    assert Enum.any?(events, &(&1["type"] == "tournament_winner_selected"))
    assert Enum.any?(events, &(&1["type"] == "tournament_collapsed"))

    collapsed = Enum.find(events, &(&1["type"] == "tournament_collapsed"))
    assert collapsed["data"]["merged"] == false
    refute Enum.any?(events, &(&1["type"] == "tournament_inconclusive"))
  end

  test "ordinary chat does not start a tournament", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, answer} = BeamAgent.ask(root_id, @list_joke)
    assert answer =~ "echo(1):"

    assert {:ok, events} = BeamAgent.events(root_id)
    refute Enum.any?(events, &(&1["type"] == "tournament_started"))
  end

  test "tournament workers inherit the live auto policy and cannot recursively delegate",
       context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :race_risky_test,
               approval_policy: :ask,
               approval_handler: self(),
               budget: %{concurrent_workers: 4}
             )

    assert :ok = BeamAgent.set_approval_policy(root_id, :auto)
    prompt = String.replace(@race_joke, "competing versions", "tournament candidates")
    assert {:ok, "race risky tool complete"} = BeamAgent.ask(root_id, prompt, 5_000)
    refute_receive {:beam_agent_approval, _request}

    {:ok, events} = BeamAgent.events(root_id)

    assert Enum.any?(events, &(&1["type"] == "tournament_started")),
           Enum.map(events, & &1["type"])

    assert Enum.any?(events, &(&1["type"] == "tournament_winner_selected"))

    for _index <- 1..3 do
      assert_receive {:race_visible_tools, system_prompt, tools}
      assert system_prompt =~ "Role: Tournament candidate"
      refute "delegate_tasks" in tools
      refute "spawn_subagent" in tools
      refute "request_capability" in tools
      assert "race_risky_probe" in tools
    end
  end

  test "a worker budget of one skips the tournament", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo,
               budget: %{concurrent_workers: 1}
             )

    assert {:ok, _answer} =
             BeamAgent.ask(
               root_id,
               String.replace(@race_joke, "competing versions", "tournament candidates")
             )

    assert {:ok, events} = BeamAgent.events(root_id)
    refute Enum.any?(events, &(&1["type"] == "tournament_started"))
  end

  test "an inconclusive tournament is durably resolved by the parent judge", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :race_divergent_test,
               budget: %{concurrent_workers: 4}
             )

    assert {:ok, answer} =
             BeamAgent.ask(
               root_id,
               String.replace(@race_joke, "competing versions", "tournament candidates")
             )

    assert answer =~ "divergent-"

    assert {:ok, events} = BeamAgent.events(root_id)
    assert Enum.any?(events, &(&1["type"] == "tournament_started"))
    assert Enum.any?(events, &(&1["type"] == "tournament_inconclusive"))
    assert Enum.any?(events, &(&1["type"] == "tournament_judgment_requested"))
    assert Enum.any?(events, &(&1["type"] == "tournament_winner_selected"))
    assert Enum.any?(events, &(&1["type"] == "tournament_collapsed"))

    winner = Enum.find(events, &(&1["type"] == "tournament_winner_selected"))
    assert winner["data"]["winner_id"] == "candidate-2"
    assert winner["data"]["selection_source"] == "parent_judgment"

    inconclusive_index = Enum.find_index(events, &(&1["type"] == "tournament_inconclusive"))
    requested_index = Enum.find_index(events, &(&1["type"] == "tournament_judgment_requested"))
    winner_index = Enum.find_index(events, &(&1["type"] == "tournament_winner_selected"))
    collapsed_index = Enum.find_index(events, &(&1["type"] == "tournament_collapsed"))

    assert inconclusive_index < requested_index
    assert requested_index < winner_index
    assert winner_index < collapsed_index

    judgment =
      events
      |> Enum.filter(&(&1["type"] == "user_message"))
      |> List.last()

    assert judgment["data"]["content"] =~ "could not select a winner"
    assert judgment["data"]["content"] =~ "candidate-1"
    assert judgment["data"]["content"] =~ "candidate-2"
    assert judgment["data"]["content"] =~ "candidate-3"

    settlements = Enum.filter(events, &(&1["type"] == "provider_auction_settled"))
    assert Enum.map(settlements, &get_in(&1, ["data", "status"])) == ["inconclusive", "selected"]
  end

  test "a writers' room prompt does not start a tournament from chat", context do
    assert {:ok, root_id} =
             BeamAgent.start_session(
               data_dir: context.data_dir,
               workspace_root: context.workspace,
               provider: :echo
             )

    assert {:ok, _answer} = BeamAgent.ask(root_id, @room_joke)
    assert {:ok, events} = BeamAgent.events(root_id)
    refute Enum.any?(events, &(&1["type"] == "tournament_started"))
  end
end
