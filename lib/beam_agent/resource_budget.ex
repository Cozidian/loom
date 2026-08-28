defmodule BeamAgent.ResourceBudget do
  @moduledoc "Validated goal and worker resource-allocation values."

  @limits [
    :model_tokens,
    :wall_time_ms,
    :retries,
    :concurrent_workers,
    :shell_commands,
    :test_runs
  ]

  @defaults %{
    model_tokens: :infinity,
    wall_time_ms: :infinity,
    retries: 8,
    concurrent_workers: 4,
    shell_commands: :infinity,
    test_runs: :infinity
  }

  def root_allocation(goal_id, spec \\ %{}) when is_binary(goal_id) and is_map(spec) do
    %{
      allocation_id: "budget-root-#{goal_id}",
      worker_id: goal_id,
      parent_allocation_id: nil,
      limits: normalize_limits(spec, @defaults),
      usage: zero_usage(),
      status: :active
    }
  end

  def child_allocation(id, worker_id, parent, remaining, requested \\ %{}) do
    requested = if is_map(requested), do: requested, else: %{}

    limits =
      Map.new(@limits, fn key ->
        available = Map.fetch!(remaining, key)
        desired = value(requested, key, available)
        {key, narrow(desired, available)}
      end)
      |> Map.put(:concurrent_workers, 1)

    %{
      allocation_id: id,
      worker_id: worker_id,
      parent_allocation_id: parent.allocation_id,
      limits: limits,
      usage: zero_usage(),
      status: :reserved
    }
  end

  def remaining(allocation) do
    Map.new(@limits, fn key ->
      limit = allocation.limits[key]
      used = allocation.usage[key]
      {key, if(limit == :infinity, do: :infinity, else: max(limit - used, 0))}
    end)
  end

  def within?(allocation, consumption) do
    Enum.all?(consumption, fn {key, amount} ->
      key in @limits and non_negative?(amount) and
        fits?(allocation.limits[key], allocation.usage[key], amount)
    end)
  end

  def consume(allocation, consumption) do
    usage =
      Enum.reduce(consumption, allocation.usage, fn {key, amount}, usage ->
        Map.update!(usage, key, &(&1 + amount))
      end)

    %{allocation | usage: usage}
  end

  def public(allocation) do
    Map.take(allocation, [
      :allocation_id,
      :worker_id,
      :parent_allocation_id,
      :limits,
      :usage,
      :status
    ])
  end

  defp normalize_limits(spec, defaults) do
    Map.new(@limits, fn key ->
      value = value(spec, key, defaults[key])
      {key, normalize_limit(value, defaults[key])}
    end)
  end

  defp zero_usage, do: Map.new(@limits, &{&1, 0})

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))
  defp normalize_limit(:infinity, _default), do: :infinity
  defp normalize_limit("infinity", _default), do: :infinity
  defp normalize_limit(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_limit(_value, default), do: default
  defp non_negative?(value), do: is_integer(value) and value >= 0
  defp fits?(:infinity, _used, _amount), do: true
  defp fits?(limit, used, amount), do: used + amount <= limit
  defp narrow(:infinity, :infinity), do: :infinity
  defp narrow(:infinity, available), do: available
  defp narrow(value, :infinity) when is_integer(value) and value >= 0, do: value
  defp narrow(value, available) when is_integer(value) and value >= 0, do: min(value, available)
  defp narrow(_value, available), do: available
end
