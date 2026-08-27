defmodule BeamAgent.ModelUsage do
  @moduledoc "Provider-neutral token usage with the original numeric counters retained."

  def normalize(%{"provider_usage" => provider_usage} = usage) when is_map(provider_usage) do
    Map.take(usage, [
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "cached_tokens",
      "provider_usage"
    ])
  end

  def normalize(usage) when is_map(usage) do
    input =
      numeric(usage, [
        "input_tokens",
        :input_tokens,
        "prompt_tokens",
        :prompt_tokens,
        "prompt_eval_count",
        :prompt_eval_count
      ])

    output =
      numeric(usage, [
        "output_tokens",
        :output_tokens,
        "completion_tokens",
        :completion_tokens,
        "eval_count",
        :eval_count
      ])

    total = numeric(usage, ["total_tokens", :total_tokens]) || sum(input, output)

    cached =
      numeric(usage, [
        "cached_tokens",
        :cached_tokens,
        "cache_read_input_tokens",
        :cache_read_input_tokens
      ])

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => total,
      "cached_tokens" => cached,
      "provider_usage" => numeric_values(usage)
    }
  end

  def normalize(_usage), do: normalize(%{})

  defp numeric(map, keys) do
    Enum.find_value(keys, fn key ->
      case map[key] do
        value when is_number(value) -> value
        _value -> nil
      end
    end)
  end

  defp numeric_values(usage) do
    Map.new(usage, fn {key, value} ->
      {to_string(key), if(is_number(value), do: value, else: nil)}
    end)
  end

  defp sum(nil, nil), do: nil
  defp sum(input, output), do: (input || 0) + (output || 0)
end
