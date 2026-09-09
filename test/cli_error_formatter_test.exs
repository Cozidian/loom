defmodule BeamAgent.CLI.ErrorFormatterTest do
  use ExUnit.Case, async: true
  alias BeamAgent.CLI.{ErrorFormatter, TUI}

  test "unwraps nested Codex JSON errors at the shared frontend boundary" do
    message = "The 'gpt-5.4' model is not supported when using Codex with a ChatGPT account."

    nested =
      JSON.encode!(%{"error" => %{"type" => "invalid_request_error", "message" => message}})

    cause =
      {:codex_app_server_error, %{"error" => %{"message" => nested}, "threadId" => "private-id"}}

    payload = TUI.notification_payload({:turn_finished, {:error, cause}})
    assert payload.error =~ message
    assert payload.error =~ "--model MODEL"
    refute payload.error =~ "threadId"
    refute payload.error =~ "\\\""
  end

  test "unavailable model is actionable and unknown errors keep a diagnostic fallback" do
    assert ErrorFormatter.format({:chatgpt_model_unavailable, "old", ["first", "second"]}) =~
             "Available models: first, second"

    assert ErrorFormatter.format({:codex_app_server_error, %{"message" => "{broken"}}) ==
             "Codex provider: {broken"

    assert ErrorFormatter.format(:other_error) == ":other_error"
  end
end
