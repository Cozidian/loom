defmodule BeamAgent.RuntimeEventView do
  @moduledoc """
  Projects runtime events for audiences with different trust levels.

  The public view is deliberately fail-closed: new payload fields are redacted
  until they are explicitly classified as safe metadata. The internal view is
  the unchanged event used by trusted, in-process runtime clients.
  """

  @safe_scalar_keys MapSet.new(~w(
    access approval_id category child_session_id command_id compacted_count
    compaction_count context_fingerprint correlation_id count decision
    estimated_tokens fingerprint from goal_id index is_error language limit
    model name output_tokens parent_session_id policy previous project_id
    provider provider_profile recovered request_id request_version response_id retries root session_id
    step stream success task_type timeout to tool tool_call_id total_tokens turn type version
    window_tokens worker_id
  ))

  @safe_container_keys MapSet.new(~w(usage))

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
