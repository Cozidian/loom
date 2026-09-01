defmodule BeamAgent.Tools.AwaitSubagent do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "await_subagent"

  @impl true
  def description,
    do:
      "Await a background subagent result by delegation handle. Other background workers continue concurrently."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        delegation_id: %{type: "string"},
        timeout_ms: %{type: "integer", minimum: 0, maximum: 120_000}
      },
      required: ["delegation_id"]
    }
  end

  @impl true
  def access, do: :delegate

  @impl true
  def execute(%{"delegation_id" => id} = arguments, context) when is_binary(id) do
    timeout_ms = Map.get(arguments, "timeout_ms", 120_000)

    if is_integer(timeout_ms) and timeout_ms in 0..120_000 do
      case BeamAgent.await_delegation(context.goal_id, id, timeout_ms) do
        {:ok, result} ->
          {:ok,
           JSON.encode!(%{
             delegation_id: result.delegation_id,
             child_session_id: result.worker_id,
             status: result.status,
             answer: result.content,
             verification: result.verification
           })}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_await_timeout}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_delegation_id}
end
