defmodule BeamAgent.ControlPlane.Conversation do
  @moduledoc "Bounded owner-facing conversation projection. Never includes tools, reasoning, or child-agent payloads."

  def new,
    do: %{
      messages: [],
      status: "idle",
      model: nil,
      provider: nil,
      started_at: nil,
      changed_files: [],
      verification: nil,
      review: nil
    }

  def consume(%{scope: %{root?: true}, durability: :durable} = event, state) do
    data = event.payload.data

    case to_string(event.payload.type) do
      "user_message" ->
        state
        |> Map.merge(%{
          status: "running",
          started_at: event.at,
          changed_files: [],
          verification: nil,
          review: nil
        })
        |> message(event, "user", data["content"])

      "assistant_message" ->
        message(state, event, "assistant", data["content"])

      "model_response_started" ->
        Map.merge(state, %{model: data["model"], provider: data["provider"], status: "running"})

      "worker_stall_suspected" ->
        %{state | status: "waiting_for_model"}

      "worker_progress_resumed" ->
        %{state | status: "running"}

      "verification_started" ->
        %{state | status: "verifying"}

      "implementation_review_started" ->
        %{state | status: "reviewing"}

      "turn_finished" ->
        %{state | status: if(data["reason"] == "completed", do: "completed", else: "stopped")}

      "goal_work_finished" ->
        Map.merge(state, %{
          status: data["status"] || "stopped",
          changed_files: Enum.take(data["changed_files"] || [], 100),
          verification: data["verification_status"],
          review: data["review_status"]
        })

      _ ->
        state
    end
  end

  def consume(_, state), do: state

  defp message(state, event, role, content) when is_binary(content) and content != "" do
    text = String.slice(content, 0, 16_000)

    entry = %{
      id: event.event_id,
      role: role,
      content: text,
      at: event.at,
      truncated: text != content
    }

    messages = Enum.reject(state.messages, &(&1.id == entry.id)) ++ [entry]
    %{state | messages: bound(Enum.take(messages, -24))}
  end

  defp message(state, _, _, _), do: state

  defp bound([_ | remaining] = messages) do
    if Enum.sum(Enum.map(messages, &byte_size(&1.content))) > 128_000,
      do: bound(remaining),
      else: messages
  end

  defp bound([]), do: []
end
