defmodule BeamAgent.Goal.Race do
  @moduledoc """
  Bounded speculative execution for independently evaluated worker alternatives.

  A race never applies or merges a result. It returns a selected candidate only
  when the supplied deterministic evaluator or consensus rule can justify one.
  """

  alias BeamAgent.{Agent, Goal.Verifier}
  alias BeamAgent.Session.EventLog

  def run(parent_session_id, candidates, opts \\ [])
      when is_binary(parent_session_id) and is_list(candidates) do
    justification = Keyword.get(opts, :justification)

    with :ok <- validate_candidates(candidates, justification),
         {:ok, parent} <- Agent.construction_context(parent_session_id) do
      race_id = new_id()

      {:ok, _event} =
        EventLog.append(parent_session_id, :race_started, %{
          "race_id" => race_id,
          "candidate_count" => length(candidates),
          "justification_fingerprint" => fingerprint(justification)
        })

      results =
        candidates
        |> Task.async_stream(
          &run_candidate(parent, race_id, &1, opts),
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
          {:ok, _event} =
            EventLog.append(parent_session_id, :race_winner_selected, %{
              "race_id" => race_id,
              "winner_id" => winner_id,
              "evaluation_fingerprint" => fingerprint(inspect(evidence))
            })

          {:ok, _event} =
            EventLog.append(parent_session_id, :race_collapsed, %{
              "race_id" => race_id,
              "winner_id" => winner_id,
              "discarded_count" => length(candidates) - 1,
              "retained_worktree_count" => retained_worktree_count(results),
              "merged" => false
            })

          {:ok, %{race_id: race_id, status: :selected, winner_id: winner_id, results: results}}

        {:error, reason} ->
          {:ok, _event} =
            EventLog.append(parent_session_id, :race_inconclusive, %{
              "race_id" => race_id,
              "failure_code" => reason_code(reason),
              "merged" => false
            })

          {:ok, %{race_id: race_id, status: :inconclusive, winner_id: nil, results: results}}
      end
    end
  end

  defp run_candidate(parent, race_id, candidate, opts) do
    id = candidate_id(candidate)
    prompt = value(candidate, :prompt) || value(candidate, :goal)
    worker_id = BeamAgent.new_session_id()
    worker_options = Keyword.get(opts, :worker_options, [])

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

    with {:ok, worktree} <- maybe_create_worktree(parent, worker_id, id, opts),
         worker_options <- bind_isolation(worker_options, worker_id, worktree),
         {:ok, handle} <- BeamAgent.spawn_worker(parent.session_id, proposal, worker_options) do
      try do
        case BeamAgent.ask(handle.worker_id, prompt) do
          {:ok, content} ->
            verification = verify_candidate(parent, handle, candidate, opts)
            {:ok, result} = BeamAgent.complete_worker(handle, content, verification)
            worktree_evidence = inspect_worktree(parent, worktree)

            {:ok, _event} =
              EventLog.append(parent.session_id, :race_candidate_completed, %{
                "race_id" => race_id,
                "candidate_id" => id,
                "worker_id" => handle.worker_id,
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
        {:error, :unsupported_race_isolation}
    end
  end

  defp bind_isolation(worker_options, worker_id, nil),
    do: Keyword.put_new(worker_options, :session_id, worker_id)

  defp bind_isolation(worker_options, worker_id, worktree) do
    worker_options
    |> Keyword.put(:session_id, worker_id)
    |> Keyword.put(:worktree_handle, worktree)
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
        {:error, :invalid_race_evaluation}
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

  defp evaluate(_results, _evaluator), do: {:error, :unsupported_race_evaluator}

  defp validate_candidates(candidates, justification)
       when length(candidates) in 2..4 and is_binary(justification) and justification != "" do
    ids = Enum.map(candidates, &candidate_id/1)

    if Enum.all?(candidates, &valid_candidate?/1) and length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, :invalid_race_candidates}
  end

  defp validate_candidates(_candidates, _justification),
    do: {:error, :race_requires_two_to_four_justified_candidates}

  defp valid_candidate?(candidate) when is_map(candidate) do
    is_binary(candidate_id(candidate)) and candidate_id(candidate) != "" and
      is_binary(value(candidate, :prompt) || value(candidate, :goal))
  end

  defp valid_candidate?(_candidate), do: false
  defp candidate_id(candidate), do: value(candidate, :id)
  defp value(map, key), do: map[key] || map[to_string(key)]
  defp normalize(content), do: content |> String.trim() |> String.downcase()
  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp reason_code(reason) when is_atom(reason), do: to_string(reason)
  defp reason_code(_reason), do: "race_inconclusive"

  defp new_id,
    do: "race-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
