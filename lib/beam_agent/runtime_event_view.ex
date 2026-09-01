defmodule BeamAgent.RuntimeEventView do
  @moduledoc """
  Projects runtime events for audiences with different trust levels.

  The public view is deliberately fail-closed: new payload fields are redacted
  until they are explicitly classified as safe metadata. The internal view is
  the unchanged event used by trusted, in-process runtime clients.
  """

  @safe_scalar_keys MapSet.new(~w(
    access agent_role agent_spec_id allocation_id approval_id attempt attempts auction_id authority authority_decision_id authority_disposition award_count bid_id budget_allocation_id cached_tokens cancelled capabilities_requested category check_count check_id child_session_id command_id compacted_count completion_reason review_status root_session_id payload_version
    compaction_count context_fingerprint context_tokens correlation_id cost_hint cost_preference count decision duration_ms
    context_ref_count context_artifact_count deduplicated_artifact_count deduplicated_artifact_bytes decision_id depth duration_ms effective_capability_id endpoint_id estimated_cost estimated_tokens expires_at failure_code fallback fingerprint from goal_fingerprint goal_id handle_id health id index instruction_count is_error kind lease_id
    average_latency_ms best_verified_samples confidence cost_tier eligible eligible_count estimated_latency_ms generated_at language latency_ms latency_preference line_count
    limit locality maximum_attempts measured_latency_ms minimum_verified_samples mode model name operational_samples
    operational_success_rate operational_successes outcome_id output_tokens quality_lower_bound
    parent_capability_id parent_session_id parent_worker_id permission_id policy previous privacy privacy_requirement project_id provider provider_profile
    recency_weighted_pass_rate recommended_endpoint_id recovered redaction request_id request_version
    exit_status failed_count passed_count policy_reason provider_count requested_awards response_id required retries root score selected_endpoint_id server session_id source submitted_at
    execution_strategy operations operations_remaining purpose_fingerprint requested_capability_mode role role_requested source state status step strategy stream success target_session_id task_type template template_requested template_source template_version timeout to tool tool_call_id tool_count tools_required total_tokens
    truncated turn type verification_id verification_status verified_pass_rate verified_passes verified_samples version window_days window_tokens worker_id
    mime_type size_bytes width height sha256 provenance
    delegation_id completion_criteria_fingerprint progress_fingerprint result_fingerprint spec_id
    organization_id organization_status coordinator_id plan_id task_id task_status task_count
    resource_pool resource_lease_id queue_depth wait_ms evidence_count
    race_id candidate_id candidate_count winner_id winner_endpoint_id winner_provider discarded_count merged evaluation_fingerprint justification_fingerprint provider_auction_id
    generation added_count changed_count removed_count change hash path command_fingerprint
    worktree_id owner_worker_id base_revision worktree_status changed_file_count patch_fingerprint force
    contract_id artifact_id expected_artifact phase worker_kind
  ))

  @safe_container_keys MapSet.new(~w(usage))
  @safe_object_keys MapSet.new(~w(evidence inputs verification))
  @safe_list_keys MapSet.new(
                    ~w(attachments awards candidate_endpoint_ids candidates changed_files endpoints file_references provider_endpoint_ids reasons rejected_fields rejected_file_references requested_scopes)
                  )
  @safe_provenance_sources MapSet.new(~w(
    goal_default parent_allocation parent_inheritance parent_proposal
    parent_proposal_runtime_constrained project_default project_state
    runtime_context_selection runtime_default runtime_inference runtime_policy runtime_root user
  ))

  @type view :: :public | :internal

  @spec project(map(), view()) :: map()
  def project(event, :internal) when is_map(event), do: event

  def project(%{payload: %{data: data} = payload} = event, :public) do
    {data, redacted?} = public_data(data)

    event
    |> Map.put(:payload, %{payload | data: data})
    |> Map.put(:visibility, :public)
    |> Map.put(:redacted?, redacted?)
  end

  def project(event, :public) when is_map(event) do
    event
    |> Map.put(:visibility, :public)
    |> Map.put(:redacted?, false)
  end

  def valid_view?(view), do: view in [:public, :internal]

  defp public_data(data) when is_map(data) do
    Enum.reduce(data, {%{}, false}, fn {key, value}, {projected, redacted?} ->
      normalized_key = to_string(key)
      {value, value_redacted?} = public_value(normalized_key, value)

      {
        Map.put(projected, key, value),
        redacted? or value_redacted?
      }
    end)
  end

  defp public_data(value), do: {redaction(value), true}

  defp public_value(key, value) do
    cond do
      MapSet.member?(@safe_scalar_keys, key) and scalar?(value) ->
        {value, false}

      MapSet.member?(@safe_container_keys, key) ->
        public_metrics(value)

      key == "provenance" and is_map(value) ->
        public_provenance(value)

      MapSet.member?(@safe_object_keys, key) and is_map(value) ->
        public_data(value)

      key in ["file_references", "rejected_file_references"] and is_list(value) ->
        public_reference_list(value)

      MapSet.member?(@safe_list_keys, key) and is_list(value) ->
        public_safe_list(value)

      key == "events" and is_list(value) ->
        public_list(value)

      key == "tool_calls" and is_list(value) ->
        public_list(value)

      true ->
        {redaction(value), not is_nil(value)}
    end
  end

  defp public_list(values) do
    Enum.map_reduce(values, false, fn value, redacted? ->
      {value, value_redacted?} = public_nested(value)
      {value, redacted? or value_redacted?}
    end)
  end

  defp public_safe_list(values) do
    Enum.map_reduce(values, false, fn
      value, redacted? when is_map(value) ->
        {value, value_redacted?} = public_data(value)
        {value, redacted? or value_redacted?}

      value, redacted? ->
        if scalar?(value), do: {value, redacted?}, else: {redaction(value), true}
    end)
  end

  defp public_reference_list(values) do
    allowed =
      MapSet.new(
        ~w(artifact_id path size_bytes source_size_bytes line_count sha256 status reason truncated provenance)
      )

    Enum.map_reduce(values, false, fn
      value, redacted? when is_map(value) ->
        {projected, item_redacted?} =
          Enum.reduce(value, {%{}, false}, fn {key, item}, {acc, hidden?} ->
            normalized = to_string(key)

            if MapSet.member?(allowed, normalized) and scalar?(item) do
              {Map.put(acc, key, item), hidden?}
            else
              {Map.put(acc, key, redaction(item)), hidden? or not is_nil(item)}
            end
          end)

        {projected, redacted? or item_redacted?}

      value, _redacted? ->
        {redaction(value), true}
    end)
  end

  defp public_nested(value) when is_map(value), do: public_data(value)
  defp public_nested(value), do: {redaction(value), not is_nil(value)}

  defp public_metrics(value) when is_map(value) do
    Enum.reduce(value, {%{}, false}, fn {key, metric}, {projected, redacted?} ->
      if is_number(metric) or is_boolean(metric) or is_nil(metric) do
        {Map.put(projected, key, metric), redacted?}
      else
        {Map.put(projected, key, redaction(metric)), true}
      end
    end)
  end

  defp public_metrics(value), do: {redaction(value), not is_nil(value)}

  defp public_provenance(value) do
    Enum.reduce(value, {%{}, false}, fn {key, source}, {projected, redacted?} ->
      if is_binary(source) and MapSet.member?(@safe_provenance_sources, source) do
        {Map.put(projected, key, source), redacted?}
      else
        {Map.put(projected, key, redaction(source)), true}
      end
    end)
  end

  defp redaction(nil), do: nil

  defp redaction(value) do
    %{
      "redacted" => true,
      "kind" => value_kind(value),
      "size" => value_size(value)
    }
  end

  defp value_kind(value) when is_binary(value), do: "text"
  defp value_kind(value) when is_map(value), do: "object"
  defp value_kind(value) when is_list(value), do: "list"
  defp value_kind(value) when is_number(value), do: "number"
  defp value_kind(value) when is_boolean(value), do: "boolean"
  defp value_kind(_value), do: "value"

  defp value_size(value) when is_binary(value), do: byte_size(value)
  defp value_size(value) when is_map(value), do: map_size(value)
  defp value_size(value) when is_list(value), do: length(value)
  defp value_size(_value), do: 1

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)
end
