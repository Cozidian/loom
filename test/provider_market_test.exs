defmodule BeamAgent.ProviderMarketTest do
  use ExUnit.Case, async: false

  defmodule ProviderA do
    @behaviour BeamAgent.LLMProvider
    def id, do: :market_a

    def configuration,
      do: %{
        name: "market_a",
        label: "Provider market test A",
        capabilities: [:text_generation, :reasoning],
        cost_hint: :low
      }

    def complete(_messages, _tools, _options),
      do: {:ok, %{content: "shared winner", tool_calls: []}}
  end

  defmodule ProviderB do
    @behaviour BeamAgent.LLMProvider
    def id, do: :market_b

    def configuration,
      do: %{
        name: "market_b",
        label: "Provider market test B",
        capabilities: [:text_generation, :reasoning],
        cost_hint: :low
      }

    def complete(_messages, _tools, _options),
      do: {:ok, %{content: "shared winner", tool_calls: []}}
  end

  setup_all do
    :ok = BeamAgent.CapabilityCatalog.register_provider(ProviderA)
    :ok = BeamAgent.CapabilityCatalog.register_provider(ProviderB)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "beam-agent-market-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    data_dir = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{workspace: workspace, data_dir: data_dir}
  end

  test "normal work opens a bounded provider auction before leasing a model", context do
    {:ok, session_id} = start_market_session(context)

    assert {:ok, "shared winner"} = BeamAgent.ask(session_id, "explain this briefly")
    assert {:ok, market} = BeamAgent.provider_market(session_id)
    assert market.purpose == :work_contract
    assert length(market.bids) == 2
    assert [%{endpoint_id: "provider-a"}] = market.awards

    {:ok, events} = BeamAgent.events(session_id)
    types = Enum.map(events, & &1["type"])
    assert "provider_auction_started" in types
    assert Enum.count(types, &(&1 == "provider_bid_submitted")) == 2
    assert "provider_auction_awarded" in types

    auction = Enum.find_index(types, &(&1 == "provider_auction_awarded"))
    route = Enum.find_index(types, &(&1 == "model_route_selected"))
    assert auction < route

    {:ok, old_coordinator} =
      BeamAgent.Names.pid(:provider_bid_coordinator, session_id)

    Process.exit(old_coordinator, :kill)
    assert eventually_new_coordinator(session_id, old_coordinator)
    assert {:ok, recovered} = BeamAgent.provider_market(session_id)
    assert recovered.id == market.id
    assert recovered.status == :awarded
    assert [%{endpoint_id: "provider-a"}] = recovered.awards
  end

  test "a tournament assigns distinct provider leases and records the winning provider",
       context do
    {:ok, session_id} = start_market_session(context)

    candidates = [
      %{id: "a", goal: "return a bounded result"},
      %{id: "b", goal: "return a bounded result"}
    ]

    assert {:ok, tournament} =
             BeamAgent.tournament_workers(session_id, candidates,
               justification: "Compare two provider implementations and retain one"
             )

    assert tournament.status == :selected

    endpoint_ids =
      tournament.results
      |> Map.values()
      |> Enum.map(fn {:ok, result} -> result.provider_bid.endpoint_id end)
      |> Enum.sort()

    assert endpoint_ids == ["provider-a", "provider-b"]

    {:ok, events} = BeamAgent.events(session_id)
    started = Enum.find(events, &(&1["type"] == "tournament_started"))
    candidate_started = Enum.find(events, &(&1["type"] == "tournament_candidate_started"))
    winner = Enum.find(events, &(&1["type"] == "tournament_winner_selected"))
    settlement = Enum.find(events, &(&1["type"] == "provider_auction_settled"))

    assert started["data"]["provider_count"] == 2
    assert is_binary(candidate_started["data"]["worker_id"])
    assert winner["data"]["winner_endpoint_id"] in ["provider-a", "provider-b"]
    assert settlement["data"]["status"] == "selected"
    assert settlement["data"]["winner_endpoint_id"] == winner["data"]["winner_endpoint_id"]

    assert {:ok, market} = BeamAgent.provider_market(session_id)
    assert market.purpose == :provider_tournament
    assert market.status == :selected
    assert market.settlement.winner_endpoint_id == winner["data"]["winner_endpoint_id"]
  end

  test "a candidate can explicitly pin an endpoint in a provider tournament", context do
    {:ok, session_id} = start_market_session(context)

    candidates = [
      %{id: "b", goal: "return a bounded result", endpoint_id: "provider-b"},
      %{id: "a", goal: "return a bounded result", endpoint_id: "provider-a"}
    ]

    assert {:ok, tournament} =
             BeamAgent.tournament_workers(session_id, candidates,
               justification: "Explicit cross-provider tournament"
             )

    assert {:ok, %{provider_bid: %{endpoint_id: "provider-b"}}} = tournament.results["b"]
    assert {:ok, %{provider_bid: %{endpoint_id: "provider-a"}}} = tournament.results["a"]
  end

  defp start_market_session(context) do
    BeamAgent.start_session(
      data_dir: context.data_dir,
      workspace_root: context.workspace,
      provider: :market_a,
      provider_profile: "provider-a",
      model_strategy: :auto,
      budget: %{concurrent_workers: 3},
      model_endpoints: [
        %{
          id: "provider-a",
          provider: :market_a,
          provider_module: ProviderA,
          measurements: %{latency_ms: 120}
        },
        %{
          id: "provider-b",
          provider: :market_b,
          provider_module: ProviderB,
          measurements: %{latency_ms: 180}
        }
      ]
    )
  end

  defp eventually_new_coordinator(goal_id, old, attempts \\ 50)
  defp eventually_new_coordinator(_goal_id, _old, 0), do: false

  defp eventually_new_coordinator(goal_id, old, attempts) do
    case BeamAgent.Names.pid(:provider_bid_coordinator, goal_id) do
      {:ok, pid} when pid != old ->
        true

      _other ->
        Process.sleep(10)
        eventually_new_coordinator(goal_id, old, attempts - 1)
    end
  end
end
