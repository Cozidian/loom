defmodule BeamAgent.Tools.Add do
  @moduledoc false
  @behaviour BeamAgent.Tool

  @impl true
  def name, do: "add"

  @impl true
  def description, do: "Add two numbers."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{a: %{type: "number"}, b: %{type: "number"}},
      required: ["a", "b"]
    }
  end

  @impl true
  def access, do: :trusted

  @impl true
  def execute(%{"a" => a, "b" => b}, _context) when is_number(a) and is_number(b),
    do: {:ok, a + b}

  def execute(_arguments, _context), do: {:error, :expected_numeric_a_and_b}
end
