defmodule BeamAgent.Goal.ProviderBidCoordinator do
  @moduledoc """
  Goal-scoped provider market and lease-award authority.

  Each eligible endpoint is quoted in an isolated OTP task. The coordinator
  applies routing policy, awards a bounded set of endpoint leases, and records
  a content-free durable audit trail on the requesting session.
  """
  use GenServer

  alias BeamAgent.{ModelRegistry, ModelRouter, Names, ProviderBid}
  alias BeamAgent.Session.EventLog

  @maximum_awards 4
  @history_limit 20
  @bid_public_fields ~w(id auction_id endpoint_id provider model score confidence estimated_latency_ms cost_tier verified_samples score_components reason submitted_at version)a

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:provider_bid_coordinator, goal_id))
  end

  def auction(goal_id, session_id, input, opts \\ [])
      when is_binary(goal_id) and is_binary(session_id) and is_map(input) and is_list(opts) do
    with {:ok, pid} <- Names.pid(:provider_bid_coordinator, goal_id) do
      GenServer.call(
        pid,
        {:auction, session_id, input, opts},
        Keyword.get(opts, :timeout, 30_000)
      )
    end
  end

  def latest(goal_id) when is_binary(goal_id) do
    with {:ok, pid} <- Names.pid(:provider_bid_coordinator, goal_id) do
      GenServer.call(pid, :latest)
    end
  end

  def settle(goal_id, session_id, auction_id, settlement)
      when is_binary(goal_id) and is_binary(session_id) and is_binary(auction_id) and
             is_map(settlement) do
    with {:ok, pid} <- Names.pid(:provider_bid_coordinator, goal_id) do
      GenServer.call(pid, {:settle, session_id, auction_id, settlement})
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       project_id: Keyword.fetch!(opts, :project_id),
       auctions: []
     }}
  end

  @impl true
  def handle_call({:auction, session_id, input, opts}, _from, state) do
    case run_auction(state, session_id, input, opts) do
      {:ok, auction} ->
        auctions = Enum.take([public_auction(auction) | state.auctions], @history_limit)
        {:reply, {:ok, auction}, %{state | auctions: auctions}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:latest, _from, %{auctions: [latest | _]} = state),
    do: {:reply, {:ok, latest}, state}

  def handle_call(:latest, _from, state) do
    case recover_latest(state.goal_id) do
      {:ok, market} -> {:reply, {:ok, market}, %{state | auctions: [market]}}
      :not_found -> {:reply, :not_found, state}
    end
  end

  def handle_call({:settle, session_id, auction_id, settlement}, _from, state) do
    data =
      settlement
      |> Map.put(:auction_id, auction_id)
      |> Map.put_new(:purpose, :work_contract)
      |> stringify()

    case append(session_id, :provider_auction_settled, data) do
      :ok ->
        auctions =
          Enum.map(state.auctions, fn
            %{id: ^auction_id} = auction ->
              auction
              |> Map.put(:status, settlement[:status] || settlement["status"] || :settled)
              |> Map.put(:settlement, settlement)

            auction ->
              auction
          end)

        {:reply, :ok, %{state | auctions: auctions}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp run_auction(state, session_id, input, opts) do
    award_count = opts |> Keyword.get(:award_count, 1) |> normalize_award_count()
    purpose = Keyword.get(opts, :purpose, :work_contract)
    auction_id = new_id()

    with {:ok, route} <- ModelRouter.route(state.project_id, input) do
      if is_nil(route.endpoint) do
        {:ok,
         %{
           id: auction_id,
           purpose: purpose,
           route: route,
           bids: [],
           awards: [],
           status: :deterministic,
           requested_awards: award_count
         }}
      else
        endpoints =
          eligible_endpoints(state.project_id, route.candidate_endpoint_ids, route.endpoint)

        with :ok <-
               append(session_id, :provider_auction_started, %{
                 "auction_id" => auction_id,
                 "purpose" => to_string(purpose),
                 "eligible_count" => length(endpoints),
                 "requested_awards" => award_count,
                 "task_type" => to_string(route.inputs.task_type),
                 "language" => to_string(route.inputs.language),
                 "preference_source" => to_string(input[:preference_source] || :unspecified),
                 "job_role" => input[:job_role]
               }),
             quote_input <-
               input
               |> Map.put(:classification, route.inputs)
               |> Map.put(:routing_evidence, Map.get(route, :evidence, %{})),
             bids <-
               quote_all(
                 state.goal_id,
                 auction_id,
                 endpoints,
                 Map.get(route, :evidence, %{}),
                 quote_input
               ),
             :ok <- append_bids(session_id, bids),
             award_opts <- enforce_routing_boundary(route, input, opts),
             {:ok, awards} <- award(route, bids, endpoints, award_count, award_opts) do
          route = apply_primary_award(route, awards)

          with :ok <-
                 append(session_id, :provider_auction_awarded, %{
                   "auction_id" => auction_id,
                   "purpose" => to_string(purpose),
                   "award_count" => length(awards),
                   "awards" => Enum.map(awards, &public_award/1),
                   "policy_reason" => route.reason
                 }) do
            {:ok,
             %{
               id: auction_id,
               purpose: purpose,
               route: Map.put(route, :provider_auction_id, auction_id),
               bids: bids,
               awards: awards,
               status: :awarded,
               requested_awards: award_count
             }}
          end
        end
      end
    end
  end

  defp enforce_routing_boundary(_route, %{market_competition: true}, opts), do: opts

  defp enforce_routing_boundary(route, _input, opts) do
    Keyword.update(
      opts,
      :pinned_endpoint_ids,
      [route.selected_endpoint_id],
      &Enum.uniq(&1 ++ [route.selected_endpoint_id])
    )
  end

  defp eligible_endpoints(project_id, ids, selected_endpoint) do
    registered =
      Enum.flat_map(ids, fn id ->
        case ModelRegistry.fetch(project_id, id) do
          {:ok, endpoint} -> [endpoint]
          {:error, _reason} -> []
        end
      end)

    case selected_endpoint do
      %{id: id} = endpoint ->
        [endpoint | Enum.reject(registered, &(&1.id == id))]

      _none ->
        registered
    end
  end

  defp quote_all(goal_id, auction_id, endpoints, evidence, input) do
    {:ok, supervisor} = Names.pid(:provider_bid_supervisor, goal_id)

    supervisor
    |> Task.Supervisor.async_stream_nolink(
      endpoints,
      fn endpoint -> ProviderBid.quote(auction_id, endpoint, evidence, input) end,
      ordered: false,
      max_concurrency: min(length(endpoints), 8),
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %ProviderBid{} = bid} -> [bid]
      _failure -> []
    end)
    |> Enum.sort_by(&{-&1.score, &1.endpoint_id})
  end

  defp award(route, bids, endpoints, count, opts) do
    pinned = Keyword.get(opts, :pinned_endpoint_ids, []) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    bid_ids = MapSet.new(bids, & &1.endpoint_id)

    case Enum.find(pinned, &(not MapSet.member?(bid_ids, &1))) do
      nil ->
        ordered_ids =
          (pinned ++ Enum.map(bids, & &1.endpoint_id) ++ [route.selected_endpoint_id])
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(&MapSet.member?(bid_ids, &1))
          |> Enum.uniq()
          |> Enum.take(count)

        awards =
          Enum.map(ordered_ids, fn endpoint_id ->
            %{
              endpoint: Enum.find(endpoints, &(&1.id == endpoint_id)),
              bid: Enum.find(bids, &(&1.endpoint_id == endpoint_id))
            }
          end)

        if awards == [], do: {:error, :no_provider_bids}, else: {:ok, awards}

      endpoint_id ->
        {:error, {:pinned_provider_not_eligible, endpoint_id}}
    end
  end

  defp apply_primary_award(route, [%{endpoint: endpoint, bid: bid} | _]) do
    %{
      route
      | endpoint: endpoint,
        selected_endpoint_id: endpoint.id,
        reason: "provider auction confirmed routing policy: #{route.reason}"
    }
    |> Map.put(:winning_bid, ProviderBid.public(bid))
  end

  defp apply_primary_award(route, []), do: route

  defp append_bid(session_id, bid) do
    data = ProviderBid.public(bid)
    append(session_id, :provider_bid_submitted, data)
  end

  defp append_bids(session_id, bids) do
    Enum.reduce_while(bids, :ok, fn bid, :ok ->
      case append_bid(session_id, bid) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append(session_id, type, data) do
    case EventLog.append(session_id, type, data) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp public_award(%{endpoint: endpoint, bid: bid}) do
    %{
      endpoint_id: endpoint.id,
      provider: to_string(endpoint.provider),
      model: endpoint.model,
      bid_id: bid.id,
      score: bid.score,
      confidence: bid.confidence,
      reason: bid.reason
    }
  end

  defp public_auction(auction) do
    %{
      id: auction.id,
      purpose: auction.purpose,
      status: auction.status,
      requested_awards: auction.requested_awards,
      bids: Enum.map(auction.bids, &ProviderBid.public/1),
      awards: Enum.map(auction.awards, &public_award/1)
    }
  end

  defp normalize_award_count(value) when is_integer(value),
    do: value |> max(1) |> min(@maximum_awards)

  defp normalize_award_count(_value), do: 1

  defp recover_latest(goal_id) do
    with {:ok, events} <- EventLog.events(goal_id),
         %{"data" => started} <-
           events |> Enum.reverse() |> Enum.find(&(&1["type"] == "provider_auction_started")) do
      auction_id = started["auction_id"]

      related =
        Enum.filter(events, fn event ->
          event["type"] in [
            "provider_bid_submitted",
            "provider_auction_awarded",
            "provider_auction_settled"
          ] and event["data"]["auction_id"] == auction_id
        end)

      bids =
        related
        |> Enum.filter(&(&1["type"] == "provider_bid_submitted"))
        |> Enum.map(&known_fields(&1["data"], @bid_public_fields))

      awarded = Enum.find(related, &(&1["type"] == "provider_auction_awarded"))
      settlement = Enum.find(related, &(&1["type"] == "provider_auction_settled"))

      awards =
        case awarded do
          %{"data" => %{"awards" => awards}} when is_list(awards) ->
            Enum.map(
              awards,
              &known_fields(&1, ~w(endpoint_id provider model bid_id score confidence reason)a)
            )

          _none ->
            []
        end

      settlement_data =
        case settlement do
          %{"data" => data} ->
            known_fields(data, ~w(purpose status winner_id winner_endpoint_id winner_provider)a)

          _none ->
            nil
        end

      {:ok,
       %{
         id: auction_id,
         purpose: known_purpose(started["purpose"]),
         status: known_status(settlement_data && settlement_data.status, awarded),
         requested_awards: started["requested_awards"],
         bids: bids,
         awards: awards,
         settlement: settlement_data
       }}
    else
      _missing -> :not_found
    end
  end

  defp known_fields(map, fields) do
    Map.new(fields, fn field -> {field, Map.get(map, to_string(field))} end)
  end

  defp known_purpose("provider_race"), do: :provider_race
  defp known_purpose("provider_tournament"), do: :provider_tournament
  defp known_purpose(_purpose), do: :work_contract

  defp known_status("selected", _awarded), do: :selected
  defp known_status("inconclusive", _awarded), do: :inconclusive
  defp known_status(_status, nil), do: :bidding
  defp known_status(_status, _awarded), do: :awarded

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp new_id,
    do: "auction-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
