defmodule BeamAgent.TaskClassifier do
  @moduledoc "Deterministic, inspectable classification inputs for model routing."

  def classify(prompt, workspace_root \\ nil) when is_binary(prompt) do
    text = String.downcase(prompt)

    %{
      task_type: task_type(text),
      language: language(text, workspace_root),
      reasoning: reasoning(text),
      deterministic_answer: arithmetic(prompt)
    }
  end

  defp task_type(text) do
    cond do
      String.contains?(text, ["subagent", "delegate", "plan and implement"]) ->
        :orchestration

      String.contains?(text, ["architecture", "design decision", "tradeoff"]) ->
        :architecture

      Regex.match?(~r/\b(?:implement|change|edit|fix)\b|\bwrite\s+code\b/u, text) ->
        :implementation

      String.contains?(text, ["debug", "bug", "failing", "error"]) ->
        :debugging

      String.contains?(text, ["test", "verify", "review"]) ->
        :verification

      arithmetic(text) != nil ->
        :deterministic

      String.length(text) < 180 ->
        :simple

      true ->
        :general
    end
  end

  defp reasoning(text) do
    if String.contains?(text, ["architecture", "difficult", "complex", "root cause"]),
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
    case Regex.run(~r/^\s*(-?\d+(?:\.\d+)?)\s*([+\-*\/])\s*(-?\d+(?:\.\d+)?)\s*\??\s*$/, prompt) do
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
