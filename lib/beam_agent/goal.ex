defmodule BeamAgent.Goal do
  @moduledoc "The actor-owned state machine for one ephemeral project goal."
  use GenServer

  alias BeamAgent.{Agent, Names, OutcomeStore, TaskClassifier, WorkContract}

  alias BeamAgent.Goal.{
    ContextPacket,
    ModelLease,
    Reviewer,
    Verifier,
    WorkArtifact,
    WorkspaceSnapshot
  }

  alias BeamAgent.Project.PathLeaseManager
  alias BeamAgent.Session.EventLog

  @maximum_repair_attempts 2
  @restart_timeout_ms 5_000

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    GenServer.start_link(__MODULE__, opts, name: Names.via(:goal, goal_id))
  end

  def snapshot(goal_id), do: call(goal_id, :snapshot)
  def status(goal_id), do: call(goal_id, :status)
  def cancel(goal_id), do: call(goal_id, :cancel)

  def submit(goal_id, prompt, attachment_ids \\ [], timeout \\ :infinity)
      when is_binary(prompt) and is_list(attachment_ids),
      do: call(goal_id, {:submit, prompt, attachment_ids}, timeout)

  def steer(goal_id, message) when is_binary(message),
    do: call(goal_id, {:steer, String.trim(message)})

  @impl true
  def init(opts) do
    {:ok,
     %{
       goal_id: Keyword.fetch!(opts, :goal_id),
       project_id: Keyword.fetch!(opts, :project_id),
       session_id: Keyword.fetch!(opts, :session_id),
       data_dir: Keyword.fetch!(opts, :data_dir),
       workspace_root: Keyword.fetch!(opts, :workspace_root),
       objective: Keyword.get(opts, :objective),
       agent_spec: Keyword.fetch!(opts, :agent_spec),
       capability_envelope: Keyword.fetch!(opts, :capability_envelope),
       phase: :idle,
       current_work: nil,
       last_work: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state}, state}
  def handle_call(:status, _from, state), do: {:reply, {:ok, goal_status(state)}, state}

  def handle_call({:submit, prompt, attachment_ids}, from, %{current_work: nil} = state) do
    objective = if String.trim(prompt) == "", do: "Process the attached user input", else: prompt

    with {:ok, workspace_baseline} <-
           WorkspaceSnapshot.capture(state.project_id,
             workspace_root: state.workspace_root,
             data_dir: state.data_dir
           ),
         {:ok, context_packet} <- ContextPacket.build(state.project_id, objective),
         {:ok, contract} <-
           WorkContract.new(objective, state.workspace_root, context_packet: context_packet),
         {:ok, event} <-
           EventLog.append(state.session_id, :goal_work_started, %{
             "work_contract" => WorkContract.to_map(contract),
             "phase" => "executing"
           }) do
      current = %{
        from: from,
        contract: contract,
        prompt: prompt,
        attachment_ids: attachment_ids,
        started_event_id: event_id(event),
        candidate_result: nil,
        artifact: nil,
        verification: nil,
        review: nil,
        attempts: 0,
        failure_fingerprints: MapSet.new(),
        cancel_requested: false,
        workspace_baseline: workspace_baseline
      }

      case launch_stage(state, current, :executing, fn ->
             Agent.ask_with_contract(state.session_id, prompt, attachment_ids, contract)
           end) do
        {:ok, current} ->
          {:noreply, %{state | phase: :executing, current_work: current}}

        {:error, reason} ->
          {:reply, {:error, {:goal_work_start_failed, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit, _prompt, _attachments}, _from, state),
    do: {:reply, {:error, :goal_busy}, state}

  def handle_call(:cancel, _from, %{current_work: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call(:cancel, _from, state) do
    current = state.current_work

    result =
      if current.stage in [:executing, :repairing] do
        Agent.cancel(state.session_id)
      else
        if current.stage == :verifying, do: stop_verification_workers(state.goal_id)
        Process.exit(current.pid, :shutdown)
        :ok
      end

    {:reply, result,
     %{state | phase: :cancelling, current_work: %{current | cancel_requested: true}}}
  end

  def handle_call({:steer, ""}, _from, state),
    do: {:reply, {:error, :empty_steering_message}, state}

  def handle_call({:steer, _message}, _from, %{current_work: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call({:steer, message}, _from, state) do
    if state.current_work.stage in [:executing, :repairing] do
      with :ok <- Agent.steer(state.session_id, message),
           {:ok, _event} <-
             EventLog.append(state.session_id, :goal_steered, %{
               "contract_id" => state.current_work.contract.id,
               "content" => message
             }) do
        {:reply, :ok, state}
      else
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, {:not_steerable, state.current_work.stage}}, state}
    end
  end

  @impl true
  def handle_info(
        {:goal_stage_result, ref, pid, stage, result},
        %{current_work: %{ref: ref, pid: pid, stage: stage} = current} = state
      ) do
    Process.demonitor(current.monitor, [:flush])
    current = Map.drop(current, [:ref, :pid, :monitor])
    continue_stage(stage, result, state, current)
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, %{current_work: current} = state)
      when current.monitor == monitor and current.pid == pid do
    result = if current.cancel_requested, do: {:error, :cancelled}, else: {:error, reason}
    finish_work(state, Map.drop(current, [:ref, :pid, :monitor]), result)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp continue_stage(stage, result, state, current) when stage in [:executing, :repairing] do
    case result do
      {:ok, _answer} ->
        current = %{current | candidate_result: result}
        artifact = build_artifact(state, current)
        current = %{current | artifact: artifact}

        if should_verify?(current.contract, artifact) do
          start_verification(state, current)
        else
          continue_after_verification(state, current, nil)
        end

      {:error, _reason} ->
        finish_work(state, current, result)
    end
  end

  defp continue_stage(:verifying, {:ok, %{status: :passed} = verification}, state, current) do
    continue_after_verification(
      state,
      %{current | verification: verification, artifact: nil},
      verification
    )
  end

  defp continue_stage(:verifying, {:ok, %{status: :failed} = verification}, state, current) do
    recover_or_finish(state, %{current | verification: verification}, :verification, verification)
  end

  defp continue_stage(:verifying, {:error, reason}, state, current) do
    finish_work(state, current, {:error, {:verification_infrastructure_failed, reason}})
  end

  defp continue_stage(:reviewing, {:ok, %{status: :passed} = review}, state, current) do
    finish_work(state, %{current | review: review}, current.candidate_result)
  end

  defp continue_stage(:reviewing, {:ok, %{status: :failed} = review}, state, current) do
    recover_or_finish(state, %{current | review: review}, :review, review)
  end

  defp continue_stage(:reviewing, {:error, reason}, state, current) do
    finish_work(state, current, {:error, {:implementation_review_failed, reason}})
  end

  defp start_verification(state, current) do
    plan = verification_plan(state.agent_spec)

    case launch_stage(state, current, :verifying, fn ->
           Verifier.run(state.goal_id, plan,
             session_id: state.session_id,
             worker_id: state.session_id,
             attach: false,
             completion_report: true
           )
         end) do
      {:ok, current} ->
        {:noreply, %{state | phase: :verifying, current_work: current}}

      {:error, reason} ->
        finish_work(state, current, {:error, {:verification_start_failed, reason}})
    end
  end

  defp continue_after_verification(state, current, verification) do
    artifact = build_artifact(state, current)
    current = %{current | artifact: artifact, verification: verification}

    if artifact && review_enabled?(state.agent_spec) &&
         Reviewer.required?(current.contract, artifact) do
      case launch_stage(state, current, :reviewing, fn ->
             Reviewer.run(state, current.contract, verification)
           end) do
        {:ok, current} -> {:noreply, %{state | phase: :reviewing, current_work: current}}
        {:error, reason} -> finish_work(state, current, {:error, {:review_start_failed, reason}})
      end
    else
      finish_work(state, current, current.candidate_result)
    end
  end

  defp recover_or_finish(state, current, kind, failure) do
    fingerprint = failure_fingerprint(kind, failure)

    cond do
      current.attempts >= @maximum_repair_attempts ->
        finish_work(state, current, terminal_failure(kind, failure))

      MapSet.member?(current.failure_fingerprints, fingerprint) ->
        finish_work(state, current, {:error, {:repeated_repair_failure, kind}})

      true ->
        attempt = current.attempts + 1
        append_recovery_events(state, current, kind, failure, attempt)

        current = %{
          current
          | attempts: attempt,
            failure_fingerprints: MapSet.put(current.failure_fingerprints, fingerprint),
            artifact: nil,
            review: nil
        }

        repair_prompt = repair_prompt(current.contract, kind, failure, attempt)

        case launch_stage(state, current, :repairing, fn ->
               with :ok <- restart_worker(state.session_id),
                    do:
                      Agent.ask_with_contract(
                        state.session_id,
                        repair_prompt,
                        [],
                        current.contract
                      )
             end) do
          {:ok, current} ->
            {:noreply, %{state | phase: :repairing, current_work: current}}

          {:error, reason} ->
            finish_work(state, current, {:error, {:repair_start_failed, reason}})
        end
    end
  end

  defp launch_stage(state, current, stage, fun) do
    with {:ok, supervisor} <- Names.pid(:goal_resource_supervisor, state.goal_id) do
      owner = self()
      ref = make_ref()
      task = fn -> send(owner, {:goal_stage_result, ref, self(), stage, fun.()}) end

      case DynamicSupervisor.start_child(supervisor, {Task, task}) do
        {:ok, pid} ->
          {:ok,
           current
           |> Map.put(:stage, stage)
           |> Map.put(:ref, ref)
           |> Map.put(:pid, pid)
           |> Map.put(:monitor, Process.monitor(pid))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp finish_work(state, current, result) do
    status = result_status(result)

    artifact =
      if status == :completed && current.artifact,
        do: current.artifact,
        else: build_artifact(state, current, result)

    verification = current.verification
    review = current.review

    append_terminal_events(state, current, result, status, verification, review, artifact)
    GenServer.reply(current.from, result)
    _ = ModelLease.release(state.goal_id, current.contract.id)
    _ = PathLeaseManager.release_owner(state.project_id, state.session_id)

    last_work = %{
      contract: current.contract,
      status: status,
      artifact: artifact,
      verification: verification,
      review: review,
      attempts: current.attempts,
      finished_at: DateTime.utc_now()
    }

    {:noreply, %{state | phase: status, current_work: nil, last_work: last_work}}
  end

  defp append_terminal_events(state, current, result, status, verification, review, artifact) do
    turn = latest_turn(state.session_id)

    _ =
      EventLog.append(state.session_id, :turn_finished, %{
        "turn" => turn,
        "reason" => terminal_reason(status),
        "verification_status" => verification_status(verification),
        "review_status" => review_status(review),
        "repair_attempts" => current.attempts
      })

    outcome_status = outcome_status(status, verification)
    classification = TaskClassifier.classify(current.contract.objective, state.workspace_root)

    case OutcomeStore.record(state.project_id, %{
           kind: :task,
           goal_id: state.goal_id,
           session_id: state.session_id,
           turn: turn,
           task_type: classification.task_type,
           language: classification.language,
           status: outcome_status,
           failure: if(status == :failed, do: result, else: nil),
           retries: current.attempts,
           verification: verification_summary(verification)
         }) do
      {:ok, %{id: id}} ->
        _ = maybe_attach_verification(state.project_id, id, verification)

        _ =
          EventLog.append(state.session_id, :task_outcome_recorded, %{
            "outcome_id" => id,
            "status" => outcome_status,
            "verification" => verification_summary(verification)
          })

      _other ->
        :ok
    end

    if is_nil(verification) do
      _ =
        EventLog.append(state.session_id, :completion_report_generated, %{
          "status" => "unverified",
          "evidence_count" => 0
        })
    end

    _ =
      EventLog.append(state.session_id, :goal_work_finished, %{
        "contract_id" => current.contract.id,
        "status" => to_string(status),
        "expected_artifact" => to_string(current.contract.expected_artifact),
        "artifact_id" => artifact && artifact.id,
        "changed_files" => (artifact && artifact.changed_files) || [],
        "verification_status" => verification_status(verification),
        "review_status" => review_status(review),
        "repair_attempts" => current.attempts
      })
  end

  defp build_artifact(state, current, result \\ nil) do
    result = result || current.candidate_result || {:error, :no_candidate}

    case WorkArtifact.build(
           state,
           current.contract,
           result,
           current.started_event_id,
           current.workspace_baseline
         ) do
      {:ok, artifact} -> artifact
      {:error, _reason} -> nil
    end
  end

  defp restart_worker(session_id) do
    with {:ok, old_agent} <- Names.pid(:agent, session_id) do
      old_conversation = optional_pid(:provider_conversation, session_id)
      Process.exit(old_agent, :kill)
      deadline = System.monotonic_time(:millisecond) + @restart_timeout_ms

      with {:ok, _new_agent} <- wait_for_restart(:agent, session_id, old_agent, deadline),
           :ok <-
             wait_for_optional_restart(
               :provider_conversation,
               session_id,
               old_conversation,
               deadline
             ) do
        :ok
      end
    end
  end

  defp wait_for_restart(kind, id, old_pid, deadline) do
    case Names.pid(kind, id) do
      {:ok, pid} when pid != old_pid ->
        {:ok, pid}

      _other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          wait_for_restart(kind, id, old_pid, deadline)
        else
          {:error, {:worker_restart_timeout, kind}}
        end
    end
  end

  defp wait_for_optional_restart(_kind, _id, nil, _deadline), do: :ok

  defp wait_for_optional_restart(kind, id, old_pid, deadline) do
    case wait_for_restart(kind, id, old_pid, deadline) do
      {:ok, _pid} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp optional_pid(kind, id) do
    case Names.pid(kind, id) do
      {:ok, pid} -> pid
      {:error, :not_found} -> nil
    end
  end

  defp stop_verification_workers(goal_id) do
    case Names.pid(:goal_verification_supervisor, goal_id) do
      {:ok, supervisor} ->
        supervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_, pid, _, _} -> DynamicSupervisor.terminate_child(supervisor, pid) end)

      {:error, :not_found} ->
        :ok
    end
  end

  defp append_recovery_events(state, current, kind, failure, attempt) do
    started_type =
      if kind == :verification,
        do: :verification_recovery_started,
        else: :implementation_review_recovery_started

    feedback_type = if kind == :verification, do: :verification_feedback, else: :review_feedback

    _ =
      EventLog.append(state.session_id, started_type, %{
        "contract_id" => current.contract.id,
        "attempt" => attempt,
        "maximum_attempts" => @maximum_repair_attempts,
        "failure_code" => "#{kind}_failed"
      })

    _ =
      EventLog.append(state.session_id, feedback_type, %{
        "contract_id" => current.contract.id,
        "attempt" => attempt,
        "content" => failure_feedback(kind, failure)
      })
  end

  defp repair_prompt(contract, kind, failure, attempt) do
    prefix =
      if kind == :verification,
        do: "Required verification rejected",
        else: "Independent review rejected"

    """
    #{prefix} the previous implementation candidate for contract #{contract.id}.
    This is repair attempt #{attempt} of #{@maximum_repair_attempts}. Keep the original objective
    and acceptance criteria authoritative. Fix only the concrete failures below, inspect the
    current workspace first, and then provide a new completed candidate.

    Original objective:
    #{contract.objective}

    Acceptance criteria:
    #{contract.acceptance_criteria}

    Concrete failure evidence:
    #{failure_feedback(kind, failure)}
    """
    |> String.trim()
  end

  defp failure_feedback(:verification, failure) do
    failure.checks
    |> Enum.filter(&(&1.required and &1.status != :passed))
    |> Enum.map_join("\n\n", fn check ->
      "Check #{check.id} failed (exit #{inspect(check.exit_status)}):\n#{String.slice(check.output || "", 0, 2_000)}"
    end)
  end

  defp failure_feedback(:review, failure), do: String.slice(failure.content || "", 0, 4_000)

  defp failure_fingerprint(kind, failure) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({kind, failure_feedback(kind, failure)}))
    |> Base.encode16(case: :lower)
  end

  defp terminal_failure(:verification, failure),
    do: {:error, {:verification_failed, failure.summary}}

  defp terminal_failure(:review, failure),
    do: {:error, {:implementation_review_failed, String.slice(failure.content || "", 0, 1_000)}}

  defp verification_plan(agent_spec) do
    requirements = agent_spec.verification_requirements
    requirements[:plan] || requirements["plan"] || :auto
  end

  defp review_enabled?(agent_spec) do
    requirements = agent_spec.verification_requirements

    Map.get(requirements, :review_required, Map.get(requirements, "review_required", true)) !=
      false
  end

  defp should_verify?(%{kind: :verification}, _artifact), do: true

  defp should_verify?(%{verification_required: true}, %{changed_files: [_ | _]}), do: true

  defp should_verify?(_contract, _artifact), do: false

  defp maybe_attach_verification(_project_id, _outcome_id, nil), do: :ok

  defp maybe_attach_verification(project_id, outcome_id, verification),
    do: OutcomeStore.attach_verification(project_id, outcome_id, verification)

  defp latest_turn(session_id) do
    case EventLog.events(session_id) do
      {:ok, events} -> Enum.count(events, &(&1["type"] == "turn_started"))
      _other -> 0
    end
  end

  defp goal_status(state) do
    %{
      goal_id: state.goal_id,
      phase: state.phase,
      current_stage: state.current_work && state.current_work.stage,
      current_contract: state.current_work && state.current_work.contract,
      last_work: state.last_work
    }
  end

  defp result_status({:ok, _result}), do: :completed
  defp result_status({:error, :cancelled}), do: :cancelled
  defp result_status({:error, _reason}), do: :failed
  defp outcome_status(:completed, %{status: :passed}), do: :succeeded
  defp outcome_status(status, _verification), do: status
  defp terminal_reason(:completed), do: "completed"
  defp terminal_reason(:cancelled), do: "cancelled"
  defp terminal_reason(:failed), do: "error"
  defp verification_status(nil), do: "not_required"
  defp verification_status(%{status: status}), do: to_string(status)
  defp review_status(nil), do: "not_required"
  defp review_status(%{status: status}), do: to_string(status)
  defp verification_summary(nil), do: %{status: :unverified}

  defp verification_summary(verification) do
    Map.take(verification, [:status, :source, :summary, :verification_id])
  end

  defp event_id(event), do: "#{event["session_id"]}:#{event["seq"]}"

  defp call(goal_id, request, timeout \\ 5_000) do
    with {:ok, pid} <- Names.pid(:goal, goal_id) do
      GenServer.call(pid, request, timeout)
    end
  end
end
