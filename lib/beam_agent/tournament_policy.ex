defmodule BeamAgent.TournamentPolicy do
  @moduledoc """
  Runtime-owned decision for a quality tournament.

  Users specify goals and may explicitly request a provider tournament. Intelligence
  does not start tournaments on its own. This policy decides when competing attempts
  at the *same* outcome are justified, then `Goal.Tournament` executes them.
  Heterogeneous work still belongs to delegation, not a tournament.
  """

  alias BeamAgent.Goal.BudgetManager

  @maximum_candidates 4
  @minimum_candidates 2
  @default_slots 4

  @counts %{
    "two" => 2,
    "three" => 3,
    "four" => 4,
    "2" => 2,
    "3" => 3,
    "4" => 4
  }

  @exclusive_markers [
    "winner",
    "keep only",
    "pick one",
    "pick the",
    "exactly one",
    "single winner",
    "do not merge",
    "don't merge",
    "never merge",
    "best of"
  ]

  @competition_markers [
    "competing",
    "independently",
    "independent versions",
    "independent attempts",
    "alternatives",
    "candidates",
    "versions of the same",
    "tournament"
  ]

  @anti_markers [
    "delegate",
    "specialist",
    "different jobs",
    "writers' room",
    "writers room",
    "depends on",
    "subagent",
    "plan and implement"
  ]

  def consider(prompt, context) when is_binary(prompt) and is_map(context) do
    text = String.downcase(prompt)

    cond do
      not root?(context) ->
        :skip

      anti?(text) ->
        :skip

      not tournament_shaped?(text) ->
        :skip

      true ->
        slots = available_slots(context)

        if slots < @minimum_candidates do
          :skip
        else
          build_plan(prompt, text, slots)
        end
    end
  end

  def consider(_prompt, _context), do: :skip

  defp build_plan(prompt, text, slots) do
    goal = user_request(prompt)
    approaches = approaches(text)
    count = candidate_count(text, approaches, slots)

    candidates =
      1..count
      |> Enum.zip(extend_approaches(approaches, count))
      |> Enum.map(fn {index, approach} ->
        %{
          id: "candidate-#{index}",
          goal: goal,
          role: role(approach),
          instructions: instructions(approach)
        }
      end)

    {:tournament,
     %{
       justification: justification(count),
       reason: "competing attempts at one outcome; pick a winner, never merge",
       candidates: candidates
     }}
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

  defp tournament_shaped?(text),
    do: contains_any?(text, @exclusive_markers) and contains_any?(text, @competition_markers)

  defp anti?(text), do: contains_any?(text, @anti_markers)

  defp contains_any?(text, markers), do: Enum.any?(markers, &String.contains?(text, &1))

  defp approaches(text) do
    captured =
      Regex.scan(~r/\(([^)]+)\)/, text)
      |> Enum.flat_map(fn [_, inner] -> split_approaches(inner) end)
      |> Enum.uniq()

    if length(captured) in @minimum_candidates..@maximum_candidates, do: captured, else: []
  end

  defp split_approaches(inner) do
    inner
    |> String.split(~r/\s*(?:,|;|\/|\bor\b)\s*/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.length(&1) > 48))
  end

  defp candidate_count(text, approaches, slots) do
    requested =
      cond do
        approaches != [] -> length(approaches)
        count = counted(text) -> count
        true -> @minimum_candidates
      end

    requested
    |> min(@maximum_candidates)
    |> min(slots)
    |> max(@minimum_candidates)
  end

  defp counted(text) do
    case Regex.run(
           ~r/\b(two|three|four|2|3|4)\s+(competing|independent|versions|candidates|approaches|alternatives)\b/,
           text
         ) do
      [_, word, _kind] -> Map.fetch!(@counts, word)
      _other -> nil
    end
  end

  defp extend_approaches([], count), do: List.duplicate(nil, count)

  defp extend_approaches(approaches, count) do
    approaches
    |> Stream.cycle()
    |> Enum.take(count)
  end

  defp role(nil), do: "Tournament candidate"
  defp role(approach), do: "Tournament candidate (#{approach})"

  defp instructions(nil) do
    [
      "Attempt this goal independently.",
      "Do not delegate to subagents; you are the provider attempt being compared.",
      "Return one complete attempt, not a list or comparison."
    ]
  end

  defp instructions(approach) do
    [
      "Use only the #{approach} approach.",
      "Do not delegate to subagents; you are the provider attempt being compared.",
      "Return one complete attempt, not a list or comparison.",
      "Do not consider other candidates."
    ]
  end

  defp justification(count) do
    "Runtime tournament of #{count} independent attempts at one outcome; select a winner, never merge"
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

    case limit do
      :infinity -> @default_slots
      n when is_integer(n) -> max(n - active, 0)
      _other -> @default_slots
    end
  end
end
