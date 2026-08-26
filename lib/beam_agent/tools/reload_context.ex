defmodule BeamAgent.Tools.ReloadContext do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Session.Context

  @impl true
  def name, do: "reload_context"

  @impl true
  def description,
    do: "Reload project instructions and skill metadata after changing their files."

  @impl true
  def input_schema, do: %{type: "object", properties: %{}}

  @impl true
  def access, do: :write

  @impl true
  def execute(arguments, context) when map_size(arguments) == 0 do
    with {:ok, summary} <- Context.reload(context.session_id) do
      {:ok, JSON.encode!(summary)}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_no_arguments}
end
