defmodule BeamAgent.Tools.SubagentStatus do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "subagent_status"

  @impl true
  def description, do: "Inspect one background subagent without waiting for it to finish."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{delegation_id: %{type: "string"}},
      required: ["delegation_id"]
    }
  end

  @impl true
  def access, do: :delegate

  @impl true
  def execute(%{"delegation_id" => id}, context) when is_binary(id) do
    case BeamAgent.worker_status(context.goal_id, id) do
      {:ok, delegation} ->
        {:ok,
         JSON.encode!(%{
           delegation_id: delegation.id,
           child_session_id: delegation.worker_id,
           status: delegation.status,
           result_status: delegation.result && delegation.result.status
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_delegation_id}
end
