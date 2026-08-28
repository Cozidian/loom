defmodule BeamAgent.RoutingEvidence do
  @moduledoc """
  Pure, confidence-aware summaries over the durable outcome ledger.

  Evidence is confidence-gated. Only explicit model verification, or task
  verification that can be attributed to exactly one endpoint for a turn,
  contributes to model-quality comparisons.
  """

  @default_window_days 30
  @default_minimum_verified_samples 5
  @seconds_per_day 86_400

  def summarize(records, opts \\ []) when is_list(records) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    window_days = positive_integer(opts[:window_days], @default_window_days)

    minimum_verified_samples =
      positive_integer(opts[:minimum_verified_samples], @default_minimum_verified_samples)

    cutoff = DateTime.add(now, -window_days * @seconds_per_day, :second)
    task_type = text(opts[:task_type])
    language = text(opts[:language])
    requested_endpoint_ids = Enum.map(opts[:endpoint_ids] || [], &text/1)

    scoped = Enum.filter(records, &in_scope?(&1, cutoff, task_type, language))
    models = Enum.filter(scoped, &(text(value(&1, :kind)) == "model"))
    tasks = Enum.filter(scoped, &(text(value(&1, :kind)) == "task"))
    quality_samples = quality_samples(models, tasks, now, window_days)

    endpoint_ids =
      (requested_endpoint_ids ++ Enum.map(models, &text(value(&1, :endpoint_id))))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    endpoints =
      Enum.map(endpoint_ids, fn endpoint_id ->
        summarize_endpoint(
          endpoint_id,
          models,
          quality_samples,
          minimum_verified_samples
        )
      end)

    recommendation = recommendation(endpoints, minimum_verified_samples)

    Map.merge(recommendation, %{
      mode: "shadow",
      window_days: window_days,
      minimum_verified_samples: minimum_verified_samples,
      task_type: task_type,
      language: language,
      generated_at: DateTime.to_iso8601(now),
      endpoints: endpoints,
      best_verified_samples: endpoints |> Enum.map(& &1.verified_samples) |> Enum.max(fn -> 0 end)
    })
  end

  def offline_evaluation(records, opts \\ []) when is_list(records) and is_list(opts) do
    summary = summarize(records, opts)

    %{
      version: 1,
      state: summary.state,
      recommended_endpoint_id: summary.recommended_endpoint_id,
      eligible_endpoint_count: Enum.count(summary.endpoints, & &1.eligible),
      verified_sample_count: Enum.sum(Enum.map(summary.endpoints, & &1.verified_samples)),
      safe_to_enable: summary.state == "ready" and length(summary.endpoints) >= 2,
      summary: summary
    }
  end

  defp in_scope?(record, cutoff, task_type, language) do
    recent?(value(record, :recorded_at), cutoff) and
      matches?(text(value(record, :task_type)), task_type) and
      matches?(text(value(record, :language)), language)
  end

  defp quality_samples(models, tasks, now, window_days) do
    models_by_task = Enum.group_by(models, &task_key/1)

    explicit =
      Enum.flat_map(models, fn model ->
        case verification_status(model) do
          status when status in ["passed", "failed"] ->
            [sample(model, status, now, window_days, "model")]

          _other ->
            []
        end
      end)

    explicitly_verified_tasks = explicit |> Enum.map(& &1.task_key) |> MapSet.new()

    attributed =
      Enum.flat_map(tasks, fn task ->
        key = task_key(task)
        task_models = Map.get(models_by_task, key, [])
        endpoints = task_models |> Enum.map(&text(value(&1, :endpoint_id))) |> Enum.uniq()

        case {verification_status(task), endpoints,
              MapSet.member?(explicitly_verified_tasks, key)} do
          {status, [endpoint_id], false} when status in ["passed", "failed"] ->
            [
              %{
                endpoint_id: endpoint_id,
                status: status,
                task_key: key,
                source: "task_turn",
                weight: recency_weight(task, now, window_days)
              }
            ]

          _other ->
            []
        end
      end)

    explicit ++ attributed
  end

  defp sample(record, status, now, window_days, source) do
    %{
      endpoint_id: text(value(record, :endpoint_id)),
      status: status,
      task_key: task_key(record),
      source: source,
      weight: recency_weight(record, now, window_days)
    }
  end

  defp summarize_endpoint(endpoint_id, models, quality_samples, minimum) do
    operational = Enum.filter(models, &(text(value(&1, :endpoint_id)) == endpoint_id))
    quality = Enum.filter(quality_samples, &(&1.endpoint_id == endpoint_id))
    operational_samples = length(operational)
    operational_successes = Enum.count(operational, &(text(value(&1, :status)) == "succeeded"))
    verified_samples = length(quality)
    verified_passes = Enum.count(quality, &(&1.status == "passed"))
    weighted_total = Enum.sum(Enum.map(quality, & &1.weight))

    weighted_passes =
      quality |> Enum.filter(&(&1.status == "passed")) |> Enum.map(& &1.weight) |> Enum.sum()

    %{
      endpoint_id: endpoint_id,
      operational_samples: operational_samples,
      operational_successes: operational_successes,
      operational_success_rate: rate(operational_successes, operational_samples),
      average_latency_ms: average_latency(operational),
      verified_samples: verified_samples,
      verified_passes: verified_passes,
      verified_pass_rate: rate(verified_passes, verified_samples),
      recency_weighted_pass_rate: weighted_rate(weighted_passes, weighted_total),
      quality_lower_bound: wilson_lower_bound(verified_passes, verified_samples),
      confidence: min(1.0, verified_samples / minimum) |> rounded(),
      eligible: verified_samples >= minimum
    }
  end

  defp recommendation(endpoints, minimum) do
    eligible = Enum.filter(endpoints, & &1.eligible)

    if length(eligible) >= 2 do
      selected =
        Enum.max_by(eligible, fn endpoint ->
          {
            endpoint.recency_weighted_pass_rate || 0.0,
            endpoint.quality_lower_bound || 0.0,
            endpoint.operational_success_rate || 0.0,
            -(endpoint.average_latency_ms || 9_999_999)
          }
        end)

      %{
        state: "ready",
        recommended_endpoint_id: selected.endpoint_id,
        reason:
          "shadow recommendation from recent verified outcomes; deterministic policy remains authoritative"
      }
    else
      %{
        state: "insufficient_evidence",
        recommended_endpoint_id: nil,
        reason: "need at least two endpoints with #{minimum} recent verified samples each"
      }
    end
  end

  defp task_key(record), do: {value(record, :session_id), value(record, :turn)}

  defp verification_status(record) do
    record |> value(:verification) |> value(:status) |> text()
  end

  defp recent?(recorded_at, cutoff) when is_binary(recorded_at) do
    case DateTime.from_iso8601(recorded_at) do
      {:ok, at, _offset} -> DateTime.compare(at, cutoff) != :lt
      _error -> false
    end
  end

  defp recent?(_recorded_at, _cutoff), do: false

  defp recency_weight(record, now, window_days) do
    half_life_days = max(window_days / 2, 1)

    case DateTime.from_iso8601(value(record, :recorded_at) || "") do
      {:ok, at, _offset} ->
        age_days = max(DateTime.diff(now, at, :second), 0) / @seconds_per_day
        :math.pow(0.5, age_days / half_life_days)

      _error ->
        0.0
    end
  end

  defp average_latency(records) do
    values = records |> Enum.map(&value(&1, :latency_ms)) |> Enum.filter(&is_number/1)

    case values do
      [] -> nil
      values -> round(Enum.sum(values) / length(values))
    end
  end

  defp rate(_numerator, 0), do: nil
  defp rate(numerator, denominator), do: rounded(numerator / denominator)
  defp weighted_rate(_numerator, denominator) when denominator == 0, do: nil
  defp weighted_rate(numerator, denominator), do: rounded(numerator / denominator)

  defp wilson_lower_bound(_passes, 0), do: nil

  defp wilson_lower_bound(passes, samples) do
    z = 1.96
    observed = passes / samples
    denominator = 1 + z * z / samples
    centre = observed + z * z / (2 * samples)
    margin = z * :math.sqrt((observed * (1 - observed) + z * z / (4 * samples)) / samples)
    rounded((centre - margin) / denominator)
  end

  defp rounded(value), do: Float.round(value * 1.0, 4)
  defp matches?(_actual, nil), do: true
  defp matches?(actual, expected), do: actual == expected

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_value, _key), do: nil

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: value
end
