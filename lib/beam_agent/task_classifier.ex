defmodule BeamAgent.TaskClassifier do
  @moduledoc "Deterministic, inspectable classification inputs for model routing."

  def classify(prompt, workspace_root \\ nil) when is_binary(prompt) do
    text = String.downcase(prompt)
    deterministic_answer = arithmetic(prompt)

    %{
      task_type: task_type(text, deterministic_answer),
      language: language(text, workspace_root),
      reasoning: reasoning(text),
      change_intent: is_nil(deterministic_answer) and change_intent?(text),
      source: :runtime_rules,
      deterministic_answer: deterministic_answer
    }
  end

  defp task_type(text, deterministic_answer) do
    cond do
      String.contains?(text, ["subagent", "delegate", "plan and implement"]) ->
        :orchestration

      String.contains?(text, ["architecture", "design decision", "tradeoff"]) ->
        :architecture

      deterministic_answer != nil ->
        :deterministic

      change_intent?(text) ->
        :implementation

      String.contains?(text, ["debug", "bug", "failing", "error"]) ->
        :debugging

      String.contains?(text, ["test", "verify", "review"]) ->
        :verification

      String.length(text) < 180 ->
        :simple

      true ->
        :general
    end
  end

  defp change_intent?(text) do
    explicit_change? =
      Regex.match?(
        ~r/\b(?:implement|change|edit|fix|refactor|migrate)\b|\bwrite\s+code\b|\bdelegate\b.{0,80}\bimplementation\b/u,
        text
      )

    requested_construction? =
      Regex.match?(
        ~r/(?:\A|\b(?:please|lets|let's|should|must|need\s+to|want\s+to|can\s+you|could\s+you|go\s+ahead\s+and)\s+)(?:build|create|add|integrate|scaffold|wire|update|upgrade|remove|rename|replace)\b/u,
        text
      )

    document_fill? =
      Regex.match?(~r/\bfill\s+(?:in\s+|out\s+)?/u, text) and
        String.contains?(text, ["document", ".docx", "template", "ros analysis"])

    explicit_change? or requested_construction? or document_fill?
  end

  defp reasoning(text) do
    if String.contains?(text, [
         "architecture",
         "difficult",
         "complex",
         "root cause",
         "end-to-end",
         "web version",
         "web application",
         "frontend",
         "phoenix",
         "integrate"
       ]),
       do: :high,
       else: :standard
  end

  defp language(text, workspace_root) do
    cond do
      String.contains?(text, ["elixir", ".ex", "otp", "genserver"]) -> :elixir
      String.contains?(text, ["typescript", ".ts", ".tsx"]) -> :typescript
      String.contains?(text, ["python", ".py"]) -> :python
      is_binary(workspace_root) and File.exists?(Path.join(workspace_root, "mix.exs")) -> :elixir
      true -> :unknown
    end
  end

  def arithmetic(prompt) do
    case Regex.run(
           ~r/^\s*(?:(?:add|calculate|compute)\s+)?(-?\d+(?:\.\d+)?)\s*([+\-*\/])\s*(-?\d+(?:\.\d+)?)\s*\??\s*$/iu,
           prompt
         ) do
      [_, left, operator, right] ->
        calculate(String.to_float(float(left)), operator, String.to_float(float(right)))

      _ ->
        nil
    end
  end

  defp float(number), do: if(String.contains?(number, "."), do: number, else: number <> ".0")
  defp calculate(left, "+", right), do: format(left + right)
  defp calculate(left, "-", right), do: format(left - right)
  defp calculate(left, "*", right), do: format(left * right)
  defp calculate(_left, "/", right) when right == 0.0, do: nil
  defp calculate(left, "/", right), do: format(left / right)
  defp format(number) when trunc(number) == number, do: Integer.to_string(trunc(number))
  defp format(number), do: Float.to_string(number)
end
