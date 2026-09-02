defmodule BeamAgent.FailureDecision do
  @moduledoc """
  Deterministic recovery policy for one failed unit of work.

  The decision is deliberately separate from execution. It classifies observed
  runtime evidence and selects a bounded action; it never grants authority,
  increases a budget, or fabricates another provider endpoint.
  """

  @retry_actions [:retry_same, :rebind, :repair]

  def decide(reason, opts \\ []) do
    attempt = Keyword.get(opts, :attempt, 1)
    maximum_attempts = Keyword.get(opts, :maximum_attempts, 1)
    alternative_endpoint? = Keyword.get(opts, :alternative_endpoint?, false)
    {classification, reason_code} = classify(reason)

    action =
      action(classification,
        attempts_exhausted?: attempt >= maximum_attempts,
        alternative_endpoint?: alternative_endpoint?
      )

    %{
      version: 1,
      classification: classification,
      action: action,
      reason_code: reason_code,
      retryable: action in @retry_actions,
      terminal: action not in @retry_actions,
      attempt: attempt,
      maximum_attempts: maximum_attempts
    }
  end

  def graph(failures) when is_list(failures) do
    decisions = Enum.map(failures, &decision/1)

    {action, classification, reason_code} =
      cond do
        decision = Enum.find(decisions, &(&1.action == :ask)) ->
          {:ask, decision.classification, decision.reason_code}

        decision = Enum.find(decisions, &(&1.classification == :budget)) ->
          {:stop, :budget, decision.reason_code}

        decision = Enum.find(decisions, &(&1.classification == :cancelled)) ->
          {:stop, :cancelled, decision.reason_code}

        decisions != [] ->
          {:replan, :task_graph, "task_graph_incomplete"}

        true ->
          {:stop, :runtime, "task_graph_failed"}
      end

    %{
      version: 1,
      action: action,
      classification: classification,
      reason_code: reason_code,
      failed_task_count: length(decisions),
      terminal: action in [:ask, :stop]
    }
  end

  defp action(:transient_provider, attempts_exhausted?: false, alternative_endpoint?: true),
    do: :rebind

  defp action(:transient_provider, attempts_exhausted?: false, alternative_endpoint?: false),
    do: :retry_same

  defp action(:verification, attempts_exhausted?: false, alternative_endpoint?: _),
    do: :repair

  defp action(classification, attempts_exhausted?: false, alternative_endpoint?: _)
       when classification in [:worker_exit, :non_final],
       do: :retry_same

  defp action(classification, attempts_exhausted?: true, alternative_endpoint?: _)
       when classification in [:transient_provider, :verification, :worker_exit, :non_final],
       do: :replan

  defp action(:plan, _opts), do: :replan
  defp action(:authority, _opts), do: :ask
  defp action(:budget, _opts), do: :stop
  defp action(:cancelled, _opts), do: :stop
  defp action(_classification, _opts), do: :stop

  defp classify({:turn_process_exit, reason}), do: classify(reason)
  defp classify({:goal_work_start_failed, reason}), do: classify(reason)
  defp classify({:subagent_start_failed, reason}), do: classify(reason)
  defp classify({:repair_start_failed, reason}), do: classify(reason)

  defp classify(:model_timeout), do: {:transient_provider, "model_timeout"}

  defp classify({:provider_http_error, status, _body}) when status == 429 or status >= 500,
    do: {:transient_provider, "provider_http_#{status}"}

  defp classify({:provider_transport_error, _reason}),
    do: {:transient_provider, "provider_transport_error"}

  defp classify({:provider_exit, _reason}), do: {:transient_provider, "provider_exit"}
  defp classify({:provider_exception, _reason}), do: {:transient_provider, "provider_exception"}

  defp classify({code, _detail})
       when code in [:verification_failed, :implementation_review_failed],
       do: {:verification, to_string(code)}

  defp classify({:non_final_model_response, _reason, _attempts}),
    do: {:non_final, "non_final_model_response"}

  defp classify({code, _detail})
       when code in [
              :cyclic_task_dependencies,
              :invalid_task_dependencies,
              :multiple_implementation_owners,
              :decomposition_deadlock
            ],
       do: {:plan, to_string(code)}

  defp classify(code)
       when code in [
              :tool_denied,
              :capability_denied,
              :capability_lease_denied,
              :path_lease_denied,
              :codex_tool_not_allowed,
              :tool_not_allowed
            ],
       do: {:authority, to_string(code)}

  defp classify(code)
       when code in [
              :budget_exhausted,
              :budget_deadline_exceeded,
              :worker_concurrency_exhausted,
              :unknown_worker_budget
            ],
       do: {:budget, to_string(code)}

  defp classify(code) when code in [:cancelled, :shutdown],
    do: {:cancelled, to_string(code)}

  defp classify({:worker_restart_timeout, _kind}),
    do: {:worker_exit, "worker_restart_timeout"}

  defp classify({:turn_process_exit, _kind, _reason}),
    do: {:worker_exit, "turn_process_exit"}

  defp classify(reason) when is_atom(reason), do: {:runtime, to_string(reason)}
  defp classify({code, _rest}) when is_atom(code), do: {:runtime, to_string(code)}
  defp classify(_reason), do: {:runtime, "runtime_failure"}

  defp decision(%{recovery: decision}) when is_map(decision), do: decision
  defp decision(%{decision: decision}) when is_map(decision), do: decision
  defp decision(decision) when is_map(decision), do: decision
end
