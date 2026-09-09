defmodule BeamAgent.CLI.ErrorFormatter do
  @moduledoc false

  # Presentation only: the runtime continues to retain the original error term.
  def format({:chatgpt_model_unavailable, model, available}) do
    "ChatGPT model #{inspect(model)} is not in the installed Codex model catalogue.\n" <>
      "Available models: #{Enum.join(available, ", ")}\n" <>
      "Restart with --model MODEL or update this provider profile. No replacement was selected."
  end

  def format({:codex_app_server_error, error}), do: codex_error(error)
  def format({:codex_turn_failed, _status, error}), do: codex_error(error)
  def format(%BeamAgent.ModelError{cause: cause}), do: format(cause)
  def format(reason), do: inspect(reason, pretty: true, limit: 8)

  defp codex_error(error) do
    case message(error, 0) do
      nil ->
        "Codex provider error: " <> inspect(error, pretty: true, limit: 8)

      text ->
        guidance =
          if String.contains?(text, "not supported") and String.contains?(text, "ChatGPT") do
            "\nThe configured model was rejected by this ChatGPT login. Check the installed Codex " <>
              "model catalogue, then restart with --model MODEL or update the provider profile."
          else
            ""
          end

        "Codex provider: " <> text <> guidance
    end
  end

  defp message(_value, depth) when depth > 6, do: nil
  defp message(%{"error" => error}, depth) when is_map(error), do: message(error, depth + 1)
  defp message(%{"message" => text}, depth), do: message(text, depth + 1)

  defp message(text, depth) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, decoded} when is_map(decoded) -> message(decoded, depth + 1) || text
      _other -> text
    end
  end

  defp message(_value, _depth), do: nil
end
