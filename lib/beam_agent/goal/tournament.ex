defmodule BeamAgent.Goal.Tournament do
  @moduledoc """
  Bounded speculative execution for independently evaluated worker alternatives.

  A tournament never applies or merges a result. It returns a selected candidate only
  when the supplied deterministic evaluator or consensus rule can justify one.
  """

  alias BeamAgent.{
    Agent,
    Goal.ModelLease,
    Goal.ProviderBidCoordinator,
    Goal.Verifier,
    ModelEndpoint,
    ModelRegistry
  }

  alias BeamAgent.Session.EventLog

  def run(parent_session_id, candidates, opts \\ [])
      when is_binary(parent_session_id) and is_list(candidates) do
    justification = Keyword.get(opts, :justification)

    with :ok <- validate_candidates(candidates, justification),
         {:ok, parent} <- Agent.construction_context(parent_session_id),
         {:ok, auction, candidates} <- assign_providers(parent, candidates, opts) do
      tournament_id = new_id()

      {:ok, _event} =
        EventLog.append(parent_session_id, :tournament_started, %{
          "tournament_id" => tournament_id,
          "candidate_count" => length(candidates),
          "provider_auction_id" => auction.id,
          "provider_count" =>
            auction.awards |> Enum.map(& &1.endpoint.id) |> Enum.uniq() |> length(),
          "provider_endpoint_ids" => Enum.map(auction.awards, & &1.endpoint.id),
          "justification_fingerprint" => fingerprint(justification)
        })

      results =
        candidates
        |> Task.async_stream(
          &run_candidate(parent, tournament_id, &1, opts),
          max_concurrency: min(length(candidates), Keyword.get(opts, :maximum_parallelism, 3)),
          ordered: true,
          timeout: Keyword.get(opts, :timeout, :infinity),
          on_timeout: :kill_task
        )
        |> Enum.zip(candidates)
        |> Map.new(fn
          {{:ok, result}, candidate} -> {candidate_id(candidate), result}
          {{:exit, reason}, candidate} -> {candidate_id(candidate), {:error, reason}}
        end)

      case evaluate(results, Keyword.get(opts, :evaluator, :consensus)) do
        {:ok, winner_id, evidence} ->
          winner = winner_result(results, winner_id)

          {:ok, _event} =
            EventLog.append(parent_session_id, :tournament_winner_selected, %{
              "tournament_id" => tournament_id,
              "winner_id" => winner_id,
              "provider_auction_id" => auction.id,
              "winner_endpoint_id" => get_in(winner, [:provider_bid, :endpoint_id]),
              "winner_provider" =>
                get_in(winner, [:provider_bid, :provider]) &&
                  to_string(get_in(winner, [:provider_bid, :provider])),
              "selection_source" => "deterministic_evaluator",
              "evaluation_fingerprint" => fingerprint(inspect(evidence))
            })

          append_settlement(
            parent.goal_id,
            parent_session_id,
            auction,
            :selected,
            winner_id,
            winner
          )

          {:ok, _event} =
            EventLog.append(parent_session_id, :tournament_collapsed, %{
              "tournament_id" => tournament_id,
              "winner_id" => winner_id,
              "discarded_count" => length(candidates) - 1,
              "retained_worktree_count" => retained_worktree_count(results),
              "merged" => false,
              "selection_source" => "deterministic_evaluator"
            })

          {:ok,
           %{
             tournament_id: tournament_id,
             provider_auction_id: auction.id,
             status: :selected,
             winner_id: winner_id,
             results: results
           }}

        {:error, reason} ->
          {:ok, _event} =
            EventLog.append(parent_session_id, :tournament_inconclusive, %{
              "tournament_id" => tournament_id,
              "failure_code" => reason_code(reason),
              "merged" => false
            })

          append_settlement(parent.goal_id, parent_session_id, auction, :inconclusive, nil, nil)

          {:ok,
           %{
             tournament_id: tournament_id,
             provider_auction_id: auction.id,
             status: :inconclusive,
             winner_id: nil,
             results: results
           }}
      end
    end
  end

  @doc false
  def request_judgment(parent_session_id, tournament) do
    candidates =
      tournament.results
      |> Enum.sort_by(fn {id, _result} -> id end)
      |> Enum.flat_map(fn
        {id, {:ok, result}} ->
          [
            %{
              "candidate_id" => id,
              "content" => result.content,
              "endpoint_id" => get_in(result, [:provider_bid, :endpoint_id]),
              "provider" => provider_name(result)
            }
          ]

        _other ->
          []
      end)

    EventLog.append(parent_session_id, :tournament_judgment_requested, %{
      "tournament_id" => tournament.tournament_id,
      "provider_auction_id" => tournament.provider_auction_id,
      "candidate_count" => length(candidates),
      "candidates" => candidates,
      "selection_source" => "parent_judgment"
    })
  end

  @doc false
  def resolve_pending_judgment(goal_id, parent_session_id, answer)
      when is_binary(goal_id) and is_binary(parent_session_id) and is_binary(answer) do
    with {:ok, events} <- EventLog.events(parent_session_id),
         %{"data" => request} <- pending_judgment(events),
         {:ok, winner} <- select_judged_candidate(request["candidates"] || [], answer) do
      tournament_id = request["tournament_id"]

      with {:ok, _event} <-
             EventLog.append(parent_session_id, :tournament_winner_selected, %{
               "tournament_id" => tournament_id,
               "winner_id" => winner["candidate_id"],
               "provider_auction_id" => request["provider_auction_id"],
               "winner_endpoint_id" => winner["endpoint_id"],
               "winner_provider" => winner["provider"],
               "selection_source" => "parent_judgment",
               "evaluation_fingerprint" => fingerprint(answer)
             }),
           :ok <-
             ProviderBidCoordinator.settle(
               goal_id,
               parent_session_id,
               request["provider_auction_id"],
               %{
                 purpose: :provider_tournament,
                 status: :selected,
                 winner_id: winner["candidate_id"],
                 winner_endpoint_id: winner["endpoint_id"],
                 winner_provider: winner["provider"]
               }
             ),
           {:ok, _event} <-
             EventLog.append(parent_session_id, :tournament_collapsed, %{
               "tournament_id" => tournament_id,
               "winner_id" => winner["candidate_id"],
               "discarded_count" => max((request["candidate_count"] || 1) - 1, 0),
               "merged" => false,
               "selection_source" => "parent_judgment"
             }) do
        {:ok, winner["content"]}
      end
    else
      nil ->
        :not_pending

      {:error, :no_matching_candidate} ->
        append_unresolved_judgment(parent_session_id)
        :unresolved

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def run_candidate(parent, competition_id, candidate, opts) do
    id = candidate_id(candidate)
    prompt = value(candidate, :prompt) || value(candidate, :goal)
    worker_id = BeamAgent.new_session_id()
    provider_assignment = value(candidate, :provider_assignment)

    worker_options =
      opts
      |> Keyword.get(:worker_options, [])
      |> bind_provider(provider_assignment)
      |> Keyword.put(:completion_review, :external)

    proposal =
      candidate
      |> Map.take([
        :goal,
        :role,
        :template,
        :instructions,
        :capabilities,
        :model_requirements,
        :verification_requirements,
        :completion_criteria,
        "goal",
        "role",
        "template",
        "instructions",
        "capabilities",
        "model_requirements",
        "verification_requirements",
        "completion_criteria"
      ])
      |> Map.put_new(:goal, prompt)
      |> prevent_nested_delegation(parent, opts)

    with {:ok, worktree} <- maybe_create_worktree(parent, worker_id, id, opts),
         worker_options <- bind_isolation(worker_options, worker_id, worktree),
         {:ok, handle} <- BeamAgent.spawn_worker(parent.session_id, proposal, worker_options),
         :ok <- lease_candidate_provider(parent.goal_id, handle.worker_id, provider_assignment),
         :ok <-
           append_candidate_started(
             parent.session_id,
             competition_id,
             id,
             handle.worker_id,
             provider_assignment,
             competition(opts)
           ) do
      notify_coordinator(opts, id, handle)
      await_coordinator_start(opts)

      try do
        case BeamAgent.ask(handle.worker_id, prompt) do
          {:ok, content} ->
            verification = verify_candidate(parent, handle, candidate, opts)
            {:ok, result} = BeamAgent.complete_worker(handle, content, verification)
            worktree_evidence = inspect_worktree(parent, worktree)

            {:ok, _event} =
              EventLog.append(parent.session_id, completed_event(competition(opts)), %{
                id_key(competition(opts)) => competition_id,
                "candidate_id" => id,
                "worker_id" => handle.worker_id,
                "provider_auction_id" => provider_assignment.auction_id,
                "endpoint_id" => provider_assignment.endpoint_id,
                "provider" => to_string(provider_assignment.provider),
                "model" => provider_assignment.model,
                "bid_score" => provider_assignment.score,
                "result_fingerprint" => fingerprint(content),
                "verification_status" => verification_status(verification),
                "worktree_id" => worktree_id(worktree),
                "patch_fingerprint" => patch_fingerprint(worktree_evidence)
              })

            {:ok,
             %{
               candidate_id: id,
               content: content,
               result: result,
               verification: verification,
               provider_bid: provider_assignment,
               worktree: worktree,
               worktree_evidence: worktree_evidence
             }}

          {:error, reason} ->
            _ = BeamAgent.cancel_worker(handle, reason)
            {:error, reason}
        end
      after
        _ = BeamAgent.stop_session(handle.worker_id)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp prevent_nested_delegation(proposal, parent, opts) do
    capabilities = value(proposal, :capabilities) || %{}

    tools =
      case value(capabilities, :tools) do
        nil -> effective_tool_names(parent)
        :all -> effective_tool_names(parent)
        "all" -> effective_tool_names(parent)
        names when is_list(names) -> Enum.map(names, &to_string/1)
        name when is_binary(name) -> [name]
        _other -> []
      end

    tools =
      Enum.reject(tools, &(&1 in ["delegate_tasks", "spawn_subagent", "request_capability"]))

    tools =
      if competition(opts) == :race and Keyword.get(opts, :isolation, :shared) == :shared do
        Enum.filter(tools, &read_only_tool?/1)
      else
        tools
      end

    capabilities = capabilities |> Map.delete("tools") |> Map.put(:tools, tools)
    proposal |> Map.delete("capabilities") |> Map.put(:capabilities, capabilities)
  end

  defp effective_tool_names(%{capability_envelope: %{scopes: %{tools: :all}}, goal_id: goal_id}) do
    builtin = Enum.map(BeamAgent.CapabilityCatalog.tool_schemas(), & &1.name)

    mcp =
      case BeamAgent.MCP.Registry.tool_schemas(goal_id) do
        schemas when is_list(schemas) -> Enum.map(schemas, & &1.name)
        _other -> []
      end

    Enum.uniq(builtin ++ mcp)
  end

  defp effective_tool_names(%{capability_envelope: %{scopes: %{tools: tools}}})
       when is_list(tools),
       do: tools

  defp effective_tool_names(_parent), do: []

  defp read_only_tool?(name) do
    case BeamAgent.CapabilityCatalog.tool(name) do
      {:ok, module} ->
        access = if function_exported?(module, :access, 0), do: module.access(), else: :trusted
        access in [:read, :trusted]

      {:error, _reason} ->
        false
    end
  end

  defp maybe_create_worktree(parent, worker_id, candidate_id, opts) do
    case Keyword.get(opts, :isolation, :shared) do
      :shared ->
        {:ok, nil}

      :worktree ->
        BeamAgent.create_worktree(parent.project_id, worker_id,
          purpose: "speculative candidate #{candidate_id}",
          event_session_id: parent.session_id
        )

      _other ->
        {:error, :unsupported_tournament_isolation}
    end
  end

  defp bind_isolation(worker_options, worker_id, nil),
    do: Keyword.put_new(worker_options, :session_id, worker_id)

  defp bind_isolation(worker_options, worker_id, worktree) do
    worker_options
    |> Keyword.put(:session_id, worker_id)
    |> Keyword.put(:worktree_handle, worktree)
  end

  @doc false
  def assign_providers(parent, candidates, _opts, purpose \\ :provider_tournament) do
    requirements = parent.agent_spec.model_requirements

    input = %{
      prompt: candidates |> hd() |> then(&(value(&1, :prompt) || value(&1, :goal))),
      workspace_root: parent.workspace_root,
      strategy: parent.model_strategy,
      preferred_connection_id:
        parent.provider_options[:profile] || parent.provider_profile || to_string(parent.provider),
      preferred_model: parent.provider_options[:model],
      preferred_endpoint_id: parent.provider_profile || to_string(parent.provider),
      preferred_provider: parent.provider,
      tools: [],
      context_tokens: 0,
      latency_preference: requirements.latency,
      cost_preference: requirements.cost,
      reasoning_requirement: requirements.reasoning,
      locality_requirement: requirements.locality,
      privacy_requirement: requirements.privacy,
      capability_envelope: parent.capability_envelope,
      modalities_required: [:text],
      force_model: true
    }

    with {:ok, pinned} <- resolve_pinned_endpoints(parent.project_id, candidates),
         {:ok, auction} <-
           ProviderBidCoordinator.auction(parent.goal_id, parent.session_id, input,
             purpose: purpose,
             award_count: length(candidates),
             pinned_endpoint_ids: pinned
           ),
         {:ok, assigned} <- attach_assignments(candidates, auction) do
      {:ok, auction, assigned}
    end
  end

  defp resolve_pinned_endpoints(project_id, candidates) do
    {:ok, endpoints} = ModelRegistry.list(project_id)

    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, ids} ->
      case requested_endpoint(candidate, endpoints) do
        nil -> {:cont, {:ok, ids}}
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp requested_endpoint(candidate, endpoints) do
    endpoint_id = value(candidate, :endpoint_id) || value(candidate, :provider_profile)
    provider = value(candidate, :provider)

    cond do
      is_binary(endpoint_id) ->
        if Enum.any?(endpoints, &(&1.id == endpoint_id)),
          do: {:ok, endpoint_id},
          else: {:error, {:unknown_model_endpoint, endpoint_id}}

      not is_nil(provider) ->
        case Enum.find(endpoints, &(to_string(&1.provider) == to_string(provider))) do
          nil -> {:error, {:unknown_model_provider, provider}}
          endpoint -> {:ok, endpoint.id}
        end

      true ->
        nil
    end
  end

  defp attach_assignments(_candidates, %{awards: []}), do: {:error, :provider_auction_empty}

  defp attach_assignments(candidates, auction) do
    awards_by_id = Map.new(auction.awards, &{&1.endpoint.id, &1})

    candidates
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn candidate, {:ok, assigned, used} ->
      case choose_award(candidate, auction.awards, awards_by_id, used) do
        nil ->
          {:halt, {:error, {:no_eligible_provider_for_candidate, candidate_id(candidate)}}}

        award ->
          assignment =
            award.bid
            |> BeamAgent.ProviderBid.public()
            |> atomize_assignment(award.endpoint, auction)

          {:cont,
           {:ok, [Map.put(candidate, :provider_assignment, assignment) | assigned],
            MapSet.put(used, award.endpoint.id)}}
      end
    end)
    |> case do
      {:ok, assigned, _used} -> {:ok, Enum.reverse(assigned)}
      error -> error
    end
  end

  defp choose_award(candidate, awards, awards_by_id, used) do
    requested = value(candidate, :endpoint_id) || value(candidate, :provider_profile)
    requested_provider = value(candidate, :provider)

    cond do
      is_binary(requested) ->
        case awards_by_id[requested] do
          %{endpoint: endpoint} = award -> if eligible?(endpoint, candidate), do: award
          _missing -> nil
        end

      not is_nil(requested_provider) ->
        Enum.find(awards, fn award ->
          to_string(award.endpoint.provider) == to_string(requested_provider) and
            eligible?(award.endpoint, candidate)
        end)

      true ->
        Enum.find(awards, fn award ->
          not MapSet.member?(used, award.endpoint.id) and eligible?(award.endpoint, candidate)
        end) || Enum.find(awards, &eligible?(&1.endpoint, candidate))
    end
  end

  defp eligible?(endpoint, candidate) do
    requirements = value(candidate, :model_requirements) || %{}
    locality = map_value(requirements, :locality)
    privacy = map_value(requirements, :privacy)

    (locality in [nil, :any, "any"] or to_string(endpoint.claims.locality) == to_string(locality)) and
      (privacy not in [:local, "local"] or endpoint.claims.privacy == :local)
  end

  defp atomize_assignment(public_bid, endpoint, auction) do
    route =
      auction.route
      |> Map.put(:endpoint, endpoint)
      |> Map.put(:selected_endpoint_id, endpoint.id)
      |> Map.put(:provider_auction_id, auction.id)
      |> Map.put(:winning_bid, public_bid)
      |> Map.put(:reason, "provider tournament lease awarded from #{public_bid.id}")

    %{
      auction_id: public_bid.auction_id,
      bid_id: public_bid.id,
      endpoint_id: endpoint.id,
      provider: endpoint.provider,
      model: endpoint.model,
      score: public_bid.score,
      confidence: public_bid.confidence,
      cost_tier: public_bid.cost_tier,
      reason: public_bid.reason,
      endpoint: endpoint,
      route: route
    }
  end

  defp bind_provider(worker_options, %{endpoint: %ModelEndpoint{} = endpoint}) do
    worker_options
    |> Keyword.put(:provider, endpoint.provider)
    |> Keyword.put(:provider_profile, endpoint.id)
    |> Keyword.put(:provider_options, ModelEndpoint.invocation_options(endpoint))
    |> Keyword.put(:model_strategy, :manual)
  end

  defp lease_candidate_provider(goal_id, worker_id, %{route: route}) do
    case ModelLease.put_new(goal_id, "worker:" <> worker_id, route) do
      {:ok, _route} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_candidate_started(
         session_id,
         competition_id,
         candidate_id,
         worker_id,
         assignment,
         competition
       ) do
    case EventLog.append(session_id, started_event(competition), %{
           id_key(competition) => competition_id,
           "candidate_id" => candidate_id,
           "worker_id" => worker_id,
           "provider_auction_id" => assignment.auction_id,
           "endpoint_id" => assignment.endpoint_id,
           "provider" => to_string(assignment.provider),
           "model" => assignment.model,
           "bid_score" => assignment.score
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_settlement(goal_id, session_id, auction, status, winner_id, winner) do
    ProviderBidCoordinator.settle(
      goal_id,
      session_id,
      auction.id,
      %{
        purpose: :provider_tournament,
        status: status,
        winner_id: winner_id,
        winner_endpoint_id: get_in(winner || %{}, [:provider_bid, :endpoint_id]),
        winner_provider:
          case get_in(winner || %{}, [:provider_bid, :provider]) do
            nil -> nil
            provider -> to_string(provider)
          end
      }
    )
  end

  defp winner_result(results, winner_id) do
    case results[winner_id] do
      {:ok, result} -> result
      _other -> %{}
    end
  end

  defp verify_candidate(parent, handle, candidate, opts) do
    verify? =
      Keyword.get(opts, :verify_candidates, false) or
        not is_nil(value(candidate, :verification_plan))

    if verify? do
      plan = value(candidate, :verification_plan) || :auto

      case Verifier.run(parent.goal_id, plan,
             session_id: handle.worker_id,
             worker_id: handle.worker_id
           ) do
        {:ok, verification} -> verification
        {:error, reason} -> %{status: :unavailable, reason: reason}
      end
    else
      %{status: :unverified}
    end
  end

  defp inspect_worktree(_parent, nil), do: nil

  defp inspect_worktree(parent, worktree) do
    case BeamAgent.inspect_worktree(parent.project_id, worktree.id) do
      {:ok, evidence} -> evidence
      {:error, reason} -> %{error: reason, handle: worktree}
    end
  end

  defp verification_status(%{status: status}), do: to_string(status)
  defp verification_status(_verification), do: "unverified"
  defp worktree_id(nil), do: nil
  defp worktree_id(worktree), do: worktree.id
  defp patch_fingerprint(%{patch_fingerprint: value}), do: value
  defp patch_fingerprint(_evidence), do: nil

  defp retained_worktree_count(results) do
    Enum.count(results, fn
      {_id, {:ok, %{worktree: worktree}}} -> not is_nil(worktree)
      _other -> false
    end)
  end

  defp evaluate(results, evaluator) when is_function(evaluator, 1) do
    case evaluator.(results) do
      {:ok, winner_id, evidence} when is_map_key(results, winner_id) ->
        {:ok, winner_id, evidence}

      {:ok, winner_id} when is_map_key(results, winner_id) ->
        {:ok, winner_id, %{source: :custom}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_tournament_evaluation}
    end
  end

  defp evaluate(results, :consensus) do
    groups =
      results
      |> Enum.flat_map(fn
        {id, {:ok, %{content: content}}} -> [{normalize(content), id}]
        _other -> []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(fn {_content, ids} -> {-length(ids), hd(Enum.sort(ids))} end)

    case groups do
      [{content, ids} | _rest] when length(ids) >= 2 ->
        {:ok, hd(Enum.sort(ids)), %{source: :exact_consensus, participants: ids, value: content}}

      _other ->
        {:error, :no_deterministic_consensus}
    end
  end

  defp evaluate(results, :verified_patch) do
    verified =
      Enum.flat_map(results, fn
        {id,
         {:ok,
          %{
            verification: %{status: :passed},
            worktree_evidence: %{
              changed_files: [_ | _],
              patch_fingerprint: patch_fingerprint
            }
          } = result}} ->
          [{id, patch_fingerprint, result}]

        _other ->
          []
      end)

    case verified do
      [{id, patch_fingerprint, _result}] ->
        {:ok, id, %{source: :deterministic_verification, patch_fingerprint: patch_fingerprint}}

      [_first, _second | _rest] ->
        patch_fingerprints = verified |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        if length(patch_fingerprints) == 1 do
          {id, patch_fingerprint, _result} = Enum.min_by(verified, &elem(&1, 0))

          {:ok, id, %{source: :equivalent_verified_patches, patch_fingerprint: patch_fingerprint}}
        else
          {:error, :independent_review_required}
        end

      [] ->
        {:error, :no_verified_patch}
    end
  end

  defp evaluate(_results, _evaluator), do: {:error, :unsupported_tournament_evaluator}

  @doc false
  def validate_candidates(candidates, justification)
      when length(candidates) in 2..4 and is_binary(justification) and justification != "" do
    ids = Enum.map(candidates, &candidate_id/1)

    if Enum.all?(candidates, &valid_candidate?/1) and length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, :invalid_tournament_candidates}
  end

  def validate_candidates(_candidates, _justification),
    do: {:error, :tournament_requires_two_to_four_justified_candidates}

  defp valid_candidate?(candidate) when is_map(candidate) do
    is_binary(candidate_id(candidate)) and candidate_id(candidate) != "" and
      is_binary(value(candidate, :prompt) || value(candidate, :goal))
  end

  defp valid_candidate?(_candidate), do: false
  defp candidate_id(candidate), do: value(candidate, :id)
  defp value(map, key), do: map[key] || map[to_string(key)]
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp normalize(content), do: content |> String.trim() |> String.downcase()
  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp reason_code(reason) when is_atom(reason), do: to_string(reason)
  defp reason_code(_reason), do: "tournament_inconclusive"

  defp competition(opts), do: Keyword.get(opts, :competition, :tournament)
  defp started_event(:race), do: :race_candidate_started
  defp started_event(_competition), do: :tournament_candidate_started
  defp completed_event(:race), do: :race_candidate_completed
  defp completed_event(_competition), do: :tournament_candidate_completed
  defp id_key(:race), do: "race_id"
  defp id_key(_competition), do: "tournament_id"

  defp notify_coordinator(opts, candidate_id, handle) do
    case Keyword.get(opts, :coordinator) do
      {pid, ref} when is_pid(pid) ->
        send(pid, {:competition_worker_started, ref, candidate_id, handle})

      _other ->
        :ok
    end
  end

  defp await_coordinator_start(opts) do
    case Keyword.get(opts, :coordinator) do
      {_pid, ref} ->
        receive do
          {:competition_go, ^ref} -> :ok
        end

      _other ->
        :ok
    end
  end

  defp pending_judgment(events) do
    requested =
      events
      |> Enum.reverse()
      |> Enum.find(&(&1["type"] == "tournament_judgment_requested"))

    case requested do
      nil ->
        nil

      %{"seq" => seq, "data" => %{"tournament_id" => tournament_id}} ->
        resolved? =
          Enum.any?(events, fn event ->
            event["seq"] > seq and event["data"]["tournament_id"] == tournament_id and
              event["type"] in [
                "tournament_winner_selected",
                "tournament_judgment_unresolved"
              ]
          end)

        if resolved?, do: nil, else: requested
    end
  end

  defp select_judged_candidate(candidates, answer) do
    explicit_id =
      case Regex.run(~r/^\s*WINNER:\s*(?<id>[^\s]+)\s*$/mi, answer, capture: ["id"]) do
        [id] -> id
        _other -> nil
      end

    exact =
      Enum.find(candidates, fn candidate ->
        normalize(candidate["content"] || "") == normalize(answer)
      end)

    contained =
      candidates
      |> Enum.filter(fn candidate ->
        content = String.trim(candidate["content"] || "")
        content != "" and String.contains?(answer, content)
      end)
      |> case do
        [candidate] -> candidate
        _other -> nil
      end

    winner =
      if explicit_id,
        do: Enum.find(candidates, &(&1["candidate_id"] == explicit_id)),
        else: exact || contained

    if winner, do: {:ok, winner}, else: {:error, :no_matching_candidate}
  end

  defp append_unresolved_judgment(parent_session_id) do
    with {:ok, events} <- EventLog.events(parent_session_id),
         %{"data" => request} <- pending_judgment(events) do
      EventLog.append(parent_session_id, :tournament_judgment_unresolved, %{
        "tournament_id" => request["tournament_id"],
        "failure_code" => "no_matching_candidate",
        "selection_source" => "parent_judgment"
      })
    else
      _other -> :ok
    end
  end

  defp provider_name(result) do
    case get_in(result, [:provider_bid, :provider]) do
      nil -> nil
      provider -> to_string(provider)
    end
  end

  defp new_id,
    do: "tournament-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
