defmodule BeamAgent.Goal.Race do
  @moduledoc """
  First-admissible speculative execution across independently supervised workers.

  The first candidate that returns a successful, admissible terminal result is
  durably selected. The coordinator then cancels every remaining worker and
  waits for their task processes to terminate before settling the provider
  auction. A late result can therefore never replace the winner.
  """

  alias BeamAgent.{Agent, Goal.ProviderBidCoordinator, Names}
  alias BeamAgent.Goal.Tournament
  alias BeamAgent.Session.EventLog

  @default_timeout 120_000

  def run(parent_session_id, candidates, opts \\ [])
      when is_binary(parent_session_id) and is_list(candidates) do
    justification = Keyword.get(opts, :justification)

    with :ok <- Tournament.validate_candidates(candidates, justification),
         :ok <- validate_isolation(opts),
         {:ok, parent} <- Agent.construction_context(parent_session_id),
         {:ok, auction, candidates} <-
           Tournament.assign_providers(parent, candidates, opts, :provider_race),
         {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, parent.goal_id) do
      race_id = new_id()

      with {:ok, _event} <-
             EventLog.append(parent_session_id, :race_started, %{
               "race_id" => race_id,
               "candidate_count" => length(candidates),
               "provider_auction_id" => auction.id,
               "provider_count" => provider_count(auction),
               "provider_endpoint_ids" => Enum.map(auction.awards, & &1.endpoint.id),
               "selection_policy" => "first_admissible",
               "justification_fingerprint" => fingerprint(justification)
             }),
           {:ok, runners} <- start_runners(supervisor, parent, race_id, candidates, opts) do
        await_race(parent, auction, race_id, runners, opts)
      end
    end
  end

  defp start_runners(supervisor, parent, race_id, candidates, opts) do
    owner = self()

    Enum.reduce_while(candidates, {:ok, %{}}, fn candidate, {:ok, runners} ->
      candidate_id = value(candidate, :id)
      ref = make_ref()

      runner_opts =
        opts
        |> Keyword.put(:competition, :race)
        |> Keyword.put(:coordinator, {owner, ref})

      task = fn ->
        result = Tournament.run_candidate(parent, race_id, candidate, runner_opts)
        send(owner, {:race_candidate_result, ref, candidate_id, self(), result})
      end

      case DynamicSupervisor.start_child(supervisor, {Task, task}) do
        {:ok, pid} ->
          runner = %{candidate_id: candidate_id, pid: pid, monitor: Process.monitor(pid)}
          {:cont, {:ok, Map.put(runners, ref, runner)}}

        {:error, reason} ->
          request_cancellation(runners, :race_start_failed)
          {:halt, {:error, {:race_candidate_start_failed, candidate_id, reason}}}
      end
    end)
  end

  defp await_race(parent, auction, race_id, runners, opts) do
    state = %{
      parent: parent,
      auction: auction,
      race_id: race_id,
      runners: runners,
      handles: %{},
      results: %{},
      down: MapSet.new(),
      started?: false,
      deadline: deadline(opts),
      opts: opts
    }

    receive_result(state)
  end

  defp receive_result(state) do
    remaining = remaining(state.deadline)

    receive do
      {:competition_worker_started, ref, candidate_id, handle} ->
        if Map.has_key?(state.runners, ref) do
          state = %{state | handles: Map.put(state.handles, candidate_id, handle)}
          state |> maybe_release_start() |> receive_result()
        else
          _ = BeamAgent.cancel_worker(handle, :race_already_settled)
          receive_result(state)
        end

      {:race_candidate_result, ref, candidate_id, _pid, result} ->
        if Map.has_key?(state.runners, ref) do
          results = Map.put(state.results, candidate_id, result)
          state = %{state | results: results} |> maybe_release_start()

          case admissible(result, state.opts) do
            {:ok, winner} -> select_winner(state, candidate_id, winner)
            {:error, reason} -> reject_candidate(state, candidate_id, reason)
          end
        else
          receive_result(state)
        end

      {:DOWN, monitor, :process, _pid, reason} ->
        case runner_by_monitor(state.runners, monitor) do
          {ref, runner} ->
            state = %{state | down: MapSet.put(state.down, ref)}

            cond do
              Map.has_key?(state.results, runner.candidate_id) ->
                maybe_finish_inconclusive(state)

              reason == :normal ->
                receive_result(state)

              true ->
                results = Map.put(state.results, runner.candidate_id, {:error, reason})
                reject_candidate(%{state | results: results}, runner.candidate_id, reason)
            end

          nil ->
            receive_result(state)
        end
    after
      remaining ->
        finish_inconclusive(state, :race_timeout)
    end
  end

  defp reject_candidate(state, candidate_id, reason) do
    _ =
      EventLog.append(state.parent.session_id, :race_candidate_rejected, %{
        "race_id" => state.race_id,
        "candidate_id" => candidate_id,
        "failure_code" => reason_code(reason)
      })

    maybe_finish_inconclusive(state)
  end

  defp maybe_release_start(%{started?: true} = state), do: state

  defp maybe_release_start(state) do
    ready = map_size(state.handles) + map_size(state.results)

    if ready == map_size(state.runners) do
      Enum.each(state.runners, fn {ref, runner} ->
        if Map.has_key?(state.handles, runner.candidate_id),
          do: send(runner.pid, {:competition_go, ref})
      end)

      %{state | started?: true}
    else
      state
    end
  end

  defp maybe_finish_inconclusive(state) do
    if map_size(state.results) == map_size(state.runners) do
      finish_inconclusive(state, :no_admissible_candidate)
    else
      receive_result(state)
    end
  end

  defp select_winner(state, winner_id, winner) do
    {:ok, _event} =
      EventLog.append(state.parent.session_id, :race_winner_selected, %{
        "race_id" => state.race_id,
        "winner_id" => winner_id,
        "provider_auction_id" => state.auction.id,
        "winner_endpoint_id" => get_in(winner, [:provider_bid, :endpoint_id]),
        "winner_provider" => provider_name(winner),
        "selection_policy" => "first_admissible"
      })

    losers = Map.reject(state.runners, fn {_ref, runner} -> runner.candidate_id == winner_id end)
    request_cancellation(losers, :race_lost, state.handles)
    wait_for_down(state.runners, state.down, cancellation_timeout(state.opts))

    append_cancelled_events(
      state.parent.session_id,
      state.race_id,
      losers,
      state.handles,
      :race_lost
    )

    results =
      Enum.reduce(losers, state.results, fn {_ref, runner}, results ->
        Map.put_new(results, runner.candidate_id, {:error, :cancelled_after_winner})
      end)

    :ok =
      settle(state, :selected, winner_id, winner)

    {:ok, _event} =
      EventLog.append(state.parent.session_id, :race_settled, %{
        "race_id" => state.race_id,
        "winner_id" => winner_id,
        "cancelled_count" => map_size(losers),
        "selection_policy" => "first_admissible"
      })

    {:ok, %{race_id: state.race_id, status: :selected, winner_id: winner_id, results: results}}
  end

  defp finish_inconclusive(state, reason) do
    pending =
      Map.reject(state.runners, fn {ref, runner} ->
        MapSet.member?(state.down, ref) or Map.has_key?(state.results, runner.candidate_id)
      end)

    request_cancellation(pending, reason, state.handles)
    wait_for_down(pending, state.down, cancellation_timeout(state.opts))

    append_cancelled_events(
      state.parent.session_id,
      state.race_id,
      pending,
      state.handles,
      reason
    )

    _ =
      EventLog.append(state.parent.session_id, :race_inconclusive, %{
        "race_id" => state.race_id,
        "failure_code" => reason_code(reason),
        "selection_policy" => "first_admissible"
      })

    :ok = settle(state, :inconclusive, nil, nil)

    {:ok,
     %{race_id: state.race_id, status: :inconclusive, winner_id: nil, results: state.results}}
  end

  defp request_cancellation(runners, reason, handles \\ %{}) do
    Enum.each(runners, fn {_ref, runner} ->
      handle = Map.get(handles, runner.candidate_id)
      if handle, do: BeamAgent.cancel_worker(handle, reason)
      if Process.alive?(runner.pid), do: Process.exit(runner.pid, :kill)
    end)
  end

  defp append_cancelled_events(session_id, race_id, runners, handles, reason) do
    Enum.each(runners, fn {_ref, runner} ->
      handle = Map.get(handles, runner.candidate_id)

      _ =
        EventLog.append(session_id, :race_candidate_cancelled, %{
          "race_id" => race_id,
          "candidate_id" => runner.candidate_id,
          "worker_id" => handle && handle.worker_id,
          "failure_code" => reason_code(reason)
        })
    end)
  end

  defp wait_for_down(runners, already_down, timeout) do
    monitors =
      runners
      |> Enum.reject(fn {ref, _runner} -> MapSet.member?(already_down, ref) end)
      |> Map.new(fn {_ref, runner} -> {runner.monitor, runner.pid} end)

    wait_for_monitors(monitors, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_for_monitors(monitors, _deadline) when map_size(monitors) == 0, do: :ok

  defp wait_for_monitors(monitors, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, monitor, :process, _pid, _reason} ->
        wait_for_monitors(Map.delete(monitors, monitor), deadline)
    after
      remaining ->
        Enum.each(monitors, fn {monitor, _pid} -> Process.demonitor(monitor, [:flush]) end)
        :timeout
    end
  end

  defp admissible({:ok, %{content: content} = result}, opts) when is_binary(content) do
    if String.trim(content) == "" do
      {:error, :empty_result}
    else
      with :ok <-
             verification_admissible(
               result,
               Keyword.get(opts, :minimum_verification, :none)
             ),
           :ok <- custom_admissible(result, Keyword.get(opts, :admissible)) do
        {:ok, result}
      end
    end
  end

  defp admissible({:ok, _result}, _opts), do: {:error, :empty_result}
  defp admissible({:error, reason}, _opts), do: {:error, reason}

  defp verification_admissible(_result, :none), do: :ok
  defp verification_admissible(%{verification: %{status: :passed}}, :passed), do: :ok
  defp verification_admissible(_result, :passed), do: {:error, :verification_not_passed}
  defp verification_admissible(_result, _other), do: {:error, :invalid_minimum_verification}

  defp custom_admissible(_result, nil), do: :ok

  defp custom_admissible(result, fun) when is_function(fun, 1) do
    try do
      case fun.(result) do
        true -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _other -> {:error, :custom_admissibility_failed}
      end
    rescue
      _error -> {:error, :custom_admissibility_failed}
    catch
      _kind, _reason -> {:error, :custom_admissibility_failed}
    end
  end

  defp custom_admissible(_result, _other), do: {:error, :invalid_admissibility_check}

  defp validate_isolation(opts) do
    isolation = Keyword.get(opts, :isolation, :shared)

    if Keyword.get(opts, :verify_candidates, false) and isolation != :worktree,
      do: {:error, :verified_race_requires_worktree_isolation},
      else: :ok
  end

  defp settle(state, status, winner_id, winner) do
    ProviderBidCoordinator.settle(
      state.parent.goal_id,
      state.parent.session_id,
      state.auction.id,
      %{
        purpose: :provider_race,
        status: status,
        winner_id: winner_id,
        winner_endpoint_id: get_in(winner || %{}, [:provider_bid, :endpoint_id]),
        winner_provider: provider_name(winner || %{})
      }
    )
  end

  defp provider_name(result) do
    case get_in(result, [:provider_bid, :provider]) do
      nil -> nil
      provider -> to_string(provider)
    end
  end

  defp runner_by_monitor(runners, monitor) do
    Enum.find(runners, fn {_ref, runner} -> runner.monitor == monitor end)
  end

  defp deadline(opts) do
    case Keyword.get(opts, :timeout, @default_timeout) do
      :infinity ->
        :infinity

      timeout when is_integer(timeout) and timeout >= 0 ->
        System.monotonic_time(:millisecond) + timeout

      _other ->
        System.monotonic_time(:millisecond) + @default_timeout
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp cancellation_timeout(opts), do: Keyword.get(opts, :cancellation_timeout, 5_000)

  defp provider_count(auction),
    do: auction.awards |> Enum.map(& &1.endpoint.id) |> Enum.uniq() |> length()

  defp value(map, key), do: map[key] || map[to_string(key)]
  defp fingerprint(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp reason_code(reason) when is_atom(reason), do: to_string(reason)

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> to_string(code)
      _other -> "race_candidate_failed"
    end
  end

  defp reason_code(_reason), do: "race_candidate_failed"

  defp new_id,
    do: "race-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
