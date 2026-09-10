defmodule BeamAgent.Evaluation.Usage do
  @moduledoc "Usage coverage for evaluation reports; absent provider counters are not zero cost."

  def summarize(events) do
    calls = Enum.count(events, &(type(&1) == "model_response_started"))

    reported =
      events
      |> Enum.filter(&(type(&1) == "model_response_finished"))
      |> Enum.map(fn event ->
        data = data(event)
        usage = data["usage"] || data[:usage] || %{}
        usage["total_tokens"] || usage[:total_tokens]
      end)
      |> Enum.filter(&(is_number(&1) and &1 >= 0))

    aggregate([
      %{
        model_calls: calls,
        usage_reported_calls: length(reported),
        reported_tokens: Enum.sum(reported)
      }
    ])
  end

  def aggregate(metrics) do
    calls = Enum.sum(Enum.map(metrics, & &1.model_calls))
    reported = Enum.sum(Enum.map(metrics, & &1.usage_reported_calls))
    tokens = Enum.sum(Enum.map(metrics, & &1.reported_tokens))
    unavailable = Enum.sum(Enum.map(metrics, &Map.get(&1, :usage_unavailable_runs, 0)))
    missing = max(calls - reported, 0)

    %{
      total_tokens: if(missing == 0 and unavailable == 0, do: tokens, else: nil),
      reported_tokens: tokens,
      usage_reported_calls: reported,
      usage_missing_calls: missing,
      usage_unavailable_runs: unavailable,
      usage_status:
        cond do
          unavailable > 0 and reported == 0 -> :unknown
          unavailable > 0 -> :partial
          calls == 0 -> :not_applicable
          missing == 0 -> :complete
          reported == 0 -> :unknown
          true -> :partial
        end
    }
  end

  defp type(%{payload: %{type: type}}), do: to_string(type)
  defp type(%{"payload" => %{"type" => type}}), do: to_string(type)
  defp type(%{type: type}), do: to_string(type)
  defp type(%{"type" => type}), do: to_string(type)
  defp type(_event), do: "unknown"
  defp data(%{payload: %{data: data}}), do: data
  defp data(%{"payload" => %{"data" => data}}), do: data
  defp data(%{data: data}), do: data
  defp data(%{"data" => data}), do: data
end
