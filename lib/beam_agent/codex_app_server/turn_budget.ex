defmodule BeamAgent.CodexAppServer.TurnBudget do
  @moduledoc false

  # Finite defaults apply to a native turn, which can include many host tools.
  @defaults [
    codex_turn_timeout_ms: 30 * 60 * 1_000,
    codex_max_turn_bytes: 16 * 1_024 * 1_024,
    codex_max_turn_messages: 100_000
  ]

  def new(options) do
    limits = Map.new(@defaults, fn {key, default} -> {key, positive(options, key, default)} end)

    %{
      deadline: now() + limits.codex_turn_timeout_ms,
      timeout_ms: limits.codex_turn_timeout_ms,
      max_bytes: limits.codex_max_turn_bytes,
      max_messages: limits.codex_max_turn_messages,
      bytes: 0,
      messages: 0
    }
  end

  def positive(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  def remaining(budget), do: max(budget.deadline - now(), 0)
  def timeout(budget), do: {:error, {:codex_turn_limit, :duration_ms, budget.timeout_ms}}

  def consume(budget, bytes, messages \\ 1) do
    budget = %{budget | bytes: budget.bytes + bytes, messages: budget.messages + messages}

    cond do
      remaining(budget) == 0 ->
        timeout(budget)

      budget.bytes > budget.max_bytes ->
        {:error, {:codex_turn_limit, :bytes, budget.max_bytes}}

      budget.messages > budget.max_messages ->
        {:error, {:codex_turn_limit, :messages, budget.max_messages}}

      true ->
        {:ok, budget}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
