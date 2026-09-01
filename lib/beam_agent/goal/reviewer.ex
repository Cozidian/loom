defmodule BeamAgent.Goal.Reviewer do
  @moduledoc "Runs an independent, read-only implementation review as a supervised goal worker."

  alias BeamAgent.Agent
  alias BeamAgent.Session.EventLog

  def required?(contract, artifact) do
    contract.kind == :implementation and artifact.changed_files != []
  end

  def run(goal, contract, verification) do
    prompt = review_prompt(contract, verification)

    proposal = %{
      goal: "Independently review the current implementation before it may complete",
      role: "Mandatory completion reviewer",
      template: "reviewer",
      instructions: [
        "Inspect the current diff and relevant source before reaching a conclusion.",
        "Do not modify files or accept claims unsupported by deterministic evidence."
      ],
      capabilities: %{
        tools: ["git_inspect", "read_file", "search_files", "file_diagnostics"],
        paths: :all
      },
      verification_requirements: %{required: false, review_required: false},
      completion_criteria: "Return REVIEW_PASS or REVIEW_FAIL with evidence"
    }

    with {:ok, construction} <- Agent.construction_context(goal.session_id),
         {:ok, _event} <-
           EventLog.append(goal.session_id, :implementation_review_started, %{
             "contract_id" => contract.id,
             "root_session_id" => goal.session_id
           }),
         {:ok, handle} <-
           BeamAgent.spawn_worker(goal.session_id, proposal, worker_options(construction)) do
      try do
        case BeamAgent.ask(handle.worker_id, prompt) do
          {:ok, answer} ->
            status = review_status(answer)
            _ = BeamAgent.complete_worker(handle, answer, %{status: :unverified})
            finish(goal.session_id, contract.id, handle.worker_id, status, answer)

          {:error, reason} ->
            _ = BeamAgent.cancel_worker(handle, reason)
            {:error, {:review_worker_failed, reason}}
        end
      after
        _ = BeamAgent.stop_session(handle.worker_id)
      end
    end
  end

  defp finish(session_id, contract_id, worker_id, status, answer) do
    with {:ok, _event} <-
           EventLog.append(session_id, :implementation_review_finished, %{
             "contract_id" => contract_id,
             "status" => status,
             "worker_id" => worker_id,
             "evidence_count" => if(status == :passed, do: 1, else: 0)
           }) do
      {:ok, %{status: status, content: answer, worker_id: worker_id}}
    end
  end

  defp review_status(answer) do
    if String.starts_with?(String.trim(answer), "REVIEW_PASS"), do: :passed, else: :failed
  end

  defp review_prompt(contract, verification) do
    """
    Review the current uncommitted workspace changes against this authoritative request:

    #{contract.objective}

    Acceptance criteria:
    #{contract.acceptance_criteria}

    Deterministic verification evidence supplied by the runtime:
    #{JSON.encode!(verification || %{status: :unverified, checks: []})}

    Inspect the Git diff and relevant source/tests using read-only tools. Do not report tests as
    missing or failed when the runtime evidence says they passed. Prioritize correctness,
    security, missing acceptance criteria, concurrency hazards, and verification gaps. The first
    line must be exactly REVIEW_PASS when there are no actionable findings, or REVIEW_FAIL when
    fixes are required. After REVIEW_FAIL, provide concrete file-and-line findings.
    """
    |> String.trim()
  end

  defp worker_options(context) do
    [
      provider: context.provider,
      provider_profile: context.provider_profile,
      provider_options: context.provider_options,
      strategy: context.strategy,
      data_dir: context.data_dir,
      workspace_root: context.workspace_root,
      context_window_tokens: context.context_window_tokens,
      compaction_threshold_percent: context.compaction_threshold_percent,
      model_strategy: context.model_strategy,
      completion_review: :external
    ]
  end
end
