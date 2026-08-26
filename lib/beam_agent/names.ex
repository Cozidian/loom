defmodule BeamAgent.Names do
  @moduledoc false

  def via(kind, id), do: {:via, Registry, {BeamAgent.Registry, {kind, id}}}

  def lookup(kind, id) do
    case Registry.lookup(BeamAgent.Registry, {kind, id}) do
      [{pid, value}] -> {:ok, pid, value}
      [] -> :error
    end
  end

  def pid(kind, id) do
    case lookup(kind, id) do
      {:ok, pid, _value} -> {:ok, pid}
      :error -> {:error, :not_found}
    end
  end
end
