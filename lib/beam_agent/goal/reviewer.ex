defmodule BeamAgent.Goal.Reviewer do
  @moduledoc "Runs an independent, read-only implementation review as a supervised goal worker."

  alias BeamAgent.{Agent, ModelRegistry}
  alias BeamAgent.Session.EventLog

  def required?(contract, artifact) do
    contract.kind == :implementation and artifact.changed_files != []
  end

  def run(goal, contract, verification, opts \\ []) do
    prior_findings = Keyword.get(opts, :prior_findings)

    with {:ok, construction} <- Agent.construction_context(goal.session_id) do
      reviewer_endpoint_id = reviewer_endpoint_id(goal.project_id, construction)
      prompt = review_prompt(contract, verification, prior_findings)

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
        model_requirements: reviewer_requirements(reviewer_endpoint_id),
        verification_requirements: %{required: false, review_required: false},
        completion_criteria: "Return REVIEW_PASS, REVIEW_WARN, or REVIEW_FAIL with evidence"
      }

      with {:ok, _event} <-
             EventLog.append(goal.session_id, :implementation_review_started, %{
               "contract_id" => contract.id,
               "root_session_id" => goal.session_id,
               "requested_endpoint_id" => reviewer_endpoint_id,
               "provider_diverse" =>
                 is_binary(reviewer_endpoint_id) and
                   reviewer_endpoint_id != construction.provider_profile
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
  end

  defp finish(session_id, contract_id, worker_id, status, answer) do
    with {:ok, _event} <-
           EventLog.append(session_id, :implementation_review_finished, %{
             "contract_id" => contract_id,
             "status" => status,
             "worker_id" => worker_id,
             "evidence_count" => if(status in [:passed, :warning], do: 1, else: 0)
           }) do
      {:ok, %{status: status, content: answer, worker_id: worker_id}}
    end
  end

  def review_status(answer) do
    case String.trim(answer) do
      "REVIEW_PASS" <> _rest -> :passed
      "REVIEW_WARN" <> _rest -> :warning
      _other -> :failed
    end
  end

  def review_rubric do
    """
    REVIEW_FAIL is reserved for release-blocking defects: security or data-loss risk, a compile
    or required-test failure, a concrete concurrency/correctness defect, or an unmet acceptance
    criterion. Documentation, provenance, naming, style, cosmetic polish, and optional hardening
    are REVIEW_WARN findings and must not trigger a repair loop.
    """
    |> String.trim()
  end

  defp review_prompt(contract, verification, prior_findings) do
    frozen_scope =
      if prior_findings do
        """
        This is a confirmation review after repair. These original blocking findings are frozen:
        #{String.slice(prior_findings.content || "", 0, 4_000)}

        Fail only when an original blocking finding remains unresolved or the repair introduced a
        new release-blocking defect. Do not move the goalposts with new minor preferences.
        """
      end

    """
    Review the current uncommitted workspace changes against this authoritative request:

    #{contract.objective}

    Acceptance criteria:
    #{contract.acceptance_criteria}

    Deterministic verification evidence supplied by the runtime:
    #{JSON.encode!(verification || %{status: :unverified, checks: []})}

    Inspect the Git diff and relevant source/tests using read-only tools. Do not report tests as
    missing or failed when the runtime evidence says they passed. Prioritize correctness,
    security, missing acceptance criteria, concurrency hazards, and verification gaps.
    If Git metadata is unavailable, inspect the relevant source and tests directly;
    an unavailable Git diff is not itself an implementation defect.

    #{review_rubric()}

    #{frozen_scope}

    The first line must be exactly REVIEW_PASS when there are no findings, REVIEW_WARN when only
    non-blocking findings remain, or REVIEW_FAIL when a repair is required. After REVIEW_WARN or
    REVIEW_FAIL, provide concrete file-and-line findings.
    """
    |> String.trim()
  end

  defp reviewer_endpoint_id(_project_id, %{model_strategy: :manual} = construction),
    do: construction.provider_profile

  defp reviewer_endpoint_id(project_id, construction) do
    local_only? = construction.model_strategy == :local_only

    case ModelRegistry.list(project_id) do
      {:ok, endpoints} ->
        endpoints
        |> Enum.reject(
          &(&1.id == construction.provider_profile or &1.health.status == :unavailable)
        )
        |> Enum.filter(&(not local_only? or &1.claims.locality == :local))
        # Independence is a fresh read-only worker, not necessarily another model.
        # Do not force a weak alternate onto the release-critical review path.
        |> Enum.filter(&(:reasoning in &1.claims.capabilities))
        |> Enum.sort_by(fn endpoint ->
          {endpoint.claims.locality != :remote, endpoint.id}
        end)
        |> List.first()
        |> case do
          nil -> nil
          endpoint -> endpoint.id
        end

      _error ->
        nil
    end
  end

  defp reviewer_requirements(endpoint_id) do
    %{
      preferred_endpoint_id: endpoint_id,
      reasoning: :high,
      locality: :any,
      privacy: :provider_allowed,
      cost: :balanced,
      latency: :batch
    }
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
