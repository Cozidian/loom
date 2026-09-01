defmodule BeamAgent.RacePolicy do
  @moduledoc "Runtime-owned opt-in policy for first-admissible provider races."

  alias BeamAgent.Goal.BudgetManager

  @default_slots 4

  def consider(prompt, context) when is_binary(prompt) and is_map(context) do
    text = String.downcase(prompt)

    if root?(context) and race_shaped?(text) do
      count = min(requested_count(text), available_slots(context))

      if count >= 2 do
        goal = user_request(prompt)

        {:race,
         %{
           justification:
             "First-admissible provider race of #{count} independent attempts; cancel all losers",
           reason: "first admissible terminal result wins; remaining workers are cancelled",
           candidates:
             Enum.map(1..count, fn index ->
               %{
                 id: "candidate-#{index}",
                 goal: goal,
                 role: "Speed race candidate",
                 instructions: [
                   "Solve the request independently and return a complete terminal answer.",
                   "Do not delegate to subagents; you are one lane in a provider race.",
                   "The first admissible completion wins and the runtime cancels the other lanes."
                 ]
               }
             end)
         }}
      else
        :skip
      end
    else
      :skip
    end
  end

  def consider(_prompt, _context), do: :skip

  defp race_shaped?(text) do
    String.contains?(text, "provider race") and
      Enum.any?(
        ["first admissible", "first valid", "first to finish"],
        &String.contains?(text, &1)
      )
  end

  defp requested_count(text) do
    cond do
      Regex.match?(~r/\b(?:three|3)\b/, text) -> 3
      Regex.match?(~r/\b(?:four|4)\b/, text) -> 4
      true -> 2
    end
  end

  defp root?(context), do: context[:parent_session_id] in [nil, ""]

  defp user_request(prompt) do
    case Regex.run(~r/(?:^|\n)\s*User request:\s*\n(?<request>[\s\S]+)\z/u, prompt,
           capture: ["request"]
         ) do
      [request] -> String.trim(request)
      _other -> prompt
    end
  end

  defp available_slots(context) do
    case context[:goal_id] do
      id when is_binary(id) ->
        case BudgetManager.snapshot(id) do
          {:ok, snapshot} -> remaining_worker_slots(snapshot)
          _other -> @default_slots
        end

      _other ->
        @default_slots
    end
  end

  defp remaining_worker_slots(snapshot) do
    root = Enum.find(snapshot.allocations, &is_nil(&1.parent_allocation_id))
    limit = root && root.limits.concurrent_workers

    active =
      Enum.count(snapshot.allocations, fn allocation ->
        allocation.parent_allocation_id != nil and allocation.status in [:active, :reserved]
      end)

    if is_integer(limit), do: max(limit - active, 0), else: @default_slots
  end
end
